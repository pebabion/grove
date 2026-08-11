import AppKit
import SwiftUI

/// Line numbers down the left of a text view.
///
/// Numbers count logical lines, not the rows they occupy: a wrapped line keeps one
/// number, which is what makes them worth anything when comparing against an error
/// message or a diff.
///
/// **Only `drawHashMarksAndLabels` may be overridden here.** Overriding `draw` to paint
/// the gutter background hid the file, and the header above it, leaving a column of
/// numbers beside an empty pane. The scroll view's own background colour reaches the
/// gutter, so there is nothing to paint.
final class LineNumberRuler: NSRulerView {
  /// Where each line begins, so the number for a position is a binary search rather
  /// than a count from the top of the file.
  private var lineStarts: [Int] = [0]

  init(textView: NSTextView) {
    super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
    clientView = textView
    ruleThickness = 44
  }

  required init(coder: NSCoder) { fatalError("not used") }

  func measure(_ text: String) {
    var starts = [0]
    var index = 0
    for byte in text.utf8 {
      index += 1
      if byte == 0x0A { starts.append(index) }
    }
    lineStarts = starts
    // Room for the widest number plus breathing space, so a long file does not clip.
    ruleThickness = max(36, CGFloat(String(starts.count).count) * 8 + 20)
    needsDisplay = true
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView = clientView as? NSTextView,
      let layout = textView.layoutManager,
      let container = textView.textContainer
    else { return }

    let visible = scrollView?.contentView.bounds ?? .zero
    let inset = textView.textContainerInset.height
    let text = textView.string as NSString

    let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
    let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

    let font =
      (textView.font ?? .monospacedSystemFont(ofSize: 11, weight: .regular))
      .withSize((textView.font?.pointSize ?? 11) - 1)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.55),
    ]

    // An empty file still has a first line, and asking the layout manager about a
    // glyph it does not have is not a question it answers politely.
    guard text.length > 0 else {
      draw(number: 1, at: inset, attributes: attributes)
      return
    }

    var index = characters.location
    var line = self.line(containing: index)

    while index < NSMaxRange(characters), index < text.length {
      let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
      let glyph = layout.glyphIndexForCharacter(at: lineRange.location)
      let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)

      draw(
        number: line + 1,
        at: fragment.minY + inset - visible.minY + (fragment.height - 14) / 2,
        attributes: attributes)

      line += 1
      guard lineRange.length > 0 else { break }
      index = NSMaxRange(lineRange)
    }
  }

  private func draw(number: Int, at y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
    let text = "\(number)" as NSString
    let size = text.size(withAttributes: attributes)
    text.draw(
      at: NSPoint(x: ruleThickness - size.width - 8, y: y), withAttributes: attributes)
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

/// A text view that answers ⌘ + F.
///
/// `NSTextView` has a find bar already; what it lacks is a way to be asked for it. The
/// menu route only works when the text view holds focus, and here focus is usually in
/// the search field or the file list, so the shortcut is caught directly.
final class FindableTextView: NSTextView {
  /// ⌘ + F and ⌘ + G only. ⌘ + E would be the usual "use the selection" shortcut, but
  /// the header above this view already opens the file in an editor with it, and that
  /// is worth more here than a second way to fill in the search field.
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
/// AppKit rather than SwiftUI's `Text`: a `Text` holding a few thousand attributed
/// lines lays out every one of them on every pass, and a source file is exactly that.
/// `NSTextView` also brings the things reading needs anyway — selection, copy, find.
///
/// Built from its TextKit 1 pieces rather than `NSTextView.scrollableTextView()`,
/// because the ruler needs a layout manager and the modern stack does not hand one over
/// without falling back anyway.
struct SourceTextView: NSViewRepresentable {
  let content: NSAttributedString
  let background: NSColor

  func makeNSView(context: Context) -> NSScrollView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)

    let container = NSTextContainer(
      size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    // Wrapped. Long lines were unreachable before: wrapping was off and the horizontal
    // scroller never appeared, so the right-hand end of a line simply could not be read.
    container.widthTracksTextView = true
    layout.addTextContainer(container)

    let text = FindableTextView(frame: .zero, textContainer: container)
    text.isEditable = false
    // The bar that slides in above the text, rather than the floating panel.
    text.usesFindBar = true
    text.isIncrementalSearchingEnabled = true
    text.isSelectable = true
    text.isRichText = false
    text.drawsBackground = true
    text.textContainerInset = NSSize(width: 6, height: 8)
    text.isVerticallyResizable = true
    text.isHorizontallyResizable = false
    text.autoresizingMask = [NSView.AutoresizingMask.width]
    text.minSize = NSSize(width: 0, height: 0)
    text.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    let scroll = NSScrollView()
    scroll.drawsBackground = true
    scroll.documentView = text
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true

    let ruler = LineNumberRuler(textView: text)
    scroll.verticalRulerView = ruler
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true

    // The ruler draws only what is on screen, so it has to be told when that changes.
    scroll.contentView.postsBoundsChangedNotifications = true
    context.coordinator.observe(scroll: scroll, ruler: ruler)
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? NSTextView else { return }
    text.backgroundColor = background
    scroll.backgroundColor = background

    guard text.attributedString() != content else { return }
    text.textStorage?.setAttributedString(content)
    (scroll.verticalRulerView as? LineNumberRuler)?.measure(content.string)
    text.scroll(.zero)
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    private var observer: NSObjectProtocol?

    /// Main-actor because it touches the scroll view's own views. It is only ever
    /// called from `makeNSView`, which is on the main actor already — but saying so is
    /// what lets an older compiler agree. This built locally on Xcode 26 and failed CI
    /// on Xcode 16 without it.
    @MainActor
    func observe(scroll: NSScrollView, ruler: LineNumberRuler) {
      observer = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scroll.contentView,
        queue: .main
      ) { [weak ruler] _ in
        MainActor.assumeIsolated { ruler?.needsDisplay = true }
      }
    }

    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }
  }
}
