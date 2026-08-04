import Foundation

/// One entry from `git worktree list --porcelain`.
public struct WorktreeInfo: Sendable, Hashable {
  public let path: String
  public let head: String
  /// Short branch name, or `nil` for a detached HEAD.
  public let branch: String?
  public let isBare: Bool
  public let isLocked: Bool

  public init(
    path: String, head: String = "", branch: String? = nil, isBare: Bool = false,
    isLocked: Bool = false
  ) {
    self.path = path
    self.head = head
    self.branch = branch
    self.isBare = isBare
    self.isLocked = isLocked
  }
}

/// What a worktree would lose if it were deleted right now.
///
/// Grove never removes a worktree without showing this first. Checking only
/// `git status` misses the cases that actually hurt: commits that exist on no
/// remote, stashes made inside the worktree, and ignored-but-real files such as
/// `.env.local` or a scratch SQL dump.
public struct WorktreeRisk: Sendable, Hashable {
  public var uncommittedFiles: [String] = []
  public var untrackedFiles: [String] = []
  public var ignoredFiles: [String] = []
  public var unpushedCommits: [String] = []
  public var stashes: [String] = []
  /// `.env*` entries that are real files rather than symlinks into the source clone.
  public var unlinkedEnvFiles: [String] = []
  /// True when the branch is an ancestor of its comparison target.
  public var isMerged: Bool = false

  public var isEmpty: Bool {
    uncommittedFiles.isEmpty && untrackedFiles.isEmpty && ignoredFiles.isEmpty
      && unpushedCommits.isEmpty && stashes.isEmpty && unlinkedEnvFiles.isEmpty
  }

  public init() {}
}

/// A thin, typed wrapper over the `git` command line.
public struct Git: Sendable {
  public let executable: String
  private let shell: Shell

  public init(executable: String = "/usr/bin/git", environment: [String: String]? = nil) {
    self.executable = executable
    self.shell = Shell(environment: environment)
  }

  /// Runs git and returns trimmed stdout, throwing on a non-zero exit.
  @discardableResult
  public func run(_ arguments: [String], in directory: URL? = nil) async throws -> String {
    try await shell.check(executable, arguments, in: directory).trimmedOutput
  }

  /// Runs git and returns the full result so the caller can inspect the exit code.
  public func attempt(_ arguments: [String], in directory: URL? = nil) async throws -> CommandResult
  {
    try await shell.run(executable, arguments, in: directory)
  }

  // MARK: - Worktrees

  public func listWorktrees(repo: URL) async throws -> [WorktreeInfo] {
    let output = try await run(["-C", repo.path, "worktree", "list", "--porcelain"])
    return Self.parseWorktreeList(output)
  }

  /// Creates a worktree, reusing `branch` if it already exists and branching
  /// from `base` if it does not.
  ///
  /// Resuming work or picking up a colleague's branch both land in the reuse
  /// case, so this is not an edge case.
  public func addWorktree(repo: URL, at path: URL, branch: String, base: String) async throws {
    if try await branchExists(repo: repo, branch: branch) {
      try await run(["-C", repo.path, "worktree", "add", path.path, branch])
    } else {
      try await run(["-C", repo.path, "worktree", "add", path.path, "-b", branch, base])
    }
  }

  /// Removes a worktree, falling back to deleting the directory and pruning
  /// when git refuses.
  public func removeWorktree(repo: URL, at path: URL, force: Bool) async throws {
    var arguments = ["-C", repo.path, "worktree", "remove", path.path]
    if force { arguments.append("--force") }

    let result = try await attempt(arguments)
    guard !result.succeeded else { return }

    if FileManager.default.fileExists(atPath: path.path) {
      try FileManager.default.removeItem(at: path)
    }
    _ = try await attempt(["-C", repo.path, "worktree", "prune"])
  }

  public func pruneWorktrees(repo: URL) async throws {
    try await run(["-C", repo.path, "worktree", "prune"])
  }

  // MARK: - Branches

  public func branchExists(repo: URL, branch: String) async throws -> Bool {
    try await attempt(["-C", repo.path, "rev-parse", "--verify", "refs/heads/\(branch)"]).succeeded
  }

  public func deleteBranch(repo: URL, branch: String, force: Bool) async throws {
    try await run(["-C", repo.path, "branch", force ? "-D" : "-d", branch])
  }

  /// The path of another worktree that already has `branch` checked out.
  public func worktreeHolding(branch: String, repo: URL) async throws -> String? {
    try await listWorktrees(repo: repo).first { $0.branch == branch }?.path
  }

  /// The remote's default branch, e.g. `origin/main`.
  ///
  /// Repos disagree about `master` versus `main`, so this is read per repo
  /// rather than assumed.
  public func defaultBranch(repo: URL) async throws -> String? {
    let result = try await attempt(["-C", repo.path, "symbolic-ref", "refs/remotes/origin/HEAD"])
    if result.succeeded {
      let ref = result.trimmedOutput
      if let range = ref.range(of: "refs/remotes/") {
        return String(ref[range.upperBound...])
      }
    }
    for candidate in ["origin/main", "origin/master"] {
      if try await attempt(["-C", repo.path, "rev-parse", "--verify", candidate]).succeeded {
        return candidate
      }
    }
    return nil
  }

