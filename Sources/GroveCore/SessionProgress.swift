import Foundation

/// What a program running in a terminal is reporting about itself.
///
/// Claude Code emits ConEmu-style progress through OSC 9: `9;4;3` while it works
/// and `9;4;0` when it stops. Captured from a real session rather than assumed, and
/// it is the signal that says a turn has finished — far better than watching output
/// go quiet.
public enum SessionProgress: Sendable, Hashable {
  case idle
  case working

  /// Reads the payload of an OSC 9 sequence, e.g. `4;3;` or `4;0;`.
  ///
  /// Returns `nil` for anything that is not a progress report: OSC 9 carries other
  /// things, and a payload Grove does not understand must not be turned into a
  /// state change.
  public static func parse(oscNine payload: String) -> SessionProgress? {
    let fields = payload.split(separator: ";", omittingEmptySubsequences: false)
    guard fields.first == "4", fields.count >= 2, let state = Int(fields[1]) else { return nil }
    // 0 clears it; 1 normal, 2 error, 3 indeterminate and 4 paused all mean busy.
    return state == 0 ? .idle : .working
  }
}
