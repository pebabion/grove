import Foundation
import Testing

@testable import GroveCore

/// Renaming moves a directory holding live worktrees. Without a repair step
/// every repo inside is left pointing at a path that no longer exists, so this
/// is tested against real git rather than trusted.
@Suite("renaming a workspace", .serialized)
struct RenameTests {
  let git = Git()
  let toolPaths = ToolPaths(searchPaths: ["/usr/bin", "/bin", "/opt/homebrew/bin"])

  @Test("moves the folder and leaves every worktree usable")
  func renameRepairsWorktrees() async throws {
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let frontend = try await sandbox.makeRepository(named: "frontend")
    let backend = try await sandbox.makeRepository(named: "backend")
    let library = RepoLibrary(
      repos: [
        RepoEntry(name: "frontend", path: frontend.path, base: "main"),
        RepoEntry(name: "backend", path: backend.path, base: "main"),
      ],
      workspaceRoot: root.path
    )

    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    let created = try await service.create(
      name: "First Try",
      branch: "kelvin/first-try",
      link: nil,
      repos: library.repos,
      in: root,
      onUpdate: { _ in }
    )
    #expect(created.lastPathComponent == "first-try")

    let before = await WorkspaceScanner(git: git).scan(root: root, library: library)
    let workspace = try #require(before.first)
    #expect(workspace.members.count == 2)

    let moved = try await service.rename(
      workspace: workspace, to: "Second Try", root: root, library: library)

    #expect(moved.lastPathComponent == "second-try")
    #expect(!FileManager.default.fileExists(atPath: created.path))

    // The real check: git still works inside each moved worktree, and the clone
    // agrees about where it lives.
    for name in ["frontend", "backend"] {
      let worktree = moved.appending(path: name)
      #expect(try await git.currentBranch(worktree: worktree) == "kelvin/first-try")
      #expect(try await git.hasUncommittedChanges(worktree: worktree) == false)
    }

    let listed = try await git.listWorktrees(repo: frontend)
    #expect(listed.contains { $0.path.hasSuffix("second-try/frontend") })
    #expect(!listed.contains { $0.path.contains("first-try") })

    // The scanner finds it under the new name with both repos intact.
    let after = await WorkspaceScanner(git: git).scan(root: root, library: library)
    #expect(after.count == 1)
    #expect(after.first?.name == "Second Try")
    #expect(after.first?.members.count == 2)
  }

  @Test("keeps the folder when only the display name changes")
  func renameToSameSlug() async throws {
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = try await sandbox.makeRepository(named: "frontend")
    let library = RepoLibrary(
      repos: [RepoEntry(name: "frontend", path: repo.path, base: "main")],
      workspaceRoot: root.path
    )

    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    _ = try await service.create(
      name: "thing", branch: "kelvin/thing", link: nil, repos: library.repos, in: root,
      onUpdate: { _ in })

    let workspace = try #require(
      await WorkspaceScanner(git: git).scan(root: root, library: library).first)

    // "Thing" slugs to "thing", so the directory must not move.
    let moved = try await service.rename(
      workspace: workspace, to: "Thing", root: root, library: library)

    #expect(moved.lastPathComponent == "thing")
    #expect(FileManager.default.fileExists(atPath: moved.appending(path: "frontend").path))
    #expect(
      await WorkspaceScanner(git: git).scan(root: root, library: library).first?.name == "Thing")
  }

  @Test("refuses a name another workspace already uses")
  func refusesCollision() async throws {
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = try await sandbox.makeRepository(named: "frontend")
    let library = RepoLibrary(
      repos: [RepoEntry(name: "frontend", path: repo.path, base: "main")],
      workspaceRoot: root.path
    )
    let service = WorkspaceService(git: git, toolPaths: toolPaths)

    _ = try await service.create(
      name: "one", branch: "kelvin/one", link: nil, repos: library.repos, in: root,
      onUpdate: { _ in })
    // A bare directory is enough to reserve the name.
    try FileManager.default.createDirectory(
      at: root.appending(path: "two"), withIntermediateDirectories: true)

    let workspace = try #require(
      await WorkspaceScanner(git: git).scan(root: root, library: library)
        .first { $0.file.name == "one" })

    await #expect(throws: WorkspaceError.self) {
      _ = try await service.rename(workspace: workspace, to: "Two", root: root, library: library)
    }
    #expect(FileManager.default.fileExists(atPath: root.appending(path: "one").path))
  }

  @Test("rejects an empty name")
  func rejectsEmptyName() async throws {
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = try await sandbox.makeRepository(named: "frontend")
    let library = RepoLibrary(
      repos: [RepoEntry(name: "frontend", path: repo.path, base: "main")],
      workspaceRoot: root.path
    )
    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    _ = try await service.create(
      name: "one", branch: "kelvin/one", link: nil, repos: library.repos, in: root,
      onUpdate: { _ in })
    let workspace = try #require(
      await WorkspaceScanner(git: git).scan(root: root, library: library).first)

    await #expect(throws: WorkspaceError.self) {
      _ = try await service.rename(workspace: workspace, to: "   ", root: root, library: library)
    }
  }
}
