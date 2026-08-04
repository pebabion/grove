import Foundation
import Testing

@testable import GroveCore

@Suite("version comparison")
struct SemanticVersionTests {
  @Test("orders by number, not by text")
  func ordersNumerically() throws {
    let ten = try #require(SemanticVersion("0.10.0"))
    let nine = try #require(SemanticVersion("0.9.0"))

    // The whole reason this type exists: "0.10.0" < "0.9.0" as strings.
    #expect(nine < ten)
    #expect("0.10.0" < "0.9.0")
  }

  @Test("compares each component in turn")
  func comparesComponents() throws {
    func v(_ s: String) throws -> SemanticVersion { try #require(SemanticVersion(s)) }

    #expect(try v("1.0.0") > v("0.99.99"))
    #expect(try v("1.2.0") > v("1.1.9"))
    #expect(try v("1.2.3") > v("1.2.2"))
    #expect(try v("1.2.3") == v("1.2.3"))
  }

  @Test("accepts a leading v and short forms")
  func acceptsTagsAndShortForms() throws {
    #expect(SemanticVersion("v1.2.3") == SemanticVersion("1.2.3"))
    #expect(SemanticVersion("2") == SemanticVersion("2.0.0"))
    #expect(SemanticVersion("2.1") == SemanticVersion("2.1.0"))
  }

  @Test("a prerelease comes before its release")
  func prereleaseOrdering() throws {
    let beta = try #require(SemanticVersion("1.0.0-beta.1"))
    let final = try #require(SemanticVersion("1.0.0"))

    #expect(beta < final)
    #expect(try #require(SemanticVersion("1.0.0-beta.2")) > beta)
  }

  @Test("rejects what is not a version")
  func rejectsRubbish() {
    #expect(SemanticVersion("") == nil)
    #expect(SemanticVersion("main") == nil)
    #expect(SemanticVersion("1.2.3.4") == nil)
    #expect(SemanticVersion("1.x.3") == nil)
    #expect(SemanticVersion("-1.0.0") == nil)
  }
}

@Suite("update check")
struct UpdateCheckerTests {
  /// A trimmed copy of what GitHub actually returned for v0.1.0.
  static func payload(tag: String) -> Data {
    Data(
      """
      {
        "tag_name": "\(tag)",
        "html_url": "https://github.com/pebabion/grove/releases/tag/\(tag)",
        "published_at": "2026-08-04T22:17:00Z",
        "draft": false,
        "prerelease": false,
        "assets": [
          {
            "name": "checksums.txt",
            "browser_download_url": "https://github.com/pebabion/grove/releases/download/\(tag)/checksums.txt"
          },
          {
            "name": "Grove-0.9.0.dmg",
            "browser_download_url": "https://github.com/pebabion/grove/releases/download/\(tag)/Grove-0.9.0.dmg"
          }
        ]
      }
      """.utf8)
  }

  private func checker(tag: String) -> UpdateChecker {
    UpdateChecker(repository: "pebabion/grove") { _ in Self.payload(tag: tag) }
  }

  @Test("offers a newer release, with the disk image")
  func findsNewerRelease() async throws {
    let update = try #require(await checker(tag: "v0.9.0").check(against: "0.1.0"))

    #expect(update.version == SemanticVersion("0.9.0"))
    #expect(update.downloadURL?.lastPathComponent == "Grove-0.9.0.dmg")
    #expect(update.pageURL.absoluteString.hasSuffix("/releases/tag/v0.9.0"))
    #expect(update.publishedAt != nil)
  }

  @Test("says nothing when already current")
  func nothingWhenCurrent() async {
    #expect(await checker(tag: "v0.1.0").check(against: "0.1.0") == nil)
  }

  @Test("says nothing when running ahead of the latest release")
  func nothingWhenAhead() async {
    #expect(await checker(tag: "v0.1.0").check(against: "0.2.0") == nil)
  }

  @Test("stays quiet when the request fails")
  func quietOnFailure() async {
    let broken = UpdateChecker(repository: "x/y") { _ in throw URLError(.notConnectedToInternet) }

    #expect(await broken.check(against: "0.1.0") == nil)
  }

  @Test("stays quiet on a response it cannot read")
  func quietOnGarbage() async {
    let garbage = UpdateChecker(repository: "x/y") { _ in Data("not json".utf8) }

    #expect(await garbage.check(against: "0.1.0") == nil)
  }

  @Test("stays quiet when this build has no usable version")
  func quietWithoutAVersion() async {
    #expect(await checker(tag: "v9.9.9").check(against: "unknown") == nil)
  }
}
