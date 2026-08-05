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

  /// Whatever the running program set the terminal title to.
  ///
  /// This is how a session gets its name: `claude --name session_1` sets the title
  /// to "✳ session_1", so the name the user chose arrives here without Grove having
  /// to be told separately.
  var title: String = ""
  var hasExited = false

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
    shell: String, font: NSFont, foreground: NSColor
  ) {
    self.workspace = workspace
    self.directory = directory
    self.fallbackName = fallbackName
    self.view = GroveTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
    self.view.font = font
    self.view.nativeForegroundColor = foreground

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
    environment: [String: String], font: NSFont, foreground: NSColor
  ) -> TerminalSession? {
    guard FileManager.default.fileExists(atPath: directory.path) else { return nil }

    let session = TerminalSession(
      workspace: workspace,
      directory: directory,
      fallbackName: fallbackName,
      environment: environment,
      shell: loginShell,
      font: font,
      foreground: foreground
    )
    session.onExit = { [weak self, id = session.id] in
      self?.sessions.removeAll { $0.id == id }
    }
    sessions.append(session)
    return session
  }

  func close(id: UUID) {
    guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
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

  /// Ends every session inside a directory that is about to disappear.
  ///
  /// Removing a worktree while a shell sits in it leaves that shell with a
  /// deleted working directory, and anything it launched still running.
  func closeAll(under directory: URL) {
    let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
    for session in sessions
    where session.directory.path == directory.path || session.directory.path.hasPrefix(prefix) {
      session.terminate()
    }
    sessions.removeAll {
      $0.directory.path == directory.path || $0.directory.path.hasPrefix(prefix)
    }
  }
}
