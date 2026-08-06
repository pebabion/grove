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

  /// Called when the running program rings the bell, which is the one signal that
  /// means nothing except "look at me".
  var onBell: (@MainActor () -> Void)?

  /// Called with the payload of an OSC 9 sequence — how a program reports whether
  /// it is working. See ``SessionProgress``.
  var onOscNine: (@MainActor (String) -> Void)?

  /// `bell` is open, unlike `progressReport` and `keyDown`, so this one signal can
  /// be taken the direct way.
  override func bell(source: Terminal) {
    super.bell(source: source)
    Log.sessions.note("bell")
    onBell?()
  }

  /// Starts listening for progress reports.
  ///
  /// Registering a handler for OSC 9 replaces SwiftTerm's own, so the parsed report
  /// is handed back to it afterwards and its progress bar keeps working. Handlers
  /// survive a resize: `setupOptions` calls `terminal.setup(isReset:)` on every
  /// bounds change, and that leaves the parser's registrations alone — checked,
  /// because a handler quietly dropped on first layout would look exactly like a
  /// feature that never worked.
  func watchProgress() {
    guard let terminal else {
      Log.sessions.problem("no terminal to watch: progress reports will never arrive")
      return
    }
    // @Sendable so the closure is not main-actor isolated. SwiftTerm calls it from
    // whatever thread is feeding the terminal, and a closure written inside a
    // main-actor type is checked for the main executor as it is entered — which traps
    // off the main thread before any hop inside it can run.
    terminal.registerOscHandler(code: 9) { @Sendable [weak self] payload in
      let text = String(decoding: payload, as: UTF8.self)
      Task { @MainActor in
        Log.sessions.note("osc 9 payload: \(text)")
        self?.onOscNine?(text)
        self?.forwardToSwiftTerm(text)
      }
    }
    Log.sessions.note("watching progress reports")
  }

  private func forwardToSwiftTerm(_ payload: String) {
    guard let terminal else { return }
    let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
    guard fields.first == "4", fields.count >= 2, let raw = Int(fields[1]),
      let state = Terminal.ProgressReportState(rawValue: raw)
    else { return }
    let percent = fields.count >= 3 ? UInt8(fields[2]) : nil
    progressReport(source: terminal, report: .init(state: state, progress: percent))
  }

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
