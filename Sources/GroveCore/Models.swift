import Foundation

// MARK: - Repo library

/// A repository Grove knows how to make worktrees from.
public struct RepoEntry: Codable, Sendable, Hashable, Identifiable {
  /// Short name, unique within the library. Doubles as the directory name
  /// inside a workspace.
  public var name: String

  /// The source clone. Stored with `~` intact so the library survives a move.
  public var path: String

  /// Branch new worktrees fork from, e.g. `origin/main`. Probed from
  /// `origin/HEAD` when the repo is added.
  public var base: String

  /// Shell command run after the worktree is created, when the repo has no
  /// `.grove/setup.sh`. See ``HookKind`` for the resolution order.
  public var setupCommand: String?

  /// Shell command run before the worktree is removed. Undoes whatever setup
  /// did outside the worktree: containers, scratch databases, hosts entries.
  public var teardownCommand: String?

  public var id: String { name }

  public var url: URL { URL(filePath: (path as NSString).expandingTildeInPath) }

  public init(
    name: String,
    path: String,
    base: String = "origin/main",
    setupCommand: String? = nil,
    teardownCommand: String? = nil
  ) {
    self.name = name
    self.path = path
    self.base = base
    self.setupCommand = setupCommand
    self.teardownCommand = teardownCommand
  }
}

/// Grove's repo library, stored at `~/.config/grove/library.json`.
public struct RepoLibrary: Codable, Sendable, Hashable {
  public var repos: [RepoEntry]

  /// Where workspaces are created, e.g. `~/code/worktrees`.
  public var workspaceRoot: String

  /// Application used by the "open workspace" action, by bundle id or name.
  public var editor: String?

  public init(repos: [RepoEntry] = [], workspaceRoot: String = "~/worktrees", editor: String? = nil)
  {
    self.repos = repos
    self.workspaceRoot = workspaceRoot
    self.editor = editor
  }

  public var workspaceRootURL: URL {
    URL(filePath: (workspaceRoot as NSString).expandingTildeInPath)
  }

  public subscript(name: String) -> RepoEntry? {
    repos.first { $0.name == name }
  }
}

// MARK: - Workspaces

/// How Grove found the command for a lifecycle hook.
///
/// A script committed in the repo beats a command in Grove's library: it is
/// versioned with the code it sets up, and colleagues get it for free.
public enum HookKind: Sendable, Hashable {
  /// `.grove/setup.sh` or `.grove/teardown.sh` inside the worktree.
  case script(path: String)
  /// Inline command from the repo library entry.
  case command(String)
}

/// State of one repo inside a workspace.
///
/// `git worktree add` can succeed and the setup script fail right after, which
/// leaves a real worktree that is not usable yet. That state has to be visible
/// and retryable rather than fatal.
public enum RepoState: String, Codable, Sendable, Hashable {
  /// Recorded in the workspace but no worktree on disk yet.
  case pending
  /// Worktree exists; setup is running.
  case settingUp
  /// Setup finished cleanly.
  case ready
  /// Worktree exists but setup failed. Keep the log, offer a retry.
  case failed
  /// Worktree exists and Grove has no record of setup, e.g. adopted from disk.
  case unknown
}

/// Grove's metadata file, written to `grove.json` in the workspace root.
///
/// The filesystem stays the source of truth: this records intent, and
/// `git worktree list` records reality. When they disagree, disk wins.
public struct WorkspaceFile: Codable, Sendable, Hashable {
  public var name: String

  /// Branch shared by every repo in the workspace.
  public var branch: String

  /// Optional link to whatever prompted the work — a ticket, a PR, a doc.
  public var link: String?

  /// Names of repo library entries that belong to this workspace.
  public var repos: [String]

  public var createdAt: Date

  public init(
    name: String,
    branch: String,
    link: String? = nil,
    repos: [String] = [],
    createdAt: Date = Date()
  ) {
    self.name = name
    self.branch = branch
    self.link = link
    self.repos = repos
    self.createdAt = createdAt
  }
}

/// A workspace as it exists on disk, joined with its metadata.
public struct Workspace: Sendable, Hashable, Identifiable {
  public var url: URL
  public var file: WorkspaceFile
  public var members: [WorkspaceMember]

  public var id: URL { url }
  public var name: String { file.name }

  public init(url: URL, file: WorkspaceFile, members: [WorkspaceMember] = []) {
    self.url = url
    self.file = file
    self.members = members
  }
}

/// One repo's worktree inside a workspace.
public struct WorkspaceMember: Sendable, Hashable, Identifiable {
  public var repoName: String
  public var url: URL
  public var branch: String?
  public var state: RepoState
  public var lastCommit: Date?
  public var hasUncommittedChanges: Bool

  public var id: String { repoName }

  public init(
    repoName: String,
    url: URL,
    branch: String? = nil,
    state: RepoState = .unknown,
    lastCommit: Date? = nil,
    hasUncommittedChanges: Bool = false
  ) {
    self.repoName = repoName
    self.url = url
    self.branch = branch
    self.state = state
    self.lastCommit = lastCommit
    self.hasUncommittedChanges = hasUncommittedChanges
  }
}
