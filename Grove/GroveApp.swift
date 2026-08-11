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
    // Applies on first launch only. After that macOS remembers whatever size the
    // window was left at, so changing this does nothing to an existing install
    // until the saved frame is cleared.
    .defaultSize(width: 1440, height: 920)
    .defaultPosition(.center)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("New Workspace…") {
          NotificationCenter.default.post(name: .newWorkspace, object: nil)
        }
        .keyboardShortcut("n")
      }
      CommandGroup(after: .toolbar) {
        Button(model.terminalCommandTitle) {
          model.toggleTerminal()
        }
        .keyboardShortcut("j", modifiers: .command)
        .disabled(model.selection == nil)

        Button("Rescan") { Task { await model.rescan() } }
          .keyboardShortcut("r")

        Button(model.fileCommandTitle) {
          model.toggleFiles()
        }
        .keyboardShortcut("p")
        .disabled(model.selection == nil)

        Divider()

        Button("Next Workspace") { model.selectWorkspace(offset: 1) }
          .keyboardShortcut("]", modifiers: [.command, .shift])
          .disabled(model.workspaces.count < 2)

        Button("Previous Workspace") { model.selectWorkspace(offset: -1) }
          .keyboardShortcut("[", modifiers: [.command, .shift])
          .disabled(model.workspaces.count < 2)

        Button("Open in Editor") {
          if let workspace = model.selectedWorkspace { model.openInEditor(workspace.url) }
        }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(model.selection == nil)

        // Shift as well as Command, because ⌘ + Backspace belongs to the terminal, where
        // it deletes to the start of the line. A menu shortcut would take it away.
        Button("Remove Workspace…") { model.askToRemoveSelectedWorkspace() }
          .keyboardShortcut(.delete, modifiers: [.command, .shift])
          .disabled(model.selection == nil)
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
