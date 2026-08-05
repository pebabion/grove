import AppKit
import SwiftUI

/// Terminal text colour.
///
/// SwiftTerm draws default-coloured text in its own mid-grey, which reads as dim
/// against a dark background — most terminals use something close to white. Grove
/// sets it explicitly rather than inheriting that.
enum TerminalPalette {
  /// Bright enough to read, short of pure white, which glares.
  static let defaultForeground = "#E8E8E8"

  static func color(_ hex: String?) -> NSColor {
    NSColor(hex: hex ?? defaultForeground) ?? NSColor(hex: defaultForeground) ?? .textColor
  }

  static func hex(_ color: NSColor) -> String {
    guard let rgb = color.usingColorSpace(.sRGB) else { return defaultForeground }
    let r = Int((rgb.redComponent * 255).rounded())
    let g = Int((rgb.greenComponent * 255).rounded())
    let b = Int((rgb.blueComponent * 255).rounded())
    return String(format: "#%02X%02X%02X", r, g, b)
  }
}

extension NSColor {
  /// Parses `#RRGGBB`, the form Grove stores colours in.
  convenience init?(hex: String) {
    var text = hex.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
    self.init(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }
}
