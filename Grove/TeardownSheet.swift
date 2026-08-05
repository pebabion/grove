import GroveCore
import SwiftUI

/// Shows exactly what is about to be destroyed before destroying it.
///
/// Everything listed is something that exists now and will be gone afterwards.
/// Nothing here describes an action Grove takes to save your work.
///
/// `git status` alone would call most of these worktrees clean. Unpushed commits
/// and ignored-but-real files like `.env.local` are the ones that hurt, so they
/// get listed by name.
struct TeardownSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  let target: TeardownTarget

  @State private var risks: [String: WorktreeRisk] = [:]
  @State private var isAuditing = true
  @State private var deleteBranches = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.title3.weight(.semibold))
        Text(subtitle)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      .padding(20)

      Divider()

      if isAuditing {
        VStack(spacing: 10) {
          ProgressView()
          Text("Checking what this would lose…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text("Everything below exists now and will be gone afterwards.")
              .font(.caption)
              .foregroundStyle(.secondary)
            ForEach(members, id: \.repoName) { member in
              riskCard(for: member)
            }
          }
          .padding(20)
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        Toggle("Also delete the local branch", isOn: $deleteBranches)
          .help("Removing a worktree leaves its branch behind. Tick this to drop it too.")

        HStack {
          Spacer()
          Button("Cancel") { dismiss() }
            .keyboardShortcut(.cancelAction)
          Button(confirmLabel, role: .destructive) {
            let branches = deleteBranches
            dismiss()
            Task { await perform(deleteBranches: branches) }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isAuditing)
        }
      }
      .padding(16)
    }
    .frame(width: 560, height: 520)
    .task { await audit() }
  }

  private var members: [WorkspaceMember] {
    switch target {
    case .whole(let workspace): workspace.members
    case .member(let member, _): [member]
    }
  }

  private var workspace: Workspace {
    switch target {
    case .whole(let workspace): workspace
    case .member(_, let workspace): workspace
    }
  }

  private var title: String {
    switch target {
    case .whole(let workspace): "Delete \(workspace.name)?"
    case .member(let member, _): "Remove \(member.repoName)?"
    }
  }

  private var subtitle: String {
    switch target {
    case .whole:
      "Runs each repo's teardown hook, removes every worktree, then deletes the workspace folder."
    case .member:
      "Runs the teardown hook and removes this worktree. The rest of the workspace stays."
    }
  }

  private var confirmLabel: String {
    switch target {
    case .whole: "Delete Workspace"
    case .member: "Remove Repo"
    }
  }

  private func riskCard(for member: WorkspaceMember) -> some View {
    let risk = risks[member.repoName] ?? WorktreeRisk()

    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: risk.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(risk.isEmpty ? Color.green : Color.orange)
        Text(member.repoName)
          .fontWeight(.medium)
        if let mark = landedMark(for: member) {
          Text(mark.label)
            .font(.caption2)
            .foregroundStyle(mark.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(mark.tint.opacity(0.18), in: Capsule())
            .help(mark.explanation)
        }
        Spacer()
      }

      if risk.isEmpty {
        Text("Nothing unsaved. Safe to remove.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          group("Commits on no remote", risk.unpushedCommits, tint: .red)
          group("Uncommitted changes", risk.uncommittedFiles, tint: .orange)
          group("Untracked files", risk.untrackedFiles, tint: .orange)
          group("Real .env files, not symlinks", risk.unlinkedEnvFiles, tint: .red)
          group("Ignored files", risk.ignoredFiles, tint: .secondary)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
  }

  /// A badge only when the work's fate is worth knowing.
  ///
  /// Read from the pull request, which is the only signal a squash merge survives:
  /// a squash rewrites the commit, so a fully merged branch never becomes an
  /// ancestor of its base.
  ///
  /// Nothing is said about the ordinary case. The card already reports "nothing
  /// unsaved, safe to remove" when there is nothing to lose, and a badge
  /// repeating it would be another label that fires on every row and tells the
  /// reader nothing.
  private func landedMark(
    for member: WorkspaceMember
  ) -> (label: String, tint: Color, explanation: String)? {
    guard let pr = model.pullRequest(for: member)?.pullRequest else { return nil }
    switch pr.state {
    case "MERGED":
      return ("merged", .green, "Pull request #" + String(pr.number) + " was merged")
    case "CLOSED":
      return (
        "closed unmerged", .orange,
        "Pull request #" + String(pr.number) + " was closed without merging"
      )
    default:
      return nil
    }
  }

  @ViewBuilder
  private func group(_ label: String, _ items: [String], tint: Color) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(label) (\(items.count))")
          .font(.caption.weight(.medium))
          .foregroundStyle(tint)
        ForEach(items.prefix(6), id: \.self) { item in
          Text(item)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        if items.count > 6 {
          Text("and \(items.count - 6) more")
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
      }
    }
  }

  private func audit() async {
    let all = await model.audit(workspace)
    switch target {
    case .whole:
      risks = all
    case .member(let member, _):
      risks = [member.repoName: all[member.repoName] ?? WorktreeRisk()]
    }
    isAuditing = false
  }

  private func perform(deleteBranches: Bool) async {
    switch target {
    case .whole(let workspace):
      await model.teardown(workspace, deleteBranches: deleteBranches)
    case .member(let member, let workspace):
      await model.removeRepo(member, from: workspace, deleteBranch: deleteBranches)
    }
  }
}
