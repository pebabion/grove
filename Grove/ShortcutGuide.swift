import GroveCore
import SwiftUI

/// The shortcuts Grove has, shown where there is nothing else to put.
///
/// A workspace with the terminal and the files both closed leaves most of the window
/// empty, and a shortcut nobody knows about is a shortcut nobody uses. It goes away the
/// moment either is opened, and can be dismissed for good once it has done its job.
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
        Shortcut(keys: "⌘ ⇧ [ / ]", what: "Previous or next workspace"),
        Shortcut(keys: "⌘ R", what: "Rescan from disk"),
        Shortcut(keys: "⌘ ⇧ E", what: "Open in your editor"),
        Shortcut(keys: "⌘ ⇧ ⌫", what: "Remove this workspace"),
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
        Shortcut(keys: "⌘ G", what: "Next match, ⇧ for previous"),
        Shortcut(keys: "⌘ E", what: "Open in your editor"),
      ]),
  ]

  var body: some View {
    VStack(spacing: 18) {
      HStack(alignment: .top, spacing: 40) {
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
              }
            }
          }
        }
      }

      Button("Hide these") {
        model.library.hidesShortcutGuide = true
        model.saveLibrary()
      }
      .buttonStyle(.link)
      .font(.caption)
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}
