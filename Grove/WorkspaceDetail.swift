import GroveCore
import SwiftUI

struct WorkspaceDetail: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace

  @State private var expandedLogs: Set<String> = []
  @State private var hoveringSummary = false

  /// Both live in the model, so switching workspaces and coming back does not
  /// reset them. A running terminal that hides itself when you look away is worse
  /// than no terminal.
  private var showingTerminal: Bool {
    get { model.terminalWorkspaces.contains(workspace.url) }
    nonmutating set {
      if newValue {
        model.terminalWorkspaces.insert(workspace.url)
      } else {
        model.terminalWorkspaces.remove(workspace.url)
      }
    }
  }

  private var showingFiles: Bool {
    get { model.fileWorkspaces.contains(workspace.url) }
    nonmutating set {
      if newValue {
        model.fileWorkspaces.insert(workspace.url)
      } else {
        model.fileWorkspaces.remove(workspace.url)
      }
    }
  }

  private var showingDetails: Bool {
    get { !model.detailsCollapsed }
    nonmutating set { model.detailsCollapsed = !newValue }
  }

  var body: some View {
    VStack(spacing: 0) {
      // Always present, one line: which workspace this is and how to get the rest
      // back. The repo list below it is reference material — worth reading once,
      // then in the way of the terminal.
      summaryBar
      Divider()

      // Creating takes over the pane. There is nothing else to read here yet — the repo
      // list holds rows that say "waiting" — and setting up takes minutes, which is too
      // long to leave the window looking like nothing is happening.
      if model.isCreating(workspace) {
        WorkspaceProgress(workspace: workspace, job: .creating)
      } else if model.isRemoving(workspace) {
        WorkspaceProgress(workspace: workspace, job: .removing)
      } else if showingFiles {
        // Files take the place of the repo list rather than sitting over the window:
        // reading one is something you do while working, not instead of it.
        FileBrowser(workspace: workspace)
      } else if showingDetails {
        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            repoList
            addRepoSection
            // Part of the page rather than floating in whatever space was left over,
            // which put it adrift in the lower third of the window.
            if !showingTerminal {
              ShortcutGuide()
                .padding(.top, 12)
            }
          }
          .padding(24)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
      }

      if showingTerminal {
        // Draggable only when the two share the window. With nothing above it there is
        // no height to trade, so the terminal simply fills.
        if showingDetails || showingFiles {
          TerminalResizer(
            height: Binding(
              get: { model.terminalHeight },
              set: { model.terminalHeight = $0 }
            )
          )
          terminalPane.frame(height: model.terminalHeight)
        } else {
          terminalPane.frame(maxHeight: .infinity)
        }
      } else if !showingDetails, !showingFiles {
        Spacer()
      }

    }
    .navigationTitle(workspace.name)
    .onChange(of: showingTerminal) { _, opened in
      // Opening a terminal is a statement about what you want the window for.
      if opened { showingDetails = false }
    }
    .onChange(of: showingFiles) { _, opened in
      // Files and the repo list want the same space, so one hides the other. Without
      // this the disclosure row looks broken: it toggles something the files are
      // covering.
      if opened { showingDetails = false }
    }
    .toolbar {
      ToolbarItemGroup {
        Button {
          model.openInEditor(workspace.url)
        } label: {
          Label("Open", systemImage: "arrow.up.forward.app")
        }
        .help(
          model.editorName.map { "Open in \($0)" } ?? "Reveal in Finder — pick an app in Settings")

        Button {
          showingFiles.toggle()
        } label: {
          Label("Files", systemImage: "doc.text.magnifyingglass")
        }
        .help(showingFiles ? "Hide files (⌘ + P)" : "Find a file in this workspace (⌘ + P)")

        Button {
          showingTerminal.toggle()
        } label: {
          Label("Terminal", systemImage: "apple.terminal")
        }
        .disabled(model.isCreating(workspace))
        .help(
          model.isCreating(workspace)
            ? "Available once the workspace is set up"
            : (showingTerminal
              ? "Hide the terminal (⌘ + J)" : "Open a terminal in this workspace (⌘ + J)"))

        Menu {
          WorkspaceActions(workspace: workspace)
        } label: {
          Label("More", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
      }
    }
  }

  private var terminalPane: some View {
    TerminalPane(
      workspace: workspace,
      showing: Binding(get: { showingTerminal }, set: { showingTerminal = $0 })
    )
  }

  /// Name, branch and size on one line, and the whole row toggles the rest.
  ///
  /// The chevron alone was the hit target before, which is a few points across and
  /// gave no sign it could be clicked. A disclosure row should be as wide as the
  /// row, and should say so on hover.
  private var summaryBar: some View {
    Button {
      showingDetails.toggle()
      if showingDetails { showingFiles = false }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.secondary)
          .rotationEffect(.degrees(showingDetails ? 90 : 0))
          .frame(width: 12)

        Text(workspace.name)
          .fontWeight(.medium)
        if !workspace.file.branch.isEmpty {
          Text(workspace.file.branch)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.head)
        }

        Spacer()

        if let size = model.sizes[workspace.url] {
          Text(size.formatted)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      // Without this the row is only clickable where it has drawn something.
      .contentShape(Rectangle())
      .background(hoveringSummary ? Color.primary.opacity(0.06) : .clear)
    }
    .buttonStyle(.plain)
    .onHover { hoveringSummary = $0 }
    .animation(.easeInOut(duration: 0.12), value: showingDetails)
    .help(showingDetails ? "Hide the repo list" : "Show the repo list")
  }

  private var repoList: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Repos")
        .font(.headline)

      VStack(spacing: 0) {
        ForEach(workspace.members) { member in
          memberRow(member)
          if member.id != workspace.members.last?.id {
            Divider()
          }
        }
      }
      .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  private func memberRow(_ member: WorkspaceMember) -> some View {
    let activity = model.activity(for: member, in: workspace)
    let state = activity?.state ?? member.state
    let logKey = member.repoName

    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        StateBadge(state: state, busy: state == .settingUp)
        RepoSwatch(repo: member.repoName, size: 10)

        VStack(alignment: .leading, spacing: 2) {
          Text(member.repoName)
            .fontWeight(.medium)
          HStack(spacing: 6) {
            if let branch = member.branch {
              Text(branch)
                .font(.system(.caption, design: .monospaced))
            }
            if member.hasUncommittedChanges {
              Text("· uncommitted changes")
                .font(.caption)
                .foregroundStyle(.orange)
            }
            if let detail = activity?.detail, state == .settingUp || state == .failed {
              Text("· \(detail)")
                .font(.caption)
                .foregroundStyle(state == .failed ? .red : .secondary)
            }
          }
          .foregroundStyle(.secondary)
        }

        Spacer()

        if let reading = model.pullRequest(for: member) {
          PullRequestBadge(reading: reading)
        } else if model.isLoadingPullRequests {
          ProgressView().controlSize(.small)
        }

        if let commit = member.lastCommit {
          Text(commit, format: .relative(presentation: .numeric, unitsStyle: .narrow))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }

        if activity?.log != nil {
          Button {
            if expandedLogs.contains(logKey) {
              expandedLogs.remove(logKey)
            } else {
              expandedLogs.insert(logKey)
            }
          } label: {
            Image(systemName: expandedLogs.contains(logKey) ? "chevron.up" : "text.alignleft")
          }
          .buttonStyle(.borderless)
          .help("Setup output")
        }

        Menu {
          Button("Open") { model.openInEditor(member.url) }
          Button("Reveal in Finder") { model.revealInFinder(member.url) }
          Button("Open in Terminal") { model.openInTerminal(member.url) }
          if let pr = model.pullRequest(for: member)?.pullRequest,
            let url = URL(string: pr.url)
          {
            Divider()
            Link("Open Pull Request " + String(pr.number), destination: url)
          }
          Divider()
          Button("Re-run Setup") {
            Task { await model.rerunSetup(for: member, in: workspace) }
          }
          Divider()
          Button("Remove from Workspace…", role: .destructive) {
            model.teardownTarget = .member(member, workspace)
          }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }

      if expandedLogs.contains(logKey), let log = activity?.log {
        ScrollView {
          Text(log)
            .font(.system(.caption2, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
        .padding(8)
        .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
      }
    }
    .padding(12)
  }

  private var addRepoSection: some View {
    let present = Set(workspace.members.map(\.repoName))
    let available = model.library.repos.filter { !present.contains($0.name) }

    return Group {
      if available.isEmpty {
        EmptyView()
      } else {
        Menu {
          ForEach(available) { repo in
            Button(repo.name) {
              Task { await model.addRepo(named: repo.name, to: workspace) }
            }
          }
        } label: {
          Text("Add Repo")
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(model.isBusy)
      }
    }
  }
}

/// Shows where a repo has got to, and shows nothing when there is nothing to
/// say.
///
/// `.unknown` means the worktree is on disk and Grove has no setup record —
/// true of everything it adopted rather than created, which is most rows most of
/// the time. A badge on every row that reports the ordinary case is noise. The
/// space stays reserved so rows do not jump when a setup starts.
struct StateBadge: View {
  let state: RepoState
  let busy: Bool

  var body: some View {
    Group {
      if busy {
        ProgressView().controlSize(.small)
      } else if let symbol {
        Image(systemName: symbol)
          .foregroundStyle(tint)
          .help(help)
      }
    }
    .frame(width: 16)
  }

  private var symbol: String? {
    switch state {
    case .ready: "checkmark.circle.fill"
    case .failed: "exclamationmark.triangle.fill"
    case .pending: "circle.dashed"
    case .settingUp: "circle.dotted"
    case .unknown: nil
    case .removed: "circle.dashed"
    }
  }

  private var tint: Color {
    switch state {
    case .ready: .green
    case .failed: .red
    case .pending: .secondary
    case .settingUp: .blue
    case .unknown: .clear
    case .removed: .secondary
    }
  }

  private var help: String {
    switch state {
    case .ready: "Setup finished"
    case .failed: "Setup failed — re-run it from the menu"
    case .pending: "Recorded but not on disk"
    case .settingUp: "Working"
    case .unknown: ""
    case .removed: "Removed"
    }
  }
}
