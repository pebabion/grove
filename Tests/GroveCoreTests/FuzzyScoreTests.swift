import Foundation
import Testing

@testable import GroveCore

@Suite("scoring a match the way fzf does")
struct FuzzyScoreTests {
  /// Bonuses from the original text, matching against the folded copy — the way the
  /// index does it. Folding before computing bonuses loses every camelCase hump, which
  /// is how this test caught the index doing exactly that.
  private func score(_ needle: String, _ text: String) -> Int32? {
    FuzzyScore.score(
      FileIndex.folded(needle),
      in: FileIndex.folded(text),
      bonuses: FuzzyScore.bonuses(for: Array(text.utf8)))
  }

  @Test("letters must appear in order")
  func requiresOrder() {
    #expect(score("abc", "a_b_c") != nil)
    #expect(score("cba", "a_b_c") == nil)
    #expect(score("abcd", "abc") == nil)
  }

  @Test("a match after a separator beats one inside a word")
  func prefersWordStarts() {
    // What makes "ps" find people_search rather than the "ps" in "capstone".
    let atBoundary = score("ps", "people_search")
    let inside = score("ps", "capstone_xxxxx")
    #expect(atBoundary != nil)
    #expect(inside != nil)
    #expect(atBoundary! > inside!)
  }

  @Test("a camelCase hump counts as a word start")
  func prefersCamelHumps() {
    // "gtv" has to find GroveTerminalView, which is the whole point of this scoring.
    #expect(score("gtv", "groveterminalview") != nil)
    #expect(score("gtv", "GroveTerminalView")! > score("gtv", "groveterminalview")!)
  }

  @Test("adjacent letters beat scattered ones")
  func prefersRuns() {
    let together = score("sql", "warehouse_sql.py")
    let apart = score("sql", "s_q_l_xxxxxxxxx")
    #expect(together! > apart!)
  }

  @Test("case never has to be guessed at")
  func caseInsensitive() {
    #expect(score("skill", "SKILL.md") != nil)
    #expect(score("SKILL", "skill.md") != nil)
  }

  @Test("the first character counts double at a word start")
  func firstCharacterAmplified() {
    // fzf's bonusFirstCharMultiplier. A query starting where a word starts is a
    // stronger signal than the same letter mid-word.
    #expect(score("s", "search")! > score("s", "users")!)
  }

  @Test("an empty query matches anything, a longer query than the text matches nothing")
  func edges() {
    #expect(score("", "anything") == 0)
    #expect(score("verylongquery", "short") == nil)
  }
}

@Suite("finding files the way an editor does")
struct FuzzyFileSearchTests {
  /// Shaped after the workspace this was tested against.
  private let files = [
    FileMatch(path: "skills/system/people-search/SKILL.md", repo: "agent-graph"),
    FileMatch(path: "agent_graph/graphs/people_search.py", repo: "agent-graph"),
    FileMatch(path: "agent_graph/tools/warehouse_sql.py", repo: "agent-graph"),
    FileMatch(path: "dbt/models/utils/date_spine_two_weeks.sql", repo: "backend"),
    FileMatch(path: "scripts/backfill_investor_duplicates_people.py", repo: "backend"),
    FileMatch(path: "Grove/GroveTerminalView.swift", repo: "grove"),
  ]

  private func best(_ query: String) -> String? {
    FileIndex(files).matches(for: query).first?.path
  }

  @Test("a query of two words finds a file that has both, in either part of the path")
  func twoWords() {
    // The case this was reported for: "people skill" must find
    // skills/system/people-search/SKILL.md. As one continuous subsequence it cannot,
    // because the path holds no space.
    #expect(best("people skill") == "skills/system/people-search/SKILL.md")
  }

  @Test("word order does not matter")
  func orderFree() {
    #expect(best("skill people") == "skills/system/people-search/SKILL.md")
  }

  @Test("a file named after the words wins over one merely filed under them")
  func namePreferred() {
    // "people search" should find people_search.py rather than the SKILL.md in a
    // people-search directory, which is what an editor does too.
    #expect(best("people search") == "agent_graph/graphs/people_search.py")
  }

  @Test("initials still work")
  func initials() {
    #expect(best("gtv") == "Grove/GroveTerminalView.swift")
  }

  @Test("extra whitespace is ignored")
  func whitespace() {
    #expect(best("  people   skill  ") == "skills/system/people-search/SKILL.md")
  }

  @Test("a word that appears nowhere rules the file out")
  func everyWordRequired() {
    #expect(FileIndex(files).matches(for: "people zzzz").isEmpty)
  }
}
