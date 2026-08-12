import AppKit
import GroveCore
import SwiftTerm
import SwiftUI

/// A live shell belonging to a workspace.
///
/// The `NSView` is created once and held here, not built in `makeNSView`.
/// SwiftUI rebuilds a representable's view whenever the surrounding state
/// changes, and a terminal cannot survive that: rebuilding it would kill the
/// shell — and with it whatever was running in it — every time a size measurement
/// arrived or a pull request badge updated.
@Observable
@MainActor
final class TerminalSession: Identifiable {
  let id = UUID()
  /// The workspace this belongs under in the sidebar.
  let workspace: URL
  /// Where the shell was started.
  let directory: URL
  /// Shown until the program running says otherwise.
  let fallbackName: String

  /// How much history a session keeps.
  ///
  /// Twenty times SwiftTerm's default. Lines are only materialised as they are used,
  /// so the cost follows what a session actually prints rather than the cap.
  private static let scrollbackLines = 10_000

  /// Whatever the running program set the terminal title to.
  ///
  /// This is how a session gets its name: `claude --name session_1` sets the title
  /// to "✳ session_1", so the name the user chose arrives here without Grove having
  /// to be told separately.
  var title: String = ""
  var hasExited = false

  /// True from the moment the session asked for attention until the user looks at
  /// it. Drawn as a dot beside the session in the sidebar, so the signal survives a
  /// notification the user never saw.
  var needsAttention = false

  /// Whether the program is doing something right now, as it reports itself.
  var isWorking = false

  /// Called when the session wants the user, whoever is looking at what.
  /// Deciding whether that deserves a notification is the app model's job.
  var onSignal: (@MainActor (SessionSignal) -> Void)?

  private var monitor = SessionActivityMonitor()

  /// Called once when the shell exits, so the owner can forget the session.
  var onExit: (@MainActor () -> Void)?

  /// Retained deliberately. See the note on this type.
  let view: GroveTerminalView

  private let delegate = Delegate()

  /// The name to show: what the program calls itself, else where it is running.
  var displayName: String {
    let stripped = Self.strippingDecoration(title)
    return stripped.isEmpty ? fallbackName : stripped
  }

  /// Removes the status glyph and padding a TUI puts in front of its title.
  ///
  /// Claude Code writes "✳ session_1"; the glyph is decoration, the name is not.
  static func strippingDecoration(_ title: String) -> String {
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let scalars = cleaned.unicodeScalars.drop { scalar in
      !(CharacterSet.alphanumerics.contains(scalar) || scalar == "/" || scalar == "~")
    }
    return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
  }

  init(
    workspace: URL, directory: URL, fallbackName: String, environment: [String: String],
    shell: String, font: NSFont, foreground: NSColor, mouseReporting: Bool
  ) {
    self.workspace = workspace
    self.directory = directory
    self.fallbackName = fallbackName
    self.view = GroveTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
    self.view.font = font
    self.view.nativeForegroundColor = foreground
    // Off unless asked for. SwiftTerm discards the selection on every chunk of output
    // while this is on, whether or not a program ever asked for the mouse, so leaving
    // it on means text cannot be selected at all.
    self.view.allowMouseReporting = mouseReporting

    // SwiftTerm keeps 500 lines, which a long agent conversation passes in minutes,
    // and the top of it was being thrown away. Set before the process starts: the
    // buffer's capacity is fixed when the terminal is created, so this is the only way
    // in from outside the library, and it cannot bring back lines already discarded.
    self.view.terminal?.changeScrollback(Self.scrollbackLines)

    delegate.session = self
    view.processDelegate = delegate

    // A deliberate environment, not an inherited one. See TerminalEnvironment.
    let variables = TerminalEnvironment.build(
      from: environment,
      termProgram: "Grove",
      programVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    )

    view.startProcess(
      executable: shell,
      args: ["-l"],
      environment: variables.map { "\($0.key)=\($0.value)" },
      execName: nil,
      currentDirectory: directory.path
    )

    // After startProcess: the terminal these hang off does not exist before it.
    view.watchProgress()
    view.onOscNine = { [weak self] payload in self?.report(oscNine: payload) }
    view.onBell = { [weak self] in self?.signal(.rangBell) }
  }

  /// Reads a progress report and signals if the session has stopped working.
  private func report(oscNine payload: String) {
    guard let reported = SessionProgress.parse(oscNine: payload) else {
      Log.sessions.note("osc 9 not a progress report: \(payload)")
      return
    }
    let signal = monitor.received(reported, at: Date())
    isWorking = monitor.isWorking
    Log.sessions.note(
      "progress \(String(describing: reported)) -> signal \(String(describing: signal))"
    )
    if let signal { self.signal(signal) }
  }

