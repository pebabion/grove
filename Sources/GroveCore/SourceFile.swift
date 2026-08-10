import Foundation

/// A file's text, or the reason there is none to show.
///
/// Reading a file for display is not the same as reading one to work with: a viewer
/// meets whatever happens to be in the repo, including a 400MB fixture and a
/// compiled binary sitting in a directory nobody cleaned. Both have to end in a
/// sentence rather than a spinner or a wall of replacement characters.
public enum SourceContents: Sendable, Equatable {
  case text(String)
  /// Too big to highlight or lay out, with the size that made it so.
  case toolarge(bytes: Int)
  /// Not text at all.
  case binary
  case unreadable(String)

  public var text: String? {
    if case .text(let value) = self { return value }
    return nil
  }
}

/// Reads files for display.
public struct SourceFile: Sendable {
  /// The largest file worth showing.
  ///
  /// Highlighting runs highlight.js over the whole file at once, so this is a limit on
  /// patience as much as on memory. Anything past it belongs in a real editor, which
  /// Grove can already open.
  public static let sizeLimit = 1_000_000

  /// How much of the front of a file is inspected before calling it binary.
  static let sniffLength = 8000

  public init() {}

  public func read(_ url: URL, limit: Int = SourceFile.sizeLimit) -> SourceContents {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    if let size = attributes?[.size] as? Int, size > limit {
      return .toolarge(bytes: size)
    }
    guard let data = try? Data(contentsOf: url) else {
      return .unreadable("Could not read \(url.lastPathComponent).")
    }
    // Checked again against the bytes actually read: the attribute is a claim about a
    // file that may have been rewritten since, which in these worktrees it may well be.
    if data.count > limit { return .toolarge(bytes: data.count) }
    return Self.decode(data)
  }

  /// Turns bytes into text, or says why it will not.
  static func decode(_ data: Data) -> SourceContents {
    guard !data.isEmpty else { return .text("") }
    if looksBinary(data) { return .binary }

    if let text = String(data: data, encoding: .utf8) { return .text(text) }
    // Latin-1 maps every byte to something, so this cannot fail. A file that is not
    // UTF-8 is usually an old file rather than an unreadable one, and showing it
    // slightly wrong beats refusing it.
    if let text = String(data: data, encoding: .isoLatin1) { return .text(text) }
    return .unreadable("This file is not in an encoding Grove can read.")
  }

  /// Whether the front of the file contains a byte no text file has.
  ///
  /// A NUL is the giveaway, and it is what `git` itself looks for. Only the front is
  /// examined, because reading 400MB to answer the question defeats the purpose.
  static func looksBinary(_ data: Data) -> Bool {
    data.prefix(sniffLength).contains(0)
  }
}
