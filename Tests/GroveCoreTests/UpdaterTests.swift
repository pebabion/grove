import Foundation
import Testing

@testable import GroveCore

/// Exercised against real disk images and real bundle swaps. This code replaces
/// the running application, so a stub that "returns success" would be worth
/// nothing — the failure mode is a user left with no app installed.
@Suite("updater", .serialized)
struct UpdaterTests {
  let updater = Updater()

  /// A minimal app bundle reporting `version`.
  private func makeBundle(at url: URL, version: String) async throws {
    let contents = url.appending(path: "Contents")
    try FileManager.default.createDirectory(
      at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleIdentifier</key><string>com.pebabion.GroveTestStub</string>
      <key>CFBundleName</key><string>Grove</string>
      <key>CFBundleExecutable</key><string>Grove</string>
      <key>CFBundleShortVersionString</key><string>\(version)</string>
    </dict>
    </plist>
    """.write(to: contents.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
    try "#!/bin/sh\nexit 0\n".write(
      to: contents.appending(path: "MacOS/Grove"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: contents.appending(path: "MacOS/Grove").path)
    // Ad-hoc sign so the staging step's signature check has something to pass.
    _ = try? await Shell().run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
  }

  private func version(of bundle: URL) -> String? {
    let plist = bundle.appending(path: "Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
      let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = parsed as? [String: Any]
    else { return nil }
    return dictionary["CFBundleShortVersionString"] as? String
  }

  /// A real disk image containing a bundle at `version`.
  private func makeImage(in sandbox: Sandbox, version: String) async throws -> URL {
    let source = sandbox.root.appending(path: "image-source-\(version)")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try await makeBundle(at: source.appending(path: "Grove.app"), version: version)

    let dmg = sandbox.root.appending(path: "Grove-\(version).dmg")
    let shell = Shell()
    let result = try await shell.run(
      "/usr/bin/hdiutil",
      [
        "create", "-volname", "Grove \(version)", "-srcfolder", source.path,
        "-ov", "-format", "UDZO", "-quiet", dmg.path,
      ])
    #expect(result.succeeded, "hdiutil create failed: \(result.standardError)")
    return dmg
  }

  @Test("takes the app out of a disk image and leaves nothing mounted")
  func stagesFromImage() async throws {
    let sandbox = try Sandbox()
    let dmg = try await makeImage(in: sandbox, version: "2.0.0")

    let staged = try await updater.stageApplication(fromImageAt: dmg)

    #expect(version(of: staged) == "2.0.0")
    #expect(staged.lastPathComponent == "Grove.app")
    // The image must be detached, or the staged copy disappears when it is.
    try await Task.sleep(for: .milliseconds(600))
    #expect(version(of: staged) == "2.0.0")
  }

  @Test("replaces an installed bundle with the new one")
  func replacesBundle() async throws {
    let sandbox = try Sandbox()
    let installed = sandbox.root.appending(path: "Applications/Grove.app")
    try FileManager.default.createDirectory(
      at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await makeBundle(at: installed, version: "1.0.0")

    let dmg = try await makeImage(in: sandbox, version: "2.0.0")
    let staged = try await updater.stageApplication(fromImageAt: dmg)

    try await updater.replace(installed, with: staged)

    #expect(version(of: installed) == "2.0.0")
    // No leftovers to confuse the next update.
    #expect(!FileManager.default.fileExists(atPath: installed.path + ".old"))
  }

  @Test("the swap script installs the update and relaunches nothing that is gone")
  func swapScriptRuns() async throws {
    let sandbox = try Sandbox()
    let installed = sandbox.root.appending(path: "Applications/Grove.app")
    try FileManager.default.createDirectory(
      at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await makeBundle(at: installed, version: "1.0.0")

    let dmg = try await makeImage(in: sandbox, version: "3.1.0")
    let staged = try await updater.stageApplication(fromImageAt: dmg)

    // A pid that has already exited, so the script proceeds at once. `open` at
    // the end will fail on a stub bundle, which is fine: the swap is what
    // matters and it happens before that.
    let script = try updater.writeSwapScript(
      staged: staged, target: installed, processIdentifier: 999_999)
    let shell = Shell()
    _ = try await shell.run("/bin/sh", [script.path])

    #expect(version(of: installed) == "3.1.0")
  }

  @Test("keeps the working copy when the new bundle cannot be moved in")
  func rollsBackOnFailure() async throws {
    let sandbox = try Sandbox()
    let installed = sandbox.root.appending(path: "Applications/Grove.app")
    try FileManager.default.createDirectory(
      at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await makeBundle(at: installed, version: "1.0.0")

    // A staged path that is not there, so the move fails after the old bundle
    // has been set aside. The old one must come back.
    let missing = sandbox.root.appending(path: "nothing/Grove.app")

    await #expect(throws: (any Error).self) {
      try await updater.replace(installed, with: missing)
    }
    #expect(version(of: installed) == "1.0.0")
  }

  @Test("refuses a bundle it cannot write")
  func refusesUnwritableTarget() async throws {
    let sandbox = try Sandbox()
    let locked = sandbox.root.appending(path: "locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try await makeBundle(at: locked.appending(path: "Grove.app"), version: "1.0.0")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o500], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }

    await #expect(throws: Updater.Failure.self) {
      _ = try updater.writeSwapScript(
        staged: sandbox.root.appending(path: "x.app"),
        target: locked.appending(path: "Grove.app"),
        processIdentifier: 1)
    }
  }

  @Test("checks the download against its published digest")
  func verifiesChecksum() async throws {
    let sandbox = try Sandbox()
    let file = sandbox.root.appending(path: "payload.bin")
    try sandbox.write("the actual bytes", to: file)

    let digest = try await updater.checksum(of: file)
    #expect(digest.count == 64)

    try await updater.verify(file, matches: digest.uppercased())

    await #expect(throws: Updater.Failure.self) {
      try await updater.verify(file, matches: String(repeating: "0", count: 64))
    }
  }

  @Test("reads a digest out of a shasum listing")
  func parsesChecksumList() {
    let list = """
      c040d26ba46489c35e9c14ab4d15614b3c4b30cc7c1ca948c8983860e7ee2c94  Grove-0.1.0.dmg
      0000000000000000000000000000000000000000000000000000000000000000  other.zip
      """

    #expect(
      Updater.expectedChecksum(for: "Grove-0.1.0.dmg", in: list)?.hasPrefix("c040d26b") == true)
    #expect(Updater.expectedChecksum(for: "missing.dmg", in: list) == nil)
  }
}
