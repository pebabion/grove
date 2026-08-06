import Foundation
import Testing

@testable import GroveCore

/// A GUI app launched from Finder gets roughly `/usr/bin:/bin` and nothing else, so
/// every tool Grove runs is resolved through here. Getting this wrong means git is
/// "not found" on a machine that plainly has git.
@Suite("finding the tools Grove runs")
struct ToolPathsTests {
  @Test("finds a tool on the search path")
  func findsOnPath() {
    let paths = ToolPaths(searchPaths: ["/usr/bin", "/bin"])
    #expect(paths.location(of: "env") == "/usr/bin/env")
  }

  @Test("returns nothing for a tool that is not there")
  func missingIsNil() {
    // nil rather than a guess: a wrong path fails later and further away.
    let paths = ToolPaths(searchPaths: ["/usr/bin", "/bin"])
    #expect(paths.location(of: "grove-not-a-real-tool") == nil)
  }

  @Test("an override wins over the search path")
  func overrideWins() {
    // This is the escape hatch for a tool a login shell never reveals.
    let paths = ToolPaths(searchPaths: ["/usr/bin", "/bin"], overrides: ["env": "/bin/echo"])
    #expect(paths.location(of: "env") == "/bin/echo")
  }

  @Test("an override is used even when nothing else can find the tool")
  func overrideForUnknownTool() {
    let paths = ToolPaths(searchPaths: [], overrides: ["gh": "/bin/echo"])
    #expect(paths.location(of: "gh") == "/bin/echo")
  }

  @Test("an override pointing at nothing hides the tool rather than falling back")
  func brokenOverrideDoesNotFallBack() {
    // Worth knowing: one mistyped override makes the tool unavailable even though it
    // sits on the search path. Loud beats quietly running a different binary than the
    // one that was asked for.
    let paths = ToolPaths(
      searchPaths: ["/usr/bin", "/bin"], overrides: ["env": "/opt/custom/does-not-exist"])
    #expect(paths.location(of: "env") == nil)
  }

  @Test("an override pointing at something unexecutable is refused too")
  func unexecutableOverride() {
    let paths = ToolPaths(searchPaths: ["/bin"], overrides: ["echo": "/etc/hosts"])
    #expect(paths.location(of: "echo") == nil)
  }

  @Test("the first directory on the path wins")
  func earlierPathWins() {
    // Order is the whole point of a search path.
    let first = ToolPaths(searchPaths: ["/bin", "/usr/bin"]).location(of: "echo")
    #expect(first == "/bin/echo")
  }

  @Test("the environment it hands out carries the search path")
  func environmentCarriesPath() {
    let paths = ToolPaths(searchPaths: ["/opt/homebrew/bin", "/usr/bin"])
    let environment = paths.processEnvironment()
    #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
  }

  @Test("an inventory reports every tool, found or not")
  func inventoryListsAll() {
    // Settings shows this, so a missing tool has to appear as missing rather than be
    // left out of the list.
    let paths = ToolPaths(searchPaths: ["/usr/bin", "/bin"])
    let inventory = paths.inventory()
    #expect(!inventory.isEmpty)
    #expect(inventory.contains { $0.tool == "git" })
    #expect(inventory.allSatisfy { !$0.tool.isEmpty })
  }

  @Test("no search paths at all finds nothing rather than trapping")
  func emptyPaths() {
    #expect(ToolPaths().location(of: "git") == nil)
  }
}

@Suite("reading and writing Grove's own files")
struct JSONStoreTests {
  private let store = JSONStore()

  private struct Note: Codable, Equatable {
    var title: String
    var count: Int
  }

  private func temporaryFile() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "grove-store-\(UUID().uuidString)/note.json")
  }

  @Test("writes a file and reads it back")
  func roundTrip() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try store.save(Note(title: "a", count: 2), to: url)
    #expect(try store.load(Note.self, from: url) == Note(title: "a", count: 2))
  }

  @Test("creates the directory it is asked to write into")
  func createsDirectories() throws {
    // Grove's first run has no config directory at all.
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try store.save(Note(title: "a", count: 1), to: url)
    #expect(FileManager.default.fileExists(atPath: url.path))
  }

  @Test("a file that is not there is nothing, not a failure")
  func missingIsNil() throws {
    // An absent library is a new install, which is a normal state.
    #expect(try store.load(Note.self, from: temporaryFile()) == nil)
  }

  @Test("a file that cannot be read is an error, not an empty result")
  func unreadableThrows() throws {
    // The distinction that once mattered most: a library Grove could not decode had to
    // stop it saving over the top, so it must not come back as "nothing here".
    let url = temporaryFile()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    try Data("this is not json".utf8).write(to: url)

    #expect(throws: (any Error).self) {
      try store.load(Note.self, from: url)
    }
  }

  @Test("saving over an existing file replaces it")
  func overwrites() throws {
    let url = temporaryFile()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

    try store.save(Note(title: "first", count: 1), to: url)
    try store.save(Note(title: "second", count: 2), to: url)
    #expect(try store.load(Note.self, from: url)?.title == "second")
  }
}
