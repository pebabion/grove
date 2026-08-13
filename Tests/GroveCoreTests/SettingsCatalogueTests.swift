import Testing

@testable import GroveCore

/// The catalogue is what the settings window draws from and what its search looks through,
/// so a mistake here is either a row with no words or a setting nobody can find.
@Suite("settings catalogue")
struct SettingsCatalogueTests {
  @Test("every entry has an id of its own")
  func idsAreUnique() {
    // Rows are looked up by id, and a duplicate would silently draw the wrong words.
    let ids = SettingsCatalogue.entries.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  @Test("every entry says what it is and what it does")
  func nothingIsBlank() {
    for entry in SettingsCatalogue.entries {
      #expect(!entry.title.isEmpty, "\(entry.id)")
      #expect(!entry.detail.isEmpty, "\(entry.id) has no description")
      // A description that repeats the title tells a reader nothing they cannot see.
      #expect(entry.detail != entry.title, "\(entry.id)")
    }
  }

  @Test("every category has something in it")
  func noEmptyCategories() {
    // An empty category is a heading with nothing under it, which reads as broken.
    for category in SettingsCategory.allCases {
      #expect(!SettingsCatalogue.entries(in: category).isEmpty, "\(category.label)")
    }
  }

  @Test("every category names itself and says what it is for")
  func categoriesAreDescribed() {
    for category in SettingsCategory.allCases {
      #expect(!category.label.isEmpty)
      #expect(!category.blurb.isEmpty, "\(category.label)")
      #expect(!category.symbol.isEmpty, "\(category.label)")
    }
  }

  @Test("an empty search finds everything, and whitespace is not a search")
  func emptySearch() {
    #expect(SettingsCatalogue.matching("").count == SettingsCatalogue.entries.count)
    #expect(SettingsCatalogue.matching("   ").count == SettingsCatalogue.entries.count)
  }

  @Test("a word in the title finds the setting")
  func findsByTitle() {
    let found = SettingsCatalogue.matching("branch prefix").map(\.id)
    #expect(found.contains("branchPrefix"))
  }

  @Test("a word only in the description finds it too")
  func findsByDetail() {
    // "lazygit" appears in what the mouse setting explains, not in its name.
    #expect(SettingsCatalogue.matching("lazygit").map(\.id) == ["terminalMouse"])
  }

  @Test("a word nobody wrote down still finds it, through the keywords")
  func findsByKeyword() {
    // Someone looking for this will type "color", or "eyes", or "glare".
    let byColor = SettingsCatalogue.matching("color").map(\.id)
    #expect(byColor.contains("terminalBackground"))
    #expect(SettingsCatalogue.matching("glare").map(\.id).contains("terminalBackground"))
    #expect(SettingsCatalogue.matching("gh").map(\.id).contains("toolPaths"))
  }

  @Test("a group's name lists what is in it")
  func findsByCategory() {
    let found = SettingsCatalogue.matching("terminal")
    #expect(found.contains { $0.category == .terminal })
    // Every terminal setting, not just the ones with the word in them.
    let ids = Set(found.map(\.id))
    for entry in SettingsCatalogue.entries(in: .terminal) {
      #expect(ids.contains(entry.id), "\(entry.id) missing from a search for its own group")
    }
  }

  @Test("all the words have to match, in any order")
  func everyWordCounts() {
    // "mouse events" both appear in one setting; "mouse branch" is in none.
    #expect(!SettingsCatalogue.matching("mouse events").isEmpty)
    #expect(SettingsCatalogue.matching("mouse branch").isEmpty)
    // Order is not something anyone should have to get right.
    let one = SettingsCatalogue.matching("terminal mouse").map(\.id)
    let other = SettingsCatalogue.matching("mouse terminal").map(\.id)
    #expect(one == other)
  }

  @Test("case and accents make no difference")
  func folding() {
    #expect(SettingsCatalogue.matching("BRANCH").map(\.id).contains("branchPrefix"))
    #expect(SettingsCatalogue.matching("Wórkspace").map(\.id).contains("workspaceRoot"))
  }

  @Test("a search for nothing in particular finds nothing")
  func noMatches() {
    #expect(SettingsCatalogue.matching("kubernetes").isEmpty)
    #expect(SettingsCatalogue.categories(matching: "kubernetes").isEmpty)
  }

  @Test("the categories a search matches come back in sidebar order")
  func categoryOrder() {
    // The list under the search has to read in the same order as the sidebar beside it.
    let all = SettingsCatalogue.categories(matching: "")
    #expect(all == SettingsCategory.allCases)
    let some = SettingsCatalogue.categories(matching: "colour")
    #expect(some == SettingsCategory.allCases.filter(some.contains))
  }

  @Test("results keep the order they are written in")
  func resultOrder() {
    let found = SettingsCatalogue.matching("")
    #expect(found.map(\.id) == SettingsCatalogue.entries.map(\.id))
  }

  @Test("every entry can be looked up by its own id")
  func lookup() {
    for entry in SettingsCatalogue.entries {
      #expect(SettingsCatalogue.entry(entry.id) == entry)
    }
  }
}
