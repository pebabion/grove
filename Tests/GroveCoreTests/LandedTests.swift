import Foundation
import Testing

@testable import GroveCore

/// The teardown sheet used to label a branch "merged" from an ancestor check
/// alone. Both of these cases were wrong on real repositories, so both are
/// pinned here.
@Suite("has the work landed", .serialized)
struct LandedTests {
  let git = Git()

  @Test("a branch with no commits of its own is not merged work")
  func branchWithNothingOnIt() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "backend", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/backend")
    // Created from the base and never committed to, which is what an untouched
    // worktree looks like.
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/idle", base: "main")

    let risk = await WorktreeAuditor(git: git).audit(
      worktree: worktree,
      repo: RepoEntry(name: "backend", path: repo.path, base: "main")
    )

    // Nothing would be lost — but nothing was merged either. The old label said
    // "merged" here, which claimed work landed where there had never been any.
    #expect(!risk.hasCommitsNotInBase)
  }

  @Test("a squash merge leaves the branch outside its base")
  func squashMergeIsInvisibleToAncestry() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "agent-graph", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/agent-graph")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/work", base: "main")

    try sandbox.write("a feature\n", to: worktree.appending(path: "feature.txt"))
    try await sandbox.commit(in: worktree, message: "add the feature")

    // Squash it onto main the way GitHub's squash button does: one new commit
    // carrying the same tree, with a different identity.
    try await git.run(["-C", repo.path, "merge", "--squash", "kelvin/work"])
    try await git.run(["-C", repo.path, "commit", "-m", "add the feature (#1)"])
    try await git.run(["-C", repo.path, "push", "-q", "origin", "main"])

    let risk = await WorktreeAuditor(git: git).audit(
      worktree: worktree,
      repo: RepoEntry(name: "agent-graph", path: repo.path, base: "main")
    )

    // The work is fully in main, yet the branch still reports commits main lacks,
    // because the squash rewrote them. This is why the pull request state decides.
    #expect(risk.hasCommitsNotInBase)
  }

  @Test("a plain merge leaves nothing to lose")
  func plainMergeLeavesNothing() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/ff", base: "main")

    try sandbox.write("more\n", to: worktree.appending(path: "more.txt"))
    try await sandbox.commit(in: worktree, message: "more work")

    try await git.run(["-C", repo.path, "merge", "--no-ff", "-m", "merge", "kelvin/ff"])
    try await git.run(["-C", repo.path, "push", "-q", "origin", "main"])

    let risk = await WorktreeAuditor(git: git).audit(
      worktree: worktree,
      repo: RepoEntry(name: "frontend", path: repo.path, base: "main")
    )

    #expect(!risk.hasCommitsNotInBase)
  }
}
