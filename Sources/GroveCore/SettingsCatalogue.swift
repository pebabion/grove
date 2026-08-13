import Foundation

/// The groups the settings window is divided into.
public enum SettingsCategory: String, CaseIterable, Codable, Sendable, Identifiable {
  case repos
  case general
  case terminal
  case notifications
  case tools
  case about

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .repos: "Repos"
    case .general: "General"
    case .terminal: "Terminal"
    case .notifications: "Notifications"
    case .tools: "Tools"
    case .about: "About"
    }
  }

  /// One line under the category's name, saying what the group is for.
  public var blurb: String {
    switch self {
    case .repos: "What Grove can make worktrees from, and how each one is set up."
    case .general: "Where workspaces go, what names they get, what opens them."
    case .terminal: "How the embedded terminal looks and behaves."
    case .notifications: "When Grove interrupts you."
    case .tools: "Where Grove found the commands it runs."
    case .about: "What this copy is, and where it keeps things."
    }
  }

  public var symbol: String {
    switch self {
    case .repos: "shippingbox"
    case .general: "gearshape"
    case .terminal: "apple.terminal"
    case .notifications: "bell"
    case .tools: "wrench.and.screwdriver"
    case .about: "info.circle"
    }
  }
}

/// One setting: what it is called, what it does, and what to search it by.
///
/// The text lives here rather than in the view so that a search can find a setting without
/// the view having been built, and so the row and the search agree by construction — the
/// row draws its title from this entry. Two copies of the same words would drift.
public struct SettingEntry: Sendable, Hashable, Identifiable {
  public let id: String
  public let category: SettingsCategory
  public let title: String
  /// The sentence under the title. Says what happens, not what the control is.
  public let detail: String
  /// Words someone might search for that the title and detail do not contain.
  public let keywords: [String]

  public init(
    id: String, category: SettingsCategory, title: String, detail: String,
    keywords: [String] = []
  ) {
    self.id = id
    self.category = category
    self.title = title
    self.detail = detail
    self.keywords = keywords
  }

  /// Whether this setting answers a search.
  ///
  /// Every word has to be found somewhere, in any order and any field — "mouse term" finds
  /// the mouse setting under Terminal. Folding is what makes a search for "notifications"
  /// match "Notifications", and searching the category too is what makes typing a group's
  /// name list everything in it.
  public func matches(_ query: String) -> Bool {
    let words = query.folded.split(separator: " ").map(String.init)
    guard !words.isEmpty else { return true }
    let haystack = ([title, detail, category.label] + keywords).map(\.folded)
    return words.allSatisfy { word in haystack.contains { $0.contains(word) } }
  }
}

extension String {
  /// Lowercased, without accents, for comparing what people type against what is written.
  var folded: String {
    folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
  }
}

