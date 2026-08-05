import AppKit
import GroveCore
import SwiftTerm
import SwiftUI

/// Hands SwiftTerm's view to SwiftUI without letting SwiftUI own it.
///
/// `makeNSView` returns the session's existing view rather than building one, and
/// `updateNSView` does nothing. That is the whole trick: a rebuilt terminal is a
/// killed shell.
struct TerminalViewBridge: NSViewRepresentable {
  let session: TerminalSession

  func makeNSView(context: Context) -> LocalProcessTerminalView { session.view }
  func updateNSView(_ view: LocalProcessTerminalView, context: Context) {}
}

/// A terminal for the workspace and one per repo, with a tab strip to choose.
struct TerminalPane: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace
  /// Cleared when the last shell exits, so `exit` puts the window back.
  @Binding var showing: Bool

  /// Also in the model, so returning to a workspace lands on the tab you left.
  private var selected: String? {
    get { model.terminalTabs[workspace.url] }
    nonmutating set { model.terminalTabs[workspace.url] = newValue }
  }

  /// Somewhere a shell can run: the workspace itself, or one of its worktrees.
  private struct Target: Identifiable {
    let label: String
    let url: URL
    /// Repos carry their colour; the workspace root gets a folder icon instead.
    let repoName: String?
    var id: String { url.path }
  }

  private var targets: [Target] {
    // The workspace root first, since it is the sensible default for anything
    // touching more than one repo.
    var all = [Target(label: "workspace", url: workspace.url, repoName: nil)]
    all += workspace.members
      .filter { $0.state != .pending }
      .map { Target(label: $0.repoName, url: $0.url, repoName: $0.repoName) }
    return all
  }

  private var current: Target? {
    targets.first { $0.id == selected } ?? targets.first
  }

  var body: some View {
    VStack(spacing: 0) {
      tabStrip
      Divider()
      terminal
    }
    .background(Color(nsColor: .textBackgroundColor))
    .task(id: current?.id) {
      // Only on open or on picking a tab. Starting from the body would resurrect
      // a shell the moment it exited.
      guard let target = current else { return }
      // Opening a terminal, or picking a tab, means wanting to type in it.
      model.startTerminal(at: target.url)
    }
    .onChange(of: liveSessions) { _, live in
      // `exit` in the last tab means the pane has nothing left to show.
      if live == 0 { showing = false }
    }
  }

  /// How many of this workspace's tabs have a shell in them.
  private var liveSessions: Int {
    targets.count { model.terminals.isRunning(at: $0.url) }
  }

  private var tabStrip: some View {
    HStack(spacing: 4) {
      ForEach(targets) { target in
        Button {
          selected = target.id
        } label: {
          HStack(spacing: 5) {
            if let repo = target.repoName {
              RepoSwatch(repo: repo, size: 7)
            } else {
              Image(systemName: "folder")
                .font(.caption2)
            }
            Text(target.label)
              .font(.caption)
            // A filled dot means a shell is alive in there, which matters when
            // deciding whether closing it will interrupt something.
            if model.terminals.isRunning(at: target.url) {
              Circle()
                .fill(.green)
                .frame(width: 5, height: 5)
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            target.id == current?.id ? Color.accentColor.opacity(0.25) : .clear,
            in: Capsule()
          )
        }
        .buttonStyle(.plain)
      }

      Spacer()

      if let target = current, model.terminals.isRunning(at: target.url) {
        Button {
          model.terminals.close(at: target.url)
        } label: {
          Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .help("End the shell in \(target.label)")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var terminal: some View {
    if let target = current, let session = model.terminals.existing(at: target.url) {
      // Identified by directory so switching tabs swaps views rather than reusing
      // one and rewiring it.
      // Padded, with the gap filled by the terminal's own background so it reads
      // as breathing room inside the terminal rather than a border around it.
      TerminalViewBridge(session: session)
        .id(session.id)
        .padding(10)
        .background(Color(nsColor: session.view.nativeBackgroundColor))
    } else {
      // Reached after `exit` in a tab that is not the last one.
      Button("Start a shell here (⌘ + J)") {
        guard let target = current else { return }
        model.startTerminal(at: target.url)
      }
      .buttonStyle(.link)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
