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
  /// What the busy work is, for the footer to name, and how far through it is when that
  /// can be known. A bar that cannot say how far along it is has nothing to draw.
  var busyLabel: String?
  var busyFraction: Double?
  var errorMessage: String?

  /// False when the library file exists but could not be decoded.
  private(set) var libraryIsReadable = true

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
  /// A version the user waved away. Kept so a five-minute check does not bring it
  /// straight back.
  private var dismissedVersion: SemanticVersion?
  var isDownloadingUpdate = false

  /// Why registering the Claude Code relay failed, for Settings to show.
  var hookError: String?
  var updateStage: UpdateStage?

  /// Live shells, one per worktree. Held here so they survive navigating away.
  let terminals = TerminalSessions()

  /// Which workspaces have their terminal pane open, and which session each is
  /// showing.
  ///
  /// Kept here rather than as view state: SwiftUI discards a detail view's state
  /// when the selection changes, so an open terminal appeared to vanish on coming
  /// back to a workspace even though its shell was still running.
  var terminalWorkspaces: Set<URL> = []
  var activeSessions: [URL: UUID] = [:]

  /// Which workspaces are showing their files instead of their repo list. Kept here
  /// for the same reason as the terminal: leaving a workspace and coming back should
  /// not undo what you were reading.
  var fileWorkspaces: Set<URL> = []

  /// Workspaces being created right now.
  ///
  /// They are in the list before they exist on disk, so that progress has somewhere to
  /// show. Until the work finishes there is nothing to open a terminal on: the folder may
  /// not be there, the worktrees are arriving one at a time, and setup is still running.
  private(set) var creatingWorkspaces: Set<URL> = []

  func isCreating(_ workspace: Workspace) -> Bool {
    creatingWorkspaces.contains(workspace.url)
  }

  /// Workspaces being taken apart, for the same reason: the pane has to know it is
  /// watching a removal rather than showing a workspace that still exists.
  private(set) var removingWorkspaces: Set<URL> = []

  func isRemoving(_ workspace: Workspace) -> Bool {
    removingWorkspaces.contains(workspace.url)
  }

  /// How tall the terminal pane is when it shares the window with the repo list.
  /// Dragged by the divider between them, and kept for the same reason the rest of
  /// this is: switching workspaces should not reset it.
  var terminalHeight: CGFloat = 320

  /// Whether the repo list is collapsed. One setting for the window, not per
  /// workspace — it is a preference about the layout, not about a workspace.
  var detailsCollapsed = false

  /// What ⌘ + P will do next, for the menu item to say.
  var fileCommandTitle: String {
    guard let workspace = selectedWorkspace, fileWorkspaces.contains(workspace.url) else {
      return "Show Files"
    }
    return "Hide Files"
  }

  /// What ⌘ + J will do next, for the menu item to say.
  var terminalCommandTitle: String {
    guard let workspace = selectedWorkspace,
      terminalWorkspaces.contains(workspace.url)
    else { return "Show Terminal" }
    return terminals.sessions(in: workspace.url).isEmpty ? "Start Session" : "Hide Terminal"
  }

  /// The session a workspace is showing, if it still exists.
  func activeSession(in workspace: Workspace) -> TerminalSession? {
    guard let id = activeSessions[workspace.url] else { return nil }
    return terminals.session(id: id)
  }

  func selectSession(_ session: TerminalSession) {
    activeSessions[session.workspace] = session.id
    session.needsAttention = false
    session.focus()
  }

  /// Every file the workspace's repos hold, for the file viewer to search.
  ///
  /// Asked of git per repo rather than walked: one call each, and it already leaves out
  /// everything `.gitignore` covers.
  func workspaceFiles(in workspace: Workspace) async -> [FileMatch] {
    guard let git else { return [] }
    var found: [FileMatch] = []
    for member in workspace.members where member.state != .pending {
      guard let paths = try? await git.listFiles(worktree: member.url) else { continue }
      found += paths.map { FileMatch(path: $0, repo: member.repoName) }
    }
    return found
  }

  /// Brings a session on screen from wherever the user is: selects its workspace,
  /// opens the terminal pane and focuses it. Used by a clicked notification, where
  /// the whole point is to land on the session rather than near it.
  func reveal(sessionID: UUID) {
    guard let session = terminals.session(id: sessionID) else { return }
    selection = session.workspace
    terminalWorkspaces.insert(session.workspace)
    selectSession(session)
  }

  /// Reports what Claude Code said, against the session it came from.
  private func handle(_ event: HookEvent) {
    guard let session = session(workingIn: event.directory) else {
      // Claude Code run somewhere Grove does not manage. Not Grove's business.
      Log.hooks.note("no session under \(event.directory.path)")
      return
    }

    hookReporting.insert(session.directory)
    let signal: SessionSignal = event.reason == .needsInput ? .needsInput : .finished
    notify(signal, from: session, saying: event.message)
  }

  /// The session an agent is working in: the one started there, or failing that the
  /// one whose worktree contains it, since an agent can change directory.
  private func session(workingIn directory: URL) -> TerminalSession? {
    let path = directory.canonical.path
    let live = terminals.sessions
    if let exact = live.first(where: { $0.directory.canonical.path == path }) { return exact }
    return
      live
      .filter { path.hasPrefix($0.directory.canonical.path + "/") }
      .max { $0.directory.path.count < $1.directory.path.count }
  }

  /// Notifies unless the user is already looking at the session.
  ///
  /// A notification for the window in front of you is noise, and the sidebar dot
  /// covers the case where they are in Grove but looking elsewhere.
  private func handle(_ signal: SessionSignal, from session: TerminalSession) {
    if hookReporting.contains(session.directory) {
      // Claude Code is reporting this one properly; the progress report only repeats
      // it, less precisely.
      session.needsAttention = true
      return
    }
    notify(signal, from: session, saying: nil)
  }

  private func notify(_ signal: SessionSignal, from session: TerminalSession, saying: String?) {
    guard notificationsEnabled else {
      Log.sessions.note("notifications are switched off")
      return
    }
    session.needsAttention = true
    guard !isWatching(session) else {
      Log.sessions.note("already watching \(session.displayName)")
      return
    }

    Log.sessions.note("notifying for \(session.displayName)")
    let workspace = session.workspace.lastPathComponent
    let name = session.displayName
    let id = session.id
    notifier.post(signal, session: name, workspace: workspace, id: id, saying: saying)
  }

  /// Whether Grove notifies at all. One switch, because the parts underneath it are
  /// not a decision anyone wants to make.
  ///
  /// Off until asked for: turning it on edits Claude Code's settings, and nothing
  /// should do that to a machine on the strength of a default.
  var notificationsEnabled: Bool { library.notifySessionEvents ?? false }

  /// Turns notifications on or off, including everything they need to work.
  ///
  /// The Claude Code relay goes in and comes out with the switch. On its own the
  /// terminal hears nothing from Claude Code — it reports progress only to terminals
  /// it recognises by name, and Grove is not one — so a notifications setting that
  /// left the relay to the user would be a setting that does nothing.
  func setNotifications(_ enabled: Bool) {
    hookError = nil
    library.notifySessionEvents = enabled
    saveLibrary()

    do {
      if enabled {
        try hookRelay.install()
        hookRelay.start()
      } else {
        hookRelay.stop()
        try hookRelay.uninstall()
        hookReporting.removeAll()
      }
    } catch {
      Log.hooks.problem(
        "could not \(enabled ? "install" : "remove") the relay: \(error.localizedDescription)")
      // Notifications stay on: the terminal's own signals still work for tools that
      // send them, and saying so is better than silently turning the switch back.
      hookError = error.localizedDescription
    }
  }

  /// Whether this session is the one on screen, in the front window.
  private func isWatching(_ session: TerminalSession) -> Bool {
    NSApp.isActive
      && selection == session.workspace
      && terminalWorkspaces.contains(session.workspace)
      && activeSessions[session.workspace] == session.id
  }

  /// Starts a session in `directory` and brings it to the front.
  ///
  /// Refused while the workspace is being created: the folder may not exist yet, the
  /// worktrees arrive one at a time and setup is still running, so a shell opened then is
  /// in a place that is still changing under it.
  @discardableResult
  func startSession(in workspace: Workspace, at directory: URL) -> TerminalSession? {
    guard !isCreating(workspace) else {
      Log.sessions.note("not starting a session: \(workspace.name) is still being created")
      return nil
    }
    return startSessionNow(in: workspace, at: directory)
  }

  @discardableResult
  private func startSessionNow(in workspace: Workspace, at directory: URL) -> TerminalSession? {
    let session = terminals.start(
      in: workspace.url,
      directory: directory,
      fallbackName: directory == workspace.url ? "workspace" : directory.lastPathComponent,
      environment: toolPaths.processEnvironment(),
      font: terminalFont,
      foreground: terminalForeground,
      mouseReporting: library.terminalMouseReporting ?? false
    )
    if let session { selectSession(session) }
    return session
  }

  /// Moves the selection through the sidebar, wrapping at the ends.
  ///
  /// With a dozen workspaces, reaching for the mouse to change which one you are looking
  /// at is the most frequent thing there is no key for.
  func selectWorkspace(offset: Int) {
    guard !workspaces.isEmpty else { return }
    guard let current = workspaces.firstIndex(where: { $0.url == selection }) else {
      selection = workspaces.first?.url
      return
    }
    let next = (current + offset + workspaces.count) % workspaces.count
    selection = workspaces[next].url
  }

  /// Opens the confirmation for removing the selected workspace.
  ///
  /// The shortcut opens the sheet rather than doing it: this is the one action that
  /// destroys work, and it already has an audit to show first.
  func askToRemoveSelectedWorkspace() {
    guard let workspace = selectedWorkspace else { return }
    teardownTarget = .whole(workspace)
  }

  /// Shows or hides the file browser for the selected workspace.
  func toggleFiles() {
    guard let workspace = selectedWorkspace else { return }
    if fileWorkspaces.contains(workspace.url) {
      fileWorkspaces.remove(workspace.url)
    } else {
      fileWorkspaces.insert(workspace.url)
    }
  }

  /// What ⌘ + W will do next, for the menu item to say.
  var closeCommandTitle: String { closableSession == nil ? "Close Window" : "Close Session" }

  /// The session ⌘ + W would end: the one on screen, when nothing is covering it.
  private var closableSession: TerminalSession? {
    guard renameTarget == nil, teardownTarget == nil else { return nil }
    guard let workspace = selectedWorkspace, terminalWorkspaces.contains(workspace.url) else {
      return nil
    }
    return activeSession(in: workspace)
  }

  /// Ends the session on screen, or closes the window when there is none.
  ///
  /// One command rather than two, because two menu items cannot share ⌘ + W: the first
  /// one found takes the key whether it is enabled or not, and a disabled one swallows it
  /// and does nothing. Measured, after nearly shipping a version where ⌘ + W stopped
  /// closing the window.
  func closeSessionOrWindow() {
    guard let session = closableSession else {
      NSApp.keyWindow?.performClose(nil)
      return
    }
    terminals.close(id: session.id)
  }

  /// Starts another session, beside the one already running.
  ///
  /// In the directory the current session is in rather than the workspace root, which is
  /// what a second tab is usually for: the same place, a second thing running. Opens the
  /// terminal first if it is closed, since a session nobody can see is not much use.
  func newSession() {
    guard let workspace = selectedWorkspace else { return }
    guard !isCreating(workspace) else { return }
    terminalWorkspaces.insert(workspace.url)
    let directory = activeSession(in: workspace)?.directory ?? workspace.url
    startSession(in: workspace, at: directory)
  }

  /// Shows the terminal, starts a session, or hides it — whichever comes next.
  ///
  /// On the model rather than the view so the menu can drive it whatever has focus,
  /// including the terminal itself.
  func toggleTerminal() {
    guard let workspace = selectedWorkspace else { return }
    // Nothing to open while it is being made, and a pane that opens and shuts is worse
    // than a shortcut that waits its turn.
    guard !isCreating(workspace) else { return }

    guard terminalWorkspaces.contains(workspace.url) else {
      terminalWorkspaces.insert(workspace.url)
      return
    }
    if terminals.sessions(in: workspace.url).isEmpty {
      startSession(in: workspace, at: workspace.url)
    } else {
      terminalWorkspaces.remove(workspace.url)
    }
  }

  /// Restyles the shells already running, after a change in Settings.
  func applyTerminalFont() {
    terminals.applyFont(terminalFont)
  }

  func applyTerminalForeground() {
    terminals.applyForeground(terminalForeground)
  }

  func applyTerminalMouseReporting() {
    terminals.applyMouseReporting(library.terminalMouseReporting ?? false)
  }

  /// The colour embedded terminals draw default text in.
  var terminalForeground: NSColor {
    TerminalPalette.color(library.terminalForeground)
  }

  /// The font embedded terminals render with.
  var terminalFont: NSFont {
    TerminalFont.font(library.terminalFont, size: library.terminalFontSize)
  }

  private let notifier = SessionNotifier()
  private let disk = DiskWatcher()
  /// When the list last caught up, so a change Grove made itself does not bounce back as
  /// a change to react to.
  private var lastScan = Date.distantPast
  let hookRelay = HookRelay()

  /// Directories that have delivered a hook event.
  ///
  /// Once Claude Code is reporting for a directory, its progress reports are left to
  /// drive the sidebar only. Both signals describe the same moment, and the hook
  /// describes it better, so notifying from both would mean two notifications for one
  /// event.
  private var hookReporting: Set<URL> = []
  private let store = JSONStore()
  private var sweepTask: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var updateTask: Task<Void, Never>?

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
    terminals.onSignal = { [weak self] session, signal in
      self?.handle(signal, from: session)
    }
    notifier.onOpen = { [weak self] id in self?.reveal(sessionID: id) }
    hookRelay.onEvent = { [weak self] event in self?.handle(event) }
    disk.onChange = { [weak self] in self?.rescanFromDisk() }

    toolPaths = await ToolPaths.discover()
    loadLibrary()
    // After loadLibrary, not before: the setting being read lives in the library, and
    // reading it first gets the default rather than the answer.
    if notificationsEnabled {
      // Put the relay back if it has gone -- an update replaces the app, and someone
      // may have tidied Claude Code's settings by hand since.
      if !hookRelay.isInstalled { try? hookRelay.install() }
      hookRelay.start()
    }
    // Turn an older "Zed" style name into the app it meant, so nobody has to
    // pick their editor a second time.
    let before = library
    library.migrateEditorName()
    if library != before { saveLibrary() }
    // Cached sizes only. Measuring walks every file and takes tens of seconds,
    // so it never happens without being asked for.
    applyToolOverrides()
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
    startUpdateChecks()
  }

  /// Rescans because something on disk changed, unless something is already happening.
  ///
  /// Skipped while creating or removing: those write to the very directories being
  /// watched, and they rescan themselves when they are done.
  private func rescanFromDisk() {
    guard !isBusy, !isScanning else { return }
    guard Date().timeIntervalSince(lastScan) > 2 else { return }
    Log.disk.note("something changed, rescanning")
    Task { await rescan() }
  }

  /// Watches the places that change when the list should change.
  ///
  /// The root, where workspaces come and go, and each worktree's git directory, where a
  /// branch switch or a commit lands. Not the worktrees themselves: an agent writing
  /// files would have this rescanning continuously.
  private func watchDisk() {
    var directories = [library.workspaceRootURL]
    for workspace in workspaces {
      for member in workspace.members where member.state != .pending {
        if let gitDirectory = Git.gitDirectory(of: member.url) {
          directories.append(gitDirectory)
        }
      }
    }
    Log.disk.note("watching \(directories.count) directories")
    disk.watch(directories)
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
    lastScan = Date()
    // The set of things worth watching changes with the set of workspaces.
    watchDisk()
    // A workspace that has just appeared should not wait for the next half-hourly sweep
    // to say how big it is. Only the ones with no reading are walked.
    Task { await measureStale() }

    // A branch can add or drop a skill without Grove doing anything, and a rescan is
    // where Grove makes itself match the disk.
    let service = WorkspaceService(git: git, toolPaths: toolPaths)
    for workspace in workspaces { service.linkSkills(in: workspace.url) }

    // Forced, because a rescan is something the user asked for. Cached answers keep
    // an open pull request looking open for fifteen minutes after it was merged, and
    // waiting out a cache is not what pressing Rescan means. Nothing refreshed pull
    // requests here at all before, so a merged one stayed open until the next launch.
    await refreshPullRequests(force: true)
  }

  /// Reads the library, keeping a failure to read distinct from an empty library.
  ///
  /// These were the same thing before, which is how a decoding bug showed up as
  /// "no repos yet" — and would have written that emptiness back over a perfectly
  /// good file the next time anything saved.
  private func loadLibrary() {
    do {
      library = try store.load(RepoLibrary.self, from: GroveLocations.libraryFile) ?? RepoLibrary()
      libraryIsReadable = true
    } catch {
      library = RepoLibrary()
      libraryIsReadable = false
      errorMessage =
        "Could not read \(GroveLocations.libraryFile.path):\n\(error.localizedDescription)"
        + "\n\nGrove will not overwrite it. Your repos and workspaces are untouched."
    }
  }

  func saveLibrary() {
    // Refuse rather than replace a file that could not be read. Whatever is in the
    // model right now is a default, not the user's settings.
    guard libraryIsReadable else { return }
    saveTask?.cancel()
    saveTask = nil
    do {
      try store.save(library, to: GroveLocations.libraryFile)
    } catch {
      errorMessage = "Could not save the library: \(error.localizedDescription)"
    }
  }

  /// Saves once the typing stops.
  ///
  /// Settings bound its fields straight to `saveLibrary`, which rewrote the whole
  /// library file on every keystroke in a shell command.
  func saveLibrarySoon() {
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      self?.saveLibrary()
    }
  }

  /// Re-reads a repo's default branch from its remote.
  func redetectBase(for name: String) async {
    guard let git, let repo = library[name] else { return }
    guard let detected = (try? await git.defaultBranch(repo: repo.url)) ?? nil else {
      errorMessage = "Could not read origin/HEAD for \(name). Is the remote reachable?"
      return
    }
    // By name again on the way back: the library can change while the network is
    // answering, and an index resolved beforehand would by then mean a different repo
    // or none at all.
    library.update(name) { $0.base = detected }
    saveLibrary()
  }

  /// Applies the stored tool overrides on top of whatever discovery found.
  func applyToolOverrides() {
    toolPaths.overrides = library.toolOverrides
  }

  /// Asks the login shell again where the tools are.
  func reloadToolPaths() async {
    toolPaths = await ToolPaths.discover()
    applyToolOverrides()
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

    // The same form the scanner will report, so everything keyed on it still matches
    // once the rescan replaces the placeholder. See URL.identity.
    let expected = root.appending(path: WorkspaceNaming.slug(name)).identity

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
    creatingWorkspaces.insert(expected)

    isBusy = true
    busyLabel = "Creating \(WorkspaceNaming.slug(name))"
    defer {
      isBusy = false
      busyLabel = nil
      busyFraction = nil
      creatingWorkspaces.remove(expected)
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
      // The folder is about to move. A shell inside it would be left with a
      // working directory that no longer exists.
      terminals.closeAll(under: workspace.url)
      terminalWorkspaces.remove(workspace.url)
      activeSessions.removeValue(forKey: workspace.url)

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
    removingWorkspaces.insert(workspace.url)
    busyLabel = "Removing \(workspace.name)"
    busyFraction = 0
    defer {
      isBusy = false
      busyLabel = nil
      busyFraction = nil
      removingWorkspaces.remove(workspace.url)
    }
    do {
      terminals.closeAll(under: workspace.url)
      terminalWorkspaces.remove(workspace.url)
      activeSessions.removeValue(forKey: workspace.url)
      try await service.teardown(
        workspace: workspace,
        library: library,
        root: library.workspaceRootURL,
        deleteBranches: deleteBranches,
        onUpdate: handler(forWorkspaceAt: workspace.url),
        onPhase: { outline in
          Task { @MainActor [weak self] in
            self?.busyLabel = outline.label
            self?.busyFraction = outline.fraction
          }
        }
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

  /// How often to ask GitHub. Twelve requests an hour against an unauthenticated
  /// limit of sixty, so there is room to spare.
  static let updateCheckInterval: Duration = .seconds(300)

  /// Asks on its own timer rather than riding along with the disk sweep, which tied
  /// the two intervals together for no reason.
  func startUpdateChecks() {
    updateTask?.cancel()
    updateTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.updateCheckInterval)
        guard !Task.isCancelled, let self else { return }
        await self.checkForUpdate()
      }
    }
  }

  /// True while an asked-for check is in flight, so a button can say so.
  var isCheckingForUpdate = false
  /// When a check last finished. Nil means Grove has not managed to ask yet, which is
  /// worth saying rather than implying everything is current.
  var lastUpdateCheck: Date?

  @discardableResult
  func checkForUpdate() async -> AvailableUpdate? {
    guard let found = await UpdateChecker().check(against: currentVersion) else {
      // A nil answer covers both "already current" and "could not ask", so it must
      // not clear a pill already on screen — checking every five minutes would
      // otherwise make one network blip look like the update going away.
      lastUpdateCheck = Date()
      return nil
    }
    lastUpdateCheck = Date()
    guard found.version != dismissedVersion else { return found }
    availableUpdate = found
    return found
  }

  /// Checks because someone asked, which means saying what came back.
  ///
  /// Also brings back a version waved away earlier: asking for a check is asking about
  /// every version, including the one dismissed last week.
  func checkForUpdateNow() async {
    isCheckingForUpdate = true
    defer { isCheckingForUpdate = false }
    dismissedVersion = nil
    await checkForUpdate()
  }

  /// Dismissing hides one particular version, not the pill for five minutes.
  func dismissUpdate() {
    dismissedVersion = availableUpdate?.version
    availableUpdate = nil
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
      let (temporary, _) = try await download(downloadURL)
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
      // Which step failed, because "could not connect to the server" says nothing about
      // whether the download, the checksum or the swap was in progress.
      let step = (updateStage ?? .downloading).rawValue.lowercased()
      errorMessage =
        "\(step.capitalized) \(update.version.description) failed: "
        + "\(error.localizedDescription)\n\nThe installed copy has not been touched. "
        + "The download page is open if you would rather do it by hand."
      NSWorkspace.shared.open(update.pageURL)
    }
  }

  /// Downloads, trying twice.
  ///
  /// A release is published a moment before its file finishes uploading, so an update
  /// asked for in that window fails to connect to something that is about to exist. One
  /// retry after a pause covers that, and covers a connection dropped in passing.
  private func download(_ url: URL) async throws -> (URL, URLResponse) {
    do {
      return try await URLSession.shared.download(from: url)
    } catch let error as URLError where Self.worthRetrying.contains(error.code) {
      Log.sessions.problem("download failed (\(error.code.rawValue)), trying once more")
      try await Task.sleep(for: .seconds(2))
      return try await URLSession.shared.download(from: url)
    }
  }

  /// Failures that are worth a second attempt rather than a dialog. A refusal by the
  /// server, or a file that is not there, would only fail again.
  private static let worthRetrying: Set<URLError.Code> = [
    .cannotConnectToHost, .networkConnectionLost, .timedOut, .cannotFindHost,
    .dnsLookupFailed, .resourceUnavailable,
  ]

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
  /// Opens a file with a chosen application.
  ///
  /// The awaiting form, not the completion handler. LaunchServices calls a completion
  /// handler on its own queue, and a closure written inside a main-actor method is
  /// itself main-actor isolated, so Swift checks the executor as the closure is
  /// entered and traps when it is not the main one. Hopping inside the closure does
  /// not help: the check happens first. This crashed the app when opening an editor.
  private func open(_ url: URL, withApplicationAt application: URL) {
    Task { [weak self] in
      do {
        _ = try await NSWorkspace.shared.open(
          [url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
      } catch {
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
