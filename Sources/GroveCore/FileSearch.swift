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
    /// Lowercased UTF-8 of the filename and of the whole path.
    let name: [UInt8]
    let path: [UInt8]
  }

  private let entries: [Entry]
  public var count: Int { entries.count }

  public init(_ files: [FileMatch]) {
    entries = files.map {
      Entry(
        match: $0,
        name: Self.folded($0.name),
        path: Self.folded($0.path))
    }
  }

  /// Lowercased ASCII bytes. Non-ASCII passes through unchanged, so a path with
  /// accented characters still matches exactly, just not case-insensitively.
  static func folded(_ text: String) -> [UInt8] {
    Array(text.utf8).map { byte in
      byte >= 65 && byte <= 90 ? byte + 32 : byte
    }
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

    let needle = Self.folded(trimmed)
    // Kept as a running best rather than scored-then-sorted. A one-letter query matches
    // nearly every file, and sorting twenty-five thousand results took fifty
    // milliseconds a keystroke on its own -- longer than the scoring it followed.
    var best: [Ranked] = []
    best.reserveCapacity(limit)

    for entry in entries {
      // A match on the filename beats one spread across directories, because that is
      // almost always what was meant.
      var score: Int
      if let inName = Self.score(needle, in: entry.name) {
        score = inName + 1000
      } else if let inPath = Self.score(needle, in: entry.path) {
        score = inPath
      } else {
        continue
      }

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

  /// Scores `needle` as a subsequence of `haystack`, rewarding runs and early hits.
  static func score(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard !needle.isEmpty else { return 0 }
    var score = 0
    var index = 0
    var previousHit = -2

    for byte in needle {
      var hit = -1
      while index < haystack.count {
        if haystack[index] == byte {
          hit = index
          index += 1
          break
        }
        index += 1
      }
      guard hit >= 0 else { return nil }
      // Consecutive characters are the strongest signal that this is the intended file.
      if hit == previousHit + 1 { score += 8 }
      if hit == 0 { score += 4 }
      previousHit = hit
    }
    // Prefer a tight match over one strung across a long name.
    return score + max(0, 20 - haystack.count / 4)
  }
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
