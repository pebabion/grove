import AppKit
import SwiftTerm

/// A terminal view that sends the key combinations macOS users expect a terminal
/// to translate.
///
/// SwiftTerm passes ordinary keys straight through, but two families never reach
/// the PTY on their own: Command combinations, which AppKit routes through the menu
/// system, and Shift + Return, which is indistinguishable from Return unless the
/// terminal chooses to distinguish it. Terminals that support these — iTerm2,
/// Ghostty — translate them into sequences readline and TUI programs already
/// understand, which is what happens here.
final class GroveTerminalView: LocalProcessTerminalView {
  private static let returnKeyCode: UInt16 = 36

  /// Only Command, and only these keys. Everything else must pass through, or the
  /// app's own shortcuts stop working while the terminal has focus.
  private static let commandTranslations: [UInt16: [UInt8]] = [
    51: [0x15],  // Backspace → ^U, delete to start of line
    123: [0x01],  // Left      → ^A, start of line
    124: [0x05],  // Right     → ^E, end of line
  ]

  private var keyMonitor: Any?

  /// SwiftTerm's initialisers are public but not open, so the monitor is installed
  /// when the view joins a window instead — which is the right lifecycle for it
  /// regardless, since it only matters while the view is on screen. Leaving the
  /// window removes it, which also covers teardown: a view being discarded is taken
  /// out of its window first.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      removeShiftReturnMonitor()
    } else if keyMonitor == nil {
      installShiftReturnMonitor()
    }
  }

  private func removeShiftReturnMonitor() {
    guard let keyMonitor else { return }
    NSEvent.removeMonitor(keyMonitor)
    self.keyMonitor = nil
  }

  /// Makes Shift + Return insert a line rather than submit.
  ///
  /// Return sends CR and means submit; a terminal that does not tell the two apart
  /// sends CR for both, so Shift + Return submitted inside Claude Code instead of
  /// breaking the line. ESC CR is the sequence `claude /terminal-setup` installs
  /// into iTerm2 for this, found beside "shift+enter" in the Claude Code binary.
  ///
  /// Done with an event monitor because `keyDown` is public but not open, so it
  /// cannot be overridden from outside SwiftTerm. The monitor runs ahead of the
  /// responder chain, so it checks that this view is the one being typed into.
  private func installShiftReturnMonitor() {
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self,
        window?.firstResponder === self,
        event.keyCode == Self.returnKeyCode,
        event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift
      else { return event }

      send([0x1b, 0x0d])
      return nil
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // performKeyEquivalent reaches every view in the window, focused or not, so a
    // ⌘ + Backspace meant for something else must not be swallowed here.
    guard window?.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      let bytes = Self.commandTranslations[event.keyCode]
    else {
      return super.performKeyEquivalent(with: event)
    }

    send(bytes)
    return true
  }
}
