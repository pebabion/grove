import Combine
import GroveCore
import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @State private var showingCreate = false

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    } detail: {
      if let workspace = model.selectedWorkspace {
        WorkspaceDetail(workspace: workspace)
      } else if model.isScanning {
        // Scanning runs git in every worktree and takes seconds. Offering "New
        // Workspace" while that happens claims there is nothing to select, which
        // is wrong and reads badly straight after deleting one.
        VStack(spacing: 10) {
          ProgressView()
          Text("Reading worktrees…")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        emptyDetail
      }
    }
    // An explicit minimum is what lets the scene's .defaultSize take effect. With
    // no frame here a NavigationSplitView reports its own size and the window
    // adopts that instead, which is how .defaultSize came to be ignored.
    .frame(minWidth: 900, minHeight: 600)
    .sheet(isPresented: $showingCreate) {
      CreateWorkspaceSheet()
    }
    .sheet(
      item: Binding(get: { model.renameTarget }, set: { model.renameTarget = $0 })
    ) { workspace in
      RenameSheet(workspace: workspace)
    }
    .sheet(
      item: Binding(get: { model.teardownTarget }, set: { model.teardownTarget = $0 })
    ) { target in
      TeardownSheet(target: target)
    }
    .onReceive(of: .newWorkspace) {
      if !model.library.repos.isEmpty { showingCreate = true }
    }
    .alert(
      "Something went wrong",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
  }

  private var sidebar: some View {
    List(selection: Binding(get: { model.selection }, set: { model.selection = $0 })) {
      Section("Workspaces") {
        ForEach(model.workspaces) { workspace in
          WorkspaceRow(workspace: workspace)
            .tag(workspace.url)
            .contextMenu {
              WorkspaceActions(workspace: workspace)
            }
        }
      }
    }
    .overlay {
      if model.isFirstScan {
        VStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Scanning \(model.library.workspaceRoot)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
      } else if model.workspaces.isEmpty {
        sidebarEmptyState
      }
    }
    // Over the sidebar, not the detail pane: these act on the list of workspaces,
    // while Open, Terminal and the rest act on the one workspace being shown.
    .toolbar {
      ToolbarItemGroup(placement: .navigation) {
        Button {
          showingCreate = true
        } label: {
          Label("New Workspace", systemImage: "plus")
        }
        .disabled(model.library.repos.isEmpty)
        .help(
          model.library.repos.isEmpty ? "Add a repo in Settings first" : "New workspace (⌘ + N)")

        Button {
          Task { await model.rescan() }
        } label: {
          Label("Rescan", systemImage: "arrow.clockwise")
        }
        .disabled(model.isScanning)
        .help("Rescan every workspace (⌘ + R)")
      }
    }
    .safeAreaInset(edge: .bottom) {
      VStack(alignment: .leading, spacing: 8) {
        if let update = model.availableUpdate {
          UpdatePill(update: update)
        }
        footer
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.bar)
    }
  }

  private var footer: some View {
    HStack(spacing: 6) {
      Group {
        if let busy = model.busyLabel {
          ProgressView().controlSize(.small)
          Text(busy)
            .lineLimit(1)
            .truncationMode(.tail)
        } else if model.isScanning {
          ProgressView().controlSize(.small)
          Text("Scanning…")
        } else if model.isMeasuring {
          ProgressView().controlSize(.small)
          Text("Measuring… \(model.pendingMeasurements) left")
        } else {
          diskFooter
        }
      }
      Spacer()
      SettingsLink {
        Image(systemName: "gearshape")
      }
      .buttonStyle(.borderless)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  /// Either the measured total or an invitation to measure. Walking every file
  /// takes tens of seconds, so it is a button rather than something that happens
  /// by itself.
  @ViewBuilder
  private var diskFooter: some View {
    let total = model.knownTotal
    if total.bytes > 0 {
      Button {
        Task { await model.measureAll() }
      } label: {
        Text(
          total.complete
            ? total.bytes.formatted(.byteCount(style: .file))
            : "\(total.bytes.formatted(.byteCount(style: .file)))+ measured"
        )
      }
      .buttonStyle(.borderless)
      .help("Measure disk usage again")
    } else if !model.workspaces.isEmpty {
      Button("Measure disk usage") {
        Task { await model.measureAll() }
      }
      .buttonStyle(.borderless)
      .help("Walks every file, which takes a while")
    } else {
      Text(model.library.workspaceRoot)
        .lineLimit(1)
        .truncationMode(.head)
    }
  }

  private var sidebarEmptyState: some View {
    VStack(spacing: 6) {
      Text(model.library.repos.isEmpty ? "No repos yet" : "No workspaces yet")
        .font(.headline)
      Text(
        model.library.repos.isEmpty
          ? "Add repositories in Settings, then create a workspace."
          : "Press ⌘ + N to create one."
      )
      .font(.caption)
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
    }
    .padding(24)
  }

  private var emptyDetail: some View {
    VStack(spacing: 14) {
      Image(systemName: "tree")
        .font(.system(size: 40))
        .foregroundStyle(.tertiary)
      Text("Grove")
        .font(.title2.weight(.semibold))
      Text("A workspace holds one worktree per repo, all on the same branch.")
        .foregroundStyle(.secondary)

      if model.library.repos.isEmpty {
        SettingsLink {
          Text("Add your repos")
        }
        .buttonStyle(.borderedProminent)
      } else {
        Button("New Workspace…") { showingCreate = true }
          .buttonStyle(.borderedProminent)
      }
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

/// One row in the workspace sidebar: the workspace, then a line per repo.
///
/// Repos are listed rather than reduced to a row of dots because they are often
/// on different branches. A workspace holding four repos on four branches showed
/// only one of them under the old layout, which was worse than showing none.
struct WorkspaceRow: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(workspace.name)
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 6)
        if let size = model.sizes[workspace.url] {
          Text(size.formatted)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }

      if workspace.members.isEmpty {
        Text(workspace.file.branch.isEmpty ? "no repos on disk" : workspace.file.branch)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      } else {
        ForEach(workspace.members) { member in
          HStack(spacing: 5) {
            RepoSwatch(repo: member.repoName, size: 7)
            Text(member.repoName)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize()
            // Branches share long prefixes, so keep the distinctive tail.
            Text(member.branch ?? "detached")
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
              .truncationMode(.head)
            if member.hasUncommittedChanges {
              Image(systemName: "pencil.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
            }
          }
        }
      }

      sessionRows
    }
    .padding(.vertical, 3)
  }

  /// The workspace's live sessions, named by whatever is running in them.
  ///
  /// `claude --name session_1` sets the terminal title, which is where the name
  /// comes from — so a session announces itself rather than needing to be labelled.
  @ViewBuilder
  private var sessionRows: some View {
    let sessions = model.terminals.sessions(in: workspace.url)
    if !sessions.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(sessions) { session in
          Button {
            model.selection = workspace.url
            model.terminalWorkspaces.insert(workspace.url)
            model.selectSession(session)
          } label: {
            HStack(spacing: 5) {
              Image(systemName: "terminal")
                .font(.caption2)
                .foregroundStyle(.secondary)
              Text(session.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
              Spacer(minLength: 0)
              // A dot that outlasts the notification: notifications get missed, and
              // "which of these is waiting for me" is the question the sidebar
              // should answer on its own.
              if session.needsAttention {
                Circle()
                  .fill(Color.orange)
                  .frame(width: 6, height: 6)
              } else if session.isWorking {
                ProgressView()
                  .controlSize(.mini)
                  .scaleEffect(0.6)
                  .frame(width: 8, height: 8)
              }
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
            .foregroundStyle(
              model.activeSessions[workspace.url] == session.id ? .primary : .secondary)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.leading, 2)
      .padding(.top, 2)
    }
  }
}

extension View {
  /// Runs `action` when `name` is posted. Used for menu commands that need to
  /// reach into a view's sheet state.
  func onReceive(of name: Notification.Name, action: @escaping () -> Void) -> some View {
    onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
  }
}
