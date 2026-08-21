import Foundation

/// Changes to the workspace list that Grove makes before disk catches up.
///
/// A scan of a real root takes about two seconds — git runs in every worktree — and adding
/// a repo does a fetch, a worktree creation and a setup hook before that. Waiting for the
/// rescan meant clicking Add and watching nothing happen for several seconds, which reads
/// as the click having missed. The same reasoning as the placeholder `createWorkspace`
/// puts in the list: show the row, then let the scan correct it.
public enum WorkspaceEdit {
  /// Puts a repo into a workspace before its worktree exists.
  ///
  /// The row it produces is `pending`, which is what a repo recorded but not yet on disk
  /// means everywhere else. Anything the scan disagrees with, the scan wins — this only
  /// has to be right for the second or two before it runs.
  public static func inserting(
    _ repo: String, at workspace: URL, branch: String, into workspaces: [Workspace]
  ) -> [Workspace] {
    workspaces.map { existing in
      guard existing.url == workspace else { return existing }
      guard !existing.members.contains(where: { $0.repoName == repo }) else { return existing }

      var updated = existing
      updated.members.append(
        WorkspaceMember(
          repoName: repo,
          // The same form the scanner reports, or nothing keyed on it will match.
          url: workspace.appending(path: repo).identity,
          branch: branch,
          state: .pending
        ))
      // The scanner sorts by name, so sort here too: a row that appears at the end and
      // then jumps into place reads as a glitch.
      updated.members.sort { $0.repoName < $1.repoName }
      if !updated.file.repos.contains(repo) {
        updated.file.repos.append(repo)
        updated.file.repos.sort()
      }
      return updated
    }
  }
}
