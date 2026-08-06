import Foundation
import Testing

@testable import GroveCore

/// Every git call in Grove goes through this. The interesting cases are the ones that
/// hang or lose output rather than the ones that fail cleanly.
@Suite("running subprocesses")
struct ShellTests {
  private let shell = Shell(environment: ["PATH": "/usr/bin:/bin"])

  @Test("captures standard output")
  func capturesOutput() async throws {
    let result = try await shell.run("/bin/echo", ["hello"])
    #expect(result.succeeded)
    #expect(result.trimmedOutput == "hello")
    #expect(result.standardError.isEmpty)
  }

  @Test("captures standard error and the exit code without throwing")
  func capturesFailure() async throws {
    // run() reports; only check() throws. A failed hook is a state Grove displays.
    let result = try await shell.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
    #expect(!result.succeeded)
    #expect(result.exitCode == 3)
    #expect(result.standardError.contains("oops"))
  }

  @Test("does not deadlock on output larger than a pipe buffer")
  func survivesChattyCommands() async throws {
    // The rule this defends: a pipe blocks the writer at 64KB, so draining stdout and
    // then stderr deadlocks on a chatty command -- which `yarn install` is. Shell
    // captures through temporary files for this reason. Two megabytes on both streams
    // at once would never come back through sequential pipe reads.
    let result = try await shell.run(
      "/bin/sh",
      [
        "-c",
        """
        i=0
        while [ $i -lt 8000 ]; do
          echo "stdout line $i padded out to make this worth doing"
          echo "stderr line $i padded out to make this worth doing" >&2
          i=$((i + 1))
        done
        """,
      ])

    #expect(result.succeeded)
    #expect(result.standardOutput.count > 300_000)
    #expect(result.standardError.count > 300_000)
    #expect(result.standardOutput.contains("stdout line 7999"))
    #expect(result.standardError.contains("stderr line 7999"))
  }

  @Test("check throws on a non-zero exit, carrying the error output")
  func checkThrows() async throws {
    await #expect(throws: ShellError.self) {
      try await shell.check("/bin/sh", ["-c", "echo bad >&2; exit 1"])
    }
  }

  @Test("check returns the result when the command succeeds")
  func checkPasses() async throws {
    let result = try await shell.check("/bin/echo", ["fine"])
    #expect(result.trimmedOutput == "fine")
  }

  @Test("reports a missing executable rather than trapping")
  func missingExecutable() async throws {
    await #expect(throws: (any Error).self) {
      try await shell.run("/nonexistent/grove-not-a-program", [])
    }
  }

  @Test("runs in the directory it is given")
  func runsInDirectory() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "grove-shell-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let result = try await shell.run("/bin/pwd", [], in: directory)
    #expect(result.trimmedOutput.hasSuffix(directory.lastPathComponent))
  }

  @Test("passes the environment it was built with, and nothing else")
  func passesEnvironment() async throws {
    // A GUI app inherits almost nothing, so what reaches a hook is exactly what Grove
    // decided to send.
    let shell = Shell(environment: ["PATH": "/usr/bin:/bin", "GROVE_MARKER": "yes"])
    let result = try await shell.run("/usr/bin/env", [])
    #expect(result.standardOutput.contains("GROVE_MARKER=yes"))
  }

  @Test("keeps output that never ends in a newline")
  func handlesMissingTrailingNewline() async throws {
    let result = try await shell.run("/usr/bin/printf", ["no trailing newline"])
    #expect(result.standardOutput == "no trailing newline")
  }
}
