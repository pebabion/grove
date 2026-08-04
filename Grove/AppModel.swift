import AppKit
import GroveCore
import SwiftUI

/// Live state for one repo during a create, setup or teardown run.
struct RepoActivity: Sendable, Hashable {
  var state: RepoState
  var detail: String
  var log: String?
}

@Observable
@MainActor
final class AppModel {
  var toolPaths = ToolPaths()
  var library = RepoLibrary()
  var workspaces: [Workspace] = []
  var selection: URL?
  var isScanning = false
  var isBusy = false
  var errorMessage: String?

  /// Keyed by `workspacePath|repoName` so two workspaces provisioning at once
  /// do not overwrite each other's progress.
  var activity: [String: RepoActivity] = [:]

  /// Sheet targets. They live here rather than in a view so the sidebar's
  /// context menu and the detail pane's menu drive the same sheets.
  var renameTarget: Workspace?
  var teardownTarget: TeardownTarget?

  private let store = JSONStore()

  var git: Git? {
    guard let executable = toolPaths.location(of: "git") else { return nil }
    return Git(executable: executable, environment: toolPaths.processEnvironment())
  }

  var selectedWorkspace: Workspace? {
    workspaces.first { $0.url == selection }
  }

  // MARK: - Lifecycle

  func load() async {
    toolPaths = await ToolPaths.discover()
    library = (try? store.load(RepoLibrary.self, from: GroveLocations.libraryFile)) ?? RepoLibrary()
    await rescan()
  }

  func rescan() async {
    guard let git else {
      errorMessage = "Could not find git. Set its path in Settings."
      return
    }
    isScanning = true
    let root = library.workspaceRootURL
    workspaces = await WorkspaceScanner(git: git).scan(root: root, library: library)
    if let selection, !workspaces.contains(where: { $0.url == selection }) {
      self.selection = workspaces.first?.url
    } else if selection == nil {
      selection = workspaces.first?.url
    }
    isScanning = false
  }

  func saveLibrary() {
    do {
      try store.save(library, to: GroveLocations.libraryFile)
    } catch {
      errorMessage = "Could not save the library: \(error.localizedDescription)"
    }
  }

  // MARK: - Repo library

  /// Adds a clone to the library, reading its default branch from the remote.
  func addRepoToLibrary(at url: URL) async {
    guard let git else { return }
    guard (try? await git.isGitRepository(url)) == true else {
      errorMessage = "\(url.lastPathComponent) is not a git repository"
      return
    }
    let name = url.lastPathComponent
    guard library[name] == nil else {
      errorMessage = "\(name) is already in the library"
      return
    }

    let base = (try? await git.defaultBranch(repo: url)) ?? "origin/main"
    library.repos.append(
      RepoEntry(
        name: name,
        path: shortenHome(url.path),
        base: base ?? "origin/main",
        colorIndex: library.nextColorIndex()
      ))
    library.repos.sort { $0.name < $1.name }
    saveLibrary()
    await rescan()
  }

  func removeRepoFromLibrary(_ name: String) {
    library.repos.removeAll { $0.name == name }
    saveLibrary()
  }

  // MARK: - Workspaces

