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

  @Test("it says which step it is on, and the bar only goes forward")
  func reportsItsSteps() async throws {
    // A rename moves a folder and then repairs a worktree per repo — seconds of git with
    // nothing on screen unless it says so. Reported badly it is worse than silence, so the
    // shape of the report is asserted the way a teardown's is.
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
    _ = try await service.create(
      name: "First Try", branch: "kelvin/first-try", link: nil, repos: library.repos,
      in: root, onUpdate: { _ in })
    let before = await WorkspaceScanner(git: git).scan(root: root, library: library)
    let workspace = try #require(before.first)

    let steps = Steps()
    _ = try await service.rename(
      workspace: workspace, to: "Second Try", root: root, library: library,
      onPhase: { steps.add($0) })

    let labels = steps.labels
    #expect(labels.contains("Moving the folder"))
    #expect(labels.contains { $0.hasPrefix("Repairing ") })
    // One per repo, so the bar keeps moving through the part that takes the time.
    #expect(labels.filter { $0.hasPrefix("Repairing ") }.count == 2)
    let fractions = steps.fractions
    #expect(fractions == fractions.sorted(), "\(fractions)")
    #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
    withExtendedLifetime(sandbox) {}
  }

  /// Collects what arrives from another task without racing.
  private final class Steps: @unchecked Sendable {
    private let lock = NSLock()
    private var outlines: [WorkOutline] = []
    func add(_ outline: WorkOutline) { lock.withLock { outlines.append(outline) } }
    var labels: [String] { lock.withLock { outlines.map(\.label) } }
    var fractions: [Double] { lock.withLock { outlines.map(\.fraction) } }
  }
}

/// Everything Grove remembers about a workspace — the terminal it has open, the files pane,
/// which one is selected — is keyed on its URL. So the URL a scan reports has to be the one
/// creating it returned, and not merely the same place written differently.
@Suite("a workspace has one URL", .serialized)
struct WorkspaceIdentityTests {
  let git = Git()
  let toolPaths = ToolPaths(searchPaths: ["/usr/bin", "/bin", "/opt/homebrew/bin"])

  @Test("the URL a scan reports equals the one create returned")
  func scanMatchesCreate() async throws {
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = try await sandbox.makeRepository(named: "backend")
    let library = RepoLibrary(
      repos: [RepoEntry(name: "backend", path: repo.path, base: "main")],
      workspaceRoot: root.path)

    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    let created = try await service.create(
      name: "test3", branch: "kelvin/test3", link: nil, repos: library.repos,
      in: root, onUpdate: { _ in })

    let scanned = await WorkspaceScanner(git: git).scan(root: root, library: library)
    let match = try #require(scanned.first)

    // Equality, not path equality: contentsOfDirectory returns directory URLs with a
    // trailing slash and appending(path:) does not, and the two are unequal even after
    // standardizing. That difference lost the selection and the open terminal.
    #expect(match.url == created, "\(match.url.absoluteString) != \(created.absoluteString)")
    withExtendedLifetime(sandbox) {}
  }

  @Test("member URLs are written the same way too")
  func membersMatch() async throws {
    let sandbox = try Sandbox()
    let root = sandbox.root.appending(path: "spaces")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let repo = try await sandbox.makeRepository(named: "backend")
    let library = RepoLibrary(
      repos: [RepoEntry(name: "backend", path: repo.path, base: "main")],
      workspaceRoot: root.path)

    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    let created = try await service.create(
      name: "test4", branch: "kelvin/test4", link: nil, repos: library.repos,
      in: root, onUpdate: { _ in })

    let scanned = await WorkspaceScanner(git: git).scan(root: root, library: library)
    let member = try #require(scanned.first?.members.first)
    #expect(member.url == created.appending(path: "backend").identity)
    withExtendedLifetime(sandbox) {}
  }
}
