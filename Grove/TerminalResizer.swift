import AppKit
import SwiftUI

/// The divider you drag to trade height between the repo list and the terminal.
///
/// Hand-rolled rather than a VSplitView: that remembers a position of its own and
/// gave no way to set a sensible default, which left the terminal a sliver on first
/// open. This keeps the height in the model, so it also survives switching
/// workspaces.
struct TerminalResizer: View {
  @Binding var height: CGFloat

  private static let range: ClosedRange<CGFloat> = 120...1400

  var body: some View {
    ZStack {
      Divider()
      // A one-pixel divider is not a drag target, so the grabbable strip is taller
      // than the line it draws.
      Color.clear
        .frame(height: 8)
        .contentShape(Rectangle())
    }
    .frame(height: 8)
    .onHover { inside in
      if inside {
        NSCursor.resizeUpDown.push()
      } else {
        NSCursor.pop()
      }
    }
    .gesture(
      DragGesture(minimumDistance: 1)
        .onChanged { drag in
          // Dragging up makes the terminal taller, which is why this subtracts.
          height = min(
            max(height - drag.translation.height, Self.range.lowerBound), Self.range.upperBound)
        }
    )
  }
}
