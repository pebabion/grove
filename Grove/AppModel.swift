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
  /// What the busy work is, for the footer to name.
  var busyLabel: String?
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

  /// A newer release than this build, once one is known.
  var availableUpdate: AvailableUpdate?
  var isDownloadingUpdate = false
  var updateStage: UpdateStage?

  /// Live shells, one per worktree. Held here so they survive navigating away.
  let terminals = TerminalSessions()

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
    // Turn an older "Zed" style name into the app it meant, so nobody has to
    // pick their editor a second time.
    let before = library
    library.migrateEditorName()
    if library != before { saveLibrary() }
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
    Task { await checkForUpdate() }
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

    let base = (try? await git.defaultBranch(repo: url)) ?? nil ?? "origin/main"
    library.repos.append(
      RepoEntry(
        name: name,
        path: shortenHome(url.path),
        base: base,
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

  func createWorkspace(name: String, branch: String, repoNames: Set<String>) async {
    guard let git else { return }
    let repos = library.repos.filter { repoNames.contains($0.name) }
    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    let root = library.workspaceRootURL

    let expected = root.appending(path: WorkspaceNaming.slug(name))

    // Put the workspace on screen and select it before any of the slow work
    // starts. Creating one runs a fetch, a worktree add and then a dependency
    // install per repo, which is minutes; waiting for all of that before the
    // rescan meant the only sign anything was happening was a greyed-out button,
    // and the per-repo progress had nowhere to appear because the workspace was
    // not selectable yet.
    let placeholder = Workspace(
      url: expected,
      file: WorkspaceFile(name: name, branch: branch, repos: repos.map(\.name)),
      members: repos.map {
        WorkspaceMember(
          repoName: $0.name,
          url: expected.appending(path: $0.name),
          branch: branch,
          state: .pending
        )
      }
    )
    workspaces.append(placeholder)
    sortWorkspaces()
    selection = expected

    isBusy = true
    busyLabel = "Creating \(WorkspaceNaming.slug(name))"
    defer {
      isBusy = false
      busyLabel = nil
    }

    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let created = try await service.create(
        name: name,
        branch: branch,
        // A workspace can carry a link in its grove.json, but nothing in the
        // interface collects one yet.
        link: nil,
        repos: repos,
        in: root,
        onUpdate: handler(forWorkspaceAt: expected)
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
      // Take the placeholder away again: nothing was created.
      workspaces.removeAll { $0.url == expected }
      await rescan()
    }
  }

  private func sortWorkspaces() {
    workspaces.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    // A shell sitting in a directory that is about to go would be left with a
    // deleted working directory, and whatever it launched still running.
    terminals.closeAll(under: member.url)
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
      terminals.closeAll(under: workspace.url)
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

  // MARK: - Updates

  /// This build's version, from the bundle.
  var currentVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  }

  func checkForUpdate() async {
    availableUpdate = await UpdateChecker().check(against: currentVersion)
  }

  /// What the update is doing, for the pill to say.
  enum UpdateStage: String, Sendable {
    case downloading = "Downloading"
    case verifying = "Verifying"
    case installing = "Installing"
    case restarting = "Restarting"
  }

  /// Downloads the release, checks it, swaps this app for it and relaunches.
  ///
  /// Nothing installed is touched until the replacement is in hand: the download
  /// is checked against the published digest, the new bundle is copied out of the
  /// image and its signature verified, and only then is the swap handed to a
  /// script that waits for this process to exit. If that move fails the script
  /// puts the working copy back.
  func installUpdate() async {
    guard let update = availableUpdate, !isDownloadingUpdate else { return }
    guard let downloadURL = update.downloadURL else {
      NSWorkspace.shared.open(update.pageURL)
      return
    }

    isDownloadingUpdate = true
    updateStage = .downloading
    defer {
      isDownloadingUpdate = false
      updateStage = nil
    }

    let updater = Updater(environment: toolPaths.processEnvironment())
    do {
      let (temporary, _) = try await URLSession.shared.download(from: downloadURL)
      let image = FileManager.default.temporaryDirectory
        .appending(path: downloadURL.lastPathComponent)
      try? FileManager.default.removeItem(at: image)
      try FileManager.default.moveItem(at: temporary, to: image)

      updateStage = .verifying
      if let checksumsURL = update.checksumsURL,
        let list = try? await fetchText(checksumsURL),
        let expected = Updater.expectedChecksum(for: image.lastPathComponent, in: list)
      {
        try await updater.verify(image, matches: expected)
      }

      updateStage = .installing
      let staged = try await updater.stageApplication(fromImageAt: image)
      let script = try updater.writeSwapScript(
        staged: staged,
        target: Bundle.main.bundleURL,
        processIdentifier: ProcessInfo.processInfo.processIdentifier
      )

      updateStage = .restarting
      try updater.launchDetached(script)
      try? FileManager.default.removeItem(at: image)
      // The script cannot move the bundle until this process is gone, so
      // quitting is the final step of the install rather than a side effect.
      NSApp.terminate(nil)
    } catch {
      errorMessage =
        "\(error.localizedDescription)\n\nThe installed copy has not been touched."
      NSWorkspace.shared.open(update.pageURL)
    }
  }

  private func fetchText(_ url: URL) async throws -> String {
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    let (data, _) = try await URLSession.shared.data(for: request)
    return String(decoding: data, as: UTF8.self)
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
      var sweeps = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.sweepInterval)
        guard !Task.isCancelled, let self else { return }
        await self.measureStale()
        // Every twelfth sweep is roughly six hours. Releases are not frequent
        // enough to justify asking more often than that.
        sweeps += 1
        if sweeps % 12 == 0 { await self.checkForUpdate() }
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

  /// Name of the app the Open action will use, or nil when it reveals in Finder.
  var editorName: String? {
    library.editorPath.flatMap(Self.applicationName)
  }

  var terminalName: String {
    library.terminalPath.flatMap(Self.applicationName) ?? "Terminal"
  }

  static func applicationName(_ path: String) -> String? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
  }

  func openInEditor(_ url: URL) {
    guard let path = library.editorPath, FileManager.default.fileExists(atPath: path) else {
      // No editor chosen, or the chosen one has been moved or deleted.
      NSWorkspace.shared.activateFileViewerSelecting([url])
      return
    }
    open(url, withApplicationAt: URL(filePath: path))
  }

  func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func openInTerminal(_ url: URL) {
    let path = library.terminalPath ?? "/System/Applications/Utilities/Terminal.app"
    guard FileManager.default.fileExists(atPath: path) else {
      NSWorkspace.shared.activateFileViewerSelecting([url])
      return
    }
    open(url, withApplicationAt: URL(filePath: path))
  }

  /// Hands `url` to a specific application, reporting a refusal rather than
  /// swallowing it the way `open -a` did.
  private func open(_ url: URL, withApplicationAt application: URL) {
    NSWorkspace.shared.open(
      [url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()
    ) { [weak self] _, error in
      guard let error else { return }
      Task { @MainActor in
        self?.errorMessage =
          "Could not open \(url.lastPathComponent) with "
          + "\(application.deletingPathExtension().lastPathComponent): "
          + error.localizedDescription
      }
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
