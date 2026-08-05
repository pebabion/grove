import AppKit
import GroveCore

/// Which font the embedded terminal renders with.
///
/// The default matters. SwiftTerm falls back to Menlo, which has none of the
/// glyphs a modern prompt is built from, so macOS substitutes them one at a time
/// from whatever family has them — and those have different metrics, which reads
/// as the font size being inconsistent. Preferring a Nerd Font when one is
/// installed avoids substitution entirely.
enum TerminalFont {
  static let defaultSize: Double = 13

  /// Tried in order. The first two are the common Nerd Font packagings; the rest
  /// are what any Mac has.
  private static let preferred = [
    "JetBrainsMono Nerd Font Mono",
    "JetBrainsMono Nerd Font",
    "MesloLGS Nerd Font Mono",
    "SF Mono",
    "Menlo",
  ]

  /// Font families that can render a terminal, computed once.
  static let monospacedFamilies: [String] = {
    NSFontManager.shared.availableFontFamilies.filter { family in
      guard let font = NSFont(name: family, size: 12) else { return false }
      return font.isFixedPitch
    }
  }()

  /// The family Grove will use, given a chosen one that may be missing.
  static func resolve(_ chosen: String?) -> String {
    if let chosen, !chosen.isEmpty, NSFont(name: chosen, size: 12) != nil { return chosen }
    return preferred.first { NSFont(name: $0, size: 12) != nil } ?? "Menlo"
  }

  static func font(_ chosen: String?, size: Double?) -> NSFont {
    let name = resolve(chosen)
    let points = size ?? defaultSize
    return NSFont(name: name, size: points)
      ?? NSFont.monospacedSystemFont(ofSize: points, weight: .regular)
  }
}
