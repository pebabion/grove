import Foundation
import Testing

@testable import GroveCore

/// Teardown deletes a directory tree. The guard that keeps it inside the configured
/// workspace root is the last thing standing between a bad argument and someone's
/// home directory, so it is tested against the real filesystem rather than trusted.
@Suite("teardown stays inside the workspace root", .serialized)
struct TeardownGuardTests {
  let git = Git()
  let toolPaths = ToolPaths(searchPaths: ["/usr/bin", "/bin", "/opt/homebrew/bin"])

  private func service() -> WorkspaceService {
    WorkspaceService(git: git, toolPaths: toolPaths)
  }

  /// A workspace-shaped directory that is not under `root`.
  private func strayWorkspace(in sandbox: Sandbox) throws -> Workspace {
    let stray = sandbox.root.appending(path: "elsewhere/precious")
    try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
    try Data("do not delete".utf8).write(to: stray.appending(path: "keep.txt"))
    return Workspace(
      url: stray,
      file: WorkspaceFile(name: "precious", branch: "main", repos: []),
      members: []
    )
  }

  @Test("refuses a workspace outside the root, and deletes nothing")
  func refusesOutsideRoot() async throws {
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let stray = try strayWorkspace(in: sandbox)

    await #expect(throws: WorkspaceError.self) {
      try await service().teardown(
        workspace: stray, library: RepoLibrary(), root: root,
        deleteBranches: false, onUpdate: { _ in })
    }
    // The refusal is only worth anything if nothing was removed on the way to it.
    #expect(FileManager.default.fileExists(atPath: stray.url.appending(path: "keep.txt").path))
  }

  @Test("refuses the root itself")
  func refusesTheRoot() async throws {
    // Not under the root: it is the root. Removing it would take every workspace.
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let asWorkspace = Workspace(
      url: root, file: WorkspaceFile(name: "spaces", branch: "main", repos: []), members: [])
    await #expect(throws: WorkspaceError.self) {
      try await service().teardown(
        workspace: asWorkspace, library: RepoLibrary(), root: root,
        deleteBranches: false, onUpdate: { _ in })
    }
    #expect(FileManager.default.fileExists(atPath: root.path))
  }

  @Test("refuses a sibling whose name merely starts with the root's")
  func refusesPrefixSibling() async throws {
    // "/spaces-backup" starts with "/spaces" as text but is not inside it. A prefix
    // test done without the separator would delete it.
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    let sibling = sandbox.root.appending(path: "spaces-backup")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: sibling.appending(path: "keep.txt"))

    let asWorkspace = Workspace(
      url: sibling, file: WorkspaceFile(name: "spaces-backup", branch: "main", repos: []),
      members: [])
    await #expect(throws: WorkspaceError.self) {
      try await service().teardown(
        workspace: asWorkspace, library: RepoLibrary(), root: root,
        deleteBranches: false, onUpdate: { _ in })
    }
    #expect(FileManager.default.fileExists(atPath: sibling.appending(path: "keep.txt").path))
  }

  @Test("removes a workspace that is inside the root")
  func removesInsideRoot() async throws {
    // The guard has to let the real case through, or it is just a way to break
    // teardown.
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = try await sandbox.makeRepository(named: "backend")
    let library = RepoLibrary(
      repos: [RepoEntry(name: "backend", path: repo.path, base: "main")],
      workspaceRoot: root.path)
    let created = try await service().create(
      name: "doomed", branch: "kelvin/doomed", link: nil, repos: library.repos,
      in: root, onUpdate: { _ in })

    let workspace = Workspace(
      url: created,
      file: WorkspaceFile(name: "doomed", branch: "kelvin/doomed", repos: ["backend"]),
      members: [])
    try await service().teardown(
      workspace: workspace, library: library, root: root,
      deleteBranches: false, onUpdate: { _ in })

    #expect(!FileManager.default.fileExists(atPath: created.path))
    #expect(FileManager.default.fileExists(atPath: root.path))
  }

  @Test("takes the skill links with it, and does not delete through them")
  func removesSkillLinks() async throws {
    // Grove symlinks each repo's skills into the workspace root, so a removal has to take
    // them too — and must remove the link rather than what it points at.
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = try await sandbox.makeRepository(named: "backend")
    try sandbox.write(
      "---\nname: probe\ndescription: a skill\n---\n",
      to: repo.appending(path: ".claude/skills/probe/SKILL.md"))
    try await sandbox.commit(in: repo, message: "add a skill")

    let library = RepoLibrary(
      repos: [RepoEntry(name: "backend", path: repo.path, base: "main")],
      workspaceRoot: root.path)
    let created = try await service().create(
      name: "doomed", branch: "kelvin/doomed", link: nil, repos: library.repos,
      in: root, onUpdate: { _ in })

    // Creating links it, which is what makes the removal worth asserting.
    let link = created.appending(path: ".claude/skills/probe")
    let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)
    #expect(target == "../../backend/.claude/skills/probe")

    let workspace = Workspace(
      url: created,
      file: WorkspaceFile(name: "doomed", branch: "kelvin/doomed", repos: ["backend"]),
      members: [
        WorkspaceMember(
          repoName: "backend", url: created.appending(path: "backend"),
          branch: "kelvin/doomed", state: .ready)
      ])
    try await service().teardown(
      workspace: workspace, library: library, root: root,
      deleteBranches: false, onUpdate: { _ in })

    #expect(!FileManager.default.fileExists(atPath: link.path))
    #expect(!FileManager.default.fileExists(atPath: created.path))
    // The clone still has its own copy: removing a link must not reach through it. This is
    // the assertion worth having — the rest of the folder going is easy to see.
    #expect(
      FileManager.default.fileExists(
        atPath: repo.appending(path: ".claude/skills/probe/SKILL.md").path))
    withExtendedLifetime(sandbox) {}
  }
}

