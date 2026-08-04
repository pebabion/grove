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

  /// Cached workspace sizes, and how many are still being measured.
  var sizes = SizeCache()
  var pendingMeasurements = 0

  /// Cached pull request answers, and whether a refresh is in flight.
  var pullRequests = PullRequestCache()
  var isLoadingPullRequests = false

  private let store = JSONStore()
  private var sweepTask: Task<Void, Never>?

  var git: Git? {
    guard let executable = toolPaths.location(of: "git") else { return nil }
    return Git(executable: executable, environment: toolPaths.processEnvironment())
  }

  var selectedWorkspace: Workspace? {
    workspaces.first { $0.url == selection }
  }

  /// Scanning with nothing on screen yet, which is the case worth a spinner.
  /// A rescan with workspaces already listed shows progress in the footer
  /// instead, so the list does not flash empty.
  var isFirstScan: Bool { isScanning && workspaces.isEmpty }

  // MARK: - Lifecycle

  func load() async {
    toolPaths = await ToolPaths.discover()
    library = (try? store.load(RepoLibrary.self, from: GroveLocations.libraryFile)) ?? RepoLibrary()
    // Cached sizes only. Measuring walks every file and takes tens of seconds,
    // so it never happens without being asked for.
    sizes = (try? store.load(SizeCache.self, from: SizeCache.fileURL)) ?? SizeCache()
    pullRequests =
      (try? store.load(PullRequestCache.self, from: PullRequestCache.fileURL))
      ?? PullRequestCache()
    await rescan()

    // Behind the interface, not in front of it: the window is usable while this
    // runs, and it is the reason sizes appear without being asked for.
    Task { await measureStale() }
    Task { await refreshPullRequests() }
    startBackgroundMeasurement()
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
      // Setup just wrote a few gigabytes of dependencies; measure while the
      // figure is worth having.
      if let workspace = workspaces.first(where: { $0.url == created }) {
        Task { await measure([workspace]) }
      }
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
      if let updated = workspaces.first(where: { $0.url == workspace.url }) {
        Task { await measure([updated]) }
      }
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
    Task { await measure([workspace]) }
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
      // Update the list before rescanning. A rescan runs git in every remaining
      // worktree and takes seconds; waiting for it would leave the deleted row
      // on screen and the detail pane empty for all of that time.
      let neighbour = SelectionAfterRemoval.next(
        after: workspace.url, in: workspaces.map(\.url))
      workspaces.removeAll { $0.url == workspace.url }
      selection = neighbour

      // Drop the deleted workspace's reading so it stops counting in the total.
      sizes.prune(keeping: workspaces.map(\.url))
      try? store.save(sizes, to: SizeCache.fileURL)

      await rescan()
    } catch {
      errorMessage = error.localizedDescription
      await rescan()
    }
  }

  // MARK: - Pull requests

  func pullRequest(for member: WorkspaceMember) -> PullRequestReading? {
    guard let branch = member.branch else { return nil }
    return pullRequests[member.repoName, branch]
  }

  /// Looks up any branch whose answer is missing or stale.
  ///
  /// Pass `force` to ignore freshness, for the explicit refresh action.
  func refreshPullRequests(force: Bool = false) async {
    guard let executable = toolPaths.location(of: "gh"), !isLoadingPullRequests else { return }

    let now = Date()
    var wanted: [(repo: String, branch: String, worktree: URL)] = []
    var seen = Set<String>()
    for workspace in workspaces {
      for member in workspace.members {
        guard let branch = member.branch else { continue }
        let key = PullRequestCache.key(repo: member.repoName, branch: branch)
        guard seen.insert(key).inserted else { continue }
        if !force, let reading = pullRequests[member.repoName, branch], reading.isFresh(asOf: now) {
          continue
        }
        wanted.append((member.repoName, branch, member.url))
      }
    }
    guard !wanted.isEmpty else { return }

    isLoadingPullRequests = true
    defer { isLoadingPullRequests = false }

    let github = GitHub(executable: executable, environment: toolPaths.processEnvironment())
    var remaining = wanted[...]

    await withTaskGroup(of: (String, String, PullRequestLookup).self) { group in
      func start(_ item: (repo: String, branch: String, worktree: URL)) {
        group.addTask {
          (item.repo, item.branch, await github.pullRequest(for: item.branch, in: item.worktree))
        }
      }
      for _ in 0..<min(GitHub.concurrencyLimit, wanted.count) {
        guard let next = remaining.popFirst() else { break }
        start(next)
      }
      while let (repo, branch, lookup) = await group.next() {
        switch lookup {
        case .found(let pr):
          pullRequests[repo, branch] = PullRequestReading(pullRequest: pr, fetchedAt: Date())
        case .none:
          pullRequests[repo, branch] = PullRequestReading(pullRequest: nil, fetchedAt: Date())
        case .unknown:
          // Leave any previous answer alone rather than recording a failure.
          break
        }
        if let next = remaining.popFirst() { start(next) }
      }
    }

    try? store.save(pullRequests, to: PullRequestCache.fileURL)
  }

  // MARK: - Disk usage

  var isMeasuring: Bool { pendingMeasurements > 0 }

  /// How old a reading may get before a background sweep replaces it.
  ///
  /// A workspace only changes size when dependencies are installed or a build
  /// runs, so a day-old figure is still useful. Grove also remeasures a
  /// workspace right after its setup finishes, which is when the number actually
  /// moves.
  static let sizeMaxAge: TimeInterval = 24 * 60 * 60

  /// Gap between background sweeps.
  static let sweepInterval: Duration = .seconds(1800)

  /// Measures workspaces with no reading, or one older than ``sizeMaxAge``.
  ///
  /// The first sweep on a new machine costs a full walk — 42 seconds for
  /// fourteen workspaces on real hardware — but it runs behind the interface and
  /// every sweep after it only touches what has gone stale, which is usually
  /// nothing. It stands down while a setup or teardown is running rather than
  /// competing with it for the disk.
  func measureStale() async {
    guard !isMeasuring, !isBusy else { return }
    let now = Date()
    let stale = workspaces.filter { workspace in
      guard let reading = sizes[workspace.url] else { return true }
      return now.timeIntervalSince(reading.measuredAt) > Self.sizeMaxAge
    }
    await measure(stale)
  }

  /// Sweeps periodically for the life of the window.
  func startBackgroundMeasurement() {
    sweepTask?.cancel()
    sweepTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.sweepInterval)
        guard !Task.isCancelled, let self else { return }
        await self.measureStale()
      }
    }
  }

  /// Total of every size Grove currently knows, and whether that covers
  /// everything on screen.
  var knownTotal: (bytes: Int64, complete: Bool) {
    let readings = workspaces.compactMap { sizes[$0.url]?.bytes }
    return (readings.reduce(0, +), readings.count == workspaces.count)
  }

  /// Measures the given workspaces, filling sizes in as each finishes.
  func measure(_ targets: [Workspace]) async {
    guard !targets.isEmpty else { return }
    let urls = targets.map(\.url)
    pendingMeasurements += urls.count

    await DiskUsage(environment: toolPaths.processEnvironment())
      .measureAll(urls) { url, reading in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if let reading { sizes[url] = reading }
          pendingMeasurements = max(0, pendingMeasurements - 1)
        }
      }

    sizes.prune(keeping: workspaces.map(\.url))
    try? store.save(sizes, to: SizeCache.fileURL)
  }

  func measureAll() async {
    await measure(workspaces)
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
