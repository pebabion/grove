import Foundation

/// The contract between Grove and a repo's setup or teardown script.
///
/// Scripts run with the worktree as their working directory and receive these
/// variables. `GROVE_REPO_ROOT` is the interesting one: it points at the source
/// clone, which is where `.env` files live and what dependency caches can be
/// linked from.
public enum HookEnvironment {
  public static func variables(
    worktree: URL,
    repoRoot: URL,
    workspace: URL,
    repoName: String,
    branch: String,
    baseBranch: String
  ) -> [String: String] {
    [
      "GROVE_WORKTREE": worktree.path,
      "GROVE_REPO_ROOT": repoRoot.path,
      "GROVE_REPO_NAME": repoName,
      "GROVE_WORKSPACE": workspace.path,
      "GROVE_WORKSPACE_NAME": workspace.lastPathComponent,
      "GROVE_BRANCH": branch,
      "GROVE_BASE_BRANCH": baseBranch,
    ]
  }

  /// Documentation shown next to the command field in Settings.
  public static let reference = """
    Runs with the new worktree as the working directory.

      GROVE_WORKTREE        the new worktree
      GROVE_REPO_ROOT       the source clone — symlink .env from here
      GROVE_REPO_NAME       this repo's name in the library
      GROVE_WORKSPACE       the workspace root
      GROVE_WORKSPACE_NAME  the workspace's directory name
      GROVE_BRANCH          the branch just created or checked out
      GROVE_BASE_BRANCH     what it forked from

    A committed .grove/setup.sh takes precedence over this command.
    Write it so it can be run twice: Grove offers a re-run when a
    lockfile changes.
    """
}

/// Decides which command to run for a lifecycle phase.
public struct HookResolver: Sendable {
  public enum Phase: Sendable {
    case setup
    case teardown

    var scriptName: String {
      switch self {
      case .setup: GroveLocations.setupScriptName
      case .teardown: GroveLocations.teardownScriptName
      }
    }
  }

  public init() {}

  /// Returns the hook for `phase`, preferring a script committed in the
  /// worktree over the library's inline command.
  public func resolve(phase: Phase, repo: RepoEntry, worktree: URL) -> HookKind? {
    let script =
      worktree
      .appending(path: GroveLocations.hookDirectoryName)
      .appending(path: phase.scriptName)

    if FileManager.default.isExecutableFile(atPath: script.path) {
      return .script(path: script.path)
    }

    let command =
      switch phase {
      case .setup: repo.setupCommand
      case .teardown: repo.teardownCommand
      }
    guard let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    return .command(command)
  }
}
