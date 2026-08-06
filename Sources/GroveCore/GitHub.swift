import Foundation

/// A pull request for a branch.
public struct PullRequest: Codable, Sendable, Hashable {
  public var number: Int
  /// `OPEN`, `MERGED` or `CLOSED`.
  public var state: String
  public var url: String
  public var isDraft: Bool
  /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or absent.
  public var reviewDecision: String?

  public init(
    number: Int, state: String, url: String, isDraft: Bool = false,
    reviewDecision: String? = nil
  ) {
    self.number = number
    self.state = state
    self.url = url
    self.isDraft = isDraft
    self.reviewDecision = reviewDecision
  }

  /// True once the PR can no longer change, which is what makes it safe to cache
  /// for a long time.
  public var isSettled: Bool { state == "MERGED" || state == "CLOSED" }
}

/// The outcome of asking about a branch.
///
/// Three answers, not two. "No pull request" is a fact worth caching; "could not
/// find out" — no `gh`, not signed in, offline — must never be cached as though
/// it were one. Deliberately not `Codable`: only the first two reach disk, as a
/// plain optional, so the cache file stays readable and survives this type being
/// renamed.
public enum PullRequestLookup: Sendable, Hashable {
  case unknown
  case none
  case found(PullRequest)
}

/// Asks GitHub whether a branch has a pull request.
///
/// One lookup per branch, rather than listing a repo's recent pull requests and
/// matching. Listing looked cheaper but was measured wrong: in a busy repository
/// the hundred most recent pull requests span only days, and most live branches
/// fell outside that window — several of which did have pull requests. Targeted
/// lookups found every one, and eleven of them took 1.7 seconds five-at-a-time.
public struct GitHub: Sendable {
  /// Simultaneous `gh` calls. Each is a network round trip, so this is about
  /// being a reasonable API client rather than saturating anything local.
  public static let concurrencyLimit = 5

  private let executable: String
  private let shell: Shell

  public init(executable: String, environment: [String: String]? = nil) {
    self.executable = executable
    self.shell = Shell(environment: environment)
  }

  /// The pull request for `branch`, if the question can be answered at all.
  public func pullRequest(for branch: String, in worktree: URL) async -> PullRequestLookup {
    let result = try? await shell.run(
      executable,
      [
        "pr", "list",
        "--head", branch,
        "--state", "all",
        "--limit", "1",
        "--json", "number,state,url,isDraft,reviewDecision",
      ],
      in: worktree
    )
    guard let result, result.succeeded else { return .unknown }
    return Self.reading(gh: result.standardOutput)
  }

  /// Reads what `gh pr list --json` printed.
  ///
  /// Separate from the call so the three outcomes can be tested without a network or a
  /// signed-in `gh`. The distinction that matters is between an empty list, which means
  /// the branch has no pull request, and output that cannot be read, which means the
  /// question went unanswered. Caching the second as the first would leave a branch
  /// looking pull-requestless for as long as the answer keeps.
  static func reading(gh output: String) -> PullRequestLookup {
    guard let found = try? JSONDecoder().decode([PullRequest].self, from: Data(output.utf8))
    else { return .unknown }
    return found.first.map(PullRequestLookup.found) ?? .none
  }
}

/// One cached answer. A `nil` pull request means the branch has none.
public struct PullRequestReading: Codable, Sendable, Hashable {
  public var pullRequest: PullRequest?
  public var fetchedAt: Date

  public init(pullRequest: PullRequest?, fetchedAt: Date) {
    self.pullRequest = pullRequest
    self.fetchedAt = fetchedAt
  }

  /// Merged and closed pull requests are finished, so their answer keeps. An open
  /// one gains reviews and an absent one can appear at any moment, so those go
  /// stale quickly.
  public func isFresh(asOf now: Date = Date()) -> Bool {
    let age = now.timeIntervalSince(fetchedAt)
    if pullRequest?.isSettled == true {
      return age < 7 * 24 * 60 * 60
    }
    return age < 15 * 60
  }
}

/// Cached pull request answers, keyed by repo and branch.
public struct PullRequestCache: Codable, Sendable {
  public var readings: [String: PullRequestReading]

  public init(readings: [String: PullRequestReading] = [:]) {
    self.readings = readings
  }

  public static func key(repo: String, branch: String) -> String { "\(repo)|\(branch)" }

  public subscript(repo: String, branch: String) -> PullRequestReading? {
    get { readings[Self.key(repo: repo, branch: branch)] }
    set { readings[Self.key(repo: repo, branch: branch)] = newValue }
  }

  public static var fileURL: URL {
    GroveLocations.cacheDirectory.appending(path: "pull-requests.json")
  }
}
