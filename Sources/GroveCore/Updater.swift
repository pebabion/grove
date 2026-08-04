import Foundation

/// Installs a downloaded release over the running app.
///
/// The swap itself cannot happen inside the process being replaced — the last
/// step is relaunching, and a process cannot outlive itself to do that. So the
/// work is handed to a small shell script that waits for this process to exit,
/// moves the new bundle into place, and reopens it. The script keeps the old
/// bundle until the new one is in place, and puts it back if the move fails.
public struct Updater: Sendable {
  public enum Failure: Error, LocalizedError, Sendable {
    case checksumMismatch(expected: String, actual: String)
    case noAppInImage
    case bundleNotWritable(String)
    case mountFailed(String)
    case signatureInvalid(String)

    public var errorDescription: String? {
      switch self {
      case .checksumMismatch(let expected, let actual):
        "The download does not match its published checksum.\nexpected \(expected)\ngot      \(actual)"
      case .noAppInImage:
        "The disk image contains no application"
      case .bundleNotWritable(let path):
        "Cannot write to \(path). Move Grove to your Applications folder and try again."
      case .mountFailed(let detail):
        "Could not open the disk image: \(detail)"
      case .signatureInvalid(let detail):
        "The downloaded app failed its signature check: \(detail)"
      }
    }
  }

  private let shell: Shell

  public init(environment: [String: String]? = nil) {
    self.shell = Shell(environment: environment)
  }

  // MARK: - Checking what arrived

  /// SHA-256 of a file, lowercase hex.
  public func checksum(of file: URL) async throws -> String {
    let result = try await shell.check("/usr/bin/shasum", ["-a", "256", file.path])
    return String(result.trimmedOutput.split(separator: " ").first ?? "")
  }

  /// Reads a `shasum` style list and returns the digest recorded for `name`.
  public static func expectedChecksum(for name: String, in list: String) -> String? {
    for line in list.split(separator: "\n") {
      let parts = line.split(separator: " ").filter { !$0.isEmpty }
      guard parts.count >= 2, parts.last.map(String.init) == name else { continue }
      return String(parts[0])
    }
    return nil
  }

  /// Throws unless the file's digest matches.
  ///
  /// These builds are ad-hoc signed, so there is no certificate chain to trust.
  /// A published checksum at least proves the bytes arrived whole and unaltered
  /// in transit, which is the check actually available.
  public func verify(_ file: URL, matches expected: String) async throws {
    let actual = try await checksum(of: file)
    guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
      throw Failure.checksumMismatch(expected: expected, actual: actual)
    }
  }

  // MARK: - Getting the new app out of the image

  /// Mounts `dmg`, copies the application out of it, and unmounts.
  ///
  /// The copy matters: the image has to be detached before the swap, or the new
  /// bundle vanishes from under the script.
  public func stageApplication(fromImageAt dmg: URL) async throws -> URL {
    let mountPoint = FileManager.default.temporaryDirectory
      .appending(path: "grove-mount-\(UUID().uuidString)")
    let staging = FileManager.default.temporaryDirectory
      .appending(path: "grove-staged-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

    let attach = try await shell.run(
      "/usr/bin/hdiutil",
      ["attach", dmg.path, "-nobrowse", "-noverify", "-quiet", "-mountpoint", mountPoint.path])
    guard attach.succeeded else {
      throw Failure.mountFailed(
        attach.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    defer {
      Task { _ = try? await shell.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"]) }
    }

    let contents = (try? FileManager.default.contentsOfDirectory(atPath: mountPoint.path)) ?? []
    guard let appName = contents.first(where: { $0.hasSuffix(".app") }) else {
      throw Failure.noAppInImage
    }

    let source = mountPoint.appending(path: appName)
    let staged = staging.appending(path: appName)
    // ditto rather than cp: it preserves the bundle's extended attributes and
    // code signature, which a naive copy can strip.
    try await shell.check("/usr/bin/ditto", [source.path, staged.path])

    // Anything downloaded carries a quarantine flag. Left on, Gatekeeper blocks
    // the relaunch and the update looks like a crash.
    _ = try await shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

    let verified = try await shell.run("/usr/bin/codesign", ["--verify", "--deep", staged.path])
    guard verified.succeeded else {
      throw Failure.signatureInvalid(
        verified.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    return staged
  }

  // MARK: - The swap

  /// Replaces `target` with `staged` immediately. Used when nothing is running
  /// from the target, and by the tests.
  public func replace(_ target: URL, with staged: URL) async throws {
    try requireWritable(target)
    let previous = target.appendingPathExtension("old")
    try? FileManager.default.removeItem(at: previous)

    if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.moveItem(at: target, to: previous)
    }
    do {
      try FileManager.default.moveItem(at: staged, to: target)
    } catch {
      // Put the old one back rather than leaving nothing installed.
      try? FileManager.default.moveItem(at: previous, to: target)
      throw error
    }
    try? FileManager.default.removeItem(at: previous)
  }

  /// Writes the script that performs the swap once this process has exited.
  ///
  /// Returns its path; the caller launches it detached and then quits.
  public func writeSwapScript(
    staged: URL, target: URL, processIdentifier: Int32
  ) throws -> URL {
    try requireWritable(target)

    let script = FileManager.default.temporaryDirectory
      .appending(path: "grove-update-\(UUID().uuidString).sh")

    // Quoted with single quotes throughout: these paths contain temporary
    // directory names, and one day one of them will contain a space.
    let body = """
      #!/bin/sh
      set -e
      target='\(target.path)'
      staged='\(staged.path)'
      previous="$target.old"

      # Wait for Grove to go before touching its bundle.
      for _ in $(seq 1 300); do
        kill -0 \(processIdentifier) 2>/dev/null || break
        sleep 0.2
      done

      rm -rf "$previous"
      if [ -e "$target" ]; then
        mv "$target" "$previous"
      fi

      if mv "$staged" "$target"; then
        rm -rf "$previous"
      else
        # Leave the working copy installed rather than nothing at all.
        [ -e "$previous" ] && mv "$previous" "$target"
        exit 1
      fi

      xattr -dr com.apple.quarantine "$target" 2>/dev/null || true
      rm -rf "$(dirname "$staged")"
      open "$target"
      rm -f "$0"
      """

    try body.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  /// Starts the script and returns, leaving the caller to quit.
  public func launchDetached(_ script: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/sh")
    process.arguments = [script.path]
    // No pipes: this has to outlive the app, so it must not be waiting on a
    // reader that is about to disappear.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    try process.run()
  }

  private func requireWritable(_ target: URL) throws {
    let parent = target.deletingLastPathComponent()
    let manager = FileManager.default
    let existsAndWritable =
      !manager.fileExists(atPath: target.path) || manager.isWritableFile(atPath: target.path)
    guard manager.isWritableFile(atPath: parent.path), existsAndWritable else {
      throw Failure.bundleNotWritable(target.path)
    }
  }
}
