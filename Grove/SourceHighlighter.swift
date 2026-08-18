import AppKit
import GroveCore
import Highlightr

/// Coloured text, ready to display.
///
/// Marked `@unchecked Sendable` because both parts are immutable once made: an
/// `NSAttributedString` that is never mutated afterwards, and an `NSColor`. Something
/// has to cross out of the highlighter, and copying a megabyte of attributed text to
/// avoid saying so would be worse.
struct HighlightedSource: @unchecked Sendable {
  let text: NSAttributedString
  let background: NSColor
}

/// Colours source text for display.
///
/// highlight.js through JavaScriptCore rather than tree-sitter. Tree-sitter is what an
/// editor wants, because it reparses as you type; nothing here is ever typed into. What
/// this needs is breadth — a workspace holds Python, TypeScript, Terraform and YAML at
/// once — and highlight.js brings about 190 languages with no grammars to vendor.
///
/// An actor, and off the main one, because highlighting costs about a millisecond per
/// kilobyte: measured, 42ms for a middling source file and near a full second at the
/// size limit. On the main actor that is a frozen window. Serial access also suits
/// JavaScriptCore, which does not want one context used from two places at once.
actor SourceHighlighter {
  static let shared = SourceHighlighter()

  /// Building one loads and compiles the highlight.js bundle, so there is one of these.
  private let highlightr: Highlightr?

  private init() {
    highlightr = Highlightr()
    // Close to the terminal's own dark palette, so a file and a shell in the same
    // window do not look like two applications.
    // Gruvbox, because its background is #282828 — the same colour the rest of the app is
    // drawn on, so the file sits in the window rather than on a panel of its own.
    highlightr?.setTheme(to: "gruvbox-dark-medium")
  }

  /// Indents the rows a long line wraps onto, so a continuation cannot be mistaken for
  /// a line of its own — the thing that makes wrapped code hard to read.
  private static func paragraphs(_ font: NSFont, wraps: Bool) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    guard wraps else {
      // Nothing to indent and nothing to break: the line runs on and the view scrolls.
      style.lineBreakMode = .byClipping
      return style
    }
    style.headIndent = font.maximumAdvancement.width * 4
    style.lineBreakMode = .byWordWrapping
    return style
  }

  /// Highlighted text, falling back to plain when the language is unknown or
  /// highlighting fails.
  ///
  /// Never returns nothing: a file that cannot be coloured is still a file someone
  /// asked to read. The font is built here rather than applied afterwards, so a large
  /// file does not need a second pass over its attributes on the main actor.
  func highlight(
    _ text: String, path: String, fontName: String, fontSize: CGFloat, wraps: Bool
  ) -> HighlightedSource {
    let font =
      NSFont(name: fontName, size: fontSize)
      ?? .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let background = highlightr?.theme.themeBackgroundColor ?? .textBackgroundColor

    func plain() -> HighlightedSource {
      HighlightedSource(
        text: NSAttributedString(
          string: text,
          attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Self.paragraphs(font, wraps: wraps),
          ]),
        background: background)
    }

    guard let highlightr, let language = SourceLanguage.named(for: path) else { return plain() }
    guard let coloured = highlightr.highlight(text, as: language, fastRender: true) else {
      return plain()
    }

    // Highlightr picks its own monospace font and size; the one from Settings is the one
    // the user chose.
    let restyled = NSMutableAttributedString(attributedString: coloured)
    let whole = NSRange(location: 0, length: restyled.length)
    restyled.addAttribute(.font, value: font, range: whole)
    restyled.addAttribute(
      .paragraphStyle, value: Self.paragraphs(font, wraps: wraps), range: whole)
    return HighlightedSource(text: restyled, background: background)
  }
}
