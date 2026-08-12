import GroveCore
import SwiftUI

/// What is happening while a workspace is being built.
///
/// In the middle of the window rather than a line in the corner. Creating a workspace is
/// minutes of fetching and installing, and for all that time the detail pane had nothing in
/// it while the only sign of life was a few points tall at the bottom of the sidebar.
struct CreationProgress: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace

  private var members: [WorkspaceMember] { workspace.members }

  /// Repos with nothing left to do, for counting.
  private var finished: Int {
    members.filter { state(of: $0) == .ready || state(of: $0) == .failed }.count
  }

  var body: some View {
    VStack(spacing: 18) {
      VStack(spacing: 5) {
        Text("Setting up \(workspace.name)")
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
      .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
      .frame(maxWidth: 520)

      // A count rather than a bar: the time goes into installing dependencies, which
      // reports nothing, so a bar would sit still through the part that takes longest.
      Text(
        finished == members.count
          ? "Finishing"
          : "\(finished) of \(members.count) \(members.count == 1 ? "repo" : "repos") ready"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
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
    case .ready:
      Image(systemName: "checkmark").foregroundStyle(.green).font(.caption)
    case .failed:
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
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
    case .failed: "Setup failed"
    default: "Waiting"
    }
  }
}
