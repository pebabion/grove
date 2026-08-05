import Foundation
import Testing

@testable import GroveCore

@Suite("login shell")
struct UserShellTests {
  @Test("reads the shell from the password database")
  func readsPasswordDatabase() throws {
    // The same source dscl reports and other editors use. Reading SHELL instead
    // gave /bin/zsh inside a bundled app, because launchd hands a GUI app no SHELL.
    let shell = try #require(UserShell.fromPasswordDatabase)

    #expect(shell.hasPrefix("/"))
    #expect(FileManager.default.isExecutableFile(atPath: shell))
  }

  @Test("prefers the account's shell over the environment")
  func preferesAccountShell() throws {
    let account = try #require(UserShell.fromPasswordDatabase)

    #expect(UserShell.path == account)
  }

  @Test("always returns something runnable")
  func alwaysRunnable() {
    #expect(FileManager.default.isExecutableFile(atPath: UserShell.path))
  }
}
