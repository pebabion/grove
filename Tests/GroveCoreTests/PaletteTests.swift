import Foundation
import Testing

@testable import GroveCore

@Suite("repo colour slots")
struct PaletteTests {
  private func library(_ names: [String]) -> RepoLibrary {
    RepoLibrary(repos: names.map { RepoEntry(name: $0, path: "~/x/\($0)") })
  }

  @Test("gives every repo a different slot")
  func slotsAreDistinct() {
    let library = library(["agent-graph", "backend", "frontend", "kubernetes", "mcp"])

    let slots = library.repos.map { library.colorIndex(for: $0.name) }

    #expect(slots.allSatisfy { $0 != nil })
    #expect(Set(slots).count == library.repos.count)
  }

  @Test("keeps a recorded slot in preference to position")
  func recordedSlotWins() {
    var library = library(["a", "b"])
    library.repos[1].colorIndex = 7

    #expect(library.colorIndex(for: "b") == 7)
    #expect(library.colorIndex(for: "a") == 0)
  }

  @Test("returns nothing for a repo outside the library")
  func unknownRepoHasNoSlot() {
    #expect(library(["a"]).colorIndex(for: "somebody-elses-clone") == nil)
  }

  @Test("hands out the lowest free slot")
  func nextSlotIsLowestFree() {
    var library = library(["a", "b", "c"])
    #expect(library.nextColorIndex() == 3)

    // Free up slot 1 and it gets reused rather than growing forever.
    library.repos[1].colorIndex = 9
    #expect(library.nextColorIndex() == 1)
  }

  @Test("wraps rather than running off the end of the palette")
  func wrapsWhenFull() {
    let names = (0..<RepoLibrary.colorSlots).map { "repo\($0)" }
    let library = library(names)

    #expect(library.nextColorIndex() < RepoLibrary.colorSlots)
    #expect(library.colorIndex(for: "repo0") == 0)
  }
}
