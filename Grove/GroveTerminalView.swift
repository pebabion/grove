import AppKit
import SwiftTerm

/// A terminal view that translates the Command-key line editing macOS users expect.
///
/// Command combinations never reach the PTY: AppKit routes them through the menu
/// system, and SwiftTerm only uses Command for link previews. So ⌘ + Backspace did
/// nothing at all. Terminals that support it — iTerm2, Ghostty — translate these
/// themselves, into the control characters readline already understands.
final class GroveTerminalView: LocalProcessTerminalView {
  /// Only Command, and only these keys. Everything else must pass through, or the
  /// app's own shortcuts stop working while the terminal has focus.
  private static let translations: [UInt16: [UInt8]] = [
    51: [0x15],  // Backspace → ^U, delete to start of line
    123: [0x01],  // Left      → ^A, start of line
    124: [0x05],  // Right     → ^E, end of line
  ]

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // performKeyEquivalent reaches every view in the window, focused or not, so a
    // ⌘ + Backspace meant for something else must not be swallowed here.
    guard window?.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      let bytes = Self.translations[event.keyCode]
    else {
      return super.performKeyEquivalent(with: event)
    }

    send(bytes)
    return true
  }
}
