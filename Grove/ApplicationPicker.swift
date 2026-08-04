import AppKit
import GroveCore
import SwiftUI

/// Chooses which application an action hands a folder to.
///
/// Shows the app's real icon and name, so a setting that has gone stale — the app
/// moved or was deleted — is visible rather than only failing later.
struct ApplicationPicker: View {
  let title: String
  /// Shown when nothing is chosen.
  let fallback: String
  @Binding var path: String?

  @State private var choosing = false

  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 8) {
        if let path, let icon = Self.icon(for: path) {
          Image(nsImage: icon)
            .resizable()
            .frame(width: 16, height: 16)
        }
        Text(display)
          .foregroundStyle(path == nil ? .secondary : .primary)
          .lineLimit(1)

        Spacer()

        Button("Choose…") { choose() }
        if path != nil {
          Button("Clear") { path = nil }
        }
      }
    }
  }

  private var display: String {
    guard let path else { return fallback }
    guard FileManager.default.fileExists(atPath: path) else {
      return "\((path as NSString).lastPathComponent) — missing"
    }
    return (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
  }

  private static func icon(for path: String) -> NSImage? {
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    return NSWorkspace.shared.icon(forFile: path)
  }

  /// An open panel rather than SwiftUI's fileImporter: it can start in
  /// /Applications and treat a bundle as a file to pick, not a folder to enter.
  private func choose() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(filePath: "/Applications")
    panel.prompt = "Choose"
    panel.message = "Pick the application to open workspaces with."
    if panel.runModal() == .OK, let chosen = panel.url {
      path = chosen.path
    }
  }
}
