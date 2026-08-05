import Foundation

/// Grove's end of the Claude Code hook system: the relay script, and the edits that
/// register it in Claude Code's settings.
///
/// The relay is a shell script rather than a socket. Hooks are commands Claude Code
/// runs, so a script that drops its input in a directory needs no port, no token and
/// no server, works when Grove is not running, and survives Grove being replaced by
/// an update — which a port written into a settings file would not.
public enum ClaudeHooks {
  /// The events Grove registers for, and why both are needed: `Notification` is how
  /// Claude Code says it wants a human, `Stop` is how it says a turn ended. Neither
  /// covers the other.
  public static let events = ["Notification", "Stop"]

  public static var supportDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Application Support/Grove", directoryHint: .isDirectory)
  }

  public static var scriptURL: URL {
    supportDirectory.appending(path: "claude-hook.sh")
  }

  public static var eventsDirectory: URL {
    supportDirectory.appending(path: "events", directoryHint: .isDirectory)
  }

  /// Where Claude Code's own settings live.
  public static var settingsURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/settings.json")
  }

  /// A copy taken before Grove's first edit, so the original is always recoverable.
  public static var settingsBackupURL: URL {
    supportDirectory.appending(path: "claude-settings-backup.json")
  }

  /// Writes each payload where Grove will find it, complete.
  ///
  /// The payload is written outside the watched directory and moved in, because
  /// creating the file there and then filling it is a race Grove loses: the watcher
  /// wakes on the empty file, reads nothing, deletes it, and the write that follows
  /// lands on a deleted inode. Every event was being dropped that way. A move within
  /// one filesystem is a rename, so the file appears whole or not at all.
  ///
  /// `mktemp` rather than a name built from the time, because two events inside the
  /// same second would collide and one would be lost. Every path exits 0: a hook that
  /// fails must not be a hook that blocks Claude Code.
  public static let script = """
    #!/bin/sh
    # Written by Grove. Relays Claude Code hook events to the app.
    # Remove the matching entries from ~/.claude/settings.json to stop this.
    dir="$HOME/Library/Application Support/Grove/events"
    mkdir -p "$dir" || exit 0
    tmp=$(mktemp "${TMPDIR:-/tmp}/grove-hook.XXXXXXXX") || exit 0
    cat > "$tmp"
    mv "$tmp" "$dir/event.${tmp##*.}" 2>/dev/null || rm -f "$tmp"
    exit 0

    """

  /// Registers the relay, keeping every hook already there.
  ///
  /// Other tools put hooks in this file — a real one held five events belonging to
  /// something else — so this appends and never replaces. Installing twice is the
  /// same as installing once.
  public static func installed(in settings: Data, command: String) throws -> Data {
    var root = try object(from: settings)
    var hooks = root["hooks"] as? [String: Any] ?? [:]

    for event in events {
      var entries = hooks[event] as? [[String: Any]] ?? []
      entries.removeAll { entry in matchesGrove(entry) }
      entries.append(["hooks": [["type": "command", "command": command]]])
      hooks[event] = entries
    }

    root["hooks"] = hooks
    return try data(from: root)
  }

  /// Takes the relay out again, leaving everything else as it was.
  public static func removed(from settings: Data) throws -> Data {
    var root = try object(from: settings)
    guard var hooks = root["hooks"] as? [String: Any] else { return settings }

    for event in events {
      guard var entries = hooks[event] as? [[String: Any]] else { continue }
      entries.removeAll { entry in matchesGrove(entry) }
      // An event left with no hooks should not leave an empty list behind.
      if entries.isEmpty {
        hooks.removeValue(forKey: event)
      } else {
        hooks[event] = entries
      }
    }

    if hooks.isEmpty {
      root.removeValue(forKey: "hooks")
    } else {
      root["hooks"] = hooks
    }
    return try data(from: root)
  }

  public static func isInstalled(in settings: Data) -> Bool {
    guard let root = try? object(from: settings),
      let hooks = root["hooks"] as? [String: Any]
    else { return false }
    return events.allSatisfy { event in
      (hooks[event] as? [[String: Any]] ?? []).contains { matchesGrove($0) }
    }
  }

  /// Recognises Grove's own entry by the script it runs.
  ///
  /// The hook format has a fixed set of fields, so Grove cannot leave a marker of its
  /// own in there without risking a payload Claude Code rejects. The script path is
  /// fixed and belongs to Grove, which makes it identification enough.
  private static func matchesGrove(_ entry: [String: Any]) -> Bool {
    guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
    return inner.contains { hook in
      (hook["command"] as? String)?.contains("Grove/claude-hook.sh") == true
    }
  }

  private static func object(from settings: Data) throws -> [String: Any] {
    // An empty file is a legitimate starting point; JSONSerialization disagrees.
    guard !settings.isEmpty else { return [:] }
    // Both failures are the same to a caller — the file is not something Grove can
    // safely rewrite — so they arrive as one error with something worth showing.
    guard let parsed = try? JSONSerialization.jsonObject(with: settings),
      let root = parsed as? [String: Any]
    else {
      throw HookError.unreadableSettings
    }
    return root
  }

  private static func data(from root: [String: Any]) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }
}

public enum HookError: Error, LocalizedError {
  case unreadableSettings

  public var errorDescription: String? {
    switch self {
    case .unreadableSettings:
      "Claude Code's settings file could not be read, so Grove left it alone."
    }
  }
}
