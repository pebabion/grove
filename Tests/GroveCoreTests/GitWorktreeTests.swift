import Foundation
import Testing

@testable import GroveCore

/// Exercises `Git` against a real repository in a temporary directory. These
/// are the operations that destroy work if they are wrong, so they are tested
/// against git itself rather than a stub.
@Suite("Git against a real repository", .serialized)
struct GitWorktreeTests {
  let git = Git()

  @Test("creates, lists and removes a worktree")
  func worktreeLifecycle() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend")

    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/thing", base: "main")

    let listed = try await git.listWorktrees(repo: repo)
    #expect(listed.count == 2)
    #expect(listed.contains { $0.branch == "kelvin/thing" })
    #expect(FileManager.default.fileExists(atPath: worktree.appending(path: "README.md").path))

    try await git.removeWorktree(repo: repo, at: worktree, force: true)

    #expect(try await git.listWorktrees(repo: repo).count == 1)
    #expect(!FileManager.default.fileExists(atPath: worktree.path))
  }

  @Test("checks out an existing branch instead of creating it twice")
  func reusesExistingBranch() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "backend")
    try await git.run(["-C", repo.path, "branch", "kelvin/existing", "main"])

    let worktree = sandbox.root.appending(path: "spaces/thing/backend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/existing", base: "main")

    let listed = try await git.listWorktrees(repo: repo)
    #expect(listed.contains { $0.branch == "kelvin/existing" })
  }

  @Test("reports which worktree already holds a branch")
  func detectsBranchHeldElsewhere() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend")
    let worktree = sandbox.root.appending(path: "spaces/one/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/taken", base: "main")

    let holder = try await git.worktreeHolding(branch: "kelvin/taken", repo: repo)

    #expect(holder != nil)
    #expect(holder?.hasSuffix("spaces/one/frontend") == true)
    #expect(try await git.worktreeHolding(branch: "kelvin/free", repo: repo) == nil)
  }

  @Test("finds commits that exist on no remote")
  func findsUnpushedCommits() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend")
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/work", base: "main")

    // No remote exists, so even the initial commit counts as unpushed. That
    // is the point: a branch with no upstream still holds work at risk.
    try sandbox.write("changed\n", to: worktree.appending(path: "README.md"))
    try await sandbox.commit(in: worktree, message: "local only")

    let unpushed = try await git.unpushedCommits(worktree: worktree)

    #expect(unpushed.count >= 1)
    #expect(unpushed.contains { $0.hasSuffix("local only") })
  }

  @Test("separates dirty, untracked and ignored files")
  func categorizesStatusEntries() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend")
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/dirty", base: "main")

    try sandbox.write("edited\n", to: worktree.appending(path: "README.md"))
    try sandbox.write("scratch\n", to: worktree.appending(path: "notes.txt"))
    try sandbox.write("SECRET=1\n", to: worktree.appending(path: ".env.local"))

    let entries = try await git.statusEntries(worktree: worktree, includeIgnored: true)

    #expect(entries.tracked.contains("README.md"))
    #expect(entries.untracked.contains("notes.txt"))
    #expect(entries.ignored.contains(".env.local"))
    #expect(try await git.hasUncommittedChanges(worktree: worktree))
  }

  @Test("reports merge status between branches")
  func reportsMergeStatus() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend")
    try await git.run(["-C", repo.path, "branch", "kelvin/untouched", "main"])

    #expect(try await git.isMerged(repo: repo, branch: "kelvin/untouched", into: "main"))
  }

  @Test("returns nil for a default branch when there is no remote")
  func toleratesMissingRemote() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend")

    #expect(try await git.defaultBranch(repo: repo) == nil)
  }
}

/// A throwaway directory that cleans itself up, plus helpers for building
/// repositories inside it.
final class Sandbox {
  let root: URL
  private let git = Git()

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appending(path: "grove-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: root)
  }

  func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try contents.write(to: url, atomically: true, encoding: .utf8)
  }

  /// A repository on `main` with one commit and a `.gitignore` covering `.env*`.
  func makeRepository(named name: String) async throws -> URL {
    let repo = root.appending(path: "repos/\(name)")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

    try await git.run(["-C", repo.path, "init", "-b", "main"])
    try await git.run(["-C", repo.path, "config", "user.name", "Grove Tests"])
    try await git.run(["-C", repo.path, "config", "user.email", "tests@grove.invalid"])
    try await git.run(["-C", repo.path, "config", "commit.gpgsign", "false"])

    try write("# \(name)\n", to: repo.appending(path: "README.md"))
    try write(".env*\n", to: repo.appending(path: ".gitignore"))
    try await commit(in: repo, message: "initial commit")

    return repo
  }

  func commit(in worktree: URL, message: String) async throws {
    try await git.run(["-C", worktree.path, "add", "-A"])
    try await git.run(["-C", worktree.path, "commit", "-m", message])
  }
}
