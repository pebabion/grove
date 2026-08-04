import Foundation

/// A measured directory size and when it was taken.
public struct SizeReading: Codable, Sendable, Hashable {
  public var bytes: Int64
  public var measuredAt: Date

  public init(bytes: Int64, measuredAt: Date) {
    self.bytes = bytes
    self.measuredAt = measuredAt
  }

  public var formatted: String {
    bytes.formatted(.byteCount(style: .file))
  }
}

/// Measures how much disk a workspace holds.
///
/// This is slow and there is no trick that makes it fast: the answer requires
/// walking every file. On a real machine, fourteen workspaces took 42 seconds
/// cold and the largest one still took 8 seconds with a warm filesystem cache.
/// So measuring is always something the user asks for, never something that
/// happens on launch, and results are cached until asked again.
public struct DiskUsage: Sendable {
  /// Simultaneous `du` processes. The work is disk-bound, so more than a handful
  /// makes the whole set slower rather than faster.
  public static let concurrencyLimit = 4

  private let shell: Shell
  private let executable: String

  public init(executable: String = "/usr/bin/du", environment: [String: String]? = nil) {
    self.executable = executable
    self.shell = Shell(environment: environment)
  }

  /// Bytes of disk a directory occupies, or `nil` if it cannot be read.
  ///
  /// Reports allocated blocks, and counts a hardlinked file once, so the figure
  /// is what removal would actually give back.
  public func measure(_ url: URL) async -> SizeReading? {
    guard let result = try? await shell.run(executable, ["-sk", url.path]),
      result.succeeded
    else { return nil }

    // `du -sk` prints "<blocks>\t<path>", one 1024-byte block per unit.
    guard let blocks = result.trimmedOutput.split(separator: "\t").first,
      let kilobytes = Int64(blocks.trimmingCharacters(in: .whitespaces))
    else { return nil }

    return SizeReading(bytes: kilobytes * 1024, measuredAt: Date())
  }

  /// Measures several directories, reporting each as it finishes rather than
  /// waiting for the slowest.
  public func measureAll(
    _ urls: [URL],
    onResult: @escaping @Sendable (URL, SizeReading?) -> Void
  ) async {
    var remaining = urls[...]

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<min(Self.concurrencyLimit, urls.count) {
        guard let next = remaining.popFirst() else { break }
        group.addTask { onResult(next, await self.measure(next)) }
      }

      while await group.next() != nil {
        guard let next = remaining.popFirst() else { continue }
        group.addTask { onResult(next, await self.measure(next)) }
      }
    }
  }
}

/// Cached sizes, keyed by path. Purely derived: deleting the file costs a
/// remeasure and nothing else.
public struct SizeCache: Codable, Sendable {
  public var readings: [String: SizeReading]

  public init(readings: [String: SizeReading] = [:]) {
    self.readings = readings
  }

  public subscript(url: URL) -> SizeReading? {
    get { readings[url.canonical.path] }
    set { readings[url.canonical.path] = newValue }
  }

  /// Forgets paths that are no longer on disk, so a torn-down workspace does not
  /// linger in the totals.
  public mutating func prune(keeping urls: [URL]) {
    let live = Set(urls.map(\.canonical.path))
    readings = readings.filter { live.contains($0.key) }
  }

  public static var fileURL: URL {
    GroveLocations.cacheDirectory.appending(path: "sizes.json")
  }
}
