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
