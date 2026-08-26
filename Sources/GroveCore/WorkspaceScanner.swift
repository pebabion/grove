import Foundation

/// Which row to select once one is removed.
///
/// Finder and Mail both land on the row that takes the deleted one's place, and
/// fall back to the one above when the last row goes. Leaving nothing selected
/// strands the user on an empty pane, which is a poor reply to a destructive
/// action.
public enum SelectionAfterRemoval {
  public static func next<T: Equatable>(after removed: T, in items: [T]) -> T? {
    guard let index = items.firstIndex(of: removed) else {
      return items.first { $0 != removed }
    }
    var remaining = items
    remaining.remove(at: index)
    guard !remaining.isEmpty else { return nil }
    return remaining[min(index, remaining.count - 1)]
  }
}

/// Turns a name into a directory-safe slug.
public enum WorkspaceNaming {
  /// Kebab-cases a branch name.
  ///
  /// Slashes survive, since branches are namespaced with them. Everything else
  /// that is not a letter or digit becomes a single hyphen — spaces included,
  /// which git will not accept at all.
  ///
  /// A trailing hyphen or slash is left in place, so this is safe to apply to
  /// half-typed text. ``finalBranchName(_:)`` tidies those away.
  public static func branchName(_ raw: String) -> String {
    var result = ""
    var lastWasDash = false
    for character in raw.lowercased() {
      if character == "/" {
        result.append(character)
        lastWasDash = false
      } else if character.isLetter || character.isNumber {
        result.append(character)
        lastWasDash = false
      } else if !lastWasDash, !result.isEmpty, !result.hasSuffix("/") {
        result.append("-")
        lastWasDash = true
      }
    }
    return result
  }

  /// The branch name to actually use: kebab-cased, with nothing dangling.
  ///
  /// Applied once, when the work is created, rather than to each keystroke.
  /// Rewriting a `TextField`'s text as it is typed leaves the field showing the
  /// old character until the next one arrives, so a typed space appeared to do
  /// nothing until you typed again.
  public static func finalBranchName(_ raw: String) -> String {
    let kebab = branchName(raw)
    let segments = kebab.split(separator: "/").map { segment -> String in
      var part = String(segment)
      while part.hasPrefix("-") { part.removeFirst() }
      while part.hasSuffix("-") { part.removeLast() }
      return part
    }
    return segments.filter { !$0.isEmpty }.joined(separator: "/")
  }

  public static func slug(_ name: String) -> String {
    let lowered = name.lowercased()
    var result = ""
    var lastWasDash = false
    for character in lowered {
      if character.isLetter || character.isNumber {
        result.append(character)
        lastWasDash = false
      } else if !lastWasDash, !result.isEmpty {
        result.append("-")
        lastWasDash = true
      }
    }
    while result.hasSuffix("-") { result.removeLast() }
    return result
  }
}

/// Finds workspaces on disk.
///
/// Disk is the source of truth. The scanner reads `grove.json` where it exists
/// and infers the rest, so worktrees made before Grove — or by hand since — show
/// up rather than being invisible.
public struct WorkspaceScanner: Sendable {
  private let git: Git
  private let store = JSONStore()

  public init(git: Git) {
    self.git = git
  }

