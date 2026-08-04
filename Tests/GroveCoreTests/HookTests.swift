import Foundation
import Testing

@testable import GroveCore

@Suite("lifecycle hooks")
struct HookTests {
  let resolver = HookResolver()

  @Test("prefers a committed script over the library command")
  func scriptBeatsCommand() throws {
    let sandbox = try Sandbox()
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    let script = worktree.appending(path: ".grove/setup.sh")
    try sandbox.write("#!/bin/sh\nyarn install\n", to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let repo = RepoEntry(name: "frontend", path: "~/x", setupCommand: "echo fallback")

    let hook = resolver.resolve(phase: .setup, repo: repo, worktree: worktree)

    #expect(hook == .script(path: script.path))
  }

  @Test("falls back to the library command when no script is committed")
  func fallsBackToCommand() throws {
    let sandbox = try Sandbox()
    let worktree = sandbox.root.appending(path: "spaces/thing/backend")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

    let repo = RepoEntry(name: "backend", path: "~/x", setupCommand: "uv sync")

    #expect(resolver.resolve(phase: .setup, repo: repo, worktree: worktree) == .command("uv sync"))
  }

  @Test("ignores a script that is not executable")
  func ignoresNonExecutableScript() throws {
    let sandbox = try Sandbox()
    let worktree = sandbox.root.appending(path: "spaces/thing/frontend")
    try sandbox.write("#!/bin/sh\n", to: worktree.appending(path: ".grove/setup.sh"))

    let repo = RepoEntry(name: "frontend", path: "~/x", setupCommand: "echo fallback")

    #expect(
      resolver.resolve(phase: .setup, repo: repo, worktree: worktree) == .command("echo fallback"))
  }

  @Test("returns nothing when a repo has no hook for the phase")
  func noHookConfigured() throws {
    let sandbox = try Sandbox()
    let worktree = sandbox.root.appending(path: "spaces/thing/kubernetes")
    try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)

    let repo = RepoEntry(name: "kubernetes", path: "~/x", setupCommand: "  ")

    #expect(resolver.resolve(phase: .setup, repo: repo, worktree: worktree) == nil)
    #expect(resolver.resolve(phase: .teardown, repo: repo, worktree: worktree) == nil)
  }

  @Test("teardown resolves its own script")
  func teardownScript() throws {
    let sandbox = try Sandbox()
    let worktree = sandbox.root.appending(path: "spaces/thing/backend")
    let script = worktree.appending(path: ".grove/teardown.sh")
    try sandbox.write("#!/bin/sh\ndocker compose down\n", to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

    let repo = RepoEntry(name: "backend", path: "~/x")

    #expect(
      resolver.resolve(phase: .teardown, repo: repo, worktree: worktree)
        == .script(path: script.path))
    #expect(resolver.resolve(phase: .setup, repo: repo, worktree: worktree) == nil)
  }

  @Test("passes the documented variables to a script")
  func exportsContract() {
    let variables = HookEnvironment.variables(
      worktree: URL(filePath: "/w/spaces/thing/frontend"),
      repoRoot: URL(filePath: "/src/frontend"),
      workspace: URL(filePath: "/w/spaces/thing"),
      repoName: "frontend",
      branch: "kelvin/thing",
      baseBranch: "origin/master"
    )

    #expect(variables["GROVE_WORKTREE"] == "/w/spaces/thing/frontend")
    #expect(variables["GROVE_REPO_ROOT"] == "/src/frontend")
    #expect(variables["GROVE_WORKSPACE"] == "/w/spaces/thing")
    #expect(variables["GROVE_WORKSPACE_NAME"] == "thing")
    #expect(variables["GROVE_REPO_NAME"] == "frontend")
    #expect(variables["GROVE_BRANCH"] == "kelvin/thing")
    #expect(variables["GROVE_BASE_BRANCH"] == "origin/master")
  }
}

@Suite("tool discovery")
struct ToolPathTests {
  @Test("puts discovered directories at the front of PATH")
  func prependsSearchPaths() {
    let paths = ToolPaths(searchPaths: ["/opt/homebrew/bin", "/usr/bin"])

    let path = paths.processEnvironment()["PATH"] ?? ""

    #expect(path.hasPrefix("/opt/homebrew/bin:/usr/bin"))
  }

  @Test("does not repeat a directory already on PATH")
  func deduplicates() {
    let paths = ToolPaths(searchPaths: ["/usr/bin", "/usr/bin", "/bin"])

    let entries = (paths.processEnvironment()["PATH"] ?? "").split(separator: ":")

    #expect(entries.filter { $0 == "/usr/bin" }.count == 1)
  }

  @Test("finds a tool on the search path")
  func locatesTool() {
    let paths = ToolPaths(searchPaths: ["/usr/bin", "/bin"])

    #expect(paths.location(of: "git") != nil)
    #expect(paths.location(of: "definitely-not-installed-xyz") == nil)
  }

  @Test("rejects an override that does not point at an executable")
  func rejectsBadOverride() {
    let paths = ToolPaths(searchPaths: ["/usr/bin"], overrides: ["git": "/nope/git"])

    #expect(paths.location(of: "git") == nil)
  }

  @Test("a login shell probe finds git")
  func discoversRealPath() async {
    let paths = await ToolPaths.discover()

    #expect(!paths.searchPaths.isEmpty)
    #expect(paths.location(of: "git") != nil)
  }
}
