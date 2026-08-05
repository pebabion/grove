import Foundation

/// The two shapes a repo can offer a skill in.
///
/// Claude Code merged custom commands into skills: `.claude/commands/deploy.md` and
/// `.claude/skills/deploy/SKILL.md` both provide `/deploy`. Repos in use have both, so
/// Grove links both. Where the two collide Claude Code prefers the skill, which Grove
/// leaves alone rather than inventing a rule of its own.
public enum SkillKind: Sendable, Hashable, CaseIterable {
  /// A directory holding `SKILL.md`.
  case skill
  /// A single markdown file.
  case command

  /// Where they live, relative to a repo or workspace root.
  public var directory: String {
    switch self {
    case .skill: ".claude/skills"
    case .command: ".claude/commands"
    }
  }

  /// What the entry is called on disk, given the name it is invoked by.
  public func entry(named name: String) -> String {
    switch self {
    case .skill: name
    case .command: "\(name).md"
    }
  }

  /// The name something is invoked by, given its entry on disk.
  public func name(ofEntry entry: String) -> String? {
    switch self {
    case .skill:
      return entry
    case .command:
      guard entry.hasSuffix(".md") else { return nil }
      return String(entry.dropLast(3))
    }
  }
}

/// A skill found in one of a workspace's repos.
public struct DiscoveredSkill: Sendable, Hashable {
  public let repo: String
  /// The name it is invoked by, without any file extension.
  public let name: String
  public let kind: SkillKind

  public init(repo: String, name: String, kind: SkillKind) {
    self.repo = repo
    self.name = name
    self.kind = kind
  }
}

/// A symlink to make one repo's skill reachable from the workspace root.
public struct SkillLink: Sendable, Hashable {
  /// The entry to create, including `.md` for a command.
  public let entry: String
  /// Where the link points, relative to the directory holding it.
  public let target: String
  public let repo: String
  public let kind: SkillKind

  public init(entry: String, target: String, repo: String, kind: SkillKind) {
    self.entry = entry
    self.target = target
    self.repo = repo
    self.kind = kind
  }
}

/// Works out what to link into a workspace's own skills directories.
///
/// An agent started at the workspace root cannot see the skills its repos carry.
/// Claude Code loads project skills from the starting directory and its parents, and a
/// repo's `.claude/skills` is neither — it is a level down. Skills below the starting
/// directory do load, but only once Claude has read a file in that subdirectory, so
/// until then they are absent from autocomplete and cannot be invoked by name.
///
/// Symlinking each one into the workspace root fixes that, and Claude Code supports it
/// directly: an entry may be a symlink, and it reads the target. Confirmed against real
/// sessions — a skill and a command, both invisible from the workspace root, became
/// available through links, and the name each answered to was the link's name rather
/// than anything in its own frontmatter.
public enum SkillLinks {
  /// Names each link, keeping the original name when nothing collides.
  ///
  /// A single repo with a `deploy` skill keeps `/deploy`, because renaming it would
  /// break what the repo documents and what people already type. Two repos with the
  /// same one both get prefixed — neither keeps the bare name, since choosing between
  /// them would be arbitrary and would change with the order they were added.
  public static func plan(for discovered: [DiscoveredSkill]) -> [SkillLink] {
    var owners: [SkillKind: [String: Set<String>]] = [:]
    for entry in discovered {
      owners[entry.kind, default: [:]][entry.name, default: []].insert(entry.repo)
    }

    return
      discovered
      .sorted { ($0.repo, $0.name) < ($1.repo, $1.name) }
      .map { found in
        let contested = (owners[found.kind]?[found.name]?.count ?? 0) > 1
        let name = contested ? "\(found.repo)-\(found.name)" : found.name
        return SkillLink(
          entry: found.kind.entry(named: name),
          // Relative, so renaming a workspace moves the whole thing intact. An
          // absolute path would point at where the workspace used to be.
          target:
            "../../\(found.repo)/\(found.kind.directory)/\(found.kind.entry(named: found.name))",
          repo: found.repo,
          kind: found.kind
        )
      }
  }
}
