import Foundation
import Testing

@testable import GroveCore

@Suite("changing a repo by name")
struct RepoUpdateTests {
  private var library: RepoLibrary {
    RepoLibrary(repos: [
      RepoEntry(name: "backend", path: "/clones/backend", base: "main"),
      RepoEntry(name: "frontend", path: "/clones/frontend", base: "master"),
    ])
  }

  @Test("changes the one named and no other")
  func changesTheRightOne() {
    var library = library
    library.update("frontend") { $0.base = "trunk" }
    #expect(library["frontend"]?.base == "trunk")
    #expect(library["backend"]?.base == "main")
  }

  @Test("a name that is gone changes nothing and does not trap")
  func missingIsHarmless() {
    // The crash this replaces: an index resolved before a repo was deleted, then used
    // to subscript the array afterwards.
    var library = library
    library.update("removed") { $0.base = "trunk" }
    #expect(library.repos.count == 2)
    #expect(library["backend"]?.base == "main")
  }

  @Test("changes nothing in an empty library")
  func emptyLibrary() {
    var library = RepoLibrary()
    library.update("backend") { $0.base = "trunk" }
    #expect(library.repos.isEmpty)
  }

  @Test("the change is visible to the next read")
  func persistsAcrossCalls() {
    var library = library
    library.update("backend") { $0.setupCommand = "make setup" }
    library.update("backend") { $0.teardownCommand = "make clean" }
    #expect(library["backend"]?.setupCommand == "make setup")
    #expect(library["backend"]?.teardownCommand == "make clean")
  }
}
