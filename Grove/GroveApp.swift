import GroveCore
import SwiftUI

@main
struct GroveApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(model)
        .task { await model.load() }
    }
    .defaultSize(width: 1000, height: 680)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Workspace…") {
          NotificationCenter.default.post(name: .newWorkspace, object: nil)
        }
        .keyboardShortcut("n")
      }
      CommandGroup(after: .toolbar) {
        Button("Rescan") { Task { await model.rescan() } }
          .keyboardShortcut("r")
      }
    }

    Settings {
      SettingsView()
        .environment(model)
    }
  }
}

extension Notification.Name {
  static let newWorkspace = Notification.Name("grove.newWorkspace")
}
