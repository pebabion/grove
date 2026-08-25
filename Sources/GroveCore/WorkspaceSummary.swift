import Foundation

/// What a workspace row has to say in four lines.
///
/// The sidebar used to print one line per repo, each carrying that repo's branch — and
/// since a workspace is one branch across every repo, that meant the same string three
/// times. The one fact worth reading, a repo sitting somewhere else, was the hardest to
/// find: it looked exactly like its neighbours.
///
/// So the shared branch is said once and only the exceptions are listed. Which repos are
/// exceptions is a question about the data, not about the view, so it is answered here.
public struct WorkspaceSummary: Sendable, Equatable {
  /// Every repo the workspace records, on disk or not.
  public let repoCount: Int

  /// The branch to print once, when the repos agree on one. Nil when they do not, and then
  /// `divergent` holds every repo that has a branch — there is nothing to say once.
  public let sharedBranch: String?

  /// Repos not on `sharedBranch`, in the order the workspace lists them.
  ///
  /// A repo with no branch is not one of these. It is either not on disk yet or detached,
  /// and its state already says so — calling it divergent would put a blank branch on
  /// screen and claim it was news.
  public let divergent: [WorkspaceMember]

  /// Repos with uncommitted work, which is what makes a workspace unsafe to remove.
  public let dirtyCount: Int

  public let failedCount: Int

  public init(_ workspace: Workspace) {
    let members = workspace.members
    repoCount = members.count
    dirtyCount = members.filter(\.hasUncommittedChanges).count
    failedCount = members.filter { $0.state == .failed }.count

    let branches = members.compactMap(\.branch).filter { !$0.isEmpty }
    let recorded = workspace.file.branch
    let shared: String?
    if !recorded.isEmpty {
      shared = recorded
    } else {
      // Adopted from disk, so nothing recorded what the workspace is for. The repos
      // themselves can still agree.
      let distinct = Set(branches)
      shared = distinct.count == 1 ? distinct.first : nil
    }
    sharedBranch = shared

    guard let shared else {
      divergent = members.filter { ($0.branch.map { !$0.isEmpty }) == true }
      return
    }
    divergent = members.filter { member in
      guard let branch = member.branch, !branch.isEmpty else { return false }
      return branch != shared
    }
  }

  /// Whether the row needs to list any repo separately.
  public var isUniform: Bool { divergent.isEmpty }
}
