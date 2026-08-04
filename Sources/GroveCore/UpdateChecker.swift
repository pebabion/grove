import Foundation

/// A version number, compared by its parts rather than as text.
///
/// String comparison gets this wrong in the one case that matters: "0.10.0" sorts
/// before "0.9.0" alphabetically, so a real update would look like a downgrade
/// and never be offered.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int
  /// Anything after a hyphen, e.g. the `beta.1` of `1.2.0-beta.1`.
  public let prerelease: String?

  public init?(_ text: String) {
    // Tags carry a leading v; bundle versions do not.
    var body = text.hasPrefix("v") ? String(text.dropFirst()) : text
    var prerelease: String?
    if let hyphen = body.firstIndex(of: "-") {
      prerelease = String(body[body.index(after: hyphen)...])
      body = String(body[..<hyphen])
    }

    let parts = body.split(separator: ".", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 3 else { return nil }
    var numbers: [Int] = []
    for part in parts {
      guard let value = Int(part), value >= 0 else { return nil }
      numbers.append(value)
    }
    major = numbers[0]
    minor = numbers.count > 1 ? numbers[1] : 0
    patch = numbers.count > 2 ? numbers[2] : 0
    self.prerelease = prerelease
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.major != rhs.major { return lhs.major < rhs.major }
    if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
    if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
    // A prerelease precedes the release it leads to: 1.0.0-beta < 1.0.0.
    switch (lhs.prerelease, rhs.prerelease) {
    case (nil, nil): return false
    case (_?, nil): return true
    case (nil, _?): return false
    case (let left?, let right?): return left < right
    }
  }

  public var description: String {
    let core = "\(major).\(minor).\(patch)"
    return prerelease.map { "\(core)-\($0)" } ?? core
  }
}

/// A newer release than the one running.
public struct AvailableUpdate: Sendable, Hashable {
  public let version: SemanticVersion
  /// The release page, for reading what changed.
  public let pageURL: URL
  /// The disk image, when the release has one.
  public let downloadURL: URL?
  /// The published SHA-256 list, used to check the download arrived whole.
  public let checksumsURL: URL?
  public let publishedAt: Date?

  public init(
    version: SemanticVersion, pageURL: URL, downloadURL: URL?, checksumsURL: URL? = nil,
    publishedAt: Date?
  ) {
    self.version = version
    self.pageURL = pageURL
    self.downloadURL = downloadURL
    self.checksumsURL = checksumsURL
    self.publishedAt = publishedAt
  }
}

/// Asks GitHub whether a newer release exists.
///
/// Reads the public releases API directly rather than going through `gh`, so it
/// works on a machine that has never installed it. `releases/latest` already
/// excludes drafts and prereleases.
public struct UpdateChecker: Sendable {
  public typealias Fetch = @Sendable (URL) async throws -> Data

  private let repository: String
  private let fetch: Fetch

  public init(repository: String = "pebabion/grove", fetch: Fetch? = nil) {
    self.repository = repository
    self.fetch = fetch ?? Self.fetchOverNetwork
  }

  public var latestReleaseURL: URL {
    URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
  }

  /// The newer release, or `nil` when this is already the latest — or when the
  /// question cannot be answered, which is treated the same way. A failed update
  /// check is not worth telling anybody about.
  public func check(against current: String) async -> AvailableUpdate? {
    guard let current = SemanticVersion(current) else { return nil }
    guard let data = try? await fetch(latestReleaseURL) else { return nil }
    guard let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
    guard let latest = SemanticVersion(release.tagName), latest > current else { return nil }

    guard let page = URL(string: release.htmlURL) else { return nil }
    let dmg = release.assets
      .first { $0.name.hasSuffix(".dmg") }
      .flatMap { URL(string: $0.browserDownloadURL) }
    let checksums = release.assets
      .first { $0.name == "checksums.txt" }
      .flatMap { URL(string: $0.browserDownloadURL) }

    return AvailableUpdate(
      version: latest,
      pageURL: page,
      downloadURL: dmg,
      checksumsURL: checksums,
      publishedAt: release.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    )
  }

  @Sendable private static func fetchOverNetwork(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    // GitHub rejects API requests with no User-Agent.
    request.setValue("Grove", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 15
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw URLError(.badServerResponse)
    }
    return data
  }

  // MARK: - Wire format

  struct Release: Decodable {
    let tagName: String
    let htmlURL: String
    let publishedAt: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
      case publishedAt = "published_at"
      case assets
    }
  }

  struct Asset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
      case name
      case browserDownloadURL = "browser_download_url"
    }
  }
}
