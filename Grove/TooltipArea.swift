import AppKit
import SwiftUI

/// A transparent AppKit view that shows a tooltip on hover.
///
/// SwiftUI's `.help` did nothing on the colour swatches. It needs a backing view
/// to hang a tooltip rect on, and a bare `Shape` with a `contentShape` does not
/// give it one, so the modifier was silently a no-op. Setting `toolTip` on a
/// real `NSView` always works, because AppKit registers the rect itself and
/// keeps it in step with the view's bounds.
///
/// Overlay it on whatever should explain itself:
///
///     mySwatch.overlay(TooltipArea(text: "frontend"))
///
/// The view does take the mouse over its own area, so a swatch inside a list row
/// is not a click target for selecting that row. The rows are far wider than the
/// swatches, so this is a fair trade for a tooltip that works.
struct TooltipArea: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.toolTip = text
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    guard view.toolTip != text else { return }
    view.toolTip = text
  }
}
