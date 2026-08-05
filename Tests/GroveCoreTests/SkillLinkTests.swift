import Foundation
import Testing

@testable import GroveCore

@Suite("naming the links into a workspace")
struct SkillLinkPlanTests {
  @Test("a skill only one repo has keeps its own name")
  func uniqueKeepsName() {
    // Renaming it would break what the repo documents and what people already type.
    let plan = SkillLinks.plan(for: [
      DiscoveredSkill(repo: "backend", name: "deploy", kind: .skill),
      DiscoveredSkill(repo: "frontend", name: "storybook", kind: .skill),
    ])
    #expect(plan.map(\.entry).sorted() == ["deploy", "storybook"])
  }

  @Test("a skill two repos share gets prefixed on both sides")
  func collisionPrefixesBoth() {
    // Neither keeps the bare name: choosing between them would be arbitrary, and the
    // choice would change with the order the repos were added.
    let plan = SkillLinks.plan(for: [
      DiscoveredSkill(repo: "backend", name: "deploy", kind: .skill),
      DiscoveredSkill(repo: "frontend", name: "deploy", kind: .skill),
    ])
    #expect(plan.map(\.entry).sorted() == ["backend-deploy", "frontend-deploy"])
  }

  @Test("a collision does not rename anything else")
  func collisionIsLocal() {
    let plan = SkillLinks.plan(for: [
      DiscoveredSkill(repo: "backend", name: "deploy", kind: .skill),
      DiscoveredSkill(repo: "frontend", name: "deploy", kind: .skill),
      DiscoveredSkill(repo: "backend", name: "migrate", kind: .skill),
    ])
    let entries = Set(plan.map(\.entry))
    #expect(entries.contains("migrate"))
    #expect(entries.contains("backend-deploy"))
    #expect(entries.contains("frontend-deploy"))
  }

  @Test("targets are relative, so a workspace can be renamed")
  func relativeTargets() {
    // Grove renames workspaces by moving the folder. An absolute target would go on
    // pointing at where the workspace used to be.
    let plan = SkillLinks.plan(for: [DiscoveredSkill(repo: "backend", name: "deploy", kind: .skill)]
    )
    #expect(plan.first?.target == "../../backend/.claude/skills/deploy")
    #expect(plan.first?.target.hasPrefix("/") == false)
  }

  @Test("the same repos in a different order give the same plan")
  func stableOrder() {
    let one = SkillLinks.plan(for: [
      DiscoveredSkill(repo: "frontend", name: "deploy", kind: .skill),
      DiscoveredSkill(repo: "backend", name: "deploy", kind: .skill),
    ])
    let two = SkillLinks.plan(for: [
      DiscoveredSkill(repo: "backend", name: "deploy", kind: .skill),
      DiscoveredSkill(repo: "frontend", name: "deploy", kind: .skill),
    ])
    #expect(one == two)
  }

  @Test("nothing to link is not an error")
  func empty() {
    #expect(SkillLinks.plan(for: []).isEmpty)
  }
}

@Suite("linking skills into a workspace on disk")
struct SkillLinkerTests {
  private let manager = FileManager.default

  /// A workspace holding repos, each with the skills named.
  private func workspace(_ repos: [String: [String]]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "grove-skills-\(UUID().uuidString)")
    for (repo, skills) in repos {
      for skill in skills {
        let directory = root.appending(path: "\(repo)/.claude/skills/\(skill)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("---\nname: \(skill)\n---\n".utf8)
          .write(to: directory.appending(path: "SKILL.md"))
      }
    }
    return root
  }

  private func links(in workspace: URL) -> [String] {
    (try? manager.contentsOfDirectory(atPath: workspace.appending(path: ".claude/skills").path))
      .map { $0.sorted() } ?? []
  }

  @Test("finds the skills a repo carries and links them")
  func linksDiscovered() throws {
    let root = try workspace(["backend": ["deploy"], "frontend": ["storybook"]])
    defer { try? manager.removeItem(at: root) }

    let linker = SkillLinker()
    let found = linker.discover(worktrees: [
      ("backend", root.appending(path: "backend")),
      ("frontend", root.appending(path: "frontend")),
    ])
    #expect(found.count == 2)
    try linker.link(found, in: root)
    #expect(links(in: root) == ["deploy", "storybook"])
  }