/// Removing a worktree is the one operation here that destroys work, so what it reports
/// while it runs is part of the feature rather than decoration.
@Suite("what a removal reports while it runs", .serialized)
struct TeardownProgressTests {
  let git = Git()
  let toolPaths = ToolPaths(searchPaths: ["/usr/bin", "/bin", "/opt/homebrew/bin"])

  private func service() -> WorkspaceService {
    WorkspaceService(git: git, toolPaths: toolPaths)
  }

  /// A workspace of two repos, and everything it said on the way out.
  private func removalReport(deleteBranches: Bool) async throws -> (
    steps: [String], phases: [String], repos: [String], fractions: [Double],
    states: [String: RepoState]
  ) {
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let backend = try await sandbox.makeRepository(named: "backend")
    let frontend = try await sandbox.makeRepository(named: "frontend")
    let library = RepoLibrary(
      repos: [
        RepoEntry(name: "backend", path: backend.path, base: "main"),
        RepoEntry(name: "frontend", path: frontend.path, base: "main"),
      ],
      workspaceRoot: root.path)

    let created = try await service().create(
      name: "doomed", branch: "kelvin/doomed", link: nil, repos: library.repos,
      in: root, onUpdate: { _ in })

    let members = ["backend", "frontend"].map {
      WorkspaceMember(
        repoName: $0, url: created.appending(path: $0), branch: "kelvin/doomed", state: .ready)
    }
    let workspace = Workspace(
      url: created,
      file: WorkspaceFile(name: "doomed", branch: "kelvin/doomed", repos: ["backend", "frontend"]),
      members: members)

    let steps = Reporter()
    try await service().teardown(
      workspace: workspace, library: library, root: root, deleteBranches: deleteBranches,
      onUpdate: { steps.add(update: $0) }, onPhase: { steps.add(phase: $0) })

    withExtendedLifetime(sandbox) {}
    return (steps.details, steps.phases, steps.repos, steps.fractions, steps.lastStates)
  }

  /// Collects what arrives from another task without racing.
  private final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var _details: [String] = []
    private var _phases: [String] = []
    private var _fractions: [Double] = []
    private var _repos: [String] = []
    private var _states: [String: RepoState] = [:]

    func add(update: ProvisionUpdate) {
      lock.withLock {
        if let detail = update.detail { _details.append(detail) }
        _repos.append(update.repo)
        _states[update.repo] = update.state
      }
    }
    func add(phase: WorkOutline) {
      lock.withLock {
        _phases.append(phase.label)
        _fractions.append(phase.fraction)
      }
    }