/// Every setting Grove has, in the order it is shown.
public enum SettingsCatalogue {
  public static let entries: [SettingEntry] = [
    // Repos
    SettingEntry(
      id: "library", category: .repos, title: "Repositories",
      detail: "Clones Grove can make worktrees from. Each records what to fork from and "
        + "how to prepare a fresh worktree.",
      keywords: ["repo", "clone", "add", "remove", "library", "setup", "teardown", "hook"]),

    // General
    SettingEntry(
      id: "workspaceRoot", category: .general, title: "Workspace folder",
      detail: "Where workspace folders are created.",
      keywords: ["root", "path", "directory", "worktrees", "location"]),
    SettingEntry(
      id: "branchPrefix", category: .general, title: "Branch prefix",
      detail: "Prepended to the branch name a new workspace gets.",
      keywords: ["git", "naming", "author", "username"]),
    SettingEntry(
      id: "editorApp", category: .general, title: "Open with",
      detail: "The Open button hands the workspace folder to this application.",
      keywords: ["editor", "vscode", "zed", "xcode", "finder", "application"]),
    SettingEntry(
      id: "terminalApp", category: .general, title: "Terminal app",
      detail: "Which application Open in Terminal uses.",
      keywords: ["iterm", "ghostty", "warp", "shell", "external"]),

    // Terminal
    SettingEntry(
      id: "terminalFont", category: .terminal, title: "Font",
      detail: "A prompt built from Nerd Font glyphs needs a font that has them, or macOS "
        + "substitutes them one at a time and the sizes stop matching.",
      keywords: ["typeface", "monospace", "nerd", "glyph", "family"]),
    SettingEntry(
      id: "terminalFontSize", category: .terminal, title: "Font size",
      detail: "How large terminal text is, in points.",
      keywords: ["size", "points", "zoom", "bigger", "smaller"]),
    SettingEntry(
      id: "terminalBackground", category: .terminal, title: "Background",
      detail: "Light text on pure black glows at the edges of the glyphs, which is what "
        + "makes a terminal tiring to read for long. Charcoal is far enough off black to "
        + "stop it.",
      keywords: ["colour", "color", "black", "charcoal", "contrast", "dark", "eyes", "glare"]),
    SettingEntry(
      id: "terminalForeground", category: .terminal, title: "Text colour",
      detail: "Applies to text a program leaves uncoloured, such as a shell or git. "
        + "Claude Code sets its own colours, so only the background reaches it.",
      keywords: ["foreground", "colour", "color", "white", "grey", "gray"]),
    SettingEntry(
      id: "terminalMouse", category: .terminal, title: "Send mouse events to programs",
      detail: "Leave this off to select text: the selection is thrown away on every chunk "
        + "of output while mouse events are being sent. Turn it on for programs that read "
        + "the mouse themselves, such as vim or lazygit.",
      keywords: ["mouse", "selection", "copy", "vim", "lazygit", "reporting", "click"]),

    // Notifications
    SettingEntry(
      id: "notify", category: .notifications, title: "Tell me when a session is waiting",
      detail: "Grove notifies you when a session finishes or stops to ask something, "
        + "unless you are already looking at it. Either way it keeps a dot in the sidebar.",
      keywords: ["notification", "banner", "alert", "claude", "hook", "agent", "waiting"]),

    // Tools
    SettingEntry(
      id: "toolPaths", category: .tools, title: "Command paths",
      detail: "An app launched from Finder inherits almost no PATH, so Grove asks your "
        + "login shell where these live. Only git is required.",
      keywords: ["git", "gh", "path", "shell", "which", "override", "yarn", "node"]),

    // About
    SettingEntry(
      id: "version", category: .about, title: "Version",
      detail: "Grove checks for a newer release every five minutes and offers it in the "
        + "window. Nothing is replaced until the download matches the published digest.",
      keywords: ["update", "upgrade", "release", "install", "check"]),
    SettingEntry(
      id: "locations", category: .about, title: "Where things are",
      detail: "The log says what Grove did and when, which is the first place to look.",
      keywords: ["log", "folder", "path", "diagnostics", "reveal"]),
  ]

  /// The entry with this id. A missing id is a programming mistake, so it reports one
  /// rather than drawing an empty row.
  public static func entry(_ id: String) -> SettingEntry {
    guard let found = entries.first(where: { $0.id == id }) else {
      preconditionFailure("no setting called \(id)")
    }
    return found
  }

  public static func entries(in category: SettingsCategory) -> [SettingEntry] {
    entries.filter { $0.category == category }
  }

  /// What a search finds, in catalogue order. An empty search finds everything.
  public static func matching(_ query: String) -> [SettingEntry] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return entries }
    return entries.filter { $0.matches(trimmed) }
  }

  /// The categories a search has anything to show for, in sidebar order.
  public static func categories(matching query: String) -> [SettingsCategory] {
    let found = Set(matching(query).map(\.category))
    return SettingsCategory.allCases.filter { found.contains($0) }
  }
}
