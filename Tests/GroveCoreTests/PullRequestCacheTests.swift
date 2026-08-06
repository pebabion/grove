import Foundation
import Testing

@testable import GroveCore

@Suite("how long a pull request answer keeps")
struct PullRequestFreshnessTests {
  private let now = Date(timeIntervalSince1970: 2_000_000)

  private func reading(_ pr: PullRequest?, agedBy seconds: TimeInterval) -> PullRequestReading {
    PullRequestReading(pullRequest: pr, fetchedAt: now.addingTimeInterval(-seconds))
  }

  private func pullRequest(state: String) -> PullRequest {
    PullRequest(number: 7, state: state, url: "https://example.com/7")
  }

  @Test("an open one goes stale quickly")
  func openGoesStale() {
    // It gains reviews, gets merged, gets closed. Holding the answer for long is how a
    // merged pull request goes on showing as open.
    let open = pullRequest(state: "OPEN")
    #expect(reading(open, agedBy: 60).isFresh(asOf: now))
    #expect(!reading(open, agedBy: 16 * 60).isFresh(asOf: now))
  }

  @Test("no pull request at all also goes stale quickly")
  func absenceGoesStale() {
    // One can be opened at any moment, so "there is none" is the most perishable
    // answer of the lot.
    #expect(reading(nil, agedBy: 60).isFresh(asOf: now))
    #expect(!reading(nil, agedBy: 16 * 60).isFresh(asOf: now))
  }

  @Test("a settled one keeps for a week")
  func settledKeeps() {
    // Merged and closed are final, so re-asking is a wasted call.
    for state in ["MERGED", "CLOSED"] {
      let settled = reading(pullRequest(state: state), agedBy: 6 * 24 * 60 * 60)
      #expect(settled.isFresh(asOf: now), "\(state) should still be fresh after six days")
    }
  }

  @Test("even a settled one is re-asked eventually")
  func settledExpires() {
    #expect(!reading(pullRequest(state: "MERGED"), agedBy: 8 * 24 * 60 * 60).isFresh(asOf: now))
  }

  @Test("an answer from the future is not treated as ancient")
  func clockSkew() {
    // A clock moved backwards makes the age negative. That must read as fresh rather
    // than wrapping into a refetch storm.
    #expect(reading(pullRequest(state: "OPEN"), agedBy: -3600).isFresh(asOf: now))
  }
}

@Suite("caching answers per repo and branch")
struct PullRequestCacheKeyTests {
  @Test("the same branch name in two repos is two answers")
  func keyedByBoth() {
    // Every repo has a branch called main, and they do not share a pull request.
    var cache = PullRequestCache()
    let fetched = Date(timeIntervalSince1970: 1000)
    cache["backend", "main"] = PullRequestReading(
      pullRequest: PullRequest(number: 1, state: "OPEN", url: "u"), fetchedAt: fetched)
    cache["frontend", "main"] = PullRequestReading(
      pullRequest: PullRequest(number: 2, state: "OPEN", url: "u"), fetchedAt: fetched)

    #expect(cache["backend", "main"]?.pullRequest?.number == 1)
    #expect(cache["frontend", "main"]?.pullRequest?.number == 2)
  }

  @Test("a branch never asked about has no answer")
  func missingIsNil() {
    #expect(PullRequestCache()["backend", "main"] == nil)
  }

  @Test("a stored absence is remembered as an absence, not as unknown")
  func absenceIsAnAnswer() {
    // "Asked, and there is no pull request" and "never asked" have to stay apart, or
    // Grove re-asks GitHub about every branch that has none, forever.
    var cache = PullRequestCache()
    cache["backend", "main"] = PullRequestReading(pullRequest: nil, fetchedAt: Date())
    #expect(cache["backend", "main"] != nil)
    #expect(cache["backend", "main"]?.pullRequest == nil)
  }

  @Test("survives being written and read back")
  func roundTrips() throws {
    var cache = PullRequestCache()
    cache["backend", "kelvin/thing"] = PullRequestReading(
      pullRequest: PullRequest(number: 42, state: "MERGED", url: "u"),
      fetchedAt: Date(timeIntervalSince1970: 1000))

    let data = try JSONEncoder().encode(cache)
    let back = try JSONDecoder().decode(PullRequestCache.self, from: data)
    #expect(back["backend", "kelvin/thing"]?.pullRequest?.number == 42)
    #expect(back["backend", "kelvin/thing"]?.pullRequest?.isSettled == true)
  }
}
