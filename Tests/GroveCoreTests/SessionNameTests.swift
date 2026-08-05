import Foundation
import Testing

@testable import GroveCore

/// A session takes its name from the terminal title the running program sets.
/// `claude --name session_1` writes "✳ session_1", verified by capturing the escape
/// sequence from a real run, so the glyph has to come off and the name must not.
@Suite("session names from terminal titles")
struct SessionNameTests {
  /// Mirrors TerminalSession.strippingDecoration, which lives in the app target.
  private func strip(_ title: String) -> String {
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let scalars = cleaned.unicodeScalars.drop { scalar in
      !(CharacterSet.alphanumerics.contains(scalar) || scalar == "/" || scalar == "~")
    }
    return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
  }

  @Test("takes the name out of what Claude Code actually writes")
  func stripsClaudeGlyph() {
    #expect(strip("✳ session_1") == "session_1")
    #expect(strip("✳ grove_probe_1") == "grove_probe_1")
    #expect(strip("✻ working") == "working")
  }

  @Test("leaves an ordinary title alone")
  func keepsPlainTitles() {
    #expect(strip("fish") == "fish")
    #expect(strip("~/code/grove") == "~/code/grove")
    #expect(strip("backend — vim") == "backend — vim")
  }

  @Test("gives nothing back for a title with no name in it")
  func emptyForDecorationOnly() {
    // The caller falls back to where the shell is running when this happens.
    #expect(strip("") == "")
    #expect(strip("   ") == "")
    #expect(strip("✳") == "")
  }
}

@Suite("progress reported through OSC 9")
struct SessionProgressTests {
  @Test("reads the states Claude Code actually sends")
  func readsRealStates() {
    // Captured from a live session: 4;3; while working, 4;0; when done.
    #expect(SessionProgress.parse(oscNine: "4;3;") == .working)
    #expect(SessionProgress.parse(oscNine: "4;0;") == .idle)
  }

  @Test("treats every non-zero state as busy")
  func nonZeroIsBusy() {
    // 1 normal, 2 error, 4 paused — all mean something is still going on.
    #expect(SessionProgress.parse(oscNine: "4;1;50") == .working)
    #expect(SessionProgress.parse(oscNine: "4;2;") == .working)
    #expect(SessionProgress.parse(oscNine: "4;4;") == .working)
  }

  @Test("ignores anything that is not a progress report")
  func ignoresOther() {
    // OSC 9 carries more than progress, and a payload Grove cannot read must not
    // be turned into a state change.
    #expect(SessionProgress.parse(oscNine: "some notification text") == nil)
    #expect(SessionProgress.parse(oscNine: "") == nil)
    #expect(SessionProgress.parse(oscNine: "4") == nil)
    #expect(SessionProgress.parse(oscNine: "4;x;") == nil)
  }
}

@Suite("deciding when a session wants attention")
struct SessionActivityMonitorTests {
  private let start = Date(timeIntervalSince1970: 1_000_000)

  private func later(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

  @Test("finishing real work is worth a signal")
  func finishingWork() {
    var monitor = SessionActivityMonitor()
    #expect(monitor.received(.working, at: start) == nil)
    #expect(monitor.isWorking)
    #expect(monitor.received(.idle, at: later(30)) == .waiting)
    #expect(!monitor.isWorking)
  }

  @Test("a session idle since it started has finished nothing")
  func idleFromTheStart() {
    // Claude Code sends 9;4;0 on launch. That must not read as a completion.
    var monitor = SessionActivityMonitor()
    #expect(monitor.received(.idle, at: start) == nil)
    #expect(monitor.received(.idle, at: later(60)) == nil)
  }

  @Test("work too brief to wait for stays quiet")
  func briefWork() {
    var monitor = SessionActivityMonitor()
    _ = monitor.received(.working, at: start)
    #expect(monitor.received(.idle, at: later(0.4)) == nil)
  }

  @Test("repeats of the same state are not transitions")
  func repeatsAreQuiet() {
    // A percentage counting up is many `working` reports; only the change matters.
    var monitor = SessionActivityMonitor()
    _ = monitor.received(.working, at: start)
    #expect(monitor.received(.working, at: later(5)) == nil)
    #expect(monitor.received(.working, at: later(10)) == nil)
    #expect(monitor.received(.idle, at: later(15)) == .waiting)
  }

  @Test("each turn of a long session signals once")
  func manyTurns() {
    var monitor = SessionActivityMonitor()
    for turn in 0..<3 {
      let base = TimeInterval(turn * 100)
      #expect(monitor.received(.working, at: later(base)) == nil)
      #expect(monitor.received(.idle, at: later(base + 20)) == .waiting)
    }
  }
}
