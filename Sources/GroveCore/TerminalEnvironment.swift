import Foundation

/// The environment an embedded shell starts with.
///
/// Built from a short list of variables rather than inherited wholesale. Whatever
/// launched Grove has no business showing up in your shell, and it is not a
/// theoretical concern: Grove started from a Claude Code session passed
/// `CLAUDE_CODE_CHILD_SESSION` down, so Claude Code run inside Grove decided it
/// was a nested session and quietly stopped saving transcripts.
///
/// A login shell rebuilds nearly everything from the user's profile anyway, so the
/// list only needs what must be right before that happens.
public enum TerminalEnvironment {
  /// Variables carried over from the process that launched Grove.
  ///
  /// `SSH_AUTH_SOCK` earns its place: without it `git push` over SSH cannot reach
  /// the agent. `LANG` and the `LC_` pair decide whether the terminal handles
  /// anything outside ASCII.
  public static let carriedOver: Set<String> = [
    "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH",
    "LANG", "LC_ALL", "LC_CTYPE",
    "SSH_AUTH_SOCK",
  ]

  /// The environment for a shell, given the environment Grove itself has.
  public static func build(
    from parent: [String: String],
    termProgram: String,
    programVersion: String
  ) -> [String: String] {
    var result = parent.filter { carriedOver.contains($0.key) }

    result["TERM"] = "xterm-256color"
    result["COLORTERM"] = "truecolor"
    // Say which terminal this is, as every terminal should. Left unset, the shell
    // reports whatever launched Grove and anything keying features off it guesses
    // wrong.
    result["TERM_PROGRAM"] = termProgram
    result["TERM_PROGRAM_VERSION"] = programVersion

    // An app launched from Finder often has no LANG at all, which leaves shells
    // assuming ASCII and mangling anything else.
    if result["LANG"] == nil, result["LC_ALL"] == nil {
      result["LANG"] = "\(Locale.current.identifier).UTF-8"
    }

    return result
  }
}
