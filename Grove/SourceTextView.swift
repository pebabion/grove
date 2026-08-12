import AppKit
import SwiftUI

/// Line numbers down the left of a text view.
///
/// A plain view rather than an `NSRulerView`. The ruler paints its own background, a few
/// shades off the file's, which leaves a seam down the gutter that reads as a deliberate
/// line. Painting over it by overriding `draw` hid the file entirely, and through a layer
/// the ruler covered it again. A view of its own has none of that, and the numbers still
/// line up because they are measured from the text's own layout.
///
/// Numbers count logical lines, not the rows they occupy: a wrapped line keeps one
/// number, which is what makes them worth anything beside an error message or a diff.
final class GutterView: NSView {
  weak var textView: NSTextView?
  weak var clip: NSClipView?

  var fill: NSColor = .textBackgroundColor {
    didSet { needsDisplay = true }
  }

  /// Where each line begins, so the number for a position is a binary search rather than
  /// a count from the top of the file.
  private var lineStarts: [Int] = [0]

  /// Numbers are drawn top-down, like the text.
  override var isFlipped: Bool { true }

  private static let rightPadding: CGFloat = 10
  private static let leftPadding: CGFloat = 10

  /// Takes the text's line positions and reports how wide the gutter has to be for the
  /// longest number it will show.
  func measure(_ text: String, font: NSFont) -> CGFloat {
    var starts = [0]
    var index = 0
    for byte in text.utf8 {
      index += 1
      if byte == 0x0A { starts.append(index) }
    }
    lineStarts = starts
    needsDisplay = true

    let widest = "\(max(starts.count, 1))" as NSString
    let size = widest.size(withAttributes: [.font: Self.numbering(font)])
    return (size.width + Self.leftPadding + Self.rightPadding).rounded(.up)
  }

  /// A size below the text's, so the numbers stay out of the way of the code.
  private static func numbering(_ font: NSFont) -> NSFont {
    .monospacedDigitSystemFont(ofSize: max(9, font.pointSize - 1), weight: .regular)
  }

  override func draw(_ dirtyRect: NSRect) {
    fill.setFill()
    dirtyRect.fill()

    guard let textView, let layout = textView.layoutManager,
      let container = textView.textContainer, let clip
    else { return }

    let text = textView.string as NSString
    guard text.length > 0 else { return }

    let visible = clip.bounds
    let inset = textView.textContainerInset.height
    let base = textView.font ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: Self.numbering(base),
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.5),
    ]

    let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

    var index = characters.location
    var line = self.line(containing: index)

    while index < NSMaxRange(characters), index < text.length {
      let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
      let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
      let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)

      let number = "\(line + 1)" as NSString
      let size = number.size(withAttributes: attributes)
      number.draw(
        at: NSPoint(
          x: bounds.width - size.width - Self.rightPadding,
          y: fragment.minY + inset - visible.minY + (fragment.height - size.height) / 2),
        withAttributes: attributes)

      line += 1
      guard lineRange.length > 0 else { break }
      index = NSMaxRange(lineRange)
    }
  }

  private func line(containing position: Int) -> Int {
    var low = 0
    var high = lineStarts.count - 1
    while low < high {
      let middle = (low + high + 1) / 2
      if lineStarts[middle] <= position { low = middle } else { high = middle - 1 }
    }
    return low
  }
}

/// The gutter and the text side by side, the gutter as wide as its widest number.
final class SourcePane: NSView {
  let gutter = GutterView()
  let scroll = NSScrollView()

  var gutterWidth: CGFloat = 40 {
    didSet { needsLayout = true }
  }

  /// No size of its own, in either direction.
  ///
  /// A plain view reports a fitting size big enough for its subviews, and one of those is
  /// a text view as tall as the whole file. SwiftUI hands a view its ideal height, so the
  /// pane claimed the lot and squeezed the header above it out of existence. A scroll
  /// view says "no opinion" for exactly this reason; this has to say it too.
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override var fittingSize: NSSize { .zero }

  override func layout() {
    super.layout()
    gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
    scroll.frame = NSRect(
      x: gutterWidth, y: 0, width: max(0, bounds.width - gutterWidth), height: bounds.height)
  }
}

/// A text view that answers ⌘ + F.
///
/// `NSTextView` has a find bar already; what it lacks is a way to be asked for it. The
/// menu route only works when the text view holds focus, and here focus is usually in the
/// search field or the file list, so the shortcut is caught directly.
final class FindableTextView: NSTextView {
  /// ⌘ + F and ⌘ + G only. ⌘ + E would be the usual "use the selection" shortcut, but the
  /// header above this view already opens the file in an editor with it, and that is worth
  /// more here than a second way to fill in the search field.
  private static let find: [String: NSTextFinder.Action] = [
    "f": .showFindInterface,
    "g": .nextMatch,
  ]

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard let key = event.charactersIgnoringModifiers?.lowercased() else {
      return super.performKeyEquivalent(with: event)
    }

    if flags == [.command, .shift], key == "g" {
      perform(.previousMatch)
      return true
    }
    if flags == .command, let action = Self.find[key] {
      perform(action)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }

