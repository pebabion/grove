import AppKit
import GroveCore
import SwiftTerm
import SwiftUI

/// A live shell running in one worktree.
///
/// The `NSView` is created once and held here, not built in `makeNSView`.
/// SwiftUI rebuilds a representable's view whenever the surrounding state
/// changes, and a terminal cannot survive that: rebuilding it would kill the
/// shell — and with it whatever was running in it — every time a size measurement
/// arrived or a pull request badge updated.
@Observable
@MainActor
final class TerminalSession: Identifiable {
  let id: String
  let worktree: URL
  let repoName: String

  /// Reported by the shell through the title escape sequence. Useful: a program
  /// that sets it says what it is, so a busy session can be told from an idle one.
  var title: String = ""
  var hasExited = false

  /// Called once when the shell exits, so the owner can forget the session.
  /// Without this, `exit` left a dead view on screen and the next redraw started
  /// a replacement shell, which looked like nothing had happened.
  var onExit: (@MainActor () -> Void)?

  /// Retained deliberately. See the note on this type.
  let view: GroveTerminalView

  private let delegate = Delegate()

  init(
    worktree: URL, repoName: String, environment: [String: String], shell: String,
    font: NSFont
  ) {
    self.id = worktree.path
    self.worktree = worktree
    self.repoName = repoName
    self.view = GroveTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))
    self.view.font = font

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
      currentDirectory: worktree.path
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

/// Every live shell, keyed by the worktree it runs in.
///
/// Sessions outlive navigating away from a workspace: the point of a terminal is
/// that a dev server or an agent keeps running while you look at something else.
/// They do not outlive quitting Grove — that needs tmux, and pretending otherwise
/// would be a lie.
@Observable
@MainActor
final class TerminalSessions {
  private(set) var sessions: [String: TerminalSession] = [:]

  /// The shell to run. See ``UserShell`` for why the environment is not trusted.
  private var loginShell: String { UserShell.path }

  func existing(at directory: URL) -> TerminalSession? {
    guard let session = sessions[directory.path], !session.hasExited else { return nil }
    return session
  }

  /// Starts a shell in `directory`, or returns the one already there.
  ///
  /// Only ever called from an explicit action — opening the pane or picking a tab.
  /// Creating sessions from a view body meant a shell that had just exited was
  /// replaced on the very next redraw.
  @discardableResult
  func start(
    at directory: URL, label: String, environment: [String: String], font: NSFont
  ) -> TerminalSession? {
    guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
    if let existing = existing(at: directory) { return existing }

    let session = TerminalSession(
      worktree: directory,
      repoName: label,
      environment: environment,
      shell: loginShell,
      font: font
    )
    session.onExit = { [weak self] in
      self?.sessions.removeValue(forKey: directory.path)
    }
    sessions[directory.path] = session
    return session
  }

  func isRunning(at directory: URL) -> Bool {
    guard let session = sessions[directory.path] else { return false }
    return !session.hasExited
  }

  func close(at directory: URL) {
    sessions.removeValue(forKey: directory.path)?.terminate()
  }

  /// Ends every session inside a directory that is about to disappear.
  ///
  /// Removing a worktree while a shell sits in it leaves that shell with a
  /// deleted working directory, and anything it launched still running.
  func closeAll(under directory: URL) {
    let prefix = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
    for (path, session) in sessions where path == directory.path || path.hasPrefix(prefix) {
      session.terminate()
      sessions.removeValue(forKey: path)
    }
  }
}
