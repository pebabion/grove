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

@Suite("decoding older library files")
struct LibraryDecodingTests {
  private func decode(_ json: String) throws -> RepoLibrary {
    try JSONDecoder().decode(RepoLibrary.self, from: Data(json.utf8))
  }

  @Test("reads a file written before a field existed")
  func toleratesMissingFields() throws {
    // Exactly what was on disk when toolOverrides was added. A default value on the
    // property does not make Swift's decoder accept the key being absent, so this
    // threw — and Grove showed no repos at all.
    let library = try decode(
      """
      {
        "workspaceRoot": "~/harmonic/worktrees",
        "branchPrefix": "kelvin",
        "repos": [{"name": "backend", "path": "~/harmonic/backend", "base": "origin/master"}]
      }
      """)

    #expect(library.workspaceRoot == "~/harmonic/worktrees")
    #expect(library.repos.map(\.name) == ["backend"])
    #expect(library.toolOverrides.isEmpty)
    #expect(library.terminalFont == nil)
    // Every field added since has to survive the same file. This test fails the moment
    // one is added without decodeIfPresent, which is the whole point of it.
    #expect(library.notifySessionEvents == nil)
    #expect(library.claudeHooks == nil)
    #expect(library.terminalMouseReporting == nil)
  }

  @Test("reads a repo entry missing its base branch")
  func toleratesMissingBase() throws {
    let library = try decode(#"{"repos":[{"name":"x","path":"~/x"}]}"#)

    #expect(library.repos.first?.base == "origin/main")
  }

  @Test("still refuses a file it cannot make sense of")
  func rejectsNonsense() {
    // A repo with no name is not a library with a default in it; it is broken, and
    // saying so is what stops Grove overwriting a file it misread.
    #expect(throws: (any Error).self) { try decode(#"{"repos":[{"path":"~/x"}]}"#) }
    #expect(throws: (any Error).self) { try decode("not json") }
  }

  @Test("a round trip keeps everything")
  func roundTrips() throws {
    var original = RepoLibrary(
      repos: [RepoEntry(name: "a", path: "~/a", colorIndex: 3)],
      workspaceRoot: "~/w",
      branchPrefix: "ada",
      terminalFont: "Menlo",
      terminalFontSize: 15
    )
    original.toolOverrides = ["gh": "/opt/gh"]

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(RepoLibrary.self, from: data)

    #expect(decoded == original)
  }
}

@Suite("terminal colour setting")
struct TerminalColourTests {
  @Test("a file written before the colour existed still loads")
  func toleratesMissingColour() throws {
    // The check that matters: every new persisted field must be decodeIfPresent, or
    // it hides the whole library the way toolOverrides did.
    let library = try JSONDecoder().decode(
      RepoLibrary.self,
      from: Data(#"{"repos":[],"workspaceRoot":"~/w","terminalFontSize":14}"#.utf8))

    #expect(library.terminalForeground == nil)
    #expect(library.terminalFontSize == 14)
  }

  @Test("the colour survives a round trip")
  func roundTrips() throws {
    let original = RepoLibrary(workspaceRoot: "~/w", terminalForeground: "#E8E8E8")

    let data = try JSONEncoder().encode(original)

    #expect(try JSONDecoder().decode(RepoLibrary.self, from: data).terminalForeground == "#E8E8E8")
  }
}
