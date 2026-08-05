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

  /// Retained deliberately. See the note on this type.
  let view: LocalProcessTerminalView

  private let delegate = Delegate()

  init(worktree: URL, repoName: String, environment: [String: String], shell: String) {
    self.id = worktree.path
    self.worktree = worktree
    self.repoName = repoName
    self.view = LocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 400))

    delegate.session = self
    view.processDelegate = delegate

    // A login shell, so the user's own profile is what runs — the whole point is
    // that this behaves like their terminal.
    var variables = environment
    // Claude Code and anything else with a full-screen interface need to know the
    // terminal can do colour and cursor addressing.
    variables["TERM"] = "xterm-256color"
    variables["COLORTERM"] = "truecolor"
    // Programs that shell out to an editor should not open one inside themselves.
    variables.removeValue(forKey: "EDITOR")

    view.startProcess(
      executable: shell,
      args: ["-l"],
      environment: variables.map { "\($0.key)=\($0.value)" },
      execName: nil,
      currentDirectory: worktree.path
    )
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
      Task { @MainActor in session?.hasExited = true }
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

  /// The shell to run, from the user's own environment.
  private var loginShell: String {
    ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
  }

  func session(for member: WorkspaceMember, environment: [String: String]) -> TerminalSession? {
    guard FileManager.default.fileExists(atPath: member.url.path) else { return nil }
    if let existing = sessions[member.url.path], !existing.hasExited { return existing }

    let session = TerminalSession(
      worktree: member.url,
      repoName: member.repoName,
      environment: environment,
      shell: loginShell
    )
    sessions[member.url.path] = session
    return session
  }

  func existing(for member: WorkspaceMember) -> TerminalSession? {
    sessions[member.url.path]
  }

  func isRunning(_ member: WorkspaceMember) -> Bool {
    guard let session = sessions[member.url.path] else { return false }
    return !session.hasExited
  }

  func close(_ member: WorkspaceMember) {
    sessions.removeValue(forKey: member.url.path)?.terminate()
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
