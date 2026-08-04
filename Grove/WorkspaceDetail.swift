import GroveCore
import SwiftUI

struct WorkspaceDetail: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace

  @State private var expandedLogs: Set<String> = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        repoList
        addRepoSection
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(workspace.name)
    .toolbar {
      ToolbarItemGroup {
        Button {
          model.openInEditor(workspace.url)
        } label: {
          Label("Open", systemImage: "arrow.up.forward.app")
        }
        .help(model.library.editor.map { "Open in \($0)" } ?? "Reveal in Finder")

        Menu {
          WorkspaceActions(workspace: workspace)
        } label: {
          Label("More", systemImage: "ellipsis.circle")
        }
      }
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        Text(workspace.name)
          .font(.title2.weight(.semibold))
        if !workspace.file.branch.isEmpty {
          Text(workspace.file.branch)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      Text(workspace.url.path)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
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
          Label("Add Repo", systemImage: "plus.circle")
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
    }
  }

  private var tint: Color {
    switch state {
    case .ready: .green
    case .failed: .red
    case .pending: .secondary
    case .settingUp: .blue
    case .unknown: .clear
    }
  }

  private var help: String {
    switch state {
    case .ready: "Setup finished"
    case .failed: "Setup failed — re-run it from the menu"
    case .pending: "Recorded but not on disk"
    case .settingUp: "Working"
    case .unknown: ""
    }
  }
}
