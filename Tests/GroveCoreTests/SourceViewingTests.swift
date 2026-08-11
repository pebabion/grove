import Foundation
import Testing

@testable import GroveCore

@Suite("reading a file for display")
struct SourceFileTests {
  private let reader = SourceFile()

  private func temporaryFile(_ bytes: Data) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "grove-source-\(UUID().uuidString)")
    try bytes.write(to: url)
    return url
  }

  @Test("reads text")
  func readsText() throws {
    let url = try temporaryFile(Data("let x = 1\n".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(reader.read(url) == .text("let x = 1\n"))
  }

  @Test("an empty file is empty text, not a failure")
  func emptyFile() throws {
    let url = try temporaryFile(Data())
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(reader.read(url) == .text(""))
  }

  @Test("refuses a file too large to lay out, and says how large")
  func refusesLargeFiles() throws {
    // Highlighting runs over the whole file at once, so this is a limit on patience.
    let url = try temporaryFile(Data(repeating: 0x41, count: 5000))
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(reader.read(url, limit: 1000) == .toolarge(bytes: 5000))
  }

  @Test("refuses a binary rather than showing its bytes")
  func refusesBinary() throws {
    var bytes = Data("ELF".utf8)
    bytes.append(contentsOf: [0x00, 0x01, 0x02, 0x00])
    let url = try temporaryFile(bytes)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(reader.read(url) == .binary)
  }

  @Test("says so when the file is not there")
  func missingFile() {
    let url = URL(fileURLWithPath: "/nonexistent/grove/file.swift")
    guard case .unreadable = reader.read(url) else {
      Issue.record("expected unreadable")
      return
    }
  }

  @Test("a NUL is what makes a file binary, and only near the front is examined")
  func binarySniffing() {
    // Reading 400MB to answer the question would defeat the purpose.
    #expect(SourceFile.looksBinary(Data([0x41, 0x00, 0x42])))
    #expect(!SourceFile.looksBinary(Data("plain text".utf8)))
    var late = Data(repeating: 0x41, count: SourceFile.sniffLength + 100)
    late.append(0)
    #expect(!SourceFile.looksBinary(late))
  }

  @Test("falls back to Latin-1 rather than refusing a file that is not UTF-8")
  func decodesLegacyEncodings() {
    // An old file is usually not an unreadable one, and slightly wrong beats absent.
    let bytes = Data([0x63, 0x61, 0x66, 0xE9])  // "café" in Latin-1
    guard case .text(let text) = SourceFile.decode(bytes) else {
      Issue.record("expected text")
      return
    }
    #expect(text == "café")
  }

  @Test("keeps valid UTF-8 as UTF-8")
  func prefersUTF8() {
    guard case .text(let text) = SourceFile.decode(Data("héllo → world".utf8)) else {
      Issue.record("expected text")
      return
    }
    #expect(text == "héllo → world")
  }
}

@Suite("naming a file's language")
struct SourceLanguageTests {
  @Test("recognises the usual extensions")
  func byExtension() {
    #expect(SourceLanguage.named(for: "Sources/Grove/AppModel.swift") == "swift")
    #expect(SourceLanguage.named(for: "app/main.py") == "python")
    #expect(SourceLanguage.named(for: "web/index.tsx") == "typescript")
    #expect(SourceLanguage.named(for: "infra/main.tf") == "terraform")
    #expect(SourceLanguage.named(for: "deploy.yaml") == "yaml")
  }

  @Test("recognises files that carry their type in their name")
  func byName() {
    #expect(SourceLanguage.named(for: "Dockerfile") == "dockerfile")
    #expect(SourceLanguage.named(for: "backend/Makefile") == "makefile")
    #expect(SourceLanguage.named(for: "Gemfile") == "ruby")
    #expect(SourceLanguage.named(for: ".gitignore") == "bash")
  }

  @Test("handles a suffix after the meaningful part")
  func compoundNames() {
    // Dockerfile.web and .env.production are both common.
    #expect(SourceLanguage.named(for: "Dockerfile.web") == "dockerfile")
    #expect(SourceLanguage.named(for: ".env.production") == "bash")
  }

  @Test("is not fooled by case")
  func caseInsensitive() {
    #expect(SourceLanguage.named(for: "MAIN.PY") == "python")
    #expect(SourceLanguage.named(for: "dockerfile") == "dockerfile")
  }

  @Test("says nothing rather than guessing")
  func unknownIsNil() {
    // Highlighting a file as the wrong language is worse than leaving it plain: the
    // colours then argue with the content.
    #expect(SourceLanguage.named(for: "notes") == nil)
    #expect(SourceLanguage.named(for: "data.bin") == nil)
    #expect(SourceLanguage.named(for: "") == nil)
  }
}

@Suite("finding a file by typing")
struct FileSearchTests {
  private let files = [
    FileMatch(path: "Grove/AppModel.swift", repo: "grove"),
    FileMatch(path: "Grove/GroveTerminalView.swift", repo: "grove"),
    FileMatch(path: "Sources/GroveCore/Git.swift", repo: "grove"),
    FileMatch(path: "app/api/views.py", repo: "backend"),
    FileMatch(path: "app/api/models.py", repo: "backend"),
    FileMatch(path: "README.md", repo: "backend"),
  ]

  private func paths(_ query: String) -> [String] {
    FileSearch.matches(for: query, in: files).map(\.path)
  }

  @Test("an empty query lists everything, in a stable order")
  func emptyQueryListsAll() {
    let all = FileSearch.matches(for: "", in: files)
    #expect(all.count == files.count)
    #expect(all.map(\.path) == files.map(\.path).sorted())
  }

  @Test("initials find a file, the way every editor's finder works")
  func matchesInitials() {
    #expect(paths("gtv").first == "Grove/GroveTerminalView.swift")
  }

  @Test("a filename match beats one spread across directories")
  func prefersFilenameMatches() {
    // "git" appears inside the path of every Grove file, but one file is called it.
    #expect(paths("git").first == "Sources/GroveCore/Git.swift")
  }

  @Test("narrows as more is typed")
  func narrows() {
    // Subsequence matching means "views" also matches GroveTerminalView.swift, which is
    // correct and useful. What matters is that the file actually called views ranks
    // first.
    #expect(paths("views").first == "app/api/views.py")
    #expect(paths("v").count > paths("views").count)
  }

  @Test("returns nothing when nothing matches, rather than everything")
  func noMatches() {
    #expect(paths("zzzznotafile").isEmpty)
  }

  @Test("ignores case and surrounding space")
  func forgiving() {
    #expect(paths("  APPMODEL  ").first == "Grove/AppModel.swift")
  }

  @Test("the same query always gives the same order")
  func stableOrder() {
    let once = FileSearch.matches(for: "py", in: files)
    let twice = FileSearch.matches(for: "py", in: files.reversed())
    #expect(once == twice)
  }

  @Test("honours the limit")
  func respectsLimit() {
    let many = (0..<500).map { FileMatch(path: "file\($0).swift", repo: "r") }
    #expect(FileSearch.matches(for: "swift", in: many, limit: 10).count == 10)
    #expect(FileSearch.matches(for: "", in: many, limit: 10).count == 10)
  }
}

@Suite("searching a repo's worth of files")
struct FileIndexTests {
  /// Roughly what three real repos hold.
  private var many: [FileMatch] {
    (0..<9000).flatMap { i in
      ["backend", "frontend", "agent-graph"].map { repo in
        FileMatch(path: "src/module\(i % 300)/file_name_\(i).py", repo: repo)
      }
    }
  }

  @Test("keeping only the best results does not make the order depend on input order")
  func stableUnderReordering() {
    // Results are selected as they are scored rather than sorted at the end, so a
    // change in the order files arrive must not change which ones are kept.
    let files = many
    let forwards = FileIndex(files).matches(for: "file_name_1", limit: 50)
    let backwards = FileIndex(files.reversed()).matches(for: "file_name_1", limit: 50)
    #expect(forwards == backwards)
    #expect(forwards.count == 50)
  }

  @Test("the best result is the same whether or not the list is capped")
  func capDoesNotChangeTheWinner() {
    let index = FileIndex(many)
    #expect(
      index.matches(for: "file_name_42", limit: 5).first
        == index.matches(for: "file_name_42", limit: 5000).first)
  }

  @Test("scores bytes rather than characters, and folds ASCII case")
  func foldsCase() {
    #expect(FileIndex.folded("AppModel.Swift") == FileIndex.folded("appmodel.swift"))
    // Non-ASCII passes through, so an accented path still matches exactly.
    #expect(FileIndex.folded("café") == Array("café".utf8))
  }

  @Test("a query matching nothing is answered without scoring everything twice")
  func rejectsQuickly() {
    #expect(FileIndex(many).matches(for: "zzzzzzzz").isEmpty)
  }

  @Test("counts what it holds")
  func reportsCount() {
    #expect(FileIndex(many).count == 27_000)
    #expect(FileIndex([]).count == 0)
  }
}

