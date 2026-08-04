import GroveCore
import SwiftUI

/// A branch's pull request, or a quiet note that it has none.
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
          OcticonImage(icon: icon(for: pr))
          Text("#\(pr.number)")
            .font(.caption.monospacedDigit())
          if let review = reviewMark(for: pr) {
            Image(systemName: review.symbol)
              .foregroundStyle(review.tint)
          }
        }
        .foregroundStyle(tint(for: pr))
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
    if pr.isDraft { return .secondary }
    switch pr.state {
    case "MERGED": return .purple
    case "CLOSED": return .red
    default: return .green
    }
  }

  /// Review state, shown only while it still matters. A merged pull request's
  /// approval is history.
  private func reviewMark(for pr: PullRequest) -> (symbol: String, tint: Color)? {
    guard pr.state == "OPEN" else { return nil }
    switch pr.reviewDecision {
    case "APPROVED": return ("checkmark.seal.fill", .green)
    case "CHANGES_REQUESTED": return ("exclamationmark.bubble.fill", .orange)
    default: return nil
    }
  }
}
