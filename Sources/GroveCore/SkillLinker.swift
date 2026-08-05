import Foundation

/// Keeps a workspace's `.claude` directories matching the skills its repos carry.
///
/// Runs whenever the set of repos changes and on a rescan, because a branch can add or
/// drop a skill without Grove doing anything. Idempotent: the result depends on what is
/// on disk, not on what happened before.
public struct SkillLinker: Sendable {
  /// Not stored: FileManager is not Sendable, and this type is passed between tasks.
  private var manager: FileManager { .default }

  public init() {}

  /// What each repo offers, found by looking.
  public func discover(worktrees: [(repo: String, url: URL)]) -> [DiscoveredSkill] {
    worktrees.flatMap { worktree in
      SkillKind.allCases.flatMap { kind in
        discover(kind, in: worktree.url, repo: worktree.repo)
      }
    }
  }

  private func discover(_ kind: SkillKind, in worktree: URL, repo: String) -> [DiscoveredSkill] {
    let directory = worktree.appending(path: kind.directory, directoryHint: .isDirectory)
    guard let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }

    return entries.compactMap { entry in
      guard let name = kind.name(ofEntry: entry) else { return nil }
      // A skill is a directory holding SKILL.md; a command is a markdown file. Anything
      // else in these directories is not something to link.
      switch kind {
      case .skill:
        let manifest = directory.appending(path: entry).appending(path: "SKILL.md")
        guard manager.fileExists(atPath: manifest.path) else { return nil }
      case .command:
        var isDirectory: ObjCBool = false
        guard
          manager.fileExists(
            atPath: directory.appending(path: entry).path, isDirectory: &isDirectory),
          !isDirectory.boolValue
        else { return nil }
      }
      return DiscoveredSkill(repo: repo, name: name, kind: kind)
    }
  }

  /// Writes the links, and clears away the ones Grove no longer needs.
  ///
  /// A single link failing is skipped rather than thrown: a workspace whose skills could
  /// not all be linked still works, and one that refused to be created because of a
  /// symlink would not.
  @discardableResult
  public func link(_ discovered: [DiscoveredSkill], in workspace: URL) throws -> [SkillLink] {
    let wanted = SkillLinks.plan(for: discovered)
    var made: [SkillLink] = []

    for kind in SkillKind.allCases {
      let directory = workspace.appending(path: kind.directory, directoryHint: .isDirectory)
      let mine = wanted.filter { $0.kind == kind }

      // Do not create a directory for a kind that has nothing in it and never had.
      guard !mine.isEmpty || manager.fileExists(atPath: directory.path) else { continue }
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)

      prune(kind, in: directory, keeping: Set(mine.map(\.entry)))
      made += write(mine, into: directory)
    }
    return made
  }

  private func write(_ links: [SkillLink], into directory: URL) -> [SkillLink] {
    var made: [SkillLink] = []
    for link in links {
      let location = directory.appending(path: link.entry)

      if let existing = try? manager.destinationOfSymbolicLink(atPath: location.path) {
        if existing == link.target {
          made.append(link)
          continue
        }
        // Points somewhere stale, perhaps at a repo that has since been removed.
        try? manager.removeItem(at: location)
      } else if manager.fileExists(atPath: location.path) {
        // Something real is sitting there, put there by someone else. Leave it.
        continue
      }

      do {
        try manager.createSymbolicLink(atPath: location.path, withDestinationPath: link.target)
        made.append(link)
      } catch {
        continue
      }
    }
    return made
  }

  /// Removes links Grove made that are no longer wanted.
  ///
  /// Recognised by shape rather than by being unfamiliar: Grove's links are relative and
  /// point at `../../<repo>/<kind directory>/<entry>`. Anything else is left alone — a
  /// real directory, an absolute link, a link somewhere else entirely. These directories
  /// are Claude Code's, not Grove's, and people keep their own skills in them.
  private func prune(_ kind: SkillKind, in directory: URL, keeping wanted: Set<String>) {
    guard let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { return }

    for entry in entries where !wanted.contains(entry) {
      let location = directory.appending(path: entry)
      guard let target = try? manager.destinationOfSymbolicLink(atPath: location.path),
        Self.isGroveShaped(target, kind: kind)
      else { continue }
      try? manager.removeItem(at: location)
    }
  }

  /// Whether a link is one Grove would have written for this kind.
  static func isGroveShaped(_ target: String, kind: SkillKind) -> Bool {
    let expected = kind.directory.split(separator: "/").map(String.init)
    let parts = target.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    // Two dots, the repo, the kind's directory, then the entry.
    guard parts.count == 4 + expected.count, parts[0] == "..", parts[1] == "..",
      Array(parts[3..<(3 + expected.count)]) == expected
    else { return false }

    let repo = parts[2]
    let entry = parts[parts.count - 1]
    guard !repo.isEmpty, !entry.isEmpty, repo != "..", entry != ".." else { return false }
    return kind.name(ofEntry: entry) != nil
  }
}
