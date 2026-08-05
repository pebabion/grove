import Foundation
import Testing

@testable import GroveCore

@Suite("reading hook payloads")
struct HookEventTests {
  private func payload(_ json: String) -> HookEvent? {
    HookEvent.decode(Data(json.utf8))
  }

  @Test("reads the notification a live session actually sent")
  func realNotification() {
    // Captured by driving Claude Code through a PTY. Note the absent `type`.
    let event = payload(
      """
      {"session_id":"abc","hook_event_name":"Notification",
       "message":"Claude is waiting for your input",
       "cwd":"/Users/me/work/api"}
      """)
    #expect(event?.reason == .needsInput)
    #expect(event?.directory.path == "/Users/me/work/api")
    #expect(event?.message == "Claude is waiting for your input")
  }

  @Test("reads the end of a turn")
  func realStop() {
    let event = payload(
      """
      {"session_id":"abc","hook_event_name":"Stop","cwd":"/Users/me/work/api"}
      """)
    #expect(event?.reason == .finished)
    #expect(event?.message == nil)
  }

  @Test("uses the type when there is one")
  func typedNotification() {
    #expect(
      payload(
        #"{"hook_event_name":"Notification","type":"agent_completed","cwd":"/w"}"#
      )?.reason == .finished)
    #expect(
      payload(
        #"{"hook_event_name":"Notification","type":"permission_prompt","cwd":"/w"}"#
      )?.reason == .needsInput)
  }

  @Test("ignores events that are not about waiting")
  func ignored() {
    // Signing in is not something the user is being waited on for.
    #expect(payload(#"{"hook_event_name":"Notification","type":"auth_success","cwd":"/w"}"#) == nil)
    // Events Grove did not register for should never be acted on.
    #expect(payload(#"{"hook_event_name":"PostToolUse","cwd":"/w"}"#) == nil)
  }

  @Test("drops anything it cannot understand rather than guessing")
  func malformed() {
    #expect(payload("not json at all") == nil)
    #expect(payload("{}") == nil)
    #expect(payload(#"{"hook_event_name":"Stop"}"#) == nil)  // no cwd
    #expect(payload(#"{"hook_event_name":"Stop","cwd":""}"#) == nil)
    #expect(HookEvent.decode(Data()) == nil)
  }
}

@Suite("registering the relay in Claude Code's settings")
struct ClaudeHooksTests {
  private let command = "/Users/me/Library/Application Support/Grove/claude-hook.sh"

  private func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
  }

  /// Shaped like the real file: another tool's hooks, on the same events Grove wants.
  private var existing: Data {
    Data(
      """
      {
        "permissions": {"allow": ["Read(/Users/me)"]},
        "statusLine": {"type": "command"},
        "hooks": {
          "Stop": [{"hooks": [{"type": "command", "command": "other-tool.sh"}]}],
          "PostToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": "other.sh"}]}]
        }
      }
      """.utf8)
  }

  @Test("leaves every other setting untouched")
  func preservesSettings() throws {
    let result = json(try ClaudeHooks.installed(in: existing, command: command))
    #expect(result["permissions"] != nil)
    #expect(result["statusLine"] != nil)
  }

  @Test("keeps hooks belonging to other tools, on the same event")
  func preservesOtherHooks() throws {
    let result = json(try ClaudeHooks.installed(in: existing, command: command))
    let hooks = result["hooks"] as? [String: Any]
    let stop = hooks?["Stop"] as? [[String: Any]] ?? []
    #expect(stop.count == 2)
    let commands = stop.flatMap { entry in
      (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
    }
    #expect(commands.contains("other-tool.sh"))
    #expect(commands.contains(command))
    #expect((hooks?["PostToolUse"] as? [[String: Any]])?.count == 1)
  }

  @Test("registers for both events")
  func registersBoth() throws {
    let installed = try ClaudeHooks.installed(in: existing, command: command)
    #expect(ClaudeHooks.isInstalled(in: installed))
    let hooks = json(installed)["hooks"] as? [String: Any]
    #expect(hooks?["Notification"] != nil)
    #expect(hooks?["Stop"] != nil)
  }

  @Test("installing twice is the same as installing once")
  func idempotent() throws {
    let once = try ClaudeHooks.installed(in: existing, command: command)
    let twice = try ClaudeHooks.installed(in: once, command: command)
    let stop = (json(twice)["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
    #expect(stop.count == 2)
  }

  @Test("removing takes back only Grove's entry")
  func removesOnlyOurs() throws {
    let installed = try ClaudeHooks.installed(in: existing, command: command)
    let removed = try ClaudeHooks.removed(from: installed)
    #expect(!ClaudeHooks.isInstalled(in: removed))

    let result = json(removed)
    let hooks = result["hooks"] as? [String: Any]
    let stop = hooks?["Stop"] as? [[String: Any]] ?? []
    #expect(stop.count == 1)
    #expect(
      (stop.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        == "other-tool.sh")
    // Notification held nothing else, so it should not linger as an empty list.
    #expect(hooks?["Notification"] == nil)
    #expect(result["permissions"] != nil)
  }

  @Test("a round trip through install and remove restores the settings")
  func roundTrip() throws {
    let installed = try ClaudeHooks.installed(in: existing, command: command)
    let removed = try ClaudeHooks.removed(from: installed)
    let before = json(existing)
    let after = json(removed)
    #expect(
      NSDictionary(dictionary: before["hooks"] as? [String: Any] ?? [:])
        == NSDictionary(dictionary: after["hooks"] as? [String: Any] ?? [:]))
  }

  @Test("works from an empty or hookless file")
  func fromNothing() throws {
    #expect(ClaudeHooks.isInstalled(in: try ClaudeHooks.installed(in: Data(), command: command)))
    let bare = Data("{}".utf8)
    #expect(ClaudeHooks.isInstalled(in: try ClaudeHooks.installed(in: bare, command: command)))
  }

  @Test("refuses to touch a settings file it cannot read")
  func refusesGarbage() {
    // Overwriting a file Grove does not understand would destroy real configuration.
    #expect(throws: HookError.self) {
      try ClaudeHooks.installed(in: Data("this is not json".utf8), command: command)
    }
  }

  @Test("removing from a file with no hooks changes nothing")
  func removeFromNothing() throws {
    let bare = Data(#"{"permissions":{}}"#.utf8)
    #expect(try ClaudeHooks.removed(from: bare) == bare)
  }

  @Test("the relay script always exits successfully")
  func scriptNeverBlocks() {
    // A hook that fails must not be a hook that stops Claude Code working.
    #expect(ClaudeHooks.script.contains("exit 0"))
    #expect(ClaudeHooks.script.contains("mktemp"))
    #expect(ClaudeHooks.script.hasPrefix("#!/bin/sh"))
  }

  @Test("the payload is moved into place, never written in place")
  func scriptMovesIntoPlace() {
    // Writing into the watched directory loses events: the watcher wakes on the
    // still-empty file, deletes it, and the write lands on a deleted inode. Measured,
    // not theoretical -- it dropped every event until the move was added.
    #expect(ClaudeHooks.script.contains("mv "))
    let lines = ClaudeHooks.script.split(separator: "\n")
    let capture = lines.first { $0.hasPrefix("cat >") }
    #expect(capture?.contains("$tmp") == true)
    #expect(capture?.contains("$dir") == false)
  }
}