  public func isMerged(repo: URL, branch: String, into target: String) async throws -> Bool {
    try await attempt([
      "-C", repo.path, "merge-base", "--is-ancestor", "refs/heads/\(branch)", target,
    ]).succeeded
  }

  public func fetch(repo: URL) async throws {
    try await run(["-C", repo.path, "fetch", "origin", "--prune"])
  }

  // MARK: - Inspection

  public func isGitRepository(_ path: URL) async throws -> Bool {
    let result = try await attempt(["-C", path.path, "rev-parse", "--git-dir"])
    return result.succeeded
  }

  /// The source clone a worktree belongs to.
  ///
  /// Every worktree of a repository shares one `.git` directory, and its parent
  /// is the original clone. This is how Grove maps a worktree it finds on disk
  /// back to a library entry — matching on directory names would guess wrong.
  public func sourceClone(of worktree: URL) async throws -> URL? {
    let result = try await attempt([
      "-C", worktree.path, "rev-parse", "--path-format=absolute", "--git-common-dir",
    ])
    guard result.succeeded, !result.trimmedOutput.isEmpty else { return nil }
    return URL(filePath: result.trimmedOutput).deletingLastPathComponent()
  }

  /// Short name of the checked-out branch, or `nil` when HEAD is detached.
  public func currentBranch(worktree: URL) async throws -> String? {
    let result = try await attempt(["-C", worktree.path, "symbolic-ref", "--short", "HEAD"])
    guard result.succeeded, !result.trimmedOutput.isEmpty else { return nil }
    return result.trimmedOutput
  }

  public func hasUncommittedChanges(worktree: URL) async throws -> Bool {
    let result = try await attempt(["-C", worktree.path, "status", "--porcelain"])
    return result.succeeded && !result.trimmedOutput.isEmpty
  }

  /// Timestamp of the most recent commit, ignoring merges.
  public func lastCommitDate(worktree: URL) async throws -> Date? {
    let result = try await attempt([
      "-C", worktree.path, "log", "-1", "--no-merges", "--format=%cI",
    ])
    guard result.succeeded, !result.trimmedOutput.isEmpty else { return nil }
    return ISO8601DateFormatter().date(from: result.trimmedOutput)
  }

  /// Commits on the current branch that exist on no remote.
  ///
  /// `--not --remotes` is the check that matters for teardown. A branch with
  /// no upstream and no PR still looks clean to `git status`.
  public func unpushedCommits(worktree: URL) async throws -> [String] {
    let result = try await attempt([
      "-C", worktree.path, "log", "--format=%h %s", "HEAD", "--not", "--remotes",
    ])
    guard result.succeeded else { return [] }
    return result.trimmedOutput.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }

  public func stashes(worktree: URL) async throws -> [String] {
    let result = try await attempt(["-C", worktree.path, "stash", "list"])
    guard result.succeeded else { return [] }
    return result.trimmedOutput.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }

  /// Paths reported by `git status --porcelain`, split by category.
  public func statusEntries(worktree: URL, includeIgnored: Bool) async throws
    -> (tracked: [String], untracked: [String], ignored: [String])
  {
    var arguments = ["-C", worktree.path, "status", "--porcelain"]
    if includeIgnored { arguments.append("--ignored=matching") }

    let result = try await attempt(arguments)
    guard result.succeeded else { return ([], [], []) }

    var tracked: [String] = []
    var untracked: [String] = []
    var ignored: [String] = []
    for line in result.standardOutput.split(separator: "\n") where line.count > 3 {
      let code = String(line.prefix(2))
      let path = String(line.dropFirst(3))
      switch code {
      case "??": untracked.append(path)
      case "!!": ignored.append(path)
      default: tracked.append(path)
      }
    }
    return (tracked, untracked, ignored)
  }

  // MARK: - Porcelain parsing

  static func parseWorktreeList(_ output: String) -> [WorktreeInfo] {
    var worktrees: [WorktreeInfo] = []
    for block in output.components(separatedBy: "\n\n") {
      var path = ""
      var head = ""
      var branch: String?
      var isBare = false
      var isLocked = false

      for line in block.split(separator: "\n") {
        let line = String(line)
        if let value = line.dropPrefix("worktree ") {
          path = value
        } else if let value = line.dropPrefix("HEAD ") {
          head = value
        } else if let value = line.dropPrefix("branch refs/heads/") {
          branch = value
        } else if line == "bare" {
          isBare = true
        } else if line == "locked" || line.hasPrefix("locked ") {
          isLocked = true
        }
      }

      if !path.isEmpty {
        worktrees.append(
          WorktreeInfo(path: path, head: head, branch: branch, isBare: isBare, isLocked: isLocked)
        )
      }
    }
    return worktrees
  }
}

extension String {
  fileprivate func dropPrefix(_ prefix: String) -> String? {
    hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
  }
}
