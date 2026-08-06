import Foundation
import Testing

@testable import GroveCore

/// Running a hook is how a workspace becomes usable — symlinking a .env, installing
/// dependencies. A hook that fails is a state Grove shows and offers to retry, not an
/// error that throws the worktree away, so the failing cases matter as much as the
/// working ones.
@Suite("running setup and teardown hooks")
struct HookRunnerTests {
  private let runner = HookRunner(toolPaths: ToolPaths(searchPaths: ["/usr/bin", "/bin"]))

  private struct Fixture {
    let root: URL
    let worktree: URL
    let repo: RepoEntry
    var workspace: URL { root.appending(path: "space") }
  }

  private func fixture() throws -> Fixture {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "grove-hook-\(UUID().uuidString)")
    let worktree = root.appending(path: "space/backend")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    let clone = root.appending(path: "clones/backend")
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    return Fixture(
      root: root, worktree: worktree,
      repo: RepoEntry(name: "backend", path: clone.path, base: "main"))
  }

  private func run(_ hook: HookKind, _ fixture: Fixture) async throws -> CommandResult {
    try await runner.run(
      hook, worktree: fixture.worktree, repo: fixture.repo,
      workspace: fixture.workspace, branch: "kelvin/work")
  }

  @Test("runs a command in the worktree")
  func runsCommandInWorktree() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let result = try await run(.command("pwd"), fixture)
    #expect(result.succeeded)
    #expect(result.trimmedOutput.hasSuffix("backend"))
  }

  @Test("reports a failing command instead of throwing")
  func failingCommandIsReported() async throws {
    // A created worktree whose setup failed is a normal state. Throwing here would
    // lose the log that says why.
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let result = try await run(.command("echo 'no lockfile' >&2; exit 2"), fixture)
    #expect(!result.succeeded)
    #expect(result.exitCode == 2)
    #expect(result.standardError.contains("no lockfile"))
  }

  @Test("a command sees the documented variables")
  func commandSeesVariables() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let result = try await run(
      .command("echo \"$GROVE_REPO_NAME $GROVE_BRANCH $GROVE_BASE_BRANCH\""), fixture)
    #expect(result.trimmedOutput == "backend kelvin/work main")
  }

  @Test("a command can reach the worktree and the source clone")
  func commandSeesPaths() async throws {
    // Symlinking .env from the clone into the worktree is the motivating case, and it
    // needs both ends.
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let result = try await run(.command("test -d \"$GROVE_REPO_ROOT\" && echo both"), fixture)
    #expect(result.trimmedOutput == "both")
  }

  @Test("runs a committed script")
  func runsScript() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let script = fixture.worktree.appending(path: "setup.sh")
    try Data("#!/bin/sh\necho ran in \"$(basename \"$PWD\")\"\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let result = try await run(.script(path: script.path), fixture)
    #expect(result.trimmedOutput == "ran in backend")
  }

  @Test("a script that exits non-zero is reported, with its output kept")
  func failingScriptIsReported() async throws {
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let script = fixture.worktree.appending(path: "setup.sh")
    try Data("#!/bin/sh\necho starting\necho broke >&2\nexit 7\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let result = try await run(.script(path: script.path), fixture)
    #expect(result.exitCode == 7)
    #expect(result.standardOutput.contains("starting"))
    #expect(result.standardError.contains("broke"))
  }

  @Test("a chatty hook does not hang")
  func chattyHookCompletes() async throws {
    // `yarn install` is the real one. Output beyond a pipe buffer used to be able to
    // deadlock a subprocess runner built on pipes.
    let fixture = try fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }

    let result = try await run(
      .command("i=0; while [ $i -lt 4000 ]; do echo \"installing package $i\"; i=$((i+1)); done"),
      fixture)
    #expect(result.succeeded)
    #expect(result.standardOutput.contains("installing package 3999"))
  }
}
