import Foundation
import Testing

@testable import GroveCore

/// The teardown audit decides what a user is warned about before work is
/// destroyed. Over-warning is its own failure: an alarm that fires on safe
/// things trains people to click through the one that matters.
@Suite("teardown audit", .serialized)
struct AuditTests {
  let git = Git()

  @Test("a stash outlives the worktree it was made in, so it is not a risk")
  func stashesAreNotAtRisk() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/thing", base: "main")

    try sandbox.write("edited\n", to: worktree.appending(path: "README.md"))
    try await git.run(["-C", worktree.path, "stash", "push", "-m", "made here"])

    // refs/stash belongs to the clone, so every worktree sees the same list.
    #expect(try await git.clonewideStashes(worktree: worktree).count == 1)
    #expect(try await git.clonewideStashes(worktree: repo).count == 1)

    let risk = await WorktreeAuditor(git: git).audit(worktree: worktree, repo: nil)
    #expect(risk.isEmpty)

    // The point: removing the worktree does not take the stash with it.
    try await git.removeWorktree(repo: repo, at: worktree, force: true)
    #expect(try await git.clonewideStashes(worktree: repo).count == 1)
  }

  @Test("reports commits that exist on no remote")
  func reportsUnpushedWork() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/thing", base: "main")

    try sandbox.write("new work\n", to: worktree.appending(path: "feature.txt"))
    try await sandbox.commit(in: worktree, message: "unpushed work")

    let risk = await WorktreeAuditor(git: git).audit(worktree: worktree, repo: nil)

    #expect(!risk.isEmpty)
    #expect(risk.unpushedCommits.contains { $0.hasSuffix("unpushed work") })
  }

  @Test("reports a real .env file but not a symlinked one")
  func distinguishesEnvFiles() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/thing", base: "main")

    // A setup hook that copies rather than links leaves secrets behind that
    // removal destroys for good.
    try sandbox.write("SECRET=copied\n", to: worktree.appending(path: ".env"))
    try sandbox.write("SECRET=source\n", to: repo.appending(path: ".env.shared"))
    try FileManager.default.createSymbolicLink(
      at: worktree.appending(path: ".env.shared"),
      withDestinationURL: repo.appending(path: ".env.shared")
    )

    let risk = await WorktreeAuditor(git: git).audit(worktree: worktree, repo: nil)

    #expect(risk.unlinkedEnvFiles.contains(".env"))
    #expect(!risk.unlinkedEnvFiles.contains(".env.shared"))
  }

  @Test("ignores .env.example, which is committed and replaceable")
  func skipsEnvExamples() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/thing", base: "main")

    try sandbox.write("KEY=\n", to: worktree.appending(path: ".env.example"))

    let risk = await WorktreeAuditor(git: git).audit(worktree: worktree, repo: nil)

    #expect(risk.unlinkedEnvFiles.isEmpty)
  }

  @Test("calls an untouched worktree safe")
  func cleanWorktreeIsEmpty() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/thing", base: "main")

    let risk = await WorktreeAuditor(git: git).audit(worktree: worktree, repo: nil)

    #expect(risk.isEmpty)
  }
}
