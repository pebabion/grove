import GroveCore
import SwiftUI

/// Placeholder shell. It exists to prove the two things that break a macOS app
/// built on subprocesses: that the bundle builds and signs, and that a window
/// launched from Finder can still find the tools it needs.
struct ContentView: View {
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider()
      toolList
    }
    .frame(minWidth: 520, minHeight: 380)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Grove")
        .font(.largeTitle.weight(.semibold))
      Text("Multi-repo worktree workspaces")
        .foregroundStyle(.secondary)
    }
    .padding(20)
  }

  private var toolList: some View {
    List {
      Section {
        ForEach(environment.toolPaths.inventory(), id: \.tool) { entry in
          HStack {
            Image(systemName: entry.path == nil ? "xmark.circle" : "checkmark.circle.fill")
              .foregroundStyle(entry.path == nil ? Color.secondary : Color.green)
            Text(entry.tool)
              .font(.system(.body, design: .monospaced))
            Spacer()
            Text(entry.path ?? "not found")
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
      } header: {
        HStack {
          Text("Tools")
          if environment.isLoading {
            ProgressView().controlSize(.small)
          }
        }
      } footer: {
        Text(
          "Launched from Finder, an app inherits almost no PATH. "
            + "Grove asks a login shell where these live."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }
}
