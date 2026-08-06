import Foundation
import Testing

@testable import GroveCore

@Suite("reading what gh said about a branch")
struct GitHubLookupTests {
  @Test("a pull request comes back with its details")
  func readsOne() {
    let lookup = GitHub.reading(
      gh: """
        [{"number":1786,"state":"OPEN","url":"https://github.com/o/r/pull/1786",
          "isDraft":false,"reviewDecision":"APPROVED"}]
        """)
    guard case .found(let pr) = lookup else {
      Issue.record("expected a pull request, got \(lookup)")
      return
    }
    #expect(pr.number == 1786)
    #expect(pr.state == "OPEN")
    #expect(pr.reviewDecision == "APPROVED")
    #expect(!pr.isSettled)
  }

  @Test("an empty list means the branch has none")
  func readsNone() {
    #expect(GitHub.reading(gh: "[]") == PullRequestLookup.none)
    #expect(GitHub.reading(gh: "[]\n") == PullRequestLookup.none)
  }

  @Test("output that cannot be read means the question went unanswered")
  func unreadableIsUnknown() {
    // Never `.none`. An unanswered question cached as "there is no pull request"
    // leaves the branch looking bare for as long as that answer keeps.
    #expect(GitHub.reading(gh: "") == .unknown)
    #expect(GitHub.reading(gh: "gh: command failed") == .unknown)
    #expect(GitHub.reading(gh: "{\"number\":1}") == .unknown)
    #expect(GitHub.reading(gh: "[{\"state\":\"OPEN\"}]") == .unknown)
  }

  @Test("optional fields may be missing")
  func toleratesMissingFields() {
    // reviewDecision is absent until someone reviews.
    let lookup = GitHub.reading(
      gh: #"[{"number":9,"state":"MERGED","url":"u","isDraft":false}]"#)
    guard case .found(let pr) = lookup else {
      Issue.record("expected a pull request")
      return
    }
    #expect(pr.reviewDecision == nil)
    #expect(pr.isSettled)
  }

  @Test("merged and closed are settled, open and draft are not")
  func settledStates() {
    // This is what decides a week of caching against fifteen minutes.
    #expect(PullRequest(number: 1, state: "MERGED", url: "u").isSettled)
    #expect(PullRequest(number: 1, state: "CLOSED", url: "u").isSettled)
    #expect(!PullRequest(number: 1, state: "OPEN", url: "u").isSettled)
    #expect(!PullRequest(number: 1, state: "", url: "u").isSettled)
  }

  @Test("only the first of several is taken")
  func takesTheFirst() {
    let lookup = GitHub.reading(
      gh: #"[{"number":1,"state":"OPEN","url":"u","isDraft":false},"#
        + #"{"number":2,"state":"CLOSED","url":"u","isDraft":false}]"#)
    guard case .found(let pr) = lookup else {
      Issue.record("expected a pull request")
      return
    }
    #expect(pr.number == 1)
  }
}
