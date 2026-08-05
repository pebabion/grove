import GroveCore
import SwiftUI

/// A branch's pull request as a filled pill, or a quiet note that it has none.
///
/// "No pull request" is worth saying out loud. It is the difference between work
/// that is under review and work that exists only on this machine, which is
/// exactly what you want to know before tearing a workspace down.
struct PullRequestBadge: View {
  let reading: PullRequestReading

  var body: some View {
    if let pr = reading.pullRequest {
      Link(destination: URL(string: pr.url) ?? URL(filePath: "/")) {
        HStack(spacing: 4) {
          OcticonImage(icon: icon(for: pr), size: 11)
          // Verbatim: Text takes a LocalizedStringKey, which formats an
          // interpolated integer for the locale — so 1786 arrived as "1,786".
          Text(verbatim: "#\(pr.number)")
            .font(.caption.weight(.semibold))
          if let review = reviewMark(for: pr) {
            Image(systemName: review)
              .font(.caption2)
              .opacity(0.9)
          }
        }
        // White on the state colour, the way GitHub draws these.
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint(for: pr), in: Capsule())
      }
      .buttonStyle(.plain)
      .help("\(pr.state.capitalized) · opens on GitHub")
    } else {
      Text("no PR")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
  }

  private func icon(for pr: PullRequest) -> Octicon {
    if pr.isDraft { return .draft }
    switch pr.state {
    case "MERGED": return .merged
    case "CLOSED": return .closed
    default: return .open
    }
  }

  /// GitHub's own state colours: green open, purple merged, red closed, grey draft.
  private func tint(for pr: PullRequest) -> Color {
    if pr.isDraft { return Color(nsColor: .systemGray) }
    switch pr.state {
    case "MERGED": return Color(red: 0.51, green: 0.35, blue: 0.79)
    case "CLOSED": return Color(red: 0.81, green: 0.30, blue: 0.28)
    default: return Color(red: 0.18, green: 0.60, blue: 0.35)
    }
  }

  /// Review state, shown only while it still matters. A merged pull request's
  /// approval is history.
  private func reviewMark(for pr: PullRequest) -> String? {
    guard pr.state == "OPEN" else { return nil }
    switch pr.reviewDecision {
    case "APPROVED": return "checkmark.seal.fill"
    case "CHANGES_REQUESTED": return "exclamationmark.bubble.fill"
    default: return nil
    }
  }
}
