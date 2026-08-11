import Foundation

/// Progress from a create, add or teardown run.
public struct ProvisionUpdate: Sendable {
  public let repo: String
  public let state: RepoState
  public let detail: String?
  public let log: String?

  public init(repo: String, state: RepoState, detail: String? = nil, log: String? = nil) {
    self.repo = repo
    self.state = state
    self.detail = detail
    self.log = log
  }
}

public enum WorkspaceError: Error, LocalizedError, Sendable {
  case nameTaken(String)
  case emptyName
  case noRepos
  case branchInUse(repo: String, path: String)
  case repoAlreadyPresent(String)
  case notUnderWorkspaceRoot(String)
  case setupFailed(repo: String, log: String)
  case repairFailed(String)

  public var errorDescription: String? {
    switch self {
    case .nameTaken(let name):
      "A workspace called \(name) already exists"
    case .emptyName:
      "Give the workspace a name"
    case .noRepos:
      "Pick at least one repo"
    case .branchInUse(let repo, let path):
      "\(repo) already has that branch checked out at \(path)"
    case .repoAlreadyPresent(let name):
      "\(name) is already in this workspace"
    case .notUnderWorkspaceRoot(let path):
      "Refusing to delete \(path): it is not inside the workspace root"
    case .setupFailed(let repo, let log):
      "Setup failed for \(repo): \(log)"
    case .repairFailed(let detail):
      "The folder moved but git could not be pointed at it:\n\(detail)"
    }
  }
}

/// Creates, changes and tears down workspaces.
/// How far through a run of work something is, and what it is doing.
///
/// A fraction as well as a sentence, so it can be drawn as a bar. Steps are counted in
/// repos rather than in operations: one repo may have a teardown hook and a branch to
/// delete where another has neither, and a bar that lurches because one repo had more to
/// do is worse than one that moves evenly.
public struct WorkOutline: Sendable, Equatable {
  public let label: String
  /// Between 0 and 1.
  public let fraction: Double

  public init(label: String, fraction: Double) {
    self.label = label
    self.fraction = min(1, max(0, fraction))
  }
}

public struct WorkspaceService: Sendable {
  private let git: Git
  private let toolPaths: ToolPaths
  private let store = JSONStore()
  private let resolver = HookResolver()
  private let hooks: HookRunner

  public init(git: Git, toolPaths: ToolPaths) {
    self.git = git
    self.toolPaths = toolPaths
    self.hooks = HookRunner(toolPaths: toolPaths)
  }

  // MARK: - Create

  /// Creates a workspace holding one worktree per repo, all on `branch`.
  ///
  /// Worktrees are added one at a time because `git worktree add` locks the
  /// source clone. Setup hooks then run together, since that is where the
  /// minutes go.
  public func create(
    name: String,
    branch: String,
    link: String?,
    repos: [RepoEntry],
    in root: URL,
    onUpdate: @escaping @Sendable (ProvisionUpdate) -> Void
  ) async throws -> URL {
    let slug = WorkspaceNaming.slug(name)
    guard !slug.isEmpty else { throw WorkspaceError.emptyName }
    guard !repos.isEmpty else { throw WorkspaceError.noRepos }

    let workspace = root.appending(path: slug)
    if FileManager.default.fileExists(atPath: workspace.path) {
      throw WorkspaceError.nameTaken(slug)
    }

    // Refuse before creating anything if a branch is checked out elsewhere.
    for repo in repos {
      if let holder = try await git.worktreeHolding(branch: branch, repo: repo.url) {
        throw WorkspaceError.branchInUse(repo: repo.name, path: holder)
      }
    }

    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try store.save(
      WorkspaceFile(name: name, branch: branch, link: link, repos: repos.map(\.name)),
      to: workspace.appending(path: GroveLocations.workspaceFileName)
    )

    // Fetch every repo at once. Fetching does not take the worktree lock, so
    // doing them one at a time only added a second or two per repo before
    // anything at all appeared on screen.
    await withTaskGroup(of: Void.self) { group in
      for repo in repos {
        group.addTask { [git] in
          onUpdate(ProvisionUpdate(repo: repo.name, state: .settingUp, detail: "Fetching"))
          try? await git.fetch(repo: repo.url)
        }
      }
    }

    var created: [RepoEntry] = []
    for repo in repos {
      onUpdate(ProvisionUpdate(repo: repo.name, state: .settingUp, detail: "Creating worktree"))
      do {
        try await git.addWorktree(
          repo: repo.url,
          at: workspace.appending(path: repo.name),
          branch: branch,
          base: repo.base
        )
        created.append(repo)
      } catch {
        onUpdate(
          ProvisionUpdate(
            repo: repo.name, state: .failed, detail: "Could not create worktree",
            log: error.localizedDescription))
      }
    }

    await runSetupHooks(for: created, workspace: workspace, branch: branch, onUpdate: onUpdate)
    linkSkills(in: workspace)
    return workspace
  }

