import Foundation

/// Which language a file is written in, named the way highlight.js names it.
///
/// Kept here rather than beside the view so it can be tested without a highlighter,
/// and so the guesses are written down in one place instead of scattered through a
/// switch in a SwiftUI body.
public enum SourceLanguage {
  /// By extension, lowercased. Only entries highlight.js recognises are worth having:
  /// a name it does not know highlights nothing and costs a round trip to find out.
  private static let byExtension: [String: String] = [
    "swift": "swift",
    "py": "python", "pyi": "python",
    "rb": "ruby",
    "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript",
    "ts": "typescript", "tsx": "typescript", "mts": "typescript",
    "go": "go",
    "rs": "rust",
    "java": "java",
    "kt": "kotlin", "kts": "kotlin",
    "c": "c", "h": "c",
    "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp",
    "m": "objectivec", "mm": "objectivec",
    "cs": "csharp",
    "php": "php",
    "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash",
    "sql": "sql",
    "json": "json",
    "yml": "yaml", "yaml": "yaml",
    "toml": "ini", "ini": "ini", "cfg": "ini", "conf": "ini",
    "xml": "xml", "plist": "xml", "svg": "xml",
    "html": "xml", "htm": "xml",
    "css": "css", "scss": "scss", "less": "less",
    "md": "markdown", "markdown": "markdown",
    "diff": "diff", "patch": "diff",
    "graphql": "graphql", "gql": "graphql",
    "lua": "lua",
    "pl": "perl", "pm": "perl",
    "r": "r",
    "scala": "scala",
    "dart": "dart",
    "ex": "elixir", "exs": "elixir",
    "erl": "erlang",
    "hs": "haskell",
    "tf": "terraform", "tfvars": "terraform",
    "proto": "protobuf",
    "gradle": "groovy",
    "make": "makefile", "mk": "makefile",
    "env": "bash",
  ]

  /// By whole filename, for the files that carry their type in their name rather than
  /// an extension.
  private static let byName: [String: String] = [
    "dockerfile": "dockerfile",
    "makefile": "makefile",
    "gemfile": "ruby",
    "rakefile": "ruby",
    "podfile": "ruby",
    "brewfile": "ruby",
    "package.json": "json",
    "cargo.lock": "ini",
    ".gitignore": "bash",
    ".gitattributes": "bash",
    ".env": "bash",
    ".zshrc": "bash",
    ".bashrc": "bash",
  ]

  /// The language for a path, or nil to show it without highlighting.
  ///
  /// Nil rather than a guess: highlighting a file as the wrong language is worse than
  /// leaving it plain, because the colours then argue with the content.
  public static func named(for path: String) -> String? {
    let file = (path as NSString).lastPathComponent
    let lowercased = file.lowercased()

    if let named = byName[lowercased] { return named }
    // Dockerfile.web, Makefile.local, .env.production — the type is the first part.
    // Tried with and without a leading dot, since the table holds ".env" but splitting
    // on dots drops it.
    if let prefix = lowercased.split(separator: ".").first, !prefix.isEmpty {
      if let named = byName[String(prefix)] ?? byName["." + prefix] { return named }
    }

    let ext = (lowercased as NSString).pathExtension
    guard !ext.isEmpty else { return nil }
    if let named = byExtension[ext] { return named }

    // .env.production leaves an extension of "production", so try the part before it.
    let parts = lowercased.split(separator: ".")
    if parts.count > 2, let named = byExtension[String(parts[parts.count - 2])] {
      return named
    }
    return nil
  }
}
