import Foundation
import Testing

@testable import GroveCore

/// Adding and removing repos rewrites worktrees and the workspace file. Tested against
/// real git, because the failures worth catching are the ones that leave a workspace
/// half-changed.
@Suite("adding and removing repos", .serialized)
struct WorkspaceChangeTests {
  let git = Git()
  let toolPaths = ToolPaths(searchPaths: ["/usr/bin", "/bin", "/opt/homebrew/bin"])

  private func service() -> WorkspaceService {
    WorkspaceService(git: git, toolPaths: toolPaths)
  }

  /// A workspace holding `backend`, plus a `frontend` in the library that is not in it.
  ///
  /// The sandbox is passed in rather than made here: it deletes its directory when it
  /// is released, so a fixture that owned it would take the repositories away with it
  /// the moment it returned.
  private func fixture(in sandbox: Sandbox) async throws -> (
    root: URL, workspace: URL, library: RepoLibrary
  ) {
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let backend = try await sandbox.makeRepository(named: "backend")
    let frontend = try await sandbox.makeRepository(named: "frontend")
    let library = RepoLibrary(
      repos: [
        RepoEntry(name: "backend", path: backend.path, base: "main"),
        RepoEntry(name: "frontend", path: frontend.path, base: "main"),
      ],
      workspaceRoot: root.path
    )

    let workspace = try await service().create(
      name: "work", branch: "kelvin/work", link: nil,
      repos: [library.repos[0]], in: root, onUpdate: { _ in })
    return (root, workspace, library)
  }

  private func workspaceFile(at workspace: URL) throws -> WorkspaceFile? {
    try JSONStore().load(
      WorkspaceFile.self, from: workspace.appending(path: GroveLocations.workspaceFileName))
  }

  @Test("adds a worktree and records it in the workspace file")
  func addsRepo() async throws {
    let sandbox = try Sandbox()
    let (_, workspace, library) = try await fixture(in: sandbox)

    try await service().addRepo(
      library.repos[1], to: workspace, branch: "kelvin/work", onUpdate: { _ in })

    let added = workspace.appending(path: "frontend")
    #expect(FileManager.default.fileExists(atPath: added.appending(path: ".git").path))
    #expect(try workspaceFile(at: workspace)?.repos.sorted() == ["backend", "frontend"])
    let branch = try await git.currentBranch(worktree: added)
    #expect(branch == "kelvin/work")
    withExtendedLifetime(sandbox) {}
  }

  @Test("refuses a repo the workspace already has")
  func refusesDuplicate() async throws {
    let sandbox = try Sandbox()
    let (_, workspace, library) = try await fixture(in: sandbox)

    await #expect(throws: WorkspaceError.self) {
      try await service().addRepo(
        library.repos[0], to: workspace, branch: "kelvin/work", onUpdate: { _ in })
    }
    // The one already there must survive the refusal untouched.
    #expect(FileManager.default.fileExists(atPath: workspace.appending(path: "backend").path))
    withExtendedLifetime(sandbox) {}
  }

  @Test("refuses a branch another worktree already holds")
  func refusesBranchInUse() async throws {
    // git will not check the same branch out twice, and finding out afterwards leaves
    // a half-made worktree behind.
    let sandbox = try Sandbox()
    let (root, workspace, library) = try await fixture(in: sandbox)
    let other = try await service().create(
      name: "other", branch: "kelvin/other", link: nil,
      repos: [library.repos[1]], in: root, onUpdate: { _ in })
    #expect(FileManager.default.fileExists(atPath: other.appending(path: "frontend").path))

    await #expect(throws: WorkspaceError.self) {
      try await service().addRepo(
        library.repos[1], to: workspace, branch: "kelvin/other", onUpdate: { _ in })
    }
    #expect(!FileManager.default.fileExists(atPath: workspace.appending(path: "frontend").path))
    withExtendedLifetime(sandbox) {}
  }

  @Test("removing takes the worktree and the record with it")
  func removesRepo() async throws {
    let sandbox = try Sandbox()
    let (_, workspace, library) = try await fixture(in: sandbox)
    let member = WorkspaceMember(
      repoName: "backend", url: workspace.appending(path: "backend"),
      branch: "kelvin/work", state: .ready)
    let space = Workspace(
      url: workspace,
      file: WorkspaceFile(name: "work", branch: "kelvin/work", repos: ["backend"]),
      members: [member])

    await service().removeRepo(
      member, from: space, library: library, deleteBranch: false, onUpdate: { _ in })

    #expect(!FileManager.default.fileExists(atPath: member.url.path))
    #expect(try workspaceFile(at: workspace)?.repos.isEmpty == true)
    // The workspace itself stays: removing a repo is not tearing down.
    #expect(FileManager.default.fileExists(atPath: workspace.path))
    withExtendedLifetime(sandbox) {}
  }

  @Test("removing a repo can leave its branch alone")
  func keepsBranchByDefault() async throws {
    let sandbox = try Sandbox()
    let (_, workspace, library) = try await fixture(in: sandbox)
    let member = WorkspaceMember(
      repoName: "backend", url: workspace.appending(path: "backend"),
      branch: "kelvin/work", state: .ready)
    let space = Workspace(
      url: workspace,
      file: WorkspaceFile(name: "work", branch: "kelvin/work", repos: ["backend"]),
      members: [member])

    await service().removeRepo(
      member, from: space, library: library, deleteBranch: false, onUpdate: { _ in })

    let repo = URL(fileURLWithPath: library.repos[0].path)
    let branches = try await git.run(["-C", repo.path, "branch", "--list", "kelvin/work"])
    #expect(branches.contains("kelvin/work"))
    withExtendedLifetime(sandbox) {}
  }
}
