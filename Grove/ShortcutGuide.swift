import GroveCore
import SwiftUI

/// The shortcuts Grove has, shown where there is nothing else to put.
///
/// Sits under the repo list, as part of the page rather than floating in whatever space
/// is left over — which put it adrift in the lower third of the window. It goes when the
/// terminal opens, since by then the window has a job to do.
///
/// This list is the only place they are written down for a reader, so it has to match
/// what the app actually binds. Anything added to the menus belongs here too.
struct ShortcutGuide: View {
  @Environment(AppModel.self) private var model

  private struct Shortcut: Identifiable {
    let keys: String
    let what: String
    var id: String { keys + what }
  }

  private struct Group: Identifiable {
    let title: String
    let shortcuts: [Shortcut]
    var id: String { title }
  }

  private let groups = [
    Group(
      title: "Workspaces",
      shortcuts: [
        Shortcut(keys: "⌘ N", what: "New workspace"),
        Shortcut(keys: "⌘ ⇧ [ / ]", what: "Previous or next"),
        Shortcut(keys: "⌘ R", what: "Rescan from disk"),
        Shortcut(keys: "⌘ ⇧ E", what: "Open in your editor"),
        Shortcut(keys: "⌘ ⇧ ⌫", what: "Remove it"),
      ]),
    Group(
      title: "Terminal",
      shortcuts: [
        Shortcut(keys: "⌘ J", what: "Show or hide it"),
        Shortcut(keys: "⇧ ↩", what: "New line, no submit"),
        Shortcut(keys: "⌘ ⌫", what: "Delete to line start"),
        Shortcut(keys: "⌘ ← / →", what: "Start or end of line"),
      ]),
    Group(
      title: "Files",
      shortcuts: [
        Shortcut(keys: "⌘ P", what: "Find a file"),
        Shortcut(keys: "⌘ F", what: "Search in this file"),
        Shortcut(keys: "⌘ G", what: "Next match"),
        Shortcut(keys: "⌘ ⇧ G", what: "Previous match"),
        Shortcut(keys: "⌘ E", what: "Open in your editor"),
      ]),
  ]

  var body: some View {
    VStack(alignment: .center, spacing: 10) {
      Text("Shortcuts")
        .font(.headline)
        .foregroundStyle(.secondary)

      HStack(alignment: .top, spacing: 24) {
        ForEach(groups) { group in
          VStack(alignment: .leading, spacing: 7) {
            Text(group.title)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.bottom, 2)

            ForEach(group.shortcuts) { shortcut in
              HStack(spacing: 10) {
                Text(shortcut.keys)
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .frame(width: 78, alignment: .leading)
                Text(shortcut.what)
                  .font(.caption)
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
                Spacer(minLength: 0)
              }
            }
          }
          // Even shares of the width, so three narrow columns do not huddle at the left
          // of a wide window.
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(16)
      .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
      // Held to the width the three columns actually need. Stretched across a wide
      // window the pairs drift apart until a key and what it does stop looking related.
      .frame(maxWidth: 720)
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }
}
