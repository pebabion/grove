import Foundation
import GroveCore

/// Installs the Claude Code relay and delivers what arrives through it.
///
/// Claude Code runs a script; the script drops each payload in a directory; this
/// watches that directory. The indirection is what makes it survive Grove restarting,
/// updating, or not running at all — events simply wait, and stale ones are discarded
/// on the way in.
@MainActor
final class HookRelay {
  /// Called for each event, once it is known to be recent.
  var onEvent: (@MainActor (HookEvent) -> Void)?

  private var source: DispatchSourceFileSystemObject?
  private var descriptor: CInt = -1

  /// Events older than this were meant for a Grove that was not running, and
  /// notifying about a turn that ended an hour ago would be worse than saying nothing.
  private static let freshness: TimeInterval = 120

  var isInstalled: Bool {
    guard let settings = try? Data(contentsOf: ClaudeHooks.settingsURL) else { return false }
    return ClaudeHooks.isInstalled(in: settings)
      && FileManager.default.fileExists(atPath: ClaudeHooks.scriptURL.path)
  }

  /// Writes the relay script and registers it with Claude Code.
  ///
  /// The settings file is copied first. It is the user's own configuration, held by
  /// other tools too, and Grove rewriting it is not something to do without a way
  /// back.
  func install() throws {
    let manager = FileManager.default
    try manager.createDirectory(at: ClaudeHooks.supportDirectory, withIntermediateDirectories: true)
    try manager.createDirectory(at: ClaudeHooks.eventsDirectory, withIntermediateDirectories: true)

    try Data(ClaudeHooks.script.utf8).write(to: ClaudeHooks.scriptURL, options: .atomic)
    try manager.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: ClaudeHooks.scriptURL.path)

    let current = (try? Data(contentsOf: ClaudeHooks.settingsURL)) ?? Data()
    if !manager.fileExists(atPath: ClaudeHooks.settingsBackupURL.path), !current.isEmpty {
      try? current.write(to: ClaudeHooks.settingsBackupURL, options: .atomic)
    }

    let updated = try ClaudeHooks.installed(in: current, command: ClaudeHooks.command)
    try updated.write(to: ClaudeHooks.settingsURL, options: .atomic)
    Log.hooks.note("relay installed")
  }

  /// Unregisters the relay, leaving the script where it is so nothing in flight fails.
  func uninstall() throws {
    let current = (try? Data(contentsOf: ClaudeHooks.settingsURL)) ?? Data()
    guard !current.isEmpty else { return }
    let updated = try ClaudeHooks.removed(from: current)
    try updated.write(to: ClaudeHooks.settingsURL, options: .atomic)
    Log.hooks.note("relay removed")
  }

  /// Starts watching, and picks up anything already waiting.
  func start() {
    guard source == nil else { return }
    try? FileManager.default.createDirectory(
      at: ClaudeHooks.eventsDirectory, withIntermediateDirectories: true)

    descriptor = open(ClaudeHooks.eventsDirectory.path, O_EVTONLY)
    guard descriptor >= 0 else {
      Log.hooks.problem("cannot watch the events directory")
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.drain() }
    }
    source.setCancelHandler { [descriptor] in close(descriptor) }
    source.resume()
    self.source = source

    Log.hooks.note("watching for events")
    drain()
  }

  func stop() {
    source?.cancel()
    source = nil
    descriptor = -1
  }

  /// Reads and deletes everything in the directory.
  ///
  /// Deleting is what stops an event being reported twice, so it happens whether or
  /// not the payload could be understood.
  private func drain() {
    let manager = FileManager.default
    guard
      let files = try? manager.contentsOfDirectory(
        at: ClaudeHooks.eventsDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }

    for file in files.sorted(by: { $0.path < $1.path }) {
      defer { try? manager.removeItem(at: file) }
      guard let data = try? Data(contentsOf: file), let event = HookEvent.decode(data) else {
        continue
      }

      let modified =
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        ?? Date()
      guard Date().timeIntervalSince(modified) < Self.freshness else {
        Log.hooks.note("discarded a stale event from \(event.directory.lastPathComponent)")
        continue
      }

      Log.hooks.note(
        "\(String(describing: event.reason)) in \(event.directory.lastPathComponent)")
      onEvent?(event)
    }
  }
}