    var details: [String] { lock.withLock { _details } }
    var phases: [String] { lock.withLock { _phases } }
    var fractions: [Double] { lock.withLock { _fractions } }
    var repos: [String] { lock.withLock { _repos } }
    /// Where each repo was left, which is the state a row draws itself from.
    var lastStates: [String: RepoState] { lock.withLock { _states } }
  }

  @Test("names each step rather than covering them with one line")
  func namesEachStep() async throws {
    let report = try await removalReport(deleteBranches: false)
    #expect(report.steps.contains("Removing the worktree"))
    #expect(report.steps.contains("Updating the workspace file"))
    #expect(report.steps.contains("Relinking skills"))
  }

  @Test("says whether the branch was kept")
  func saysWhatHappenedToTheBranch() async throws {
    let kept = try await removalReport(deleteBranches: false)
    #expect(kept.steps.contains("Removed, branch kept"))
    #expect(!kept.steps.contains { $0.hasPrefix("Deleting the branch") })

    let deleted = try await removalReport(deleteBranches: true)
    #expect(deleted.steps.contains("Deleting the branch kelvin/doomed"))
    #expect(deleted.steps.contains("Removed, with its branch"))
  }

  @Test("a repo that has not started yet says it is waiting")
  func queuedReposSayWaiting() async throws {
    // Otherwise a row with a spinner and no words looks stuck rather than queued.
    let report = try await removalReport(deleteBranches: false)
    #expect(report.steps.filter { $0 == "Waiting" }.count == 2)
  }

  @Test("reports which repo of how many, and the folder at the end")
  func reportsWorkspaceProgress() async throws {
    let report = try await removalReport(deleteBranches: false)
    #expect(report.phases.contains("Removing backend — 1 of 2"))
    #expect(report.phases.contains("Removing frontend — 2 of 2"))
    // The folder goes a child at a time, so it is named piece by piece and then as a
    // whole, rather than in one line that would sit there for the length of the delete.
    #expect(report.phases.contains("Removing grove.json"))
    #expect(report.phases.contains("Removing the workspace folder"))
    // The last word is that it is done, which is what takes the bar to the end.
    #expect(report.phases.last == "Removed doomed")
  }

  @Test("a removed repo does not look like one that has not started")
  func removedIsItsOwnState() async throws {
    // Both are repos with nothing on disk. Reported as `pending`, a finished repo drew
    // the same row as a queued one, so a teardown looked like it had done nothing.
    let report = try await removalReport(deleteBranches: false)
    #expect(report.states["backend"] == .removed)
    #expect(report.states["frontend"] == .removed)
  }

  @Test("every repo is accounted for")
  func everyRepoReports() async throws {
    let report = try await removalReport(deleteBranches: false)
    #expect(Set(report.repos) == ["backend", "frontend"])
  }
}

extension TeardownProgressTests {
  @Test("progress only ever moves forward, and finishes at the end")
  func progressIsHonest() async throws {
    // A bar that goes backwards, or stops short of the end, is worse than no bar.
    let report = try await removalReport(deleteBranches: false)
    #expect(report.fractions == report.fractions.sorted())
    #expect(report.fractions.first == 0)
    #expect(report.fractions.last == 1)
    #expect(report.fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
  }
}

extension TeardownProgressTests {
  @Test("the bar moves during a repo, not only between repos")
  func movesWithinARepo() async throws {
    // Two repos and a folder would be three updates. The point of the finer reporting is
    // that the bar keeps moving through the parts that take the time.
    let report = try await removalReport(deleteBranches: true)
    #expect(report.phases.count > 8, "only \(report.phases.count) updates")
    #expect(report.fractions == report.fractions.sorted())
  }

  @Test("names each thing it deletes from the workspace folder")
  func namesWhatItDeletes() async throws {
    // One removeItem on the whole tree says nothing for as long as it takes, which on a
    // workspace holding node_modules is most of the wait.
    let report = try await removalReport(deleteBranches: false)
    #expect(report.phases.contains { $0.hasPrefix("Removing ") && $0.contains("grove.json") })
  }

  @Test("a step within a repo is attributed to that repo")
  func attributesStepsToRepos() async throws {
    let report = try await removalReport(deleteBranches: true)
    #expect(report.phases.contains { $0.hasPrefix("backend: ") })
    #expect(report.phases.contains { $0.contains("deleting the branch kelvin/doomed") })
  }
}