  @Test("a link resolves to the skill it stands for")
  func linkResolves() throws {
    let root = try workspace(["backend": ["deploy"]])
    defer { try? manager.removeItem(at: root) }

    let linker = SkillLinker()
    try linker.link(
      linker.discover(worktrees: [("backend", root.appending(path: "backend"))]),
      in: root)

    let manifest = root.appending(path: ".claude/skills/deploy/SKILL.md")
    #expect(manager.fileExists(atPath: manifest.path))
  }

  @Test("a directory without SKILL.md is not a skill")
  func ignoresNonSkills() throws {
    let root = try workspace(["backend": ["deploy"]])
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(
      at: root.appending(path: "backend/.claude/skills/notes"), withIntermediateDirectories: true)

    let linker = SkillLinker()
    #expect(linker.discover(worktrees: [("backend", root.appending(path: "backend"))]).count == 1)
  }

  @Test("running twice changes nothing")
  func idempotent() throws {
    let root = try workspace(["backend": ["deploy"]])
    defer { try? manager.removeItem(at: root) }

    let linker = SkillLinker()
    let worktrees = [("backend", root.appending(path: "backend"))]
    try linker.link(linker.discover(worktrees: worktrees), in: root)
    try linker.link(linker.discover(worktrees: worktrees), in: root)
    #expect(links(in: root) == ["deploy"])
  }

  @Test("a removed repo takes its links with it")
  func prunesRemoved() throws {
    let root = try workspace(["backend": ["deploy"], "frontend": ["storybook"]])
    defer { try? manager.removeItem(at: root) }

    let linker = SkillLinker()
    let both = [
      ("backend", root.appending(path: "backend")), ("frontend", root.appending(path: "frontend")),
    ]
    try linker.link(linker.discover(worktrees: both), in: root)
    #expect(links(in: root).count == 2)

    // The workspace now holds only backend.
    try linker.link(
      linker.discover(worktrees: [("backend", root.appending(path: "backend"))]), in: root)
    #expect(links(in: root) == ["deploy"])
  }

  @Test("leaves a skill someone wrote by hand alone")
  func keepsHandWritten() throws {
    // This directory is Claude Code's, not Grove's, and people keep their own skills
    // in it. Deleting one because Grove did not create it would destroy real work.
    let root = try workspace(["backend": ["deploy"]])
    defer { try? manager.removeItem(at: root) }

    let mine = root.appending(path: ".claude/skills/mine")
    try manager.createDirectory(at: mine, withIntermediateDirectories: true)
    try Data("---\nname: mine\n---\n".utf8).write(to: mine.appending(path: "SKILL.md"))

    let linker = SkillLinker()
    try linker.link(
      linker.discover(worktrees: [("backend", root.appending(path: "backend"))]), in: root)
    #expect(links(in: root) == ["deploy", "mine"])
  }

  @Test("leaves a link someone else made alone")
  func keepsForeignLinks() throws {
    let root = try workspace(["backend": ["deploy"]])
    let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "grove-elsewhere-\(UUID().uuidString)")
    try manager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    defer {
      try? manager.removeItem(at: root)
      try? manager.removeItem(at: elsewhere)
    }

    let skills = root.appending(path: ".claude/skills")
    try manager.createDirectory(at: skills, withIntermediateDirectories: true)
    try manager.createSymbolicLink(
      atPath: skills.appending(path: "borrowed").path, withDestinationPath: elsewhere.path)

