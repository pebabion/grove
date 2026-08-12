import Foundation
import Testing

@testable import GroveCore

@Suite("translating key combinations for a shell")
struct TerminalKeyTests {
  private func bytes(
    _ key: TerminalKeys.Key, command: Bool = false, shift: Bool = false, option: Bool = false,
    control: Bool = false
  ) -> [UInt8]? {
    TerminalKeys.bytes(
      for: .init(
        key: key.rawValue, command: command, shift: shift, option: option, control: control))
  }

  @Test("command and an arrow jump to the start or end of the line")
  func arrowsJump() {
    #expect(bytes(.leftArrow, command: true) == [0x01])  // ^A
    #expect(bytes(.rightArrow, command: true) == [0x05])  // ^E
  }

  @Test("an arrow's own flags do not stop it matching")
  func ignoresFunctionAndNumericPad() {
    // The bug this exists for: macOS puts .function and .numericPad on every arrow key
    // whether or not anyone pressed such a thing. A view comparing the whole modifier set
    // against "command" therefore never matched, and ⌘ + ← did nothing at all. Only the
    // four modifiers a person types with are considered, so there is nothing to ignore.
    let chord = TerminalKeys.Chord(key: TerminalKeys.Key.leftArrow.rawValue, command: true)
    #expect(TerminalKeys.bytes(for: chord) == [0x01])
  }

  @Test("command and backspace delete to the start of the line")
  func deleteToStart() {
    #expect(bytes(.delete, command: true) == [0x15])  // ^U
  }

  @Test("shift and return make a line without submitting")
  func shiftReturn() {
    #expect(bytes(.returnKey, shift: true) == [0x1B, 0x0D])  // ESC CR
  }

  @Test("an unmodified key is left alone")
  func plainKeysPassThrough() {
    #expect(bytes(.leftArrow) == nil)
    #expect(bytes(.rightArrow) == nil)
    #expect(bytes(.delete) == nil)
    #expect(bytes(.returnKey) == nil)
  }

  @Test("option and control are left to the program")
  func otherModifiersPassThrough() {
    // ⌥ + ← is a word jump the shell handles itself, and ^A already means something.
    #expect(bytes(.leftArrow, command: true, option: true) == nil)
    #expect(bytes(.leftArrow, option: true) == nil)
    #expect(bytes(.delete, command: true, control: true) == nil)
  }

  @Test("the wrong combination of shift and command matches nothing")
  func wrongCombinations() {
    #expect(bytes(.leftArrow, command: true, shift: true) == nil)
    #expect(bytes(.returnKey, command: true, shift: true) == nil)
    #expect(bytes(.returnKey, command: true) == nil)
  }

  @Test("keys with no translation are not touched")
  func unknownKeys() {
    #expect(TerminalKeys.bytes(for: .init(key: 0, command: true)) == nil)
    #expect(TerminalKeys.bytes(for: .init(key: 999, command: true)) == nil)
  }
}