  /// Rebuilds the workspace's own skills directory from the repos now in it.
  ///
  /// An agent started at the workspace root cannot otherwise reach the skills its
  /// repos carry: Claude Code loads project skills from the starting directory
  /// upwards, and a repo's `.claude/skills` is a level down. Reads what is on disk
  /// rather than what Grove just did, so it is safe to call at any point and corrects
  /// a workspace that was changed behind Grove's back.
  ///
  /// Never fatal. A workspace whose skills could not be linked still works; one that
  /// refused to be created because of a symlink would not.
  @discardableResult
  public func linkSkills(in workspace: URL) -> [SkillLink] {
    let linker = SkillLinker()
    let worktrees = Self.worktreeDirectories(in: workspace).map {
      (repo: $0.lastPathComponent, url: $0)
    }
    return (try? linker.link(linker.discover(worktrees: worktrees), in: workspace)) ?? []
  }

  /// Adds one more repo to an existing workspace.
  public func addRepo(
    _ repo: RepoEntry,
    to workspace: URL,
    branch: String,
    onUpdate: @escaping @Sendable (ProvisionUpdate) -> Void
  ) async throws {
    let worktree = workspace.appending(path: repo.name)
    if FileManager.default.fileExists(atPath: worktree.path) {
      throw WorkspaceError.repoAlreadyPresent(repo.name)
    }
    if let holder = try await git.worktreeHolding(branch: branch, repo: repo.url) {
      throw WorkspaceError.branchInUse(repo: repo.name, path: holder)
    }

    onUpdate(ProvisionUpdate(repo: repo.name, state: .settingUp, detail: "Fetching"))
    try? await git.fetch(repo: repo.url)

    onUpdate(ProvisionUpdate(repo: repo.name, state: .settingUp, detail: "Creating worktree"))
    try await git.addWorktree(repo: repo.url, at: worktree, branch: branch, base: repo.base)

    let metadataURL = workspace.appending(path: GroveLocations.workspaceFileName)
    if var file = try store.load(WorkspaceFile.self, from: metadataURL) {
      if !file.repos.contains(repo.name) { file.repos.append(repo.name) }
      try store.save(file, to: metadataURL)
    }

    await runSetupHooks(for: [repo], workspace: workspace, branch: branch, onUpdate: onUpdate)
    linkSkills(in: workspace)
  }

  /// Runs a repo's setup hook again, for when a lockfile moved or setup failed.
  public func runSetup(
    for repo: RepoEntry,
    workspace: URL,
    branch: String,
    onUpdate: @escaping @Sendable (ProvisionUpdate) -> Void
  ) async {
    await runSetupHooks(for: [repo], workspace: workspace, branch: branch, onUpdate: onUpdate)
  }

  private func runSetupHooks(
    for repos: [RepoEntry],
    workspace: URL,
    branch: String,
    onUpdate: @escaping @Sendable (ProvisionUpdate) -> Void
  ) async {
    await withTaskGroup(of: Void.self) { group in
      for repo in repos {
        group.addTask { [self] in
          let worktree = workspace.appending(path: repo.name)
          guard let hook = resolver.resolve(phase: .setup, repo: repo, worktree: worktree) else {
            onUpdate(ProvisionUpdate(repo: repo.name, state: .ready, detail: "No setup hook"))
            return
          }

          onUpdate(ProvisionUpdate(repo: repo.name, state: .settingUp, detail: "Running setup"))
          do {
            let result = try await hooks.run(
              hook, worktree: worktree, repo: repo, workspace: workspace, branch: branch)
            let log = (result.standardOutput + result.standardError)
              .trimmingCharacters(in: .whitespacesAndNewlines)
            // A worktree exists either way. Failed setup is a state to retry,
            // not a reason to throw the worktree away.
            onUpdate(
              ProvisionUpdate(
                repo: repo.name,
                state: result.succeeded ? .ready : .failed,
                detail: result.succeeded ? "Ready" : "Setup exited \(result.exitCode)",
                log: log.isEmpty ? nil : log
              ))
          } catch {
            onUpdate(
              ProvisionUpdate(
                repo: repo.name, state: .failed, detail: "Setup could not start",
                log: error.localizedDescription))
          }
        }
      }
    }
  }

  // MARK: - Rename

