import Foundation

/// Reads and writes Grove's JSON files.
///
/// Everything Grove persists is small, hand-editable, and stored as JSON so the
/// package carries no dependencies. Writes go through a temporary file and an
/// atomic replace, so a crash mid-save cannot leave a truncated library behind.
public struct JSONStore: Sendable {
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  public init() {
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  /// Decodes `T` from `url`, or returns `nil` when the file does not exist.
  public func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard !data.isEmpty else { return nil }
    return try decoder.decode(type, from: data)
  }

  public func save<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try encoder.encode(value)
    let scratch = url.deletingLastPathComponent()
      .appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
    try data.write(to: scratch)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
  }
}

extension URL {
  /// One agreed spelling for a path, so two URLs naming the same directory
  /// compare equal.
  ///
  /// Neither `standardizedFileURL` nor `resolvingSymlinksInPath()` is enough on
  /// its own. FileManager reports `/private/var/…` while a URL built from
  /// `temporaryDirectory` says `/var/…`, and both survive those calls unchanged.
  /// macOS has exactly two of these doubled roots, `/private/var` and
  /// `/private/tmp`, so the shorter spelling is chosen deliberately.
  public var canonical: URL {
    let resolved = resolvingSymlinksInPath().standardizedFileURL
    for root in ["/private/var", "/private/tmp"] where resolved.path.hasPrefix(root + "/") {
      return URL(filePath: String(resolved.path.dropFirst("/private".count)))
    }
    return resolved
  }
}

/// Where Grove keeps its files.
public enum GroveLocations {
  /// `~/.config/grove`
  public static var configDirectory: URL {
    URL(filePath: NSHomeDirectory()).appending(path: ".config/grove")
  }

  /// `~/.config/grove/library.json`
  public static var libraryFile: URL {
    configDirectory.appending(path: "library.json")
  }

  /// `~/Library/Caches/com.pebabion.Grove` — derived data only. Nothing here
  /// is authoritative; deleting it costs a rescan and nothing else.
  public static var cacheDirectory: URL {
    URL(filePath: NSHomeDirectory()).appending(path: "Library/Caches/com.pebabion.Grove")
  }

  /// Grove's metadata file inside a workspace directory.
  public static let workspaceFileName = "grove.json"

  /// Directory a repo may commit its lifecycle scripts to.
  public static let hookDirectoryName = ".grove"
  public static let setupScriptName = "setup.sh"
  public static let teardownScriptName = "teardown.sh"
}
