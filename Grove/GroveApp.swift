import GroveCore
import SwiftUI

@main
struct GroveApp: App {
  @State private var environment = AppEnvironment()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(environment)
        .task { await environment.start() }
    }
    .defaultSize(width: 900, height: 600)
    .commands {
      CommandGroup(after: .newItem) {
        Button("Rescan Tools") {
          Task { await environment.start() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
      }
    }
  }
}

/// App-wide state. Currently just the resolved tool paths; the repo library and
/// workspace scanner land here next.
@Observable
@MainActor
final class AppEnvironment {
  var toolPaths = ToolPaths()
  var isLoading = true

  func start() async {
    isLoading = true
    toolPaths = await ToolPaths.discover()
    isLoading = false
  }

  /// A `Git` bound to the discovered `git`, or `nil` if there isn't one.
  var git: Git? {
    guard let executable = toolPaths.location(of: "git") else { return nil }
    return Git(executable: executable, environment: toolPaths.processEnvironment())
  }
}
