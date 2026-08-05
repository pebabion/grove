import Foundation

/// The shell this user actually uses.
///
/// Read from the password database, not from `SHELL`. An app launched from Finder
/// inherits no `SHELL` at all — `launchctl getenv SHELL` is empty — so trusting
/// the environment meant falling back to `/bin/zsh` for someone whose shell is
/// fish. Their terminal had no completions and no prompt, because it was a shell
/// they had never configured.
public enum UserShell {
  /// Absolute path to the login shell, falling back only when the real one is
  /// unusable.
  public static var path: String {
    if let fromDatabase = fromPasswordDatabase, isUsable(fromDatabase) {
      return fromDatabase
    }
    // Worth trying second: correct when Grove was started from a terminal.
    if let fromEnvironment = ProcessInfo.processInfo.environment["SHELL"],
      isUsable(fromEnvironment)
    {
      return fromEnvironment
    }
    return "/bin/zsh"
  }

  /// What `getpwuid` reports, which is what `dscl . -read /Users/x UserShell` shows
  /// and what other editors use.
  public static var fromPasswordDatabase: String? {
    guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
    let path = String(cString: shell)
    return path.isEmpty ? nil : path
  }

  private static func isUsable(_ path: String) -> Bool {
    !path.isEmpty && FileManager.default.isExecutableFile(atPath: path)
  }
}
