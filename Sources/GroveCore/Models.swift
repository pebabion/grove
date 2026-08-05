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

  /// Which palette slot this repo uses.
  ///
  /// Assigned when the repo is added, taking the lowest slot nobody else holds.
  /// Hashing the name was tried first and put three of five repos on the same
  /// colour — with a handful of deliberately-added repos, picking beats guessing.
  public var colorIndex: Int?

  public var id: String { name }

  public var url: URL { URL(filePath: (path as NSString).expandingTildeInPath) }

  public init(
    name: String,
    path: String,
    base: String = "origin/main",
    setupCommand: String? = nil,
    teardownCommand: String? = nil,
    colorIndex: Int? = nil
  ) {
    self.name = name
    self.path = path
    self.base = base
    self.setupCommand = setupCommand
    self.teardownCommand = teardownCommand
    self.colorIndex = colorIndex
  }
}

/// Grove's repo library, stored at `~/.config/grove/library.json`.
public struct RepoLibrary: Codable, Sendable, Hashable {
  public var repos: [RepoEntry]

  /// Where workspaces are created, e.g. `~/code/worktrees`.
  public var workspaceRoot: String

  /// Application name typed into an earlier version of Settings. Read once to
  /// find the app it meant, then left alone.
  public var editor: String?

  /// Application the Open action hands a workspace to, as a path to the bundle.
  ///
  /// A path rather than a name: a name has to be guessed at by `open -a`, which
  /// says nothing when the guess is wrong, and Grove could not show which app it
  /// meant. Empty means reveal in Finder instead.
  public var editorPath: String?

  /// Application the "Open in Terminal" action uses. Empty means Terminal.
  public var terminalPath: String?

  /// Prepended to generated branch names, e.g. `kelvin` gives `kelvin/thing`.
  public var branchPrefix: String?

  /// Font family for the embedded terminal. Empty picks the best installed default.
  ///
  /// Worth choosing rather than assuming: a prompt built from Nerd Font glyphs
  /// rendered in a font without them makes macOS substitute glyph by glyph, and
  /// substitutes have different metrics — which reads as inconsistent sizing.
  public var terminalFont: String?
  public var terminalFontSize: Double?

  /// Explicit paths for tools the login shell does not reveal, keyed by tool name.
  ///
  /// ``ToolPaths`` has always honoured overrides, but nothing set them and nothing
  /// kept them, so anyone whose gh lived somewhere unusual had no way to say so.
  public var toolOverrides: [String: String] = [:]

  public init(
    repos: [RepoEntry] = [],
    workspaceRoot: String = "~/worktrees",
    editor: String? = nil,
    editorPath: String? = nil,
    terminalPath: String? = nil,
    branchPrefix: String? = nil,
    terminalFont: String? = nil,
    terminalFontSize: Double? = nil,
    toolOverrides: [String: String] = [:]
  ) {
    self.repos = repos
    self.workspaceRoot = workspaceRoot
    self.editor = editor
    self.editorPath = editorPath
    self.terminalPath = terminalPath
    self.branchPrefix = branchPrefix
    self.terminalFont = terminalFont
    self.terminalFontSize = terminalFontSize
    self.toolOverrides = toolOverrides
  }

  /// Resolves the older `editor` name to a bundle path, once.
  ///
  /// Settings used to take a name like "Zed" and pass it to `open -a`. Anyone
  /// upgrading has that in their library and should not have to pick their editor
  /// again.
  public mutating func migrateEditorName(
    lookup: (String) -> String? = RepoLibrary.applicationPath(named:)
  ) {
    guard editorPath == nil, let name = editor, !name.isEmpty else { return }
    editorPath = lookup(name)
    editor = nil
  }

  /// Where an application of that name lives, if it is installed.
  public static func applicationPath(named name: String) -> String? {
    let trimmed = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    let roots = [
      "/Applications", "/System/Applications",
      (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
    ]
    for root in roots {
      let candidate = "\(root)/\(trimmed).app"
      if FileManager.default.fileExists(atPath: candidate) { return candidate }
    }
    return nil
  }

  /// The branch a workspace called `name` gets by default.
  ///
  /// No name means no branch. Returning a bare prefix like `kelvin/` looked
  /// harmless but was not: the create sheet showed it, the field wrote that value
  /// back through its binding, and the branch stopped following the name.
  public func suggestedBranch(for name: String) -> String {
    let slug = WorkspaceNaming.slug(name)
    guard !slug.isEmpty else { return "" }
    guard let prefix = branchPrefix?.trimmingCharacters(in: .whitespaces), !prefix.isEmpty else {
      return slug
    }
    return "\(prefix)/\(slug)"
  }

  public var workspaceRootURL: URL {
    URL(filePath: (workspaceRoot as NSString).expandingTildeInPath)
  }

  public subscript(name: String) -> RepoEntry? {
    repos.first { $0.name == name }
  }

  /// How many colours the palette holds. The library declares it so both the
  /// slot picker and the views agree.
  public static let colorSlots = 12

  /// Palette slot for a repo, falling back to its position in the library for
  /// entries written before slots were recorded.
  ///
  /// Returns `nil` for a repo that is not in the library — a worktree found on
  /// disk from a clone Grove does not know about.
  public func colorIndex(for name: String) -> Int? {
    guard let position = repos.firstIndex(where: { $0.name == name }) else { return nil }
    return repos[position].colorIndex ?? position % Self.colorSlots
  }

  /// The lowest palette slot no repo currently holds.
  public func nextColorIndex() -> Int {
    let taken = Set(repos.indices.compactMap { repos[$0].colorIndex ?? $0 % Self.colorSlots })
    return (0..<Self.colorSlots).first { !taken.contains($0) } ?? repos.count % Self.colorSlots
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
