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
    .groveWindow()
    // The toolbar is part of the same surface as the sidebar under it. Left alone it draws
    // the system's own material, a lighter band across the top.
    .toolbarBackground(Theme.surface, for: .windowToolbar)
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
    // A List draws its own material, which has to be turned off before a colour of ours
    // can show through.
    .scrollContentBackground(.hidden)
    .background(Theme.surface.opacity(0.55))
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
      .background(Theme.surface)
      .overlay(alignment: .top) { Divider().overlay(Theme.divider) }
    }
  }

  private var footer: some View {
    HStack(spacing: 6) {
      Group {
        if let busy = model.busyLabel {
          // A bar when the work can say how far along it is, a spinner when it cannot.
          // A bar that fills at its own pace is a lie about progress.
          if let fraction = model.busyFraction {
            ProgressView(value: fraction)
              .progressViewStyle(.linear)
              .controlSize(.small)
              .frame(width: 90)
          } else {
            ProgressView().controlSize(.small)
          }
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

  /// The measured total, or the root while the first measurement is still running.
  ///
  /// No button to start it: measuring happens on its own, when a reading is missing or has
  /// gone stale. A control for something that already happens is a thing to wonder about.
  @ViewBuilder
  private var diskFooter: some View {
    let total = model.knownTotal
    if total.bytes > 0 {
      Text(
        total.complete
          ? total.bytes.formatted(.byteCount(style: .file))
          : "\(total.bytes.formatted(.byteCount(style: .file)))+"
      )
      .help(total.complete ? "Disk used by every workspace" : "Still measuring")
    } else {
      Text(model.library.workspaceRoot)
        .lineLimit(1)
        .truncationMode(.head)
    }
  }

  private var sidebarEmptyState: some View {
    VStack(spacing: 6) {
      Text(model.library.repos.isEmpty ? "No repos yet" : "Nothing in flight")
        .font(.headline)
      Text(
        model.library.repos.isEmpty
          ? "Grove needs to know where your clones are."
          : "\(model.library.repos.count) repos ready."
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
        .foregroundStyle(Theme.highlight.opacity(0.8))

      // This screen is where someone learns what the app is for, so it says it rather
      // than naming itself twice.
      Text(model.library.repos.isEmpty ? "Point Grove at a clone" : "Nothing in flight")
        .font(.title2.weight(.semibold))
      Text(
        model.library.repos.isEmpty
          ? "A workspace is one branch checked out across every repo it touches. Grove needs "
            + "to know where those repos live before it can make one."
          : "A new workspace cuts a branch in each repo you pick and installs what they need."
      )
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 380)

      if model.library.repos.isEmpty {
        SettingsLink {
          Text("Add a repo…")
        }
        .buttonStyle(ThemedButtonStyle(prominent: true))
      } else {
        HStack(spacing: 10) {
          Button("New workspace…") { showingCreate = true }
            .buttonStyle(ThemedButtonStyle(prominent: true))
          // Beside the button rather than instead of it: the shortcut is worth learning,
          // and a screen that only names a shortcut cannot be acted on with the mouse.
          HStack(spacing: 5) {
            Text("⌘ N")
              .font(.system(.caption2, design: .monospaced))
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(RoundedRectangle(cornerRadius: 4).fill(Theme.selection))
            Text("does the same")
              .font(.caption)
          }
          .foregroundStyle(.tertiary)
        }
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

  /// What the row prints: the branch once, and only the repos that are somewhere else.
  private var summary: WorkspaceSummary { WorkspaceSummary(workspace) }

  /// Whether any session in this workspace is waiting for a human.
  private var waiting: Bool {
    model.terminals.sessions(in: workspace.url).contains(where: \.needsAttention)
  }

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      // A workspace with a session waiting is the one thing worth finding while scanning a
      // column of rows, and a dot on a session line three lines down is not findable.
      RoundedRectangle(cornerRadius: 1)
        .fill(waiting ? Theme.warning : .clear)
        .frame(width: 2)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(workspace.name)
            .fontWeight(.medium)
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 6)
          if let size = model.sizes[workspace.url] {
            Text(size.formatted)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }

        if let branch = summary.sharedBranch {
          Text(branch)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        } else if workspace.members.isEmpty {
          Text("no repos on disk")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }

        if !workspace.members.isEmpty {
          HStack(spacing: 7) {
            HStack(spacing: 3) {
              ForEach(workspace.members) { member in
                RepoSwatch(repo: member.repoName, size: 7)
              }
            }
            Text("\(summary.repoCount) \(summary.repoCount == 1 ? "repo" : "repos")")
              .font(.caption)
              .foregroundStyle(.tertiary)
            if summary.dirtyCount > 0 {
              // Uncommitted work is what makes a workspace unsafe to remove, so it is
              // worth a count rather than a mark per repo.
              Label("\(summary.dirtyCount)", systemImage: "pencil")
                .font(.caption2)
                .foregroundStyle(Theme.warning)
            }
            if summary.failedCount > 0 {
              Label("\(summary.failedCount)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.danger)
            }
            Spacer(minLength: 0)
          }
        }

        // Only the repos that are not on the workspace's branch. Everything else is
        // covered by the line above, and printing it again is what made rows unreadable.
        ForEach(summary.divergent) { member in
          HStack(spacing: 5) {
            RepoSwatch(repo: member.repoName, size: 7)
            Text(member.repoName)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize()
            // Branches share long prefixes, so keep the distinctive tail.
            Text(member.branch ?? "detached")
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(Theme.warning)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }

        sessionRows
      }
    }
    .padding(.vertical, 3)
    // A selected row is drawn on a lighter ground, where the dimmest tier measures 3.8:1 —
    // under what body text needs. Promote it rather than brighten the tier everywhere:
    // `Palette.tiersOnSelection` says which ones are allowed here, and a test holds it.
    .foregroundStyle(Theme.title, Theme.detail, selected ? Theme.detail : Theme.faint)
  }

  private var selected: Bool { model.selection == workspace.url }

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
                  .fill(Theme.warning)
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
