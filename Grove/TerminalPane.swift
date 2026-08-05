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

/// A terminal per repo in the workspace, with a tab strip to pick between them.
struct TerminalPane: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace

  @State private var selected: String?

  var body: some View {
    VStack(spacing: 0) {
      tabStrip
      Divider()
      terminal
    }
    .background(Color(nsColor: .textBackgroundColor))
  }

  private var members: [WorkspaceMember] {
    workspace.members.filter { FileManager.default.fileExists(atPath: $0.url.path) }
  }

  private var current: WorkspaceMember? {
    members.first { $0.repoName == selected } ?? members.first
  }

  private var tabStrip: some View {
    HStack(spacing: 4) {
      ForEach(members) { member in
        Button {
          selected = member.repoName
        } label: {
          HStack(spacing: 5) {
            RepoSwatch(repo: member.repoName, size: 7)
            Text(member.repoName)
              .font(.caption)
            // A filled dot means a shell is alive in there, which matters when
            // deciding whether closing the pane will interrupt something.
            if model.terminals.isRunning(member) {
              Circle()
                .fill(.green)
                .frame(width: 5, height: 5)
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            member.repoName == current?.repoName ? Color.accentColor.opacity(0.25) : .clear,
            in: Capsule()
          )
        }
        .buttonStyle(.plain)
      }

      Spacer()

      if let member = current, model.terminals.isRunning(member) {
        Button {
          model.terminals.close(member)
        } label: {
          Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .help("End the shell in \(member.repoName)")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var terminal: some View {
    if let member = current,
      let session = model.terminals.session(
        for: member, environment: model.toolPaths.processEnvironment())
    {
      // Identified by worktree so switching tabs swaps views rather than reusing
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
      Text("No worktree to open a shell in yet.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
