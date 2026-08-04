import Foundation
import Testing

@testable import GroveCore

@Suite("worktree list --porcelain parsing")
struct GitParsingTests {
  @Test("parses the main worktree and a linked one")
  func parsesTwoEntries() {
    let output = """
      worktree /Users/x/code/frontend
      HEAD abc123def456
      branch refs/heads/master

      worktree /Users/x/code/worktrees/tidb/frontend
      HEAD 789abc012def
      branch refs/heads/kelvin/tidb-performance
      """

    let worktrees = Git.parseWorktreeList(output)

    #expect(worktrees.count == 2)
    #expect(worktrees[0].path == "/Users/x/code/frontend")
    #expect(worktrees[0].branch == "master")
    #expect(worktrees[0].head == "abc123def456")
    #expect(worktrees[1].branch == "kelvin/tidb-performance")
    #expect(worktrees.allSatisfy { !$0.isBare })
  }

  @Test("marks bare and locked worktrees")
  func flagsBareAndLocked() {
    let output = """
      worktree /Users/x/repos/thing.git
      bare

      worktree /Users/x/worktrees/held
      HEAD aaa111
      branch refs/heads/held
      locked reason goes here
      """

    let worktrees = Git.parseWorktreeList(output)

    #expect(worktrees[0].isBare)
    #expect(worktrees[0].branch == nil)
    #expect(worktrees[1].isLocked)
    #expect(worktrees[1].branch == "held")
  }

  @Test("reports a detached HEAD as having no branch")
  func handlesDetachedHead() {
    let output = """
      worktree /Users/x/worktrees/detached
      HEAD bbb222
      detached
      """

    let worktrees = Git.parseWorktreeList(output)

    #expect(worktrees.count == 1)
    #expect(worktrees[0].branch == nil)
  }

  @Test("ignores empty output")
  func handlesEmptyOutput() {
    #expect(Git.parseWorktreeList("").isEmpty)
    #expect(Git.parseWorktreeList("\n\n\n").isEmpty)
  }
}
