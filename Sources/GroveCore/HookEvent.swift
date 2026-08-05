import Foundation

/// Something Claude Code reported about itself through a hook.
///
/// This is the precise signal. A progress report says only that work stopped, which
/// is the same whether the agent finished or paused to ask a question. A hook says
/// which, and brings the wording with it.
public struct HookEvent: Sendable, Equatable {
  public enum Reason: Sendable, Equatable {
    case needsInput
    case finished
  }

  public let reason: Reason
  /// Where the agent is working, which is how the event finds its session.
  public let directory: URL
  /// Claude Code's own wording, such as "Claude is waiting for your input".
  public let message: String?

  public init(reason: Reason, directory: URL, message: String?) {
    self.reason = reason
    self.directory = directory
    self.message = message
  }

  /// Reads one hook payload, or nothing if it is not an event worth reporting.
  ///
  /// Deliberately forgiving. The payload is written by a different program on its own
  /// release schedule: a live capture had no `type` field at all, though the
  /// documentation lists one, so nothing here may depend on a field being present.
  /// An event that cannot be understood is dropped rather than guessed at.
  public static func decode(_ data: Data) -> HookEvent? {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let payload = object as? [String: Any],
      let event = payload["hook_event_name"] as? String,
      let cwd = payload["cwd"] as? String, !cwd.isEmpty
    else { return nil }

    let message = (payload["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let type = payload["type"] as? String

    guard let reason = reason(event: event, type: type) else { return nil }
    return HookEvent(reason: reason, directory: URL(fileURLWithPath: cwd), message: message)
  }

  private static func reason(event: String, type: String?) -> Reason? {
    switch event {
    case "Stop":
      return .finished
    case "Notification":
      switch type {
      // Signing in is not something a session is waiting on the user for.
      case "auth_success": return nil
      case "agent_completed": return .finished
      // Every other notification, named or not, is Claude Code asking for a human.
      default: return .needsInput
      }
    default:
      return nil
    }
  }
}