@Suite("narrowing a search instead of starting over")
struct SearchNarrowingTests {
  private let files = [
    FileMatch(path: "skills/system/people-search/SKILL.md", repo: "agent-graph"),
    FileMatch(path: "agent_graph/graphs/people_search.py", repo: "agent-graph"),
    FileMatch(path: "agent_graph/tools/warehouse_sql.py", repo: "agent-graph"),
    FileMatch(path: "Grove/GroveTerminalView.swift", repo: "grove"),
  ]

  @Test("recognises a query that only adds to the last one")
  func recognisesGrowth() {
    // Adding characters can only ever exclude files, so the previous matches are a
    // complete set to search. Deleting or editing can bring files back.
    #expect(FileIndex.narrows(from: "peo", to: "peop"))
    #expect(FileIndex.narrows(from: "people", to: "people skill"))
    #expect(!FileIndex.narrows(from: "peop", to: "peo"))
    #expect(!FileIndex.narrows(from: "peop", to: "seop"))
    #expect(!FileIndex.narrows(from: "", to: "p"))
  }

  @Test("narrowing gives the same answer as starting over")
  func narrowingIsExact() {
    // The whole optimisation rests on this: it must be a shortcut, not an approximation.
    let index = FileIndex(files)
    var previous: FileIndex.Result?
    for query in ["p", "pe", "peo", "peop", "people", "people ", "people s", "people skill"] {
      let narrowed = index.search(query, refining: previous)
      let fresh = index.search(query, refining: nil)
      #expect(narrowed.matches == fresh.matches, "differs at \"\(query)\"")
      previous = narrowed
    }
  }