    let linker = SkillLinker()
    try linker.link([], in: root)
    #expect(links(in: root).contains("borrowed"))
  }

  @Test("only removes links shaped like the ones it writes")
  func recognisesOwnShape() {
    // Prune has to tell Grove's links from everyone else's, and being unfamiliar is
    // not enough of a test -- a hand-written link would fail it.
    #expect(SkillLinker.isGroveShaped("../../backend/.claude/skills/deploy", kind: .skill))
    #expect(!SkillLinker.isGroveShaped("/Users/me/skills/deploy", kind: .skill))
    #expect(!SkillLinker.isGroveShaped("../../backend/.claude/commands/deploy", kind: .skill))
    #expect(!SkillLinker.isGroveShaped("../elsewhere", kind: .skill))
    #expect(!SkillLinker.isGroveShaped("../../../escape/.claude/skills/deploy", kind: .skill))
    #expect(SkillLinker.isGroveShaped("../../backend/.claude/commands/babysit.md", kind: .command))
    #expect(!SkillLinker.isGroveShaped("../../backend/.claude/commands/babysit", kind: .command))
  }

  @Test("repairs a link that points somewhere stale")
  func repairsStale() throws {
    let root = try workspace(["backend": ["deploy"]])
    defer { try? manager.removeItem(at: root) }

    let skills = root.appending(path: ".claude/skills")
    try manager.createDirectory(at: skills, withIntermediateDirectories: true)
    try manager.createSymbolicLink(
      atPath: skills.appending(path: "deploy").path,
      withDestinationPath: "../../gone/.claude/skills/deploy")

    let linker = SkillLinker()
    try linker.link(
      linker.discover(worktrees: [("backend", root.appending(path: "backend"))]), in: root)
    let target = try manager.destinationOfSymbolicLink(
      atPath: skills.appending(path: "deploy").path)
    #expect(target == "../../backend/.claude/skills/deploy")
  }

  @Test("a workspace with no skills gets no directory")
  func noSkillsNoDirectory() throws {
    let root = try workspace(["backend": []])
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }

    try SkillLinker().link([], in: root)
    #expect(!manager.fileExists(atPath: root.appending(path: ".claude").path))
  }
}

@Suite("linking the older command form")
struct CommandLinkTests {
  private let manager = FileManager.default

  @Test("a command is a file, and its link keeps the extension")
  func commandNaming() {
    // Claude Code merged commands into skills, and repos in use still have them, so
    // /babysit-pr has to work from the workspace root too.
    let plan = SkillLinks.plan(for: [
      DiscoveredSkill(repo: "backend", name: "babysit-pr", kind: .command)
    ])
    #expect(plan.first?.entry == "babysit-pr.md")
    #expect(plan.first?.target == "../../backend/.claude/commands/babysit-pr.md")
  }

  @Test("commands collide only with commands")
  func separateNamespaces() {
    // They live in different directories, so a skill and a command of the same name do
    // not clash on disk. Claude Code prefers the skill, which is its rule to make.
    let plan = SkillLinks.plan(for: [
      DiscoveredSkill(repo: "backend", name: "deploy", kind: .skill),
      DiscoveredSkill(repo: "frontend", name: "deploy", kind: .command),
    ])
    #expect(Set(plan.map(\.entry)) == ["deploy", "deploy.md"])
  }

  @Test("finds and links both forms from a repo")
  func linksBoth() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "grove-both-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: root) }

    let skill = root.appending(path: "backend/.claude/skills/tests")
    try manager.createDirectory(at: skill, withIntermediateDirectories: true)
    try Data("---\nname: tests\n---\n".utf8).write(to: skill.appending(path: "SKILL.md"))

    let commands = root.appending(path: "backend/.claude/commands")
    try manager.createDirectory(at: commands, withIntermediateDirectories: true)
    try Data("run it\n".utf8).write(to: commands.appending(path: "babysit-pr.md"))

    let linker = SkillLinker()
    let found = linker.discover(worktrees: [("backend", root.appending(path: "backend"))])
    #expect(found.count == 2)
    try linker.link(found, in: root)

    #expect(manager.fileExists(atPath: root.appending(path: ".claude/skills/tests/SKILL.md").path))
    #expect(manager.fileExists(atPath: root.appending(path: ".claude/commands/babysit-pr.md").path))
  }

  @Test("a directory inside commands is not a command")
  func ignoresDirectories() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "grove-cmddir-\(UUID().uuidString)")
    defer { try? manager.removeItem(at: root) }
    try manager.createDirectory(
      at: root.appending(path: "backend/.claude/commands/notes.md"),
      withIntermediateDirectories: true)

    let linker = SkillLinker()
    #expect(linker.discover(worktrees: [("backend", root.appending(path: "backend"))]).isEmpty)
  }
}
