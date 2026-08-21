import Foundation
import Testing

@testable import GroveCore

/// Adding a repo shows its row before disk has it, so what that row looks like is worth
/// pinning down: it has to match what the scan will report two seconds later, or the list
/// visibly rearranges itself once the scan lands.
@Suite("adding a repo to the list")
struct WorkspaceEditTests {
  private func workspace(_ path: String, repos: [String]) -> Workspace {
    let url = URL(filePath: "/tmp/spaces/\(path)").identity
    return Workspace(
      url: url,
      file: WorkspaceFile(name: path, branch: "kelvin/thing", repos: repos),
      members: repos.sorted().map {
        WorkspaceMember(
          repoName: $0, url: url.appending(path: $0).identity, branch: "kelvin/thing",
          state: .ready)
      })
  }

  @Test("the repo appears straight away, on the workspace's own branch")
  func inserts() throws {
    let list = [workspace("one", repos: ["agent-graph", "backend"])]
    let after = WorkspaceEdit.inserting(
      "frontend", at: list[0].url, branch: "kelvin/thing", into: after0(list))
    let member = try #require(after[0].members.first { $0.repoName == "frontend" })
    #expect(member.state == .pending)
    #expect(member.branch == "kelvin/thing")
    #expect(after[0].members.count == 3)
  }

  /// Keeps the call readable above.
  private func after0(_ list: [Workspace]) -> [Workspace] { list }

  @Test("its url is the form the scanner reports")
  func urlMatchesTheScanner() throws {
    // Anything keyed on a member's url — a terminal, the files pane — stops matching
    // otherwise. This is the trailing-slash trap that once looked like a killed terminal.
    let list = [workspace("one", repos: ["backend"])]
    let after = WorkspaceEdit.inserting(
      "frontend", at: list[0].url, branch: "kelvin/thing", into: list)
    let member = try #require(after[0].members.first { $0.repoName == "frontend" })
    #expect(member.url == list[0].url.appending(path: "frontend").identity)
  }

  @Test("members stay in the order the scan will put them in")
  func staysSorted() {
    // The scanner sorts by name. A row that appears at the end and then jumps reads as a
    // glitch, and it was one.
    let list = [workspace("one", repos: ["backend", "kubernetes"])]
    let after = WorkspaceEdit.inserting(
      "agent-graph", at: list[0].url, branch: "kelvin/thing", into: list)
    #expect(after[0].members.map(\.repoName) == ["agent-graph", "backend", "kubernetes"])
  }

  @Test("the metadata agrees with the members")
  func recordsTheRepo() {
    let list = [workspace("one", repos: ["backend"])]
    let after = WorkspaceEdit.inserting(
      "frontend", at: list[0].url, branch: "kelvin/thing", into: list)
    #expect(after[0].file.repos == ["backend", "frontend"])
  }

  @Test("a repo already there is not added twice")
  func noDuplicates() {
    // Add is offered from two places, and a double click on a slow add would otherwise
    // leave two rows with the same id — which breaks the list that draws them.
    let list = [workspace("one", repos: ["backend"])]
    let once = WorkspaceEdit.inserting(
      "backend", at: list[0].url, branch: "kelvin/thing", into: list)
    #expect(once[0].members.count == 1)
    #expect(once[0].file.repos == ["backend"])
  }

  @Test("only the workspace named is touched")
  func leavesOthersAlone() {
    let list = [
      workspace("one", repos: ["backend"]),
      workspace("two", repos: ["backend"]),
    ]
    let after = WorkspaceEdit.inserting(
      "frontend", at: list[0].url, branch: "kelvin/thing", into: list)
    #expect(after[0].members.count == 2)
    #expect(after[1].members.count == 1)
  }

  @Test("a workspace that is not in the list is not invented")
  func unknownWorkspace() {
    let list = [workspace("one", repos: ["backend"])]
    let after = WorkspaceEdit.inserting(
      "frontend", at: URL(filePath: "/tmp/spaces/gone").identity, branch: "kelvin/thing",
      into: list)
    #expect(after == list)
  }
}