  func createWorkspace(name: String, branch: String, link: String?, repoNames: Set<String>) async {
    guard let git else { return }
    let repos = library.repos.filter { repoNames.contains($0.name) }
    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    let root = library.workspaceRootURL

    isBusy = true
    defer { isBusy = false }

    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let created = try await service.create(
        name: name,
        branch: branch,
        link: link?.isEmpty == true ? nil : link,
        repos: repos,
        in: root,
        onUpdate: handler(forWorkspaceAt: root.appending(path: WorkspaceNaming.slug(name)))
      )
      await rescan()
      selection = created
    } catch {
      errorMessage = error.localizedDescription
      await rescan()
    }
  }

  func addRepo(named repoName: String, to workspace: Workspace) async {
    guard let git, let repo = library[repoName] else { return }
    let service = WorkspaceService(git: git, toolPaths: toolPaths)

    isBusy = true
    defer { isBusy = false }
    do {
      try await service.addRepo(
        repo,
        to: workspace.url,
        branch: workspace.file.branch,
        onUpdate: handler(forWorkspaceAt: workspace.url)
      )
      await rescan()
    } catch {
      errorMessage = error.localizedDescription
      await rescan()
    }
  }

  func rerunSetup(for member: WorkspaceMember, in workspace: Workspace) async {
    guard let git, let repo = library[member.repoName] else {
      errorMessage = "\(member.repoName) is not in the library, so Grove has no setup hook for it."
      return
    }
    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    isBusy = true
    defer { isBusy = false }
    await service.runSetup(
      for: repo,
      workspace: workspace.url,
      branch: member.branch ?? workspace.file.branch,
      onUpdate: handler(forWorkspaceAt: workspace.url)
    )
  }

  func rename(_ workspace: Workspace, to newName: String) async {
    guard let git else { return }
    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    isBusy = true
    defer { isBusy = false }
    do {
      let moved = try await service.rename(
        workspace: workspace,
        to: newName,
        root: library.workspaceRootURL,
        library: library
      )
      await rescan()
      selection = workspaces.first { $0.url.canonical == moved.canonical }?.url
    } catch {
      errorMessage = error.localizedDescription
      await rescan()
    }
  }

  func audit(_ workspace: Workspace) async -> [String: WorktreeRisk] {
    guard let git else { return [:] }
    return await WorkspaceService(git: git, toolPaths: toolPaths)
      .audit(workspace: workspace, library: library)
  }

  func removeRepo(
    _ member: WorkspaceMember, from workspace: Workspace, deleteBranch: Bool
  ) async {
    guard let git else { return }
    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    isBusy = true
    defer { isBusy = false }
    await service.removeRepo(
      member, from: workspace, library: library, deleteBranch: deleteBranch,
      onUpdate: handler(forWorkspaceAt: workspace.url))
    await rescan()
  }

  func teardown(_ workspace: Workspace, deleteBranches: Bool) async {
    guard let git else { return }
    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    isBusy = true
    defer { isBusy = false }
    do {
      try await service.teardown(
        workspace: workspace,
        library: library,
        root: library.workspaceRootURL,
        deleteBranches: deleteBranches,
        onUpdate: handler(forWorkspaceAt: workspace.url)
      )
      selection = nil
      await rescan()
    } catch {
      errorMessage = error.localizedDescription
      await rescan()
    }
  }

  // MARK: - Opening things

  func openInEditor(_ url: URL) {
    guard let editor = library.editor, !editor.isEmpty else {
      NSWorkspace.shared.activateFileViewerSelecting([url])
      return
    }
    Task {
      let shell = Shell(environment: toolPaths.processEnvironment())
      _ = try? await shell.run("/usr/bin/open", ["-a", editor, url.path])
    }
  }

  func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func openInTerminal(_ url: URL) {
    Task {
      let shell = Shell(environment: toolPaths.processEnvironment())
      _ = try? await shell.run("/usr/bin/open", ["-a", "Terminal", url.path])
    }
  }

  // MARK: - Helpers

  func activity(for member: WorkspaceMember, in workspace: Workspace) -> RepoActivity? {
    activity[Self.key(workspace.url, member.repoName)]
  }

  private func handler(forWorkspaceAt url: URL) -> @Sendable (ProvisionUpdate) -> Void {
    { update in
      Task { @MainActor [weak self] in
        self?.activity[Self.key(url, update.repo)] = RepoActivity(
          state: update.state,
          detail: update.detail ?? update.state.rawValue,
          log: update.log
        )
      }
    }
  }

  private static func key(_ workspace: URL, _ repo: String) -> String {
    "\(workspace.path)|\(repo)"
  }

  private func shortenHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}
