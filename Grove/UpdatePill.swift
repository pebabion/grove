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
      Task { await model.downloadUpdate() }
    } label: {
      HStack(spacing: 6) {
        if model.isDownloadingUpdate {
          ProgressView()
            .controlSize(.small)
            .tint(.white)
        } else {
          Image(systemName: "shippingbox.fill")
        }
        Text(
          model.isDownloadingUpdate
            ? "Downloading \(update.version.description)…"
            : "Update Available: \(update.version.description)"
        )
        .fontWeight(.medium)
      }
      .font(.caption)
      .foregroundStyle(.white)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(Color.accentColor, in: Capsule())
    }
    .buttonStyle(.plain)
    .disabled(model.isDownloadingUpdate)
    .help("Running \(model.currentVersion) · downloads the disk image")
    .contextMenu {
      Link("What's new in \(update.version.description)", destination: update.pageURL)
      Button("Dismiss") { model.availableUpdate = nil }
    }
  }
}
