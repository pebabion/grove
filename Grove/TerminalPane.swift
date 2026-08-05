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

  func makeNSView(context: Context) -> GroveTerminalView { session.view }
  func updateNSView(_ view: GroveTerminalView, context: Context) {}
}

/// The workspace's sessions, with a tab each and a way to start more.
struct TerminalPane: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace
  /// Cleared when the last session ends, so `exit` puts the window back.
  @Binding var showing: Bool

  private var sessions: [TerminalSession] { model.terminals.sessions(in: workspace.url) }

  private var current: TerminalSession? {
    model.activeSession(in: workspace) ?? sessions.first
  }

  var body: some View {
    VStack(spacing: 0) {
      tabStrip
      Divider()
      terminal
    }
    .background(Color(nsColor: .textBackgroundColor))
    .task(id: sessions.isEmpty) {
      // One session to begin with, in the workspace root. Starting from the body
      // would resurrect a shell the moment it exited.
      if sessions.isEmpty { model.startSession(in: workspace, at: workspace.url) }
    }
    .onChange(of: sessions.count) { _, count in
      if count == 0 { showing = false }
    }
  }

  private var tabStrip: some View {
    HStack(spacing: 4) {
      ForEach(sessions) { session in
        Button {
          model.selectSession(session)
        } label: {
          HStack(spacing: 5) {
            RepoSwatch(repo: session.fallbackName, size: 7)
            Text(session.displayName)
              .font(.caption)
              .lineLimit(1)
            if session.needsAttention {
              Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            session.id == current?.id ? Color.accentColor.opacity(0.25) : .clear,
            in: Capsule()
          )
        }
        .buttonStyle(.plain)
        .help("Started in \(session.directory.lastPathComponent)")
      }

      // Where a session comes from: the workspace itself, or one of its repos.
      Menu {
        Button("Workspace") { model.startSession(in: workspace, at: workspace.url) }
        ForEach(workspace.members.filter { $0.state != .pending }) { member in
          Button(member.repoName) { model.startSession(in: workspace, at: member.url) }
        }
      } label: {
        Image(systemName: "plus")
          .font(.caption)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .help("Start another session")

      Spacer()

      if let session = current {
        Button {
          model.terminals.close(id: session.id)
        } label: {
          Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .help("End \(session.displayName)")
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }

  @ViewBuilder
  private var terminal: some View {
    if let session = current {
      // Padded, with the gap filled by the terminal's own background so it reads
      // as breathing room inside the terminal rather than a border around it.
      TerminalViewBridge(session: session)
        .id(session.id)
        .padding(10)
        .background(Color(nsColor: session.view.nativeBackgroundColor))
    } else {
      Button("Start a session (⌘ + J)") {
        model.startSession(in: workspace, at: workspace.url)
      }
      .buttonStyle(.link)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
