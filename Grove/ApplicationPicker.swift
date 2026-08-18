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

  /// Lives only in the settings window, so it wears that window's clothes rather than the
  /// system's: a bordered blue-grey button beside cream text is the one thing that reads as
  /// having come from somewhere else.
  var body: some View {
    HStack(spacing: 8) {
      if !title.isEmpty {
        Text(title)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(Theme.title)
      }
      if let path, let icon = Self.icon(for: path) {
        Image(nsImage: icon)
          .resizable()
          .frame(width: 15, height: 15)
      }
      Text(display)
        .font(.system(size: 12))
        .foregroundStyle(path == nil ? Theme.faint : Theme.detail)
        .lineLimit(1)
        .truncationMode(.middle)

      Button("Choose…") { choose() }
        .buttonStyle(ThemedButtonStyle())
      if path != nil {
        Button("Clear") { path = nil }
          .buttonStyle(ThemedButtonStyle())
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
