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
      } else {
        emptyDetail
      }
    }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showingCreate = true
        } label: {
          Label("New Workspace", systemImage: "plus")
        }
        .disabled(model.library.repos.isEmpty)
        .help(
          model.library.repos.isEmpty
            ? "Add a repo in Settings first" : "Create a workspace")
      }
      ToolbarItem {
        Button {
          Task { await model.rescan() }
        } label: {
          Label("Rescan", systemImage: "arrow.clockwise")
        }
        .disabled(model.isScanning)
      }
    }
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
      if model.workspaces.isEmpty, !model.isScanning {
        sidebarEmptyState
      }
    }
    .safeAreaInset(edge: .bottom) {
      HStack(spacing: 6) {
        if model.isScanning {
          ProgressView().controlSize(.small)
          Text("Scanning…")
        } else if model.isMeasuring {
          ProgressView().controlSize(.small)
          Text("Measuring… \(model.pendingMeasurements) left")
        } else {
          diskFooter
        }
        Spacer()
        SettingsLink {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.bar)
    }
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
          : "Press ⌘N to create one."
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

/// One row in the workspace sidebar.
///
/// The dots are the workspace's repos, one colour each, so its make-up reads at
/// a glance without opening it.
struct WorkspaceRow: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 3) {
        Text(workspace.name)
          .lineLimit(1)
        // No spacing: each swatch carries its own hover box, which supplies the gap.
        HStack(spacing: 0) {
          ForEach(workspace.members) { member in
            RepoSwatch(repo: member.repoName, size: 7)
          }
          if !workspace.file.branch.isEmpty {
            Text(workspace.file.branch)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
      }
      Spacer()
      if workspace.members.contains(where: \.hasUncommittedChanges) {
        Image(systemName: "pencil.circle.fill")
          .foregroundStyle(.orange)
          .help("Uncommitted changes")
      }
      if let size = model.sizes[workspace.url] {
        Text(size.formatted)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .help("Measured \(size.measuredAt.formatted(.relative(presentation: .named)))")
      }
    }
    .padding(.vertical, 2)
  }
}

extension View {
  /// Runs `action` when `name` is posted. Used for menu commands that need to
  /// reach into a view's sheet state.
  func onReceive(of name: Notification.Name, action: @escaping () -> Void) -> some View {
    onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
  }
}