  /// Renames a workspace, moving its folder and repairing every worktree inside.
  ///
  /// The move is the whole difficulty. Each worktree's `.git` file points into
  /// its clone and the clone points back at the old path, so a plain `mv` leaves
  /// every repo in the workspace broken until `git worktree repair` runs.
  public func rename(
    workspace: Workspace,
    to newName: String,
    root: URL,
    library: RepoLibrary
  ) async throws -> URL {
    let slug = WorkspaceNaming.slug(newName)
    guard !slug.isEmpty else { throw WorkspaceError.emptyName }

    // Canonicalise before comparing or slicing paths. `standardizedFileURL`
    // leaves `/var` alone while FileManager hands back `/private/var`, and
    // mixing the two silently produced a path that existed nowhere.
    let resolvedRoot = root.canonical
    let current = workspace.url.canonical
    guard current.path.hasPrefix(resolvedRoot.path + "/") else {
      throw WorkspaceError.notUnderWorkspaceRoot(current.path)
    }

    var destination = current
    if slug != current.lastPathComponent {
      destination = resolvedRoot.appending(path: slug)
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw WorkspaceError.nameTaken(slug)
      }
      try FileManager.default.moveItem(at: current, to: destination)

      // Find the moved worktrees by looking at where they now are, rather than
      // by rewriting their old paths. A worktree's own `.git` file still names
      // its clone correctly — only the clone's record of the worktree is stale —
      // so each one can point the way back to the repo that needs repairing.
      var complaints: [String] = []
      for worktree in Self.worktreeDirectories(in: destination) {
        guard let clone = try await git.sourceClone(of: worktree) else { continue }
        if let complaint = try await git.repairWorktree(repo: clone, at: worktree) {
          complaints.append("\(worktree.lastPathComponent): \(complaint)")
        }
      }
      if !complaints.isEmpty {
        throw WorkspaceError.repairFailed(complaints.joined(separator: "\n"))
      }
    }

    let metadataURL = destination.appending(path: GroveLocations.workspaceFileName)
    var file = (try? store.load(WorkspaceFile.self, from: metadataURL)) ?? workspace.file
    file.name = newName
    try store.save(file, to: metadataURL)

