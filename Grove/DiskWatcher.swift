import Foundation

/// Watches directories and says when any of them changed.
///
/// Directories rather than files, deliberately. Git writes `HEAD` by writing a new file
/// and renaming it over the old one, so a watch on the file itself is left holding an
/// inode nobody will touch again. A watch on the directory sees the rename.
///
/// What is watched is chosen to be quiet: the workspace root, which changes when a
/// workspace appears or goes, and each worktree's git directory, which changes when a
/// branch is switched or a commit is made. Watching the worktrees themselves would fire
/// on every file an agent writes, which is constantly.
@MainActor
final class DiskWatcher {
  /// Called after things settle, never more than once per burst.
  var onChange: (@MainActor () -> Void)?

  private var sources: [DispatchSourceFileSystemObject] = []
  private var settling: Task<Void, Never>?

  /// Long enough for a git command to finish what it is doing, short enough that the
  /// list catches up before anyone reaches for a refresh.
  private static let settleFor = Duration.milliseconds(700)

  func watch(_ directories: [URL]) {
    stop()
    for directory in directories {
      let descriptor = open(directory.path, O_EVTONLY)
      guard descriptor >= 0 else { continue }

      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor,
        eventMask: [.write, .rename, .delete],
        queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.settle() }
      }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      sources.append(source)
    }
  }

  func stop() {
    settling?.cancel()
    settling = nil
    for source in sources { source.cancel() }
    sources.removeAll()
  }

  /// Collapses a burst of changes into one call.
  ///
  /// A single `git checkout` writes many times; rescanning on each would mean several
  /// scans of the whole root for one action.
  private func settle() {
    settling?.cancel()
    settling = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.settleFor)
      guard !Task.isCancelled else { return }
      self?.onChange?()
    }
  }
}
