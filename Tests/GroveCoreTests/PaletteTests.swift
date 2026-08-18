import Testing

@testable import GroveCore

/// The window's palette makes a claim about being comfortable to read, so it is asserted
/// rather than eyeballed — the same treatment the terminal's background gets.
@Suite("palette")
struct PaletteTests {
  /// WCAG's threshold for body text at ordinary sizes. Grove's smallest text is 11pt, which
  /// is not large, so this is the bar that applies.
  static let readable = 4.5

  @Test("every text tier is readable on everything it is drawn on")
  func everyTierIsReadable() throws {
    // The tier that broke this rule was #9A8E7A at 3.67:1 on the surface, and it carried
    // the only description each keyboard shortcut had.
    for tier in Palette.textTiers {
      for ground in Palette.grounds {
        let ratio = try #require(Contrast.ratio(tier, ground))
        #expect(ratio >= Self.readable, "\(tier) on \(ground) is \(ratio):1")
      }
    }
  }

  @Test("a selected row only uses tiers that are readable on it")
  func selectionIsReadable() throws {
    // The dimmest tier is deliberately absent: it measures 3.8:1 there, and the fix is to
    // promote it on a selected row rather than to brighten it everywhere.
    for tier in Palette.tiersOnSelection {
      let ratio = try #require(Contrast.ratio(tier, Palette.selection))
      #expect(ratio >= Self.readable, "\(tier) on a selection is \(ratio):1")
    }
    #expect(!Palette.tiersOnSelection.contains(Palette.faint))
    let faint = try #require(Contrast.ratio(Palette.faint, Palette.selection))
    #expect(faint < Self.readable, "faint now passes on a selection — the rule can go")
  }

  @Test("titles clear the stricter bar for small text")
  func titlesAreStrong() throws {
    // 7:1 is WCAG AAA. A title has to be the thing the eye lands on first.
    for ground in Palette.grounds {
      let ratio = try #require(Contrast.ratio(Palette.title, ground))
      #expect(ratio >= 7, "titles on \(ground) are \(ratio):1")
    }
  }

  @Test("the tiers are actually distinguishable, brightest first")
  func tiersDescend() throws {
    // Three tiers that measure the same are one tier with extra names.
    let ratios = try Palette.textTiers.map {
      try #require(Contrast.ratio($0, Palette.background))
    }
    #expect(ratios == ratios.sorted(by: >), "\(ratios)")
    for (brighter, dimmer) in zip(ratios, ratios.dropFirst()) {
      #expect(brighter - dimmer > 0.75, "\(brighter):1 and \(dimmer):1 are too close")
    }
  }

  @Test("every colour that carries meaning stands out from the background")
  func statusColoursRead() throws {
    // These are read as a state — failed, working, merged — so they have to be legible on
    // their own rather than only in contrast with each other.
    for colour in [Palette.warning, Palette.danger, Palette.confirm, Palette.info] {
      let ratio = try #require(Contrast.ratio(colour, Palette.background))
      #expect(ratio >= 3, "\(colour) on the background is \(ratio):1")
    }
  }

  @Test("a panel is dimmer than the surface it is made of")
  func blendingIsHonest() throws {
    // Which is the whole reason grounds includes the blends: measuring against the surface
    // alone flattered every tier by about half a point.
    let panel = try #require(Contrast.blend(Palette.surface, over: Palette.background, alpha: 0.5))
    let onPanel = try #require(Contrast.ratio(Palette.faint, panel))
    let onSurface = try #require(Contrast.ratio(Palette.faint, Palette.surface))
    #expect(onPanel > onSurface)
    #expect(Palette.grounds.contains(panel))
  }

  @Test("blending reaches both ends and reads nothing it cannot parse")
  func blendEdges() throws {
    #expect(Contrast.blend("#FFFFFF", over: "#000000", alpha: 1) == "#FFFFFF")
    #expect(Contrast.blend("#FFFFFF", over: "#000000", alpha: 0) == "#000000")
    #expect(Contrast.blend("#FFFFFF", over: "#000000", alpha: 0.5) == "#808080")
    #expect(Contrast.blend("nonsense", over: "#000000", alpha: 0.5) == nil)
  }

  @Test("every entry is a colour that can be read")
  func everyEntryParses() {
    let all =
      Palette.textTiers + Palette.grounds + [
        Palette.divider, Palette.warning, Palette.danger, Palette.confirm, Palette.info,
        Palette.highlight,
      ]
    for colour in all {
      #expect(Contrast.luminance(colour) != nil, "\(colour)")
    }
  }

  @Test("the divider is visible against the background without ruling a line")
  func dividerIsSubtle() throws {
    // It has to be seen and not noticed: above the background, well under the text.
    let ratio = try #require(Contrast.ratio(Palette.divider, Palette.background))
    #expect(ratio > 1.2, "\(ratio):1 — invisible")
    #expect(ratio < 2.5, "\(ratio):1 — that is a rule, not a divider")
  }
}
