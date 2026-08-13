import Foundation
import Testing

@testable import GroveCore

/// The terminal's colours are a comfort feature, so what makes them comfortable is
/// asserted rather than eyeballed.
@Suite("terminal contrast")
struct TerminalContrastTests {
  /// Grove's default text colour, and the grey Claude Code draws its own body text in —
  /// measured off a screenshot of a real session, since it sets 24-bit colour and none of
  /// it comes from the palette.
  static let groveText = "#D4D4D4"
  static let claudeText = "#C0C0C0"

  @Test("black on white is the widest contrast there is")
  func extremes() throws {
    let ratio = try #require(Contrast.ratio("#000000", "#FFFFFF"))
    #expect(abs(ratio - 21) < 0.01)
    let same = try #require(Contrast.ratio("#808080", "#808080"))
    #expect(abs(same - 1) < 0.01)
  }

  @Test("the order of the two colours makes no difference")
  func symmetric() throws {
    let one = try #require(Contrast.ratio("#1C1C1C", Self.groveText))
    let other = try #require(Contrast.ratio(Self.groveText, "#1C1C1C"))
    #expect(abs(one - other) < 0.0001)
  }

  @Test("a colour it cannot read reports nothing rather than guessing")
  func unreadable() {
    #expect(Contrast.ratio("nonsense", "#000000") == nil)
    #expect(Contrast.ratio("#FFF", "#000000") == nil)
    #expect(Contrast.luminance("#12345") == nil)
  }

  @Test("green weighs more than blue")
  func channelWeights() throws {
    // Not decoration: it is why a neutral grey is the only safe way to dim a background
    // without changing how bright it looks.
    let green = try #require(Contrast.luminance("#00FF00"))
    let red = try #require(Contrast.luminance("#FF0000"))
    let blue = try #require(Contrast.luminance("#0000FF"))
    #expect(green > red)
    #expect(red > blue)
  }

  @Test("every background stays past WCAG's 7:1 for body text")
  func everyLevelIsReadable() throws {
    // The point of the setting is comfort, and a level that made text hard to read would
    // be a worse fault than the glare it was fixing.
    for level in TerminalBackground.allCases {
      let grove = try #require(Contrast.ratio(Self.groveText, level.hex))
      let claude = try #require(Contrast.ratio(Self.claudeText, level.hex))
      #expect(grove >= 7, "\(level.label) with Grove's text is \(grove):1")
      #expect(claude >= 7, "\(level.label) with Claude Code's text is \(claude):1")
    }
  }

  @Test("the levels run from harshest to softest, and none repeat")
  func levelsAreOrdered() throws {
    let ratios = try TerminalBackground.allCases.map {
      try #require(Contrast.ratio(Self.claudeText, $0.hex))
    }
    #expect(ratios == ratios.sorted(by: >), "\(ratios)")
    #expect(Set(TerminalBackground.allCases.map(\.hex)).count == TerminalBackground.allCases.count)
  }

  @Test("every background is a neutral grey")
  func noColourCast() throws {
    // A background with a cast tints every uncoloured glyph on it, and the ask was to
    // stay black and white.
    for level in TerminalBackground.allCases {
      let hex = level.hex.dropFirst()
      let red = hex.prefix(2)
      #expect(hex == red + red + red, "\(level.label) is \(level.hex)")
    }
  }

  @Test("black is still on offer, unchanged")
  func blackIsExact() throws {
    // Someone who wants what they had should get exactly that, not a near miss.
    #expect(TerminalBackground.black.hex == "#000000")
    let ratio = try #require(Contrast.ratio(Self.claudeText, TerminalBackground.black.hex))
    #expect(abs(ratio - 11.5) < 0.1)
  }

  @Test("a stored level survives, and nonsense falls back to the default")
  func reading() {
    #expect(TerminalBackground(stored: "ash") == .ash)
    #expect(TerminalBackground(stored: "black") == .black)
    #expect(TerminalBackground(stored: nil) == .charcoal)
    #expect(TerminalBackground(stored: "chartreuse") == .charcoal)
  }

  @Test("the choice is kept across a save and a load")
  func roundTrips() throws {
    // The field was added to a library file people already have, so it has to be optional
    // going in and coming out. A missing key must not fail the whole file.
    var library = RepoLibrary()
    library.terminalBackground = TerminalBackground.ash.rawValue
    let data = try JSONEncoder().encode(library)
    let read = try JSONDecoder().decode(RepoLibrary.self, from: data)
    #expect(read.terminalBackground == "ash")

    let old = try JSONDecoder().decode(RepoLibrary.self, from: Data(#"{"repos":[]}"#.utf8))
    #expect(old.terminalBackground == nil)
    #expect(TerminalBackground(stored: old.terminalBackground) == .charcoal)
  }
}
