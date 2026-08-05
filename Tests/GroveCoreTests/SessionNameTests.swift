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
