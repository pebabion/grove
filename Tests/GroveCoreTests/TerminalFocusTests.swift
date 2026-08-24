import Testing

@testable import GroveCore

/// Who gets the keyboard is a question with exactly two wrong answers, and both were live
/// at some point: the sidebar keeping it after a workspace switch, and the terminal taking
/// it away from the file search.
@Suite("who gets the keyboard")
struct TerminalFocusTests {
  @Test("a terminal on screen takes it")
  func takesIt() {
    // The case the whole thing exists for: switch workspace, start typing to the agent.
    #expect(TerminalFocus.shouldTakeKeyboard(hasSession: true, filesShowing: false))
  }

  @Test("nothing to type into, nothing to take")
  func noSession() {
    // An empty pane, or one explaining that the workspace is still being built.
    #expect(!TerminalFocus.shouldTakeKeyboard(hasSession: false, filesShowing: false))
  }

  @Test("the file search keeps it while it is open")
  func filesWin() {
    // The search field takes the keyboard when it appears. A terminal grabbing it back
    // would leave the two fighting over every keystroke.
    #expect(!TerminalFocus.shouldTakeKeyboard(hasSession: true, filesShowing: true))
    #expect(!TerminalFocus.shouldTakeKeyboard(hasSession: false, filesShowing: true))
  }
}
