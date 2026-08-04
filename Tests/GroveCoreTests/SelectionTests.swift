import Foundation
import Testing

@testable import GroveCore

@Suite("selection after removal")
struct SelectionTests {
  @Test("takes the place of the removed row")
  func selectsTheRowBelow() {
    #expect(SelectionAfterRemoval.next(after: "b", in: ["a", "b", "c"]) == "c")
    #expect(SelectionAfterRemoval.next(after: "a", in: ["a", "b", "c"]) == "b")
  }

  @Test("falls back to the row above when the last one goes")
  func selectsTheRowAbove() {
    #expect(SelectionAfterRemoval.next(after: "c", in: ["a", "b", "c"]) == "b")
  }

  @Test("selects nothing when that was the only row")
  func nothingLeft() {
    #expect(SelectionAfterRemoval.next(after: "a", in: ["a"]) == nil)
    #expect(SelectionAfterRemoval.next(after: "a", in: []) == nil)
  }

  @Test("picks something sane when the removed row was not in the list")
  func removedRowAbsent() {
    #expect(SelectionAfterRemoval.next(after: "z", in: ["a", "b"]) == "a")
    #expect(SelectionAfterRemoval.next(after: "z", in: []) == nil)
  }

  @Test("works on the URLs the sidebar actually holds")
  func worksWithURLs() {
    let urls = ["one", "two", "three"].map { URL(filePath: "/w/\($0)") }

    #expect(SelectionAfterRemoval.next(after: urls[1], in: urls) == urls[2])
    #expect(SelectionAfterRemoval.next(after: urls[2], in: urls) == urls[1])
  }
}
