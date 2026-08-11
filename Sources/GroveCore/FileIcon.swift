import Foundation

/// How a file should look in a list: a symbol for what kind of thing it is, and a
/// colour for which language it is written in.
///
/// Two pieces because they answer different questions. The symbol says at a glance
/// whether a row is code, a note, a picture or a pile of configuration; the colour tells
/// Python from TypeScript among rows that all look like code. A symbol per language
/// would be the other approach, and macOS has no Python glyph to offer.
public struct FileIcon: Sendable, Hashable {
  /// An SF Symbol name.
  public let symbol: String
  /// The language's own colour, as GitHub draws it, or nil for anything unrecognised.
  public let colour: String?

  public init(symbol: String, colour: String?) {
    self.symbol = symbol
    self.colour = colour
  }

  /// Conventional colours, so a Python file looks the way a Python file looks
  /// everywhere else. Taken from GitHub's language colours, lightened where the
  /// original disappears against a dark background.
  private static let colours: [String: String] = [
    "python": "#4B8BBE",
    "swift": "#F05138",
    "typescript": "#3178C6",
    "javascript": "#F1E05A",
    "go": "#00ADD8",
    "rust": "#DEA584",
    "ruby": "#E5535B",
    "java": "#B07219",
    "kotlin": "#A97BFF",
    "c": "#8AB4F8",
    "cpp": "#F34B7D",
    "objectivec": "#438EFF",
    "csharp": "#68217A",
    "php": "#8892BF",
    "bash": "#89E051",
    "sql": "#E38C00",
    "json": "#CBCB41",
    "yaml": "#CB171E",
    "ini": "#6D8086",
    "xml": "#E37933",
    "css": "#563D7C",
    "scss": "#C6538C",
    "less": "#1D365D",
    "markdown": "#9DC3E6",
    "dockerfile": "#2496ED",
    "makefile": "#427819",
    "terraform": "#7B42BC",
    "graphql": "#E10098",
    "lua": "#000080",
    "perl": "#0298C3",
    "r": "#198CE7",
    "scala": "#C22D40",
    "dart": "#00B4AB",
    "elixir": "#6E4A7E",
    "erlang": "#B83998",
    "haskell": "#5E5086",
    "protobuf": "#C1C1C1",
    "groovy": "#4298B8",
    "diff": "#88A0A8",
  ]

  /// Which symbol suits a language, by what working with it feels like rather than by
  /// what it compiles to.
  private static let symbols: [String: String] = [
    "bash": "terminal",
    "markdown": "doc.text",
    "json": "curlybraces",
    "yaml": "list.bullet.rectangle",
    "ini": "slider.horizontal.3",
    "sql": "cylinder",
    "xml": "chevron.left.slash.chevron.right",
    "css": "paintbrush",
    "scss": "paintbrush",
    "less": "paintbrush",
    "dockerfile": "shippingbox",
    "makefile": "hammer",
    "terraform": "cube.transparent",
    "graphql": "point.3.connected.trianglepath.dotted",
    "diff": "plusminus",
    "protobuf": "arrow.left.arrow.right",
  ]

  /// Files that are not source at all, recognised by extension.
  private static let byExtension: [String: FileIcon] = [
    "png": FileIcon(symbol: "photo", colour: nil),
    "jpg": FileIcon(symbol: "photo", colour: nil),
    "jpeg": FileIcon(symbol: "photo", colour: nil),
    "gif": FileIcon(symbol: "photo", colour: nil),
    "svg": FileIcon(symbol: "photo", colour: "#E37933"),
    "ico": FileIcon(symbol: "photo", colour: nil),
    "pdf": FileIcon(symbol: "doc.richtext", colour: nil),  // the one place a badge fits
    "zip": FileIcon(symbol: "archivebox", colour: nil),
    "gz": FileIcon(symbol: "archivebox", colour: nil),
    "tar": FileIcon(symbol: "archivebox", colour: nil),
    "lock": FileIcon(symbol: "lock", colour: nil),
    "txt": FileIcon(symbol: "doc.text", colour: nil),
    "csv": FileIcon(symbol: "tablecells", colour: nil),
    "env": FileIcon(symbol: "key", colour: "#89E051"),
  ]

  /// The icon for a path.
  public static func named(for path: String) -> FileIcon {
    let file = (path as NSString).lastPathComponent.lowercased()
    let ext = (file as NSString).pathExtension

    if let language = SourceLanguage.named(for: path) {
      return FileIcon(
        // Anything recognised as a language but with no symbol of its own is code, and
        // code is what the angle brackets mean.
        symbol: symbols[language] ?? "chevron.left.forwardslash.chevron.right",
        colour: colours[language])
    }
    if !ext.isEmpty, let known = byExtension[ext] { return known }
    // A dotfile with no extension is configuration more often than not.
    if file.hasPrefix("."), ext.isEmpty {
      return FileIcon(symbol: "gearshape", colour: nil)
    }
    return FileIcon(symbol: "doc", colour: nil)
  }
}
