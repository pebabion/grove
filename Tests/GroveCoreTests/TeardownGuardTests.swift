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
    steps: [String], phases: [String], repos: [String]
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
    return (steps.details, steps.phases, steps.repos)
  }

  /// Collects what arrives from another task without racing.
  private final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var _details: [String] = []
    private var _phases: [String] = []
    private var _repos: [String] = []

    func add(update: ProvisionUpdate) {
      lock.withLock {
        if let detail = update.detail { _details.append(detail) }
        _repos.append(update.repo)
      }
    }
    func add(phase: String) { lock.withLock { _phases.append(phase) } }

    var details: [String] { lock.withLock { _details } }
    var phases: [String] { lock.withLock { _phases } }
    var repos: [String] { lock.withLock { _repos } }
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
    #expect(report.phases.last == "Removing the workspace folder")
  }

  @Test("every repo is accounted for")
  func everyRepoReports() async throws {
    let report = try await removalReport(deleteBranches: false)
    #expect(Set(report.repos) == ["backend", "frontend"])
  }
}
