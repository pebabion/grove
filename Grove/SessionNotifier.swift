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

  func post(_ signal: SessionSignal, session: String, workspace: String, id: UUID) async {
    guard Self.isAvailable else {
      Log.sessions.problem("no bundle identifier, so notifications are unavailable")
      return
    }
    guard await isAllowed() else {
      Log.sessions.problem("not allowed to notify")
      return
    }

    let content = UNMutableNotificationContent()
    content.title = session
    content.subtitle = workspace
    content.body =
      switch signal {
      case .waiting: "Waiting for you"
      case .rangBell: "Needs your input"
      }
    content.sound = .default
    content.userInfo = [sessionKey: id.uuidString]
    // Grouped by session, so ten turns in one session do not stack up ten cards.
    content.threadIdentifier = id.uuidString

    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil)
    do {
      try await center.add(request)
      Log.sessions.note("posted for \(session)")
    } catch {
      Log.sessions.problem("posting failed: \(error.localizedDescription)")
    }
  }

  /// Posts one immediately, for checking that notifications arrive at all.
  ///
  /// Worth having as a button: the ordinary path stays silent while you are looking
  /// at the session, so "nothing happened" is both the correct behaviour and the
  /// symptom of it being broken, and there is no way to tell which from the outside.
  func postTest() async {
    await post(.waiting, session: "Test", workspace: "Grove", id: UUID())
  }

  /// Asks once, then remembers. Asking on every notification would be a sheet per
  /// turn until the user answered.
  private func isAllowed() async -> Bool {
    if let authorization { return authorization }
    var granted = false
    do {
      granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
    } catch {
      Log.sessions.problem("asking permission failed: \(error.localizedDescription)")
    }
    Log.sessions.note("permission granted: \(granted)")
    authorization = granted
    return granted
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
