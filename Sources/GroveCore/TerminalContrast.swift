import Foundation

/// How dark the terminal's background is.
///
/// A level rather than a colour picker, because the question people have is "this is
/// harsh, give me less of it" and not "which grey". All three are neutral — equal parts
/// red, green and blue — so nothing acquires a colour cast.
///
/// Why this exists at all: SwiftTerm's default background is pure black, and measured
/// against a real session that is 90% of what is on screen. Pure white on pure black is
/// the pairing that causes halation, the glow around light glyphs on a very dark field
/// that makes text look soft, and it is why no terminal shipping today defaults to it —
/// iTerm2 uses #14191E, VS Code #1F1F1F, Ghostty #282C34.
public enum TerminalBackground: String, CaseIterable, Codable, Sendable {
  /// What a terminal does with no background set. Highest contrast, and the harshest.
  case black
  /// Off black, and the default. Far enough up to stop the glow, dark enough to still
  /// read as a terminal rather than a document.
  case charcoal
  /// For long sessions in a bright room.
  case ash

  public static let `default` = TerminalBackground.charcoal

  public var hex: String {
    switch self {
    case .black: "#000000"
    case .charcoal: "#1C1C1C"
    case .ash: "#262626"
    }
  }

  public var label: String {
    switch self {
    case .black: "Black"
    case .charcoal: "Charcoal"
    case .ash: "Ash"
    }
  }

  /// Reads a stored value, falling back to the default rather than failing.
  public init(stored: String?) {
    self = TerminalBackground(rawValue: stored ?? "") ?? .default
  }
}

/// Contrast between two colours, by the WCAG definition.
///
/// Here so the shipped pairings can be asserted rather than eyeballed. 7:1 is WCAG's AAA
/// threshold for body text, and every background Grove offers stays above it against both
/// its own default text colour and the grey Claude Code draws with.
public enum Contrast {
  /// The ratio between two `#RRGGBB` colours, from 1 to 21. Nil if either cannot be read.
  public static func ratio(_ first: String, _ second: String) -> Double? {
    guard let a = luminance(first), let b = luminance(second) else { return nil }
    let lighter = max(a, b)
    let darker = min(a, b)
    return (lighter + 0.05) / (darker + 0.05)
  }

  /// Relative luminance: sRGB channels linearised, then weighted for the eye's response
  /// to each — which is why green counts for the most and blue the least.
  public static func luminance(_ hex: String) -> Double? {
    guard let (r, g, b) = channels(hex) else { return nil }
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
  }

  private static func linear(_ channel: Int) -> Double {
    let value = Double(channel) / 255
    return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
  }

  /// One colour drawn at `alpha` over another, as the hex of the result.
  ///
  /// A translucent panel is not the colour it is made of: the sidebar's surface at 55% over
  /// the background is dimmer than the surface itself, and that is the ground text is
  /// actually read against.
  public static func blend(_ top: String, over bottom: String, alpha: Double) -> String? {
    guard let top = channels(top), let bottom = channels(bottom) else { return nil }
    let mix = { (a: Int, b: Int) in
      Int((Double(a) * alpha + Double(b) * (1 - alpha)).rounded())
    }
    return String(
      format: "#%02X%02X%02X", mix(top.0, bottom.0), mix(top.1, bottom.1), mix(top.2, bottom.2))
  }

  private static func channels(_ hex: String) -> (Int, Int, Int)? {
    var text = hex.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
    return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
  }
}
