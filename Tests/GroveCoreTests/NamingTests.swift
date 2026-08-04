import Foundation
import Testing

@testable import GroveCore

@Suite("branch names")
struct BranchNamingTests {
  @Test("kebab-cases what someone types")
  func kebabCases() {
    #expect(WorkspaceNaming.branchName("Improve TiDB Performance") == "improve-tidb-performance")
    #expect(WorkspaceNaming.branchName("Fix  the   thing") == "fix-the-thing")
    #expect(WorkspaceNaming.branchName("snake_case_name") == "snake-case-name")
  }

  @Test("keeps the slashes branches are namespaced with")
  func keepsSlashes() {
    #expect(WorkspaceNaming.branchName("kelvin/Improve TiDB") == "kelvin/improve-tidb")
    #expect(WorkspaceNaming.branchName("feat/scout/usage") == "feat/scout/usage")
  }

  @Test("stays typeable")
  func staysTypeable() {
    // A trailing hyphen survives, or typing "scout-" then a word would fight the
    // field. So does a trailing slash, for the same reason.
    #expect(WorkspaceNaming.branchName("scout-") == "scout-")
    #expect(WorkspaceNaming.branchName("kelvin/") == "kelvin/")
    // No hyphen is inserted straight after a separator or at the very start.
    #expect(WorkspaceNaming.branchName("kelvin/ thing") == "kelvin/thing")
    #expect(WorkspaceNaming.branchName("  leading") == "leading")
  }

  @Test("a suggested branch is already kebab-cased")
  func suggestionIsKebab() {
    let library = RepoLibrary(branchPrefix: "kelvin")

    let suggestion = library.suggestedBranch(for: "Improve TiDB Performance")

    #expect(suggestion == "kelvin/improve-tidb-performance")
    // Feeding a suggestion back through must not change it, or the create sheet
    // would think Grove's own text had been edited by hand.
    #expect(WorkspaceNaming.branchName(suggestion) == suggestion)
  }

  @Test("no prefix means no leading slash")
  func withoutPrefix() {
    #expect(RepoLibrary().suggestedBranch(for: "Some Work") == "some-work")
  }
}

@Suite("editor setting")
struct EditorSettingTests {
  @Test("an older editor name resolves to the app it meant")
  func migratesName() {
    var library = RepoLibrary(editor: "Zed")

    library.migrateEditorName { name in "/Applications/\(name).app" }

    #expect(library.editorPath == "/Applications/Zed.app")
    // Cleared, so the migration does not run again and overwrite a later choice.
    #expect(library.editor == nil)
  }

  @Test("leaves a path already chosen alone")
  func doesNotOverwriteChoice() {
    var library = RepoLibrary(editor: "Zed", editorPath: "/Applications/Cursor.app")

    library.migrateEditorName { _ in "/Applications/Zed.app" }

    #expect(library.editorPath == "/Applications/Cursor.app")
  }

  @Test("drops a name for an app that is not installed")
  func unresolvableName() {
    var library = RepoLibrary(editor: "NotInstalled")

    library.migrateEditorName { _ in nil }

    #expect(library.editorPath == nil)
    #expect(library.editor == nil)
  }

  @Test("finds an installed application by name")
  func findsRealApplication() {
    // Calculator ships in /System/Applications on every Mac. Finder does not —
    // it lives in /System/Library/CoreServices, which is not somewhere anyone
    // picks an editor from.
    #expect(RepoLibrary.applicationPath(named: "Calculator") != nil)
    #expect(RepoLibrary.applicationPath(named: "Calculator.app") != nil)
    #expect(RepoLibrary.applicationPath(named: "DefinitelyNotAnApp") == nil)
  }
}

@Suite("the branch actually created")
struct FinalBranchTests {
  @Test("kebab-cases and tidies what was typed")
  func tidiesTypedText() {
    #expect(WorkspaceNaming.finalBranchName("kelvin/Improve TiDB ") == "kelvin/improve-tidb")
    #expect(WorkspaceNaming.finalBranchName("Fix The Thing") == "fix-the-thing")
  }

  @Test("drops dangling separators the typing rules allowed")
  func dropsDanglingSeparators() {
    // branchName keeps these so the field does not fight mid-word; this is where
    // they go.
    #expect(WorkspaceNaming.finalBranchName("kelvin/scout-") == "kelvin/scout")
    #expect(WorkspaceNaming.finalBranchName("kelvin/") == "kelvin")
    #expect(WorkspaceNaming.finalBranchName("kelvin//thing") == "kelvin/thing")
    #expect(WorkspaceNaming.finalBranchName("-leading-") == "leading")
  }

  @Test("nothing typed means nothing to create")
  func emptyStaysEmpty() {
    #expect(WorkspaceNaming.finalBranchName("") == "")
    #expect(WorkspaceNaming.finalBranchName("   ") == "")
    #expect(WorkspaceNaming.finalBranchName("///") == "")
  }

  @Test("leaves an already-clean name alone")
  func idempotent() {
    let clean = "kelvin/improve-tidb-performance"

    #expect(WorkspaceNaming.finalBranchName(clean) == clean)
    #expect(WorkspaceNaming.finalBranchName(WorkspaceNaming.finalBranchName(clean)) == clean)
  }
}
