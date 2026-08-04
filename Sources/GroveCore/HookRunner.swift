import Foundation

/// Runs a repo's setup or teardown hook.
public struct HookRunner: Sendable {
  private let toolPaths: ToolPaths

  public init(toolPaths: ToolPaths) {
    self.toolPaths = toolPaths
  }

  /// Runs `hook` with the worktree as its working directory.
  ///
  /// Hooks are ordinary shell, so they inherit a `PATH` built from
  /// ``ToolPaths`` on top of the variables in ``HookEnvironment``.
  public func run(
    _ hook: HookKind,
    worktree: URL,
    repo: RepoEntry,
    workspace: URL,
    branch: String
  ) async throws -> CommandResult {
    var environment = toolPaths.processEnvironment()
    for (key, value) in HookEnvironment.variables(
      worktree: worktree,
      repoRoot: repo.url,
      workspace: workspace,
      repoName: repo.name,
      branch: branch,
      baseBranch: repo.base
    ) {
      environment[key] = value
    }

    let shell = Shell(environment: environment)
    switch hook {
    case .script(let path):
      return try await shell.run(path, [], in: worktree)
    case .command(let command):
      return try await shell.run("/bin/sh", ["-c", command], in: worktree)
    }
  }
}

/// Builds a ``WorktreeRisk`` so nothing is deleted without the user seeing what
/// it holds.
public struct WorktreeAuditor: Sendable {
  private let git: Git

  public init(git: Git) {
    self.git = git
  }

  public func audit(worktree: URL, repo: RepoEntry?) async -> WorktreeRisk {
    var risk = WorktreeRisk()
    guard FileManager.default.fileExists(atPath: worktree.path) else { return risk }

    if let entries = try? await git.statusEntries(worktree: worktree, includeIgnored: true) {
      risk.uncommittedFiles = entries.tracked
      risk.untrackedFiles = entries.untracked
      risk.ignoredFiles = entries.ignored
    }
    risk.unpushedCommits = (try? await git.unpushedCommits(worktree: worktree)) ?? []
    risk.stashes = (try? await git.stashes(worktree: worktree)) ?? []
    risk.unlinkedEnvFiles = Self.unlinkedEnvFiles(in: worktree)

    if let repo, let branch = try? await git.currentBranch(worktree: worktree) {
      risk.isMerged =
        (try? await git.isMerged(repo: repo.url, branch: branch, into: repo.base)) ?? false
    }
    return risk
  }

  /// `.env*` files that are real files rather than symlinks into the source clone.
  ///
  /// A setup script that copies instead of links leaves secrets that deleting
  /// the worktree destroys for good.
  static func unlinkedEnvFiles(in worktree: URL) -> [String] {
    let manager = FileManager.default
    var found: [String] = []

    func inspect(_ directory: URL, prefix: String) {
      guard
        let entries = try? manager.contentsOfDirectory(
          at: directory,
          includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      else { return }

      // Hidden files are skipped above, so ask for .env* explicitly.
      let names = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
      for name in names where name.hasPrefix(".env") {
        if name.hasSuffix(".example") || name.hasSuffix(".sample") { continue }
        let url = directory.appending(path: name)
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink != true {
          found.append(prefix.isEmpty ? name : "\(prefix)/\(name)")
        }
      }

      // One level down covers monorepo layouts such as app/ and common/.
      guard prefix.isEmpty else { return }
      for entry in entries {
        let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
        guard values?.isDirectory == true, entry.lastPathComponent != "node_modules" else {
          continue
        }
        inspect(entry, prefix: entry.lastPathComponent)
      }
    }

    inspect(worktree, prefix: "")
    return found.sorted()
  }
}
