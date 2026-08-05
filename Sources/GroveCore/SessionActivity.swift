import Foundation

/// Something a session did that is worth telling the user about.
public enum SessionSignal: Sendable, Hashable {
  /// The program stopped working and is waiting — finished, or asking a question.
  /// This is all a progress report can tell us.
  case waiting
  /// The program rang the terminal bell, which only ever means "look at me".
  case rangBell
  /// Claude Code said it wants an answer. Only a hook can distinguish this.
  case needsInput
  /// Claude Code said the turn is over.
  case finished
}

/// Watches one session's progress reports and decides when it wants attention.
///
/// The rule is the transition, not the state: a session that has been idle since it
/// started has not finished anything, so only working → idle counts.
///
/// Both "I am done" and "I need your permission" arrive the same way, because an
/// agent that stops to ask a question has stopped working. Grove does not try to
/// tell them apart — from the other side of the room they are the same event, which
/// is that the session is waiting for you.
public struct SessionActivityMonitor: Sendable {
  /// How long a session must work before finishing is worth a notification.
  ///
  /// Without this, a program that reports progress around something instant makes
  /// Grove announce a completion the user never waited for.
  public static let minimumWork: TimeInterval = 2

  private var progress: SessionProgress = .idle
  private var workingSince: Date?

  public init() {}

  public var isWorking: Bool { progress == .working }

  /// Feeds in a progress report and returns a signal if one is due.
  public mutating func received(_ reported: SessionProgress, at now: Date) -> SessionSignal? {
    defer { progress = reported }

    switch (progress, reported) {
    case (.idle, .working):
      workingSince = now
      return nil
    case (.working, .idle):
      let started = workingSince
      workingSince = nil
      guard let started, now.timeIntervalSince(started) >= Self.minimumWork else { return nil }
      return .waiting
    default:
      // Repeats of the state it is already in, which arrive often: a percentage
      // ticking upwards is several `working` reports in a row.
      return nil
    }
  }
}
