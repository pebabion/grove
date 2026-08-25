import Foundation
import Testing

@testable import GroveCore

/// What the sidebar prints per workspace. The rule it encodes — say the branch once, list
/// only the repos that are somewhere else — is the whole reason a row is scannable, so the
/// edge cases are pinned here rather than discovered in a screenshot.
@Suite("what a workspace row says")
struct WorkspaceSummaryTests {
  private func workspace(
    branch: String = "kelvin/thing",
    members: [(String, String?, RepoState, Bool)]
  ) -> Workspace {
    let url = URL(filePath: "/tmp/spaces/one").identity
    return Workspace(
      url: url,
      file: WorkspaceFile(name: "one", branch: branch, repos: members.map(\.0)),
      members: members.map { name, memberBranch, state, dirty in
        WorkspaceMember(
          repoName: name, url: url.appending(path: name).identity, branch: memberBranch,
          state: state, hasUncommittedChanges: dirty)
      })
  }

  @Test("repos on the workspace's branch are not listed one by one")
  func uniform() {
    let summary = WorkspaceSummary(
      workspace(members: [
        ("agent-graph", "kelvin/thing", .ready, false),
        ("backend", "kelvin/thing", .ready, false),
        ("kubernetes", "kelvin/thing", .ready, false),
      ]))
    #expect(summary.sharedBranch == "kelvin/thing")
    #expect(summary.divergent.isEmpty)
    #expect(summary.isUniform)
    #expect(summary.repoCount == 3)
  }

  @Test("a repo somewhere else is the one that gets a line")
  func oddOneOut() {
    // The case the redesign exists for: one repo on someone else's branch among three.
    let summary = WorkspaceSummary(
      workspace(members: [
        ("agent-graph", "devin/1787145049-scout-formatted-xlsx-exports", .ready, false),
        ("backend", "kelvin/thing", .ready, false),
        ("frontend", "kelvin/thing", .ready, false),
      ]))
    #expect(summary.divergent.map(\.repoName) == ["agent-graph"])
    #expect(!summary.isUniform)
  }

  @Test("a repo with no branch is not called divergent")
  func noBranch() {
    // Pending or detached. Its state says what is going on; a blank branch on screen
    // presented as news would not.
    let summary = WorkspaceSummary(
      workspace(members: [
        ("agent-graph", nil, .pending, false),
        ("backend", "", .unknown, false),
        ("frontend", "kelvin/thing", .ready, false),
      ]))
    #expect(summary.divergent.isEmpty)
    #expect(summary.repoCount == 3)
  }

  @Test("a workspace adopted from disk takes the branch its repos agree on")
  func adopted() {
    // Worktrees made before Grove have no grove.json, so nothing recorded the intent.
    let summary = WorkspaceSummary(
      workspace(
        branch: "",
        members: [
          ("agent-graph", "old/work", .unknown, false),
          ("backend", "old/work", .unknown, false),
        ]))
    #expect(summary.sharedBranch == "old/work")
    #expect(summary.divergent.isEmpty)
  }

  @Test("repos that agree on nothing all get a line")
  func noSharedBranch() {
    // Nothing to say once, so the row falls back to what it always did.
    let summary = WorkspaceSummary(
      workspace(
        branch: "",
        members: [
          ("agent-graph", "one", .unknown, false),
          ("backend", "two", .unknown, false),
        ]))
    #expect(summary.sharedBranch == nil)
    #expect(summary.divergent.map(\.repoName) == ["agent-graph", "backend"])
  }

  @Test("what is recorded wins over what the repos happen to be on")
  func recordedWins() {
    // Every repo has been switched away by hand. The workspace is still for its branch,
    // and all three are the exception — which is exactly what should be visible.
    let summary = WorkspaceSummary(
      workspace(members: [
        ("agent-graph", "elsewhere", .ready, false),
        ("backend", "elsewhere", .ready, false),
      ]))
    #expect(summary.sharedBranch == "kelvin/thing")
    #expect(summary.divergent.count == 2)
  }

  @Test("it counts what makes a workspace unsafe to remove, and what failed")
  func counts() {
    let summary = WorkspaceSummary(
      workspace(members: [
        ("agent-graph", "kelvin/thing", .ready, true),
        ("backend", "kelvin/thing", .failed, false),
        ("frontend", "kelvin/thing", .ready, true),
      ]))
    #expect(summary.dirtyCount == 2)
    #expect(summary.failedCount == 1)
  }

  @Test("an empty workspace says nothing rather than crashing")
  func empty() {
    let summary = WorkspaceSummary(workspace(branch: "", members: []))
    #expect(summary.repoCount == 0)
    #expect(summary.sharedBranch == nil)
    #expect(summary.divergent.isEmpty)
    #expect(summary.dirtyCount == 0)
  }
}
