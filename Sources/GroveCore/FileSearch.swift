import Foundation

/// One file offered as a search result.
public struct FileMatch: Sendable, Hashable, Identifiable {
  /// Repo-relative, as git reports it.
  public let path: String
  /// Which repo in the workspace it belongs to.
  public let repo: String

  public var id: String { "\(repo)/\(path)" }
  public var name: String { (path as NSString).lastPathComponent }

  public init(path: String, repo: String) {
    self.path = path
    self.repo = repo
  }
}

/// A workspace's files, prepared for searching.
///
/// The preparation is the point. Lowercasing each path and turning it into characters
/// costs nothing once and 70 to 90 milliseconds per keystroke when done for every file
/// every time — measured at 25,000 files, which is what three real repos hold. Bytes
/// rather than Characters for the same reason: a Swift `Character` is a grapheme
/// cluster, and comparing a few million of them per keypress is not free.
public struct FileIndex: Sendable {
  private struct Entry: Sendable {
    let match: FileMatch
    /// Lowercased UTF-8 of the filename and of the whole path, with the per-position
    /// bonuses that go with them. The bonuses depend only on the text, so they are
    /// computed here rather than on every keystroke.
    let name: [UInt8]
    let nameBonuses: [Int32]
    let path: [UInt8]
    let pathBonuses: [Int32]
  }

  private let entries: [Entry]
  public var count: Int { entries.count }

  public init(_ files: [FileMatch]) {
    entries = files.map { file in
      // Bonuses come from the original text and matching from the folded copy. Folding
      // first would have thrown away every camelCase hump before it could be scored,
      // which is exactly the signal that makes "gtv" find GroveTerminalView. ASCII
      // folding keeps the length, so the two agree position for position.
      return Entry(
        match: file,
        name: Self.folded(file.name),
        nameBonuses: FuzzyScore.bonuses(for: Array(file.name.utf8)),
        path: Self.folded(file.path),
        pathBonuses: FuzzyScore.bonuses(for: Array(file.path.utf8)))
    }
  }

  /// Lowercased ASCII bytes. Non-ASCII passes through unchanged, so a path with
  /// accented characters still matches exactly, just not case-insensitively.
  static func folded(_ text: String) -> [UInt8] {
    Array(text.utf8).map { FuzzyScore.folded($0) }
  }

  /// Ranked matches for `query`, best first.
  ///
  /// Subsequence matching, the way every editor's file finder works: "gtv" finds
  /// `GroveTerminalView.swift`. Anything stricter means typing whole path fragments,
  /// and anything looser fills the list with files that merely share letters.
  public func matches(for query: String, limit: Int = 200) -> [FileMatch] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      return
        entries
        .map(\.match)
        .sorted { $0.path < $1.path }
        .prefix(limit)
        .map { $0 }
    }

    // Split on whitespace and require every word, each matched on its own. A query is
    // words, not one run of characters: "people skill" has to find
    // skills/system/people-search/SKILL.md, and as a single subsequence it cannot,
    // because the path holds no space.
    let words =
      trimmed
      .split(whereSeparator: \.isWhitespace)
      .map { Self.folded(String($0)) }
    guard !words.isEmpty else {
      return entries.map(\.match).sorted { $0.path < $1.path }.prefix(limit).map { $0 }
    }
    // Kept as a running best rather than scored-then-sorted. A one-letter query matches
    // nearly every file, and sorting twenty-five thousand results took fifty
    // milliseconds a keystroke on its own -- longer than the scoring it followed.
    var best: [Ranked] = []
    best.reserveCapacity(limit)

    for entry in entries {
      guard let score = Self.score(words: words, in: entry) else { continue }
      let candidate = Ranked(match: entry.match, score: score)
      if best.count == limit, let worst = best.last, !Self.isBetter(candidate, than: worst) {
        continue
      }
      best.insert(candidate, at: Self.insertionPoint(for: candidate, in: best))
      if best.count > limit { best.removeLast() }
    }

    return best.map(\.match)
  }

  private struct Ranked: Sendable {
    let match: FileMatch
    let score: Int
  }

  /// A total order, so the result never depends on the order files came out of git:
  /// better score first, then shorter paths, then by identity.
  private static func isBetter(_ candidate: Ranked, than other: Ranked) -> Bool {
    if candidate.score != other.score { return candidate.score > other.score }
    if candidate.match.path.count != other.match.path.count {
      return candidate.match.path.count < other.match.path.count
    }
    return candidate.match.id < other.match.id
  }

  private static func insertionPoint(for candidate: Ranked, in sorted: [Ranked]) -> Int {
    var low = 0
    var high = sorted.count
    while low < high {
      let middle = (low + high) / 2
      if isBetter(candidate, than: sorted[middle]) {
        high = middle
      } else {
        low = middle + 1
      }
    }
    return low
  }

  /// Scores every word against one file, or nil if any word is missing.
  ///
  /// Each word is scored where it does best — the filename or the whole path — with a
  /// filename hit preferred, because a word someone types is usually the name of the
  /// thing they want rather than a directory on the way to it. Words are matched
  /// independently, so their order does not matter.
  private static func score(words: [[UInt8]], in entry: Entry) -> Int? {
    var total: Int32 = 0
    for word in words {
      let inName = FuzzyScore.score(word, in: entry.name, bonuses: entry.nameBonuses)
        .map { $0 + Self.nameReward }
      let inPath = FuzzyScore.score(word, in: entry.path, bonuses: entry.pathBonuses)

      guard let best = [inName, inPath].compactMap({ $0 }).max() else { return nil }
      total += best
    }
    // Averaged over the words, so a two-word query is not worth twice a one-word query
    // and scores stay comparable between them.
    return Int(total) / words.count
  }

  /// What a filename match is worth over a path match.
  ///
  /// Clear but not absolute: fzf scores a short query in the low hundreds, so this
  /// outranks an equally good path match without making a poor name match beat an
  /// excellent path one.
  private static let nameReward: Int32 = 96

}

/// Searching a list of files directly, without preparing an index first.
///
/// For a handful of files and for tests. Anything holding a repo's worth should build a
/// ``FileIndex`` once and keep it.
public enum FileSearch {
  public static func matches(for query: String, in files: [FileMatch], limit: Int = 200)
    -> [FileMatch]
  {
    FileIndex(files).matches(for: query, limit: limit)
  }
}