  @Test("a result carries every match, not just the ones shown")
  func carriesEveryMatch() {
    // Narrowing against the visible slice would lose files the next keystroke needs.
    let many = (0..<500).map { FileMatch(path: "src/file\($0)_thing.py", repo: "r") }
    let result = FileIndex(many).search("thing", limit: 10, refining: nil)
    #expect(result.matches.count == 10)

    let next = FileIndex(many).search("thingy", limit: 10, refining: result)
    let fresh = FileIndex(many).search("thingy", limit: 10, refining: nil)
    #expect(next.matches == fresh.matches)
  }

  @Test("splitting the work across cores does not change the answer")
  func parallelIsDeterministic() {
    // Enough files to cross the threshold where the work is divided.
    let many = (0..<5000).map { FileMatch(path: "src/module\($0 % 50)/file\($0).py", repo: "r") }
    let index = FileIndex(many)
    #expect(index.matches(for: "file123") == index.matches(for: "file123"))
    #expect(FileIndex(many.reversed()).matches(for: "file123") == index.matches(for: "file123"))
  }
}

@Suite("giving a file an icon")
struct FileIconTests {
  @Test("code gets a code symbol and its language's colour")
  func codeFiles() {
    let python = FileIcon.named(for: "app/api/views.py")
    #expect(python.symbol == "chevron.left.forwardslash.chevron.right")
    #expect(python.colour == "#4B8BBE")

    // The colour is what separates rows that all look like code.
    #expect(FileIcon.named(for: "Grove/AppModel.swift").colour != python.colour)
  }

  @Test("things that are not code get symbols of their own")
  func distinctSymbols() {
    // A shell script, a note and a pile of configuration should not look alike.
    #expect(FileIcon.named(for: "scripts/setup.sh").symbol == "terminal")
    #expect(FileIcon.named(for: "README.md").symbol == "doc.text")
    #expect(FileIcon.named(for: "package.json").symbol == "curlybraces")
    #expect(FileIcon.named(for: "deploy.yaml").symbol == "list.bullet.rectangle")
    #expect(FileIcon.named(for: "Dockerfile").symbol == "shippingbox")
    #expect(FileIcon.named(for: "Makefile").symbol == "hammer")
    #expect(FileIcon.named(for: "schema.sql").symbol == "cylinder")
  }

  @Test("files that are not text at all are recognised too")
  func nonTextFiles() {
    #expect(FileIcon.named(for: "assets/logo.png").symbol == "photo")
    #expect(FileIcon.named(for: "docs/manual.pdf").symbol == "doc.richtext")
    #expect(FileIcon.named(for: "vendor/bundle.tar").symbol == "archivebox")
    #expect(FileIcon.named(for: "data/rows.csv").symbol == "tablecells")
  }

  @Test("a dotfile reads as configuration")
  func dotfiles() {
    #expect(FileIcon.named(for: ".gitattributes").symbol == "terminal")
    #expect(FileIcon.named(for: ".dockerignore").symbol == "gearshape")
  }

  @Test("anything unrecognised gets a plain document and no colour")
  func unknown() {
    // A wrong colour is worse than none: it says a file is something it is not.
    let icon = FileIcon.named(for: "notes")
    #expect(icon.symbol == "doc")
    #expect(icon.colour == nil)
  }

  @Test("case does not matter")
  func caseInsensitive() {
    #expect(FileIcon.named(for: "SETUP.SH") == FileIcon.named(for: "setup.sh"))
    #expect(FileIcon.named(for: "README.MD").symbol == "doc.text")
  }
}