  private func signal(_ signal: SessionSignal) {
    Log.sessions.note(
      "signal \(String(describing: signal)), handler attached: \(self.onSignal != nil)"
    )
    onSignal?(signal)
  }

  /// Puts the keyboard into this terminal.
  ///
  /// Retried briefly: the view has no window for the first frame or two after
  /// SwiftUI inserts it, and `makeFirstResponder` on a view with no window does
  /// nothing at all.
  func focus() {
    Task { @MainActor [weak self] in
      for _ in 0..<20 {
        guard let self else { return }
        if let window = view.window {
          window.makeFirstResponder(view)
          return
        }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }
  }

  func terminate() {
    guard !hasExited else { return }
    view.terminate()
    hasExited = true
  }

  /// SwiftTerm's delegate is a class reference, so it cannot be the observable
  /// session itself without a retain cycle through `processDelegate`.
  private final class Delegate: LocalProcessTerminalViewDelegate {
    weak var session: TerminalSession?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
      // Read the session out first. The delegate itself is not Sendable, so
      // capturing it in the Task would send `self` across isolation; the session
      // is a @MainActor class and so is Sendable.
      let session = session
      Task { @MainActor in session?.title = title }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
      let session = session
      Task { @MainActor in
        guard let session, !session.hasExited else { return }
        session.hasExited = true
        session.onExit?()
      }
    }
  }
}

/// Every live shell, in the order they were started.
///
/// A workspace can have several: one per agent, or one per repo, or both. They
/// outlive navigating away, which is the point — something long-running keeps going
/// while you look elsewhere. They do not outlive quitting Grove, and there is no
/// honest way to make them.
@Observable
@MainActor
final class TerminalSessions {
  private(set) var sessions: [TerminalSession] = []

  /// Called when any session wants attention. Set once, by the app model.
  var onSignal: (@MainActor (TerminalSession, SessionSignal) -> Void)?

  /// The shell to run. See ``UserShell`` for why the environment is not trusted.
  private var loginShell: String { UserShell.path }

  func sessions(in workspace: URL) -> [TerminalSession] {
    sessions.filter { $0.workspace == workspace && !$0.hasExited }
  }

  func session(id: UUID) -> TerminalSession? {
    sessions.first { $0.id == id && !$0.hasExited }
  }

  /// Starts a shell. Every call makes a new session, so one workspace can hold
  /// several at once.
  @discardableResult
  func start(
    in workspace: URL, directory: URL, fallbackName: String,
    environment: [String: String], font: NSFont, foreground: NSColor, mouseReporting: Bool
  ) -> TerminalSession? {
    guard FileManager.default.fileExists(atPath: directory.path) else {
      Log.sessions.problem("no session: \(directory.path) does not exist")
      return nil
    }

    let session = TerminalSession(
      workspace: workspace,
      directory: directory,
      fallbackName: fallbackName,
      environment: environment,
      shell: loginShell,
      font: font,
      foreground: foreground,
      mouseReporting: mouseReporting
    )
    session.onExit = { [weak self, id = session.id, name = fallbackName] in
      Log.sessions.note("\(name) exited on its own")
      self?.sessions.removeAll { $0.id == id }
    }
    // Weak on both sides: the session holds this closure, so capturing it strongly
    // would be a cycle and no session would ever be freed.
    session.onSignal = { [weak self, weak session] signal in
      guard let self, let session else { return }
      onSignal?(session, signal)
    }
    sessions.append(session)
    return session
  }

  func close(id: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
    Log.sessions.note("closing \(sessions[index].displayName) because it was asked for")
    sessions[index].terminate()
    sessions.remove(at: index)
  }

  /// Restyles every live shell.
  ///
  /// Setting the font on a running view is enough — SwiftTerm rebuilds its metrics
  /// and reports the new cell size to the PTY, so anything full-screen redraws to
  /// fit.
  func applyFont(_ font: NSFont) {
    for session in sessions { session.view.font = font }
  }

  func applyForeground(_ color: NSColor) {
    for session in sessions { session.view.nativeForegroundColor = color }
  }

  /// Changes it on the shells already running, so the setting takes effect without
  /// starting a new session.
  func applyMouseReporting(_ enabled: Bool) {
    for session in sessions { session.view.allowMouseReporting = enabled }
  }

  /// Ends every session inside a directory that is about to disappear.
  ///
  /// Removing a worktree while a shell sits in it leaves that shell with a
  /// deleted working directory, and anything it launched still running.
  func closeAll(under directory: URL) {
    let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
    for session in sessions
    where session.directory.path == directory.path || session.directory.path.hasPrefix(prefix) {
      Log.sessions.note("closing \(session.displayName): \(directory.lastPathComponent) is going")
      session.terminate()
    }
    sessions.removeAll {
      $0.directory.path == directory.path || $0.directory.path.hasPrefix(prefix)
    }
  }
}
