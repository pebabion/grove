import Foundation
import Testing

@testable import GroveCore

@Suite("JSON storage")
struct StorageTests {
  let store = JSONStore()

  @Test("round-trips a repo library")
  func roundTripsLibrary() throws {
    let sandbox = try Sandbox()
    let file = sandbox.root.appending(path: "config/library.json")

    let library = RepoLibrary(
      repos: [
        RepoEntry(
          name: "frontend",
          path: "~/code/frontend",
          base: "origin/master",
          setupCommand: "ln -sf $GROVE_REPO_ROOT/app/.env app/.env && yarn install"
        ),
        RepoEntry(name: "backend", path: "~/code/backend", base: "origin/master"),
      ],
      workspaceRoot: "~/code/worktrees",
      editor: "Zed"
    )

    try store.save(library, to: file)
    let loaded = try store.load(RepoLibrary.self, from: file)

    #expect(loaded == library)
    #expect(loaded?["frontend"]?.setupCommand?.contains("yarn install") == true)
    #expect(loaded?["nope"] == nil)
  }

  @Test("returns nil rather than throwing for a missing file")
  func missingFileIsNotAnError() throws {
    let sandbox = try Sandbox()
    let missing = sandbox.root.appending(path: "nothing.json")

    #expect(try store.load(RepoLibrary.self, from: missing) == nil)
  }

  @Test("overwrites an existing file atomically")
  func overwritesExistingFile() throws {
    let sandbox = try Sandbox()
    let file = sandbox.root.appending(path: "library.json")

    try store.save(RepoLibrary(workspaceRoot: "~/first"), to: file)
    try store.save(RepoLibrary(workspaceRoot: "~/second"), to: file)

    #expect(try store.load(RepoLibrary.self, from: file)?.workspaceRoot == "~/second")
    // The temporary file used for the atomic replace must not survive.
    let leftovers = try FileManager.default
      .contentsOfDirectory(atPath: sandbox.root.path)
      .filter { $0.hasPrefix(".library.json") }
    #expect(leftovers.isEmpty)
  }

  @Test("round-trips a workspace file")
  func roundTripsWorkspaceFile() throws {
    let sandbox = try Sandbox()
    let file = sandbox.root.appending(path: GroveLocations.workspaceFileName)

    let workspace = WorkspaceFile(
      name: "tidb-performance",
      branch: "kelvin/tidb-performance",
      link: "https://example.invalid/ticket/1",
      repos: ["frontend", "backend"]
    )

    try store.save(workspace, to: file)
    let loaded = try store.load(WorkspaceFile.self, from: file)

    #expect(loaded?.name == "tidb-performance")
    #expect(loaded?.repos == ["frontend", "backend"])
    #expect(loaded?.link == "https://example.invalid/ticket/1")
  }

  @Test("expands tildes in library paths")
  func expandsTildes() {
    let entry = RepoEntry(name: "frontend", path: "~/code/frontend")

    #expect(entry.url.path.hasPrefix(NSHomeDirectory()))
    #expect(!entry.url.path.contains("~"))
  }
}