  /// The find actions are asked for through a menu item's tag, so one is made to ask
  /// with. There is no other way in.
  private func perform(_ action: NSTextFinder.Action) {
    let request = NSMenuItem()
    request.tag = action.rawValue
    performTextFinderAction(request)
  }
}

/// Read-only text view holding an already-coloured string.
///
/// AppKit rather than SwiftUI's `Text`: a `Text` holding a few thousand attributed lines
/// lays out every one of them on every pass, and a source file is exactly that.
/// `NSTextView` also brings the things reading needs anyway — selection, copy, find.
///
/// Built from its TextKit 1 pieces rather than `NSTextView.scrollableTextView()`, because
/// the gutter needs a layout manager and the modern stack does not hand one over without
/// falling back anyway.
struct SourceTextView: NSViewRepresentable {
  let content: NSAttributedString
  let background: NSColor
  let wraps: Bool

  func makeNSView(context: Context) -> SourcePane {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)

    let container = NSTextContainer(
      size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    layout.addTextContainer(container)

    let text = FindableTextView(frame: .zero, textContainer: container)
    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    // The bar that slides in above the text, rather than the floating panel.
    text.usesFindBar = true
    text.isIncrementalSearchingEnabled = true
    text.drawsBackground = true
    text.textContainerInset = NSSize(width: 6, height: 8)
    text.isVerticallyResizable = true
    text.minSize = NSSize(width: 0, height: 0)
    text.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    let pane = SourcePane()
    // Without this the scroll view draws over whatever is above the pane, which took the
    // file's name and path with it. A plain NSView stopped clipping its subviews by
    // default in macOS 14, and the text view inside is as tall as the file.
    pane.clipsToBounds = true
    pane.scroll.drawsBackground = true
    pane.scroll.documentView = text
    pane.scroll.hasVerticalScroller = true
    pane.scroll.autohidesScrollers = true
    pane.addSubview(pane.gutter)
    pane.addSubview(pane.scroll)

    pane.gutter.textView = text
    pane.gutter.clip = pane.scroll.contentView
    Self.apply(wraps: wraps, to: text, in: pane.scroll)

    // The gutter draws only what is on screen, so it has to be told when that changes.
    pane.scroll.contentView.postsBoundsChangedNotifications = true
    context.coordinator.observe(pane: pane)
    return pane
  }

  /// Wrapping, or a line that runs on and a scroller to follow it.
  ///
  /// Both halves matter: with `widthTracksTextView` off, the container must also be given
  /// an unbounded width and the text view must be allowed to grow, or the line is laid out
  /// beyond a view that never widens and cannot be scrolled to. That combination is what
  /// left long lines unreachable the first time.
  static func apply(wraps: Bool, to text: NSTextView, in scroll: NSScrollView) {
    guard let container = text.textContainer else { return }

    container.widthTracksTextView = wraps
    container.size = NSSize(
      width: wraps ? scroll.contentSize.width : CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude)

    text.isHorizontallyResizable = !wraps
    text.autoresizingMask = wraps ? [.width] : [.width, .height]
    text.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    if wraps {
      text.frame.size.width = scroll.contentSize.width
    }

    scroll.hasHorizontalScroller = !wraps
  }

  func updateNSView(_ pane: SourcePane, context: Context) {
    guard let text = pane.scroll.documentView as? NSTextView else { return }
    text.backgroundColor = background
    pane.scroll.backgroundColor = background
    // The same colour as the file, so there is no seam between them.
    pane.gutter.fill = background

    if (text.textContainer?.widthTracksTextView ?? true) != wraps {
      Self.apply(wraps: wraps, to: text, in: pane.scroll)
    }

    guard text.attributedString() != content else { return }
    text.textStorage?.setAttributedString(content)
    pane.gutterWidth = pane.gutter.measure(
      content.string,
      font: text.font ?? .monospacedSystemFont(ofSize: 11, weight: .regular))
    text.scroll(.zero)
  }

  /// Takes whatever space it is offered.
  ///
  /// Without this SwiftUI asks the view how big it wants to be, and a plain view answers
  /// with something large enough for its subviews — one of which is a text view as tall as
  /// the file. The pane then claimed the whole height and squeezed the header above it out
  /// of existence. `intrinsicContentSize` and `fittingSize` are not consulted here; this
  /// is the one SwiftUI asks.
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: SourcePane, context: Context)
    -> CGSize?
  {
    proposal.replacingUnspecifiedDimensions(by: CGSize(width: 480, height: 320))
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    private var observer: NSObjectProtocol?

    /// Main-actor because it touches the scroll view's own views. It is only ever called
    /// from `makeNSView`, which is on the main actor already — but saying so is what lets
    /// an older compiler agree. This built locally on Xcode 26 and failed CI on Xcode 16
    /// without it.
    @MainActor
    func observe(pane: SourcePane) {
      observer = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: pane.scroll.contentView,
        queue: .main
      ) { [weak pane] _ in
        MainActor.assumeIsolated { pane?.gutter.needsDisplay = true }
      }
    }

    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }
  }
}
