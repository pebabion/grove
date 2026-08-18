import GroveCore
import SwiftUI

/// What is happening while a workspace is being built or taken apart.
///
/// In the middle of the window rather than a line in the corner. Both jobs run for
/// minutes, and for all that time the detail pane had nothing in it while the only sign
/// of life was a few points tall at the bottom of the sidebar.
struct WorkspaceProgress: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace
  let job: Job

  enum Job {
    case creating
    case removing

    var title: String {
      switch self {
      case .creating: "Setting up"
      case .removing: "Removing"
      }
    }
  }

  private var members: [WorkspaceMember] { workspace.members }

  /// Repos with nothing left to do, for counting.
  private var finished: Int {
    members.filter { done(state(of: $0)) }.count
  }

  private func done(_ state: RepoState) -> Bool {
    switch job {
    case .creating: state == .ready || state == .failed
    case .removing: state == .removed
    }
  }

  var body: some View {
    VStack(spacing: 18) {
      VStack(spacing: 5) {
        Text("\(job.title) \(workspace.name)")
          .font(.title3.weight(.medium))
        Text(workspace.file.branch)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }

      VStack(spacing: 0) {
        ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
          if index > 0 { Divider() }
          row(for: member)
        }
      }
      .grovePanel()
      .frame(maxWidth: 520)

      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
  }

  /// A bar for a removal, a count for a creation.
  ///
  /// A teardown knows its own size — a step per repo and the folder at the end — so a bar
  /// there measures something. Creating does not: almost all of the time goes into
  /// installing dependencies, which reports nothing, so a bar would stand still through
  /// the longest part and read as stuck.
  @ViewBuilder
  private var footer: some View {
    switch job {
    case .creating:
      Text(
        finished == members.count
          ? "Finishing"
          : "\(finished) of \(members.count) \(members.count == 1 ? "repo" : "repos") ready"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .removing:
      VStack(spacing: 8) {
        ProgressView(value: model.busyFraction ?? 0)
          .progressViewStyle(.linear)
          .frame(maxWidth: 320)
        // The step the whole workspace is on, which the rows cannot say: the folder
        // itself goes after the last repo, and it is the slowest part.
        Text(model.busyLabel ?? "Removing")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
  }

  private func row(for member: WorkspaceMember) -> some View {
    HStack(spacing: 10) {
      mark(for: state(of: member))
        .frame(width: 16)

      RepoSwatch(repo: member.repoName, size: 8)

      Text(member.repoName)
        .font(.callout)

      Spacer(minLength: 12)

      Text(detail(of: member))
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
  }

  @ViewBuilder
  private func mark(for state: RepoState) -> some View {
    switch state {
    case .ready, .removed:
      Image(systemName: "checkmark").foregroundStyle(Theme.confirm).font(.caption)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).font(
        .caption)
    case .settingUp:
      ProgressView().controlSize(.small).scaleEffect(0.7)
    default:
      Image(systemName: "circle.dotted").foregroundStyle(.tertiary).font(.caption)
    }
  }

  private func state(of member: WorkspaceMember) -> RepoState {
    model.activity(for: member, in: workspace)?.state ?? member.state
  }

  /// What the repo is doing, or what is left to say when it is not doing anything.
  private func detail(of member: WorkspaceMember) -> String {
    if let activity = model.activity(for: member, in: workspace), !activity.detail.isEmpty {
      return activity.detail
    }
    return switch state(of: member) {
    case .ready: "Ready"
    case .failed: job == .creating ? "Setup failed" : "Failed"
    case .removed: "Removed"
    default: "Waiting"
    }
  }
}
