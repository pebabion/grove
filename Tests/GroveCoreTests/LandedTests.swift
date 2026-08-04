import Foundation
import Testing

@testable import GroveCore

/// Grove once decided "merged" by comparing a branch against its base. These
/// tests record why that cannot work, so nobody wires it back in: the pull
/// request's own state is the only signal that survives how teams actually merge.
@Suite("counting commits against a base", .serialized)
struct LandedTests {
  let git = Git()

  @Test("a squash merge leaves the branch still ahead of its base")
  func squashMergeStaysAhead() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "agent-graph", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/agent-graph")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/work", base: "main")

    try sandbox.write("a feature\n", to: worktree.appending(path: "feature.txt"))
    try await sandbox.commit(in: worktree, message: "add the feature")

    // Squash onto main the way GitHub's squash button does: one new commit with
    // the same tree and a different identity.
    try await git.run(["-C", repo.path, "merge", "--squash", "kelvin/work"])
    try await git.run(["-C", repo.path, "commit", "-m", "add the feature (#1)"])
    try await git.run(["-C", repo.path, "push", "-q", "origin", "main"])

    // The work is wholly in main, yet the branch still reports a commit main
    // lacks, because the squash rewrote it. Any "is it merged" check built on
    // this number would say no for as long as the branch exists.
    #expect(try await git.commitCount(worktree: worktree, notIn: "main") == 1)
  }

  @Test("a merge commit does bring the count to zero")
  func plainMergeClearsTheCount() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "frontend", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/ff", base: "main")

    try sandbox.write("more\n", to: worktree.appending(path: "more.txt"))
    try await sandbox.commit(in: worktree, message: "more work")
    try await git.run(["-C", repo.path, "merge", "--no-ff", "-m", "merge", "kelvin/ff"])

    #expect(try await git.commitCount(worktree: worktree, notIn: "main") == 0)
  }

  @Test("a branch never committed to also reports zero")
  func untouchedBranchReportsZero() async throws {
    let sandbox = try Sandbox()
    let repo = try await sandbox.makeRepository(named: "backend", withRemote: true)
    let worktree = sandbox.root.appending(path: "spaces/thing/backend")
    try await git.addWorktree(repo: repo, at: worktree, branch: "kelvin/idle", base: "main")

    // Zero for a quite different reason than the merge above, which is why this
    // number cannot be dressed up as "merged" either way.
    #expect(try await git.commitCount(worktree: worktree, notIn: "main") == 0)
  }
}
