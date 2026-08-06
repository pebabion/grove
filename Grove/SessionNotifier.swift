import AppKit
import GroveCore
import UserNotifications

/// Which session a notification belongs to. Outside the class because a delegate
/// callback arrives off the main actor and cannot read main-actor state.
private let sessionKey = "grove.session"

/// Posts a macOS notification when a session wants attention, and takes you there
/// when you click it.
///
/// Permission is asked for the first time there is something to say, not at launch.
/// A permission sheet before the user has done anything is the fastest way to get
/// notifications denied for good.
@MainActor
final class SessionNotifier {
  /// Called with a session id when the user clicks a notification.
  var onOpen: (@MainActor (UUID) -> Void)?

  private let center = UNUserNotificationCenter.current()
  private var authorization: Bool?
  private let handler = Handler()

  /// Notifications need a bundle identifier, so this is nil when Grove runs as a
  /// bare binary rather than an app — `swift run`, or a unit test host.
  private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

  init() {
    guard Self.isAvailable else { return }
    handler.notifier = self
    center.delegate = handler
  }

  /// Posts a notification, asking permission first if it has not been asked yet.
  ///
  /// Completion handlers rather than the async API throughout. `UNUserNotificationCenter`
  /// is not Sendable on every toolchain that builds this, so awaiting one of its
  /// methods from the main actor counts as sending it across isolation and does not
  /// compile — it built locally and failed in CI. Called this way it never leaves the
  /// main actor at all.
  func post(
    _ signal: SessionSignal, session: String, workspace: String, id: UUID, saying: String? = nil
  ) {
    guard Self.isAvailable else {
      Log.sessions.problem("no bundle identifier, so notifications are unavailable")
      return
    }

    allowed { [weak self] granted in
      guard let self else { return }
      guard granted else {
        Log.sessions.problem("not allowed to notify")
        return
      }
      deliver(signal, session: session, workspace: workspace, id: id, saying: saying)
    }
  }

  private func deliver(
    _ signal: SessionSignal, session: String, workspace: String, id: UUID, saying: String?
  ) {
    let content = UNMutableNotificationContent()
    content.title = session
    content.subtitle = workspace
    // Claude Code's own wording when it gave any: "Claude is waiting for your
    // input" says more than anything Grove would write in its place.
    let groveWords: String =
      switch signal {
      case .waiting: "Waiting for you"
      case .rangBell, .needsInput: "Needs your input"
      case .finished: "Finished"
      }
    content.body = saying ?? groveWords
    content.sound = .default
    content.userInfo = [sessionKey: id.uuidString]
    // Grouped by session, so ten turns in one session do not stack up ten cards.
    content.threadIdentifier = id.uuidString

    // Keyed by session, so a later signal replaces the earlier one rather than
    // stacking beside it. That is also what keeps the terminal's vaguer "waiting"
    // from sitting under Claude Code's more precise reason for the same moment.
    let request = UNNotificationRequest(
      identifier: id.uuidString, content: content, trigger: nil)
    // @Sendable for the same reason as everywhere else callbacks arrive: the closure
    // must not carry main-actor isolation into a queue that is not the main one.
    center.add(request) { @Sendable error in
      if let error {
        Task { @MainActor in
          Log.sessions.problem("posting failed: \(error.localizedDescription)")
        }
      } else {
        Task { @MainActor in Log.sessions.note("posted for \(session)") }
      }
    }
  }

  /// Asks once, then remembers. Asking on every notification would be a sheet per
  /// turn until the user answered.
  private func allowed(_ done: @escaping @MainActor (Bool) -> Void) {
    if let authorization {
      done(authorization)
      return
    }
    center.requestAuthorization(options: [.alert, .sound, .badge]) { @Sendable granted, error in
      Task { @MainActor in
        if let error {
          Log.sessions.problem("asking permission failed: \(error.localizedDescription)")
        }
        Log.sessions.note("permission granted: \(granted)")
        self.authorization = granted
        done(granted)
      }
    }
  }

  fileprivate func open(sessionID: String) {
    guard let id = UUID(uuidString: sessionID) else { return }
    NSApp.activate(ignoringOtherApps: true)
    onOpen?(id)
  }

  /// `UNUserNotificationCenterDelegate` is an `NSObject` protocol, so it cannot be
  /// the notifier itself without making that a class inheriting NSObject.
  private final class Handler: NSObject, UNUserNotificationCenterDelegate {
    weak var notifier: SessionNotifier?

    /// Shows the notification even when Grove is the app in front.
    ///
    /// Without this, macOS accepts a notification from the frontmost app and then
    /// silently declines to draw it — `add` succeeds, nothing appears, and there is
    /// no error anywhere to explain it. Grove needs the banner in exactly that case:
    /// looking at one workspace while a session in another finishes is the whole
    /// point, and Grove is still the front app.
    func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler:
        @escaping (UNNotificationPresentationOptions) ->
        Void
    ) {
      completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping () -> Void
    ) {
      let id = response.notification.request.content.userInfo[sessionKey] as? String
      let notifier = notifier
      if let id {
        Task { @MainActor in notifier?.open(sessionID: id) }
      }
      // Called here rather than inside the Task: the handler is not Sendable, so it
      // cannot cross into another isolation, and nothing about opening a session
      // needs to finish before AppKit is told the click was dealt with.
      completionHandler()
    }
  }
}
