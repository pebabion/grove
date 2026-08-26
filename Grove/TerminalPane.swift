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

  private var current: TerminalSession? { model.activeSession(in: workspace) }

  private var filesShowing: Bool { model.fileWorkspaces.contains(workspace.url) }

  /// Puts the keyboard in the terminal when the terminal is what is on screen.
  ///
  /// Switching workspaces rebuilds this view, which is what makes `onAppear` the right
  /// hook: the keyboard follows the workspace rather than staying in the sidebar.
  private func takeKeyboard() {
    guard
      TerminalFocus.shouldTakeKeyboard(hasSession: current != nil, filesShowing: filesShowing)
    else { return }
    current?.focus()
  }

  var body: some View {
    VStack(spacing: 0) {
      tabStrip
      Divider().overlay(Theme.divider)
      terminal
    }
    // The strip belongs to the window, not to the terminal: the terminal keeps its own
    // background, which is a separate setting and deliberately neutral.
    .background(Theme.surface)
    // One session to begin with, in the workspace root — and only as this pane appears.
    //
    // Keyed on `sessions.isEmpty` it also fired when the LAST session ended, so typing
    // `exit` closed the shell and Grove immediately started another one, then hid the pane
    // because the count had reached zero. The log said it plainly: "workspace exited on its
    // own" followed at the same second by "watching progress reports". What was left was an
    // invisible shell, alive and running, with a row in the sidebar nobody could explain.
    .task {
      if sessions.isEmpty, !model.isCreating(workspace) {
        model.startSession(in: workspace, at: workspace.url)
      }
    }
    .onChange(of: sessions.count) { _, count in
      // Not while a session is waiting for the workspace to exist: closing then is what
      // made a terminal opened during creation look as though it had been killed.
      if count == 0, !model.isCreating(workspace) { showing = false }
    }
    // Coming on screen: switching workspace, opening the pane with ⌘ J, or a shell
    // arriving in a workspace that had none.
    .onAppear { takeKeyboard() }
    .onChange(of: current?.id) { _, _ in takeKeyboard() }
    // Closing the files pane hands the keyboard back rather than leaving it in a search
    // field that is no longer there.
    .onChange(of: filesShowing) { _, showing in
      if !showing { takeKeyboard() }
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
                .fill(Theme.warning)
                .frame(width: 5, height: 5)
            }
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            session.id == current?.id ? Theme.selection : .clear,
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
    } else if model.isCreating(workspace) {
      VStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Setting the workspace up first")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Button("Start a session (⌘ + J)") {
        model.startSession(in: workspace, at: workspace.url)
      }
      .buttonStyle(.link)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}
