import Foundation

/// The outcome of a finished subprocess.
public struct CommandResult: Sendable {
  public let exitCode: Int32
  public let standardOutput: String
  public let standardError: String

  public var succeeded: Bool { exitCode == 0 }

  /// Standard output with surrounding whitespace removed, which is what
  /// nearly every git invocation actually wants.
  public var trimmedOutput: String {
    standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum ShellError: Error, LocalizedError, Sendable {
  case executableNotFound(String)
  case failed(command: String, exitCode: Int32, standardError: String)

  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let path):
      return "Could not find executable: \(path)"
    case .failed(let command, let exitCode, let standardError):
      let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
      if detail.isEmpty {
        return "\(command) exited with code \(exitCode)"
      }
      return "\(command) exited with code \(exitCode): \(detail)"
    }
  }
}

/// Runs subprocesses and collects their output.
///
/// Output is captured through temporary files rather than pipes. A pipe holds
/// only 64KB before the writer blocks, so draining stdout and stderr one after
/// the other can deadlock on a chatty command. Setup scripts running `yarn
/// install` are exactly that. Files cannot deadlock.
public struct Shell: Sendable {
  /// Environment for spawned processes. `nil` inherits the parent's.
  ///
  /// A GUI app launched from Finder inherits almost no `PATH`, so callers
  /// should pass an environment built from ``ToolPaths``.
  public var environment: [String: String]?

  public init(environment: [String: String]? = nil) {
    self.environment = environment
  }

  /// Runs `executable` and returns its result, whatever the exit code.
  public func run(
    _ executable: String,
    _ arguments: [String],
    in directory: URL? = nil
  ) async throws -> CommandResult {
    let invocation = Invocation(
      executable: executable,
      arguments: arguments,
      directory: directory,
      environment: environment
    )
    return try await Task.detached(priority: .userInitiated) {
      try Self.execute(invocation)
    }.value
  }

  /// Runs `executable` and throws ``ShellError/failed`` unless it exits zero.
  @discardableResult
  public func check(
    _ executable: String,
    _ arguments: [String],
    in directory: URL? = nil
  ) async throws -> CommandResult {
    let result = try await run(executable, arguments, in: directory)
    guard result.succeeded else {
      let command = ([executable] + arguments).joined(separator: " ")
      throw ShellError.failed(
        command: command,
        exitCode: result.exitCode,
        standardError: result.standardError
      )
    }
    return result
  }

  private struct Invocation: Sendable {
    let executable: String
    let arguments: [String]
    let directory: URL?
    let environment: [String: String]?
  }

  private static func execute(_ invocation: Invocation) throws -> CommandResult {
    guard FileManager.default.isExecutableFile(atPath: invocation.executable) else {
      throw ShellError.executableNotFound(invocation.executable)
    }

    let outputURL = temporaryFileURL()
    let errorURL = temporaryFileURL()
    defer {
      try? FileManager.default.removeItem(at: outputURL)
      try? FileManager.default.removeItem(at: errorURL)
    }

    let manager = FileManager.default
    manager.createFile(atPath: outputURL.path, contents: nil)
    manager.createFile(atPath: errorURL.path, contents: nil)

    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)

    let process = Process()
    process.executableURL = URL(filePath: invocation.executable)
    process.arguments = invocation.arguments
    process.currentDirectoryURL = invocation.directory
    process.environment = invocation.environment
    process.standardOutput = outputHandle
    process.standardError = errorHandle
    process.standardInput = FileHandle.nullDevice

    try process.run()
    process.waitUntilExit()

    try? outputHandle.close()
    try? errorHandle.close()

    return CommandResult(
      exitCode: process.terminationStatus,
      standardOutput: (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "",
      standardError: (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
    )
  }

  private static func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "grove-\(UUID().uuidString)")
  }
}