    return destination
  }

  /// Directories under `root` that are git worktrees, plus `root` itself when it
  /// is one. Covers single-repo workspaces adopted from disk.
  static func worktreeDirectories(in root: URL) -> [URL] {
    let manager = FileManager.default
    var found: [URL] = []
    if manager.fileExists(atPath: root.appending(path: ".git").path) {
      found.append(root)
    }
    let children =
      (try? manager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
      )) ?? []
    for child in children {
      let isDirectory =
        (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      guard isDirectory, manager.fileExists(atPath: child.appending(path: ".git").path) else {
        continue
      }
      found.append(child)
    }
    return found
  }

  // MARK: - Audit

  /// What each repo in a workspace would lose if it were removed now.
  public func audit(workspace: Workspace, library: RepoLibrary) async -> [String: WorktreeRisk] {
    let auditor = WorktreeAuditor(git: git)
    var risks: [String: WorktreeRisk] = [:]
    for member in workspace.members {
      risks[member.repoName] = await auditor.audit(worktree: member.url)
    }
    return risks
  }

  // MARK: - Teardown

  /// Removes one repo's worktree, running its teardown hook first.
  public func removeRepo(
    _ member: WorkspaceMember,
    from workspace: Workspace,
    library: RepoLibrary,
    deleteBranch: Bool,
    onUpdate: @escaping @Sendable (ProvisionUpdate) -> Void
  ) async {
    await removeRepo(
      member, from: workspace, library: library, deleteBranch: deleteBranch,
      onUpdate: onUpdate, within: { _, _ in })
  }

  /// The same, reporting where it has got to within this one repo, from 0 to 1.
  ///
  /// The weights are guesses at what takes the time, and only roughly: removing the
  /// worktree deletes every file in it, which dwarfs the rest, and a teardown hook can
  /// take as long as it likes. Rough is enough for a bar that has to keep moving.
  func removeRepo(
    _ member: WorkspaceMember,
    from workspace: Workspace,
    library: RepoLibrary,
    deleteBranch: Bool,
    onUpdate: @escaping @Sendable (ProvisionUpdate) -> Void,
    within: @escaping @Sendable (String, Double) -> Void
  ) async {
    let repo = library[member.repoName]

    if let repo, let hook = resolver.resolve(phase: .teardown, repo: repo, worktree: member.url) {
      report("Running the teardown hook", 0.05)
      let result = try? await hooks.run(
        hook, worktree: member.url, repo: repo, workspace: workspace.url,
        branch: member.branch ?? workspace.file.branch)
      if let result, !result.succeeded {
        // Report it and carry on: a failed teardown hook must not leave the
        // worktree stranded.
        onUpdate(
          ProvisionUpdate(
            repo: member.repoName, state: .failed,
            detail: "Teardown hook exited \(result.exitCode)",
            log: result.standardError))
      }
    }

    // Each step says what it is doing rather than one line covering all of them.
    // Removing a worktree is the one operation here that destroys work, so a person
    // watching it deserves to know which part is taking the time and what it touched.
    func report(_ detail: String, _ progress: Double = 0) {
      onUpdate(ProvisionUpdate(repo: member.repoName, state: .settingUp, detail: detail))
      within(detail, progress)
    }

    if let repo {
      report("Removing the worktree", 0.35)
      let removal = try? await git.removeWorktree(repo: repo.url, at: member.url, force: true)
      if removal == .byHand {
        // Worth saying: git declined and the directory was deleted outright.
        report("Git would not remove it, so the folder was deleted", 0.75)
      }

      if deleteBranch, let branch = member.branch {
        report("Deleting the branch \(branch)", 0.8)
        try? await git.deleteBranch(repo: repo.url, branch: branch, force: true)
      }
    } else if FileManager.default.fileExists(atPath: member.url.path) {
      // No entry in the library, so there is no clone to ask: the folder is all there is.
      report("Deleting the folder — this repo is not in the library", 0.35)
      try? FileManager.default.removeItem(at: member.url)
    }

    report("Updating the workspace file", 0.9)
    let metadataURL = workspace.url.appending(path: GroveLocations.workspaceFileName)
    if var file = try? store.load(WorkspaceFile.self, from: metadataURL) {
      file.repos.removeAll { $0 == member.repoName }
      try? store.save(file, to: metadataURL)
    }

    // The removed repo's skills went with its worktree, so its links are now dangling.
    report("Relinking skills", 0.95)
    linkSkills(in: workspace.url)

    onUpdate(
      ProvisionUpdate(
        repo: member.repoName, state: .pending,
        detail: deleteBranch ? "Removed, with its branch" : "Removed, branch kept"))
  }

  /// Removes every worktree and then the workspace directory.
  ///
  /// `onPhase` reports what is happening to the workspace as a whole, which the per-repo
  /// updates cannot: which repo of how many is being dealt with, and the folder itself
  /// going at the end.
  public func teardown(
    workspace: Workspace,
    library: RepoLibrary,
    root: URL,
    deleteBranches: Bool,
    onUpdate: @escaping @Sendable (ProvisionUpdate) -> Void,
    onPhase: @escaping @Sendable (WorkOutline) -> Void = { _ in }
  ) async throws {
    // Never delete outside the configured root, whatever the caller passes.
    let resolvedRoot = root.canonical.path
    let resolved = workspace.url.canonical.path
    guard resolved.hasPrefix(resolvedRoot + "/") else {
      throw WorkspaceError.notUnderWorkspaceRoot(resolved)
    }

    // Everything queued says so, so a row that has not started yet does not look stuck.
    for member in workspace.members {
      onUpdate(ProvisionUpdate(repo: member.repoName, state: .pending, detail: "Waiting"))
    }

    // One step per repo, plus the folder at the end.
    let steps = Double(workspace.members.count + 1)
    for (index, member) in workspace.members.enumerated() {
      let base = Double(index) / steps
      onPhase(
        WorkOutline(
          label: "Removing \(member.repoName) — \(index + 1) of \(workspace.members.count)",
          fraction: base))
      await removeRepo(
        member, from: workspace, library: library, deleteBranch: deleteBranches,
        onUpdate: onUpdate,
        within: { detail, progress in
          onPhase(
            WorkOutline(
              label: "\(member.repoName): \(detail.prefix(1).lowercased())\(detail.dropFirst())",
              fraction: base + progress / steps))
        })
    }

    if FileManager.default.fileExists(atPath: workspace.url.path) {
      let base = Double(workspace.members.count) / steps
      try removeFolder(workspace.url) { name, progress in
        onPhase(
          WorkOutline(
            label: "Removing \(name)", fraction: base + progress / steps))
      }
    }
    onPhase(WorkOutline(label: "Removed \(workspace.name)", fraction: 1))
  }

  /// Deletes a directory a child at a time, naming each one.
  ///
  /// One `removeItem` on the whole tree says nothing for as long as it takes, and on a
  /// workspace holding a few `node_modules` that is most of the wait. Going one child at a
  /// time costs nothing and turns the slowest part of a teardown into something that moves.
  private func removeFolder(
    _ folder: URL, report: (_ name: String, _ progress: Double) -> Void
  ) throws {
    let manager = FileManager.default
    let children =
      (try? manager.contentsOfDirectory(atPath: folder.path))?.sorted() ?? []

    for (index, child) in children.enumerated() {
      report(child, Double(index) / Double(max(children.count, 1)))
      try? manager.removeItem(at: folder.appending(path: child))
    }

    // The folder itself last, named for what it is rather than by its own name, which
    // beside a list of children reads as though a child had the same name.
    report("the workspace folder", 1)
    if manager.fileExists(atPath: folder.path) {
      try manager.removeItem(at: folder)
    }
  }
}
