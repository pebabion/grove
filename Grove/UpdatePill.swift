import GroveCore
import SwiftUI

/// The "Update Available" button, shown only when there is one.
///
/// Deliberately a button rather than a dialog: an update is worth noticing and
/// never worth interrupting for.
struct UpdatePill: View {
  @Environment(AppModel.self) private var model
  let update: AvailableUpdate

  var body: some View {
    Button {
      Task { await model.installUpdate() }
    } label: {
      HStack(spacing: 6) {
        if model.isDownloadingUpdate {
          ProgressView()
            .controlSize(.small)
            .tint(Theme.title)
        } else {
          Image(systemName: "shippingbox.fill")
        }
        Text(label)
          .fontWeight(.medium)
      }
      .font(.caption)
      .foregroundStyle(Theme.title)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Theme.highlight, in: Capsule())
    }
    .buttonStyle(.plain)
    .disabled(model.isDownloadingUpdate)
    .help("Running \(model.currentVersion) · installs \(update.version) and restarts")
    .contextMenu {
      Link("What's new in \(update.version.description)", destination: update.pageURL)
      Button("Dismiss") { model.dismissUpdate() }
    }
  }

  /// Names the step in progress, so a pause during verify or install does not
  /// look like nothing happening.
  private var label: String {
    if let stage = model.updateStage {
      return "\(stage.rawValue) \(update.version.description)…"
    }
    return "Update Available: \(update.version.description)"
  }
}
