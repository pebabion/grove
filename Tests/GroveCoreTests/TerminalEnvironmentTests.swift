import Foundation
import Testing

@testable import GroveCore

@Suite("terminal environment")
struct TerminalEnvironmentTests {
  private func build(_ parent: [String: String]) -> [String: String] {
    TerminalEnvironment.build(from: parent, termProgram: "Grove", programVersion: "1.2.3")
  }

  @Test("drops the session state of whatever launched Grove")
  func dropsLaunchingSessionState() {
    // The bug this exists for: Claude Code inside Grove saw this marker, decided it
    // was a nested session and stopped saving transcripts.
    let result = build([
      "HOME": "/Users/x",
      "CLAUDE_CODE_CHILD_SESSION": "1",
      "CLAUDE_CODE_SESSION_ID": "abc",
      "CLAUDE_CODE_ENTRYPOINT": "cli",
      "SOME_OTHER_APP_TOKEN": "secret",
    ])

    #expect(result["CLAUDE_CODE_CHILD_SESSION"] == nil)
    #expect(result["CLAUDE_CODE_SESSION_ID"] == nil)
    #expect(result["CLAUDE_CODE_ENTRYPOINT"] == nil)
    #expect(result["SOME_OTHER_APP_TOKEN"] == nil)
  }

  @Test("keeps what a shell cannot do without")
  func keepsEssentials() {
    let result = build([
      "HOME": "/Users/x",
      "USER": "x",
      "SHELL": "/opt/homebrew/bin/fish",
      "PATH": "/opt/homebrew/bin:/usr/bin",
      // Without this, git push over SSH cannot reach the agent.
      "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
      "TMPDIR": "/private/tmp/x/",
    ])

    #expect(result["HOME"] == "/Users/x")
    #expect(result["PATH"] == "/opt/homebrew/bin:/usr/bin")
    #expect(result["SSH_AUTH_SOCK"] == "/private/tmp/agent.sock")
    #expect(result["TMPDIR"] == "/private/tmp/x/")
  }

  @Test("says which terminal it is")
  func identifiesItself() {
    let result = build(["TERM_PROGRAM": "ghostty", "TERM": "dumb"])

    #expect(result["TERM_PROGRAM"] == "Grove")
    #expect(result["TERM_PROGRAM_VERSION"] == "1.2.3")
    #expect(result["TERM"] == "xterm-256color")
    #expect(result["COLORTERM"] == "truecolor")
  }

  @Test("supplies a locale when the app was given none")
  func suppliesLocale() {
    #expect(build(["HOME": "/Users/x"])["LANG"]?.hasSuffix(".UTF-8") == true)
    // An explicit one is left alone.
    #expect(build(["LANG": "en_GB.UTF-8"])["LANG"] == "en_GB.UTF-8")
    #expect(build(["LC_ALL": "C"])["LANG"] == nil)
  }
}
