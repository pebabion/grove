import Foundation

/// fzf's scoring, which is what the fuzzy finders people are used to descend from.
///
/// The greedy version this replaces took the first occurrence of each character and
/// scored what it found, so a file whose letters happen to appear early but scattered
/// beat one where they sit together further along. This aligns the query against the
/// text properly — the same dynamic programme fzf uses — so "wsql" prefers
/// `warehouse_sql.py` over a path that merely contains those letters in order.
///
/// Constants are fzf's, not invented here. They encode judgements worth inheriting: a
/// match just after a separator or at a camelCase hump is worth far more than one in
/// the middle of a word, and a run of adjacent characters is worth more than the sum of
/// its parts.
public enum FuzzyScore {
  static let match: Int32 = 16
  static let gapStart: Int32 = -3
  static let gapExtension: Int32 = -1
  static let boundary: Int32 = 8
  static let boundaryWhite: Int32 = 10
  static let boundaryDelimiter: Int32 = 9
  static let nonWord: Int32 = 8
  static let camel: Int32 = 7
  static let consecutive: Int32 = 4
  static let firstCharMultiplier: Int32 = 2

  enum CharClass: UInt8 {
    case white, nonWord, delimiter, lower, upper, letter, number
  }

  static func charClass(_ byte: UInt8) -> CharClass {
    switch byte {
    case 0x61...0x7A: .lower
    case 0x41...0x5A: .upper
    case 0x30...0x39: .number
    case 0x20, 0x09, 0x0A, 0x0D: .white
    // Path separators and the punctuation that divides names: matching just after one
    // of these is a word start, which is what people aim at when they type.
    case UInt8(ascii: "/"), UInt8(ascii: ":"), UInt8(ascii: ";"), UInt8(ascii: "|"),
      UInt8(ascii: ","), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."):
      .delimiter
    case 0x80...0xFF: .letter
    default: .nonWord
    }
  }

  static func bonus(previous: CharClass, current: CharClass) -> Int32 {
    switch (previous, current) {
    case (.white, _) where current != .white: boundaryWhite
    case (.delimiter, _) where current != .white && current != .nonWord: boundaryDelimiter
    case (.nonWord, _) where current != .white && current != .nonWord: boundary
    case (.lower, .upper): camel
    case (_, .number) where previous != .number: camel
    case (_, .nonWord), (_, .white): nonWord
    default: 0
    }
  }

  /// The bonus each position in `text` carries, which depends only on the text.
  ///
  /// Computed once per file when the index is built. It is the same for every query, and
  /// recomputing it per keystroke was measurable.
  public static func bonuses(for text: [UInt8]) -> [Int32] {
    var previous = CharClass.white
    return text.map { byte in
      let current = charClass(byte)
      defer { previous = current }
      return bonus(previous: previous, current: current)
    }
  }

  /// How well `needle` matches `text`, or nil when it does not appear at all.
  ///
  /// `needle` must already be lowercased; `text` is matched case-insensitively for
  /// ASCII so a query never has to guess at capitals.
  public static func score(_ needle: [UInt8], in text: [UInt8], bonuses: [Int32]) -> Int32? {
    guard !needle.isEmpty else { return 0 }
    guard needle.count <= text.count else { return nil }

    // One character needs no alignment: there is nothing to align it against, and the
    // best it can do is the best-placed occurrence. This is the first keystroke, when
    // nothing has been narrowed down yet and every file is still a candidate.
    if needle.count == 1 {
      let target = needle[0]
      var best: Int32 = 0
      for index in text.indices where folded(text[index]) == target {
        best = max(best, match + bonuses[index] * firstCharMultiplier)
      }
      return best > 0 ? best : nil
    }

    // A cheap pass first: if the characters are not present in order, no alignment
    // exists and the expensive part is skipped. This rejects almost everything.
    guard let window = window(needle, in: text) else { return nil }

    let start = window.lowerBound
    let width = window.count
    let rows = needle.count

    return withUnsafeTemporaryAllocation(of: Int32.self, capacity: width * 2) { scores in
      withUnsafeTemporaryAllocation(of: Int32.self, capacity: width * 2) { runs in
        var previousRow = 0
        var currentRow = width
        var best: Int32 = 0

        for row in 0..<rows {
          let target = needle[row]
          var inGap = false

          for column in 0..<width {
            let index = start + column
            // A plain sentinel rather than Int32.min: a gap penalty added to the minimum
            // overflows, and Swift traps on that rather than wrapping.
            var matched = Self.unreachable
            var run: Int32 = 0

            if folded(text[index]) == target {
              let diagonal: Int32 =
                row == 0 ? 0 : (column == 0 ? Self.unreachable : scores[previousRow + column - 1])
              if diagonal > Self.unreachable {
                let carried: Int32 = row == 0 || column == 0 ? 0 : runs[previousRow + column - 1]
                run = carried + 1

                var reward = bonuses[index]
                if row == 0 {
                  // The query's first character counts double where it lands on a word
                  // start, which is how "gtv" finds GroveTerminalView.
                  reward *= firstCharMultiplier
                } else if run > 1 {
                  // A run is worth at least the consecutive bonus, and at least what its
                  // first character was worth, so adjacency is never punished.
                  let first = bonuses[index - Int(run) + 1]
                  if reward >= boundary, reward > first {
                    run = 1
                  } else {
                    reward = max(reward, max(consecutive, first))
                  }
                }
                matched = diagonal + match + reward
              }
            }

            let left: Int32 = column == 0 ? Self.unreachable : scores[currentRow + column - 1]
            let gap: Int32 =
              left > Self.unreachable ? left + (inGap ? gapExtension : gapStart) : Self.unreachable

            if matched > Self.unreachable, matched >= gap {
              scores[currentRow + column] = matched
              runs[currentRow + column] = run
              inGap = false
            } else {
              scores[currentRow + column] = gap
              runs[currentRow + column] = 0
              inGap = gap > Self.unreachable
            }

            if row == rows - 1 {
              best = max(best, scores[currentRow + column])
            }
          }
          swap(&previousRow, &currentRow)
        }
        return best > 0 ? best : nil
      }
    }
  }

  /// Stands for "no alignment reaches here". Far below any real score and far above the
  /// minimum, so adding a penalty to it cannot overflow.
  static let unreachable: Int32 = -1_000_000

  /// The smallest stretch of `text` that could hold `needle`, or nil if none can.
  static func window(_ needle: [UInt8], in text: [UInt8]) -> Range<Int>? {
    var first = -1
    var index = 0
    for byte in needle {
      var found = -1
      while index < text.count {
        if folded(text[index]) == byte {
          found = index
          index += 1
          break
        }
        index += 1
      }
      guard found >= 0 else { return nil }
      if first < 0 { first = found }
    }
    return first..<index
  }

  static func folded(_ byte: UInt8) -> UInt8 {
    byte >= 65 && byte <= 90 ? byte + 32 : byte
  }
}
