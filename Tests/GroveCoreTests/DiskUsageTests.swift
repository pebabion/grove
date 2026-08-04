import Foundation
import Testing

@testable import GroveCore

@Suite("disk usage")
struct DiskUsageTests {
  @Test("measures a directory and notices a bigger one is bigger")
  func measuresDirectories() async throws {
    let sandbox = try Sandbox()
    let small = sandbox.root.appending(path: "small")
    let large = sandbox.root.appending(path: "large")
    try sandbox.write(String(repeating: "a", count: 1024), to: small.appending(path: "f"))
    try sandbox.write(String(repeating: "a", count: 512 * 1024), to: large.appending(path: "f"))

    let usage = DiskUsage()
    let smallReading = try #require(await usage.measure(small))
    let largeReading = try #require(await usage.measure(large))

    #expect(smallReading.bytes > 0)
    #expect(largeReading.bytes > smallReading.bytes)
    #expect(largeReading.formatted.contains("kB") || largeReading.formatted.contains("MB"))
  }

  @Test("returns nothing for a path that is not there")
  func missingDirectory() async {
    let missing = URL(filePath: "/definitely/not/a/real/path/xyz")

    #expect(await DiskUsage().measure(missing) == nil)
  }

  @Test("reports each directory as it finishes")
  func measuresManyDirectories() async throws {
    let sandbox = try Sandbox()
    var targets: [URL] = []
    for index in 0..<7 {
      let directory = sandbox.root.appending(path: "d\(index)")
      try sandbox.write("x", to: directory.appending(path: "f"))
      targets.append(directory)
    }

    let collected = Collector()
    await DiskUsage().measureAll(targets) { url, reading in
      Task { await collected.add(url, reading) }
    }
    // The callback hops onto another task, so let those land.
    try await Task.sleep(for: .milliseconds(200))

    #expect(await collected.count == targets.count)
  }

  @Test("caches by path and forgets what is gone")
  func cachePrunes() {
    var cache = SizeCache()
    let kept = URL(filePath: "/tmp/kept")
    let removed = URL(filePath: "/tmp/removed")
    cache[kept] = SizeReading(bytes: 100, measuredAt: Date(timeIntervalSince1970: 0))
    cache[removed] = SizeReading(bytes: 200, measuredAt: Date(timeIntervalSince1970: 0))

    cache.prune(keeping: [kept])

    #expect(cache[kept]?.bytes == 100)
    #expect(cache[removed] == nil)
  }

  @Test("survives a save and load")
  func cacheRoundTrips() throws {
    let sandbox = try Sandbox()
    let file = sandbox.root.appending(path: "sizes.json")
    var cache = SizeCache()
    cache[URL(filePath: "/tmp/a")] = SizeReading(
      bytes: 4096, measuredAt: Date(timeIntervalSince1970: 10))

    let store = JSONStore()
    try store.save(cache, to: file)
    let loaded = try #require(try store.load(SizeCache.self, from: file))

    #expect(loaded[URL(filePath: "/tmp/a")]?.bytes == 4096)
  }
}

private actor Collector {
  private var seen: [URL: SizeReading?] = [:]
  var count: Int { seen.count }
  func add(_ url: URL, _ reading: SizeReading?) { seen[url] = reading }
}
