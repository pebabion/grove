import Foundation
import os

/// Where Grove says what it is doing.
///
/// This exists because the UI cannot be watched from outside — no screenshots, no
/// scripted clicks — so when something that should have happened does not, the only
/// way to find out where it stopped is to have the app say so at each step.
///
/// Everything goes to both the unified log and a plain file. The file is there
/// because `log show` needs privileges that a sandboxed process does not have, and a
/// diagnostic nobody can read is not a diagnostic:
///
///     tail -f ~/Library/Logs/Grove.log
enum Log {
  static let sessions = Category(name: "sessions")

  struct Category {
    let name: String
    private let logger: Logger

    init(name: String) {
      self.name = name
      self.logger = Logger(subsystem: "com.pebabion.Grove", category: name)
    }

    func note(_ message: String) {
      logger.notice("\(message, privacy: .public)")
      Log.append("\(name): \(message)")
    }

    func problem(_ message: String) {
      logger.error("\(message, privacy: .public)")
      Log.append("\(name): \(message)")
    }
  }

  private static let file: URL = {
    let logs = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Logs", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    return logs.appending(path: "Grove.log")
  }()

  /// Serialised, because sessions report from whatever thread read their bytes.
  private static let queue = DispatchQueue(label: "com.pebabion.Grove.log")

  private static let stamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()

  private static func append(_ message: String) {
    let line = "\(stamp.string(from: Date()))  \(message)\n"
    queue.async {
      guard let data = line.data(using: .utf8) else { return }
      if let handle = try? FileHandle(forWritingTo: file) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
      } else {
        try? data.write(to: file)
      }
    }
  }
}
