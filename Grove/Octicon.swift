import AppKit
import SwiftUI

/// GitHub's own pull request glyphs, from Primer Octicons.
///
/// The SVG files ship in the bundle and are drawn as they are. NSImage reads SVG
/// natively on macOS, so there is no conversion step and nothing to get subtly
/// wrong — an earlier attempt turned the path data into Swift bezier calls by
/// hand and produced blobs. See THIRD-PARTY.md for the licence.
enum Octicon: String {
  case open = "git-pull-request"
  case merged = "git-merge"
  case closed = "git-pull-request-closed"
  case draft = "git-pull-request-draft"
}

/// Draws an ``Octicon``, tinted by the surrounding foreground style.
struct OcticonImage: View {
  let icon: Octicon
  var size: CGFloat = 12

  var body: some View {
    if let image = Self.image(for: icon) {
      Image(nsImage: image)
        .renderingMode(.template)
        .resizable()
        .frame(width: size, height: size)
    }
  }

  /// Decoded once per icon: these appear on every repo row, and re-reading the
  /// file for each would be wasteful.
  @MainActor private static var cache: [Octicon: NSImage] = [:]

  @MainActor private static func image(for icon: Octicon) -> NSImage? {
    if let cached = cache[icon] { return cached }
    guard let url = Bundle.main.url(forResource: icon.rawValue, withExtension: "svg"),
      let image = NSImage(contentsOf: url)
    else { return nil }
    // Template rendering is what lets foregroundStyle colour the glyph.
    image.isTemplate = true
    cache[icon] = image
    return image
  }
}
