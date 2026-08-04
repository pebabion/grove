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
          WorkspaceRow(workspace: workspace).tag(workspace.url)
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
        } else {
          Text(model.library.workspaceRoot)
            .lineLimit(1)
            .truncationMode(.head)
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
struct WorkspaceRow: View {
  let workspace: Workspace

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(Palette.color(for: workspace.name))
        .frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 2) {
        Text(workspace.name)
          .lineLimit(1)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if workspace.members.contains(where: \.hasUncommittedChanges) {
        Image(systemName: "pencil.circle.fill")
          .foregroundStyle(.orange)
          .help("Uncommitted changes")
      }
    }
    .padding(.vertical, 2)
  }

  private var subtitle: String {
    let count = workspace.members.count
    let repos = count == 1 ? "1 repo" : "\(count) repos"
    return workspace.file.branch.isEmpty ? repos : "\(repos) · \(workspace.file.branch)"
  }
}

/// Stable per-workspace accent, hashed from the name.
///
/// cwt wrote these colours into each worktree's VS Code settings and kept a
/// counter in config to cycle them. Deriving from the name needs no stored
/// state and cannot drift.
enum Palette {
  private static let colors: [Color] = [
    .init(red: 0.18, green: 0.55, blue: 0.34),
    .init(red: 0.42, green: 0.35, blue: 0.80),
    .init(red: 0.80, green: 0.52, blue: 0.25),
    .init(red: 0.13, green: 0.59, blue: 0.64),
    .init(red: 0.75, green: 0.23, blue: 0.17),
    .init(red: 0.48, green: 0.41, blue: 0.68),
    .init(red: 0.23, green: 0.49, blue: 0.65),
    .init(red: 0.37, green: 0.46, blue: 0.43),
  ]

  static func color(for name: String) -> Color {
    var hash: UInt64 = 5381
    for byte in name.utf8 {
      hash = hash &* 33 &+ UInt64(byte)
    }
    return colors[Int(hash % UInt64(colors.count))]
  }
}

extension View {
  /// Runs `action` when `name` is posted. Used for menu commands that need to
  /// reach into a view's sheet state.
  func onReceive(of name: Notification.Name, action: @escaping () -> Void) -> some View {
    onReceive(NotificationCenter.default.publisher(for: name)) { _ in action() }
  }
}
