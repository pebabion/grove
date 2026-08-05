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

  @State private var selected: String?

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
      .filter { FileManager.default.fileExists(atPath: $0.url.path) }
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
    if let target = current,
      let session = model.terminals.session(
        at: target.url, label: target.label,
        environment: model.toolPaths.processEnvironment())
    {
      // Identified by directory so switching tabs swaps views rather than reusing
      // one and rewiring it.
      TerminalViewBridge(session: session)
        .id(session.id)
        .overlay(alignment: .top) {
          if session.hasExited {
            Text("The shell exited. Close the tab to start another.")
              .font(.caption)
              .padding(6)
              .background(.thinMaterial, in: Capsule())
              .padding(.top, 6)
          }
        }
    } else {
      Text("No directory to open a shell in yet.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
