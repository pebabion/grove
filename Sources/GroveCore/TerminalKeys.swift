import Foundation

/// What a key combination should send to a shell.
///
/// Here rather than in the view so it can be tested. The bug that put it here: arrow keys
/// carry `.function` and `.numericPad` in their modifiers whether or not anyone pressed
/// anything of the sort, so a view comparing the whole modifier set against "command"
/// never matched, and ⌘ + ← did nothing. Only the four modifiers anyone types with are
/// looked at.
public enum TerminalKeys {
  /// The keys macOS numbers, for the ones Grove translates.
  public enum Key: UInt16, Sendable {
    case delete = 51
    case leftArrow = 123
    case rightArrow = 124
    case returnKey = 36
  }

  /// A key with the modifiers that matter. Whether the key is on a numeric pad, or is a
  /// function key, is not one of them.
  public struct Chord: Sendable, Equatable {
    public let key: UInt16
    public let command: Bool
    public let shift: Bool
    public let option: Bool
    public let control: Bool

    public init(
      key: UInt16, command: Bool = false, shift: Bool = false, option: Bool = false,
      control: Bool = false
    ) {
      self.key = key
      self.command = command
      self.shift = shift
      self.option = option
      self.control = control
    }
  }

  /// The bytes to send, or nil to leave the key alone.
  ///
  /// The translations are the ones terminals conventionally provide, so readline and the
  /// TUIs built on it behave the way people expect:
  ///
  /// - ⌘ + ← and ⌘ + → become ^A and ^E, start and end of line
  /// - ⌘ + Backspace becomes ^U, delete to the start of the line
  /// - Shift + Return becomes ESC CR, a new line without submitting
  public static func bytes(for chord: Chord) -> [UInt8]? {
    guard let key = Key(rawValue: chord.key) else { return nil }

    // Nothing here is defined with option or control held; passing those through matters
    // more than guessing at them.
    guard !chord.option, !chord.control else { return nil }

    switch key {
    case .leftArrow where chord.command && !chord.shift:
      return [0x01]
    case .rightArrow where chord.command && !chord.shift:
      return [0x05]
    case .delete where chord.command && !chord.shift:
      return [0x15]
    case .returnKey where chord.shift && !chord.command:
      return [0x1B, 0x0D]
    default:
      return nil
    }
  }
}
