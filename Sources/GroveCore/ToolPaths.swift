import Foundation

/// Absolute paths to the command line tools Grove shells out to.
///
/// An app launched from Finder inherits a `PATH` of roughly `/usr/bin:/bin`.
/// Homebrew, mise, asdf, nvm and every editor CLI live outside that, so a GUI
/// app that assumes `PATH` will report "gh not found" on a machine where `gh`
/// works fine in Terminal. ``discover()`` asks a login shell where things are
/// and the answers get cached; Settings should let the user correct them.
public struct ToolPaths: Codable, Sendable, Hashable {
  /// Directories to prepend to `PATH` for spawned processes, in order.
  public var searchPaths: [String]

  /// Explicit overrides keyed by tool name. Wins over ``searchPaths``.
  public var overrides: [String: String]

  public init(searchPaths: [String] = [], overrides: [String: String] = [:]) {
    self.searchPaths = searchPaths
    self.overrides = overrides
  }

  /// Tools Grove looks for at startup. `git` is required; the rest are used by
  /// setup hooks and the open-in-editor action, and may legitimately be absent.
  public static let known = ["git", "gh", "zed", "code", "yarn", "uv", "poetry", "pnpm", "npm"]

  /// Absolute path for `tool`, or `nil` if it was not found.
  public func location(of tool: String) -> String? {
    if let override = overrides[tool] {
      return FileManager.default.isExecutableFile(atPath: override) ? override : nil
    }
    for directory in searchPaths {
      let candidate = (directory as NSString).appendingPathComponent(tool)
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  /// Environment for spawned processes, with ``searchPaths`` on the front of `PATH`.
  public func processEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    let inherited = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let merged = searchPaths + inherited.split(separator: ":").map(String.init)
    var seen = Set<String>()
    environment["PATH"] = merged.filter { seen.insert($0).inserted }.joined(separator: ":")
    return environment
  }

  /// Asks the user's login shell for its `PATH`.
  ///
  /// A login shell sources the same profile files Terminal does, so this picks
  /// up Homebrew, version managers and anything else the user has set up.
  public static func discover() async -> ToolPaths {
    let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let shell = Shell()
    var directories: [String] = []

    if let result = try? await shell.run(loginShell, ["-l", "-c", "printf %s \"$PATH\""]),
      result.succeeded
    {
      directories = result.trimmedOutput
        .split(separator: ":")
        .map(String.init)
        .filter { !$0.isEmpty }
    }

    // Fall back to the usual suspects when the probe fails or comes back thin.
    let fallbacks = [
      "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    var seen = Set<String>()
    let searchPaths = (directories + fallbacks).filter { seen.insert($0).inserted }
    return ToolPaths(searchPaths: searchPaths)
  }

  /// A report of which known tools resolved, for display in Settings.
  public func inventory() -> [(tool: String, path: String?)] {
    Self.known.map { ($0, location(of: $0)) }
  }
}