  public func scan(root: URL, library: RepoLibrary) async -> [Workspace] {
    let manager = FileManager.default
    guard
      let entries = try? manager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    // Map every library repo's clone path to its name once, so each worktree
    // can be attributed by its shared .git directory.
    // A `let`, because a task group refuses to capture a mutable one — and it has no
    // business changing once the scan starts anyway.
    let repoByClone = library.repos.reduce(into: [String: String]()) { table, repo in
      table[repo.url.standardizedFileURL.path] = repo.name
    }

    let directories = entries.filter {
      (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    // Every workspace at once. Each one asks git four questions per worktree, and asking
    // them in a queue is what made a scan of nineteen worktrees take five seconds — which
    // every create, rename, add and removal waits on before it looks finished.
    //
    // Read-only git calls in separate worktrees do not contend: each has its own index,
    // and the clone they share is only read. This is not the worktree lock the rules
    // elsewhere are about — that one belongs to `git worktree add`, which is still serial.
    let workspaces = await withTaskGroup(of: Workspace?.self) { group in
      for entry in directories {
        group.addTask { [self] in await inspect(entry, repoByClone: repoByClone) }
      }
      var found: [Workspace] = []
      for await workspace in group {
        if let workspace { found.append(workspace) }
      }
      return found
    }

    return workspaces.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private func inspect(_ directory: URL, repoByClone: [String: String]) async -> Workspace? {
    let manager = FileManager.default
    let metadataURL = directory.appending(path: GroveLocations.workspaceFileName)
    let recorded = try? store.load(WorkspaceFile.self, from: metadataURL)

    // Child directories that are worktrees of a known repo.
    var members: [WorkspaceMember] = []
    let children =
      (try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []

    let childDirectories =
      children
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
      // Sorted, so the tie-break below is the same on every scan: a task group finishes in
      // whatever order it likes, and which of two same-named repos keeps the name would
      // otherwise change from one scan to the next.
      .sorted { $0.lastPathComponent < $1.lastPathComponent }

    let found = await withTaskGroup(of: (Int, WorkspaceMember?).self) { group in
      for (index, child) in childDirectories.enumerated() {
        group.addTask { [self] in (index, await member(at: child, repoByClone: repoByClone)) }
      }
      var byIndex: [Int: WorkspaceMember] = [:]
      for await (index, member) in group {
        if let member { byIndex[index] = member }
      }
      return childDirectories.indices.compactMap { byIndex[$0] }
    }

    for var member in found {
      // Two worktrees of one repo in the same workspace would collide on name,
      // and a duplicate id breaks the list that renders them. Directory name
      // breaks the tie.
      if members.contains(where: { $0.repoName == member.repoName }) {
        member.repoName = member.url.lastPathComponent
      }
      members.append(member)
    }

    // A directory that is itself a worktree counts as a single-repo workspace.
    // Several of these exist from before Grove.
    if members.isEmpty, let solo = await member(at: directory, repoByClone: repoByClone) {
      members = [solo]
    }

    guard !members.isEmpty || recorded != nil else { return nil }

    let file =
      recorded
      ?? WorkspaceFile(
        name: directory.lastPathComponent,
        branch: members.first?.branch ?? "",
        repos: members.map(\.repoName),
        createdAt: creationDate(of: directory)
      )

    members.sort { $0.repoName < $1.repoName }

    // Repos the metadata claims but disk does not have. Disk wins on state;
    // the entry stays visible so it can be retried or dropped.
    for name in file.repos where !members.contains(where: { $0.repoName == name }) {
      members.append(
        WorkspaceMember(
          repoName: name, url: directory.appending(path: name).identity, state: .pending)
      )
    }

    // One form for every workspace URL, or nothing keyed on it will match. See
    // URL.identity.
    return Workspace(url: directory.identity, file: file, members: members)
  }

  private func member(at url: URL, repoByClone: [String: String]) async -> WorkspaceMember? {
    guard FileManager.default.fileExists(atPath: url.appending(path: ".git").path) else {
      return nil
    }
    guard let clone = try? await git.sourceClone(of: url) else { return nil }

    // Name the member after its library entry, not its directory. Worktrees
    // made before Grove often sit in a folder named after the task rather than
    // the repo, and the library name is what setup and teardown hooks hang off.
    let clonePath = clone.standardizedFileURL.path
    let repoName = repoByClone[clonePath] ?? clone.lastPathComponent

    // Three independent questions, so three git processes at once rather than in turn.
    async let branch = try? await git.currentBranch(worktree: url)
    async let commit = try? await git.lastCommitDate(worktree: url)
    async let dirty = (try? await git.hasUncommittedChanges(worktree: url)) ?? false

    return await WorkspaceMember(
      repoName: repoName,
      url: url.identity,
      branch: branch,
      state: .unknown,
      lastCommit: commit,
      hasUncommittedChanges: dirty
    )
  }

  private func creationDate(of url: URL) -> Date {
    let values = try? url.resourceValues(forKeys: [.creationDateKey])
    return values?.creationDate ?? Date()
  }
}
