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
    guard Self.isAvailable, await isAllowed() else { return }

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
    try? await center.add(request)
  }

  /// Asks once, then remembers. Asking on every notification would be a sheet per
  /// turn until the user answered.
  private func isAllowed() async -> Bool {
    if let authorization { return authorization }
    let granted =
      (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
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
