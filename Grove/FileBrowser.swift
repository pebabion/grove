import AppKit
import GroveCore
import SwiftUI

/// What the reading pane is currently being asked for.
///
/// Both parts change what is displayed, so both have to restart the work: a different
/// file obviously, and a change of wrapping because the paragraph style lives inside the
/// attributed text.
private struct TextRequest: Equatable {
  let file: FileMatch
  let wraps: Bool
}

/// Find a file in the workspace and read it, in the window rather than over it.
///
/// Part of the detail pane, taking the place of the repo list, so the terminal stays
/// below it and the workspace stays selected. A sheet floating over the window blocked
/// everything behind it to do a thing you want to do *while* working.
///
/// Deliberately not an editor. Agents rewrite these files while they are on screen, so
/// anything that could save would need to know what changed underneath it — and Grove
/// already opens a real editor in one click.
struct FileBrowser: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace

  /// Prepared once when the sheet opens. Searching the raw list instead would redo the
  /// preparation on every keystroke, which is the whole cost.
  @State private var index = FileIndex([])
  @State private var query = ""
  /// The last completed search. Held rather than computed, because searching is work
  /// and a computed property would redo it for every pass over the body.
  @State private var result: FileIndex.Result?
  @State private var selection: FileMatch?
  @State private var contents: SourceContents?
  /// Held rather than recomputed: highlighting is about a millisecond per kilobyte, and
  /// a computed property would redo it on every pass over the body.
  @State private var highlighted: HighlightedSource?
  /// The file whose path was just copied, so the button can say so for a moment.
  @State private var copied: FileMatch?
  @State private var isLoading = true
  @FocusState private var searchFocused: Bool

  private var matches: [FileMatch] { result?.matches ?? [] }

  /// Wrapping is on unless it has been turned off.
  private var wraps: Bool { model.library.wrapsSourceText ?? true }

  var body: some View {
    HSplitView {
      list
      detail
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task { await load() }
    // Cancelled and restarted on every keystroke, and the search itself runs away from
    // the main actor. Typing is never waiting on a search, however large the workspace.
    .task(id: query) { await search() }
  }

  private var list: some View {
    VStack(spacing: 0) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Find a file", text: $query)
          .textFieldStyle(.plain)
          .focused($searchFocused)
          .onSubmit { if selection == nil { selection = matches.first } }
      }
      .padding(8)
      Divider().overlay(Theme.divider)

      if isLoading {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if matches.isEmpty, !query.isEmpty, result != nil {
        Text("No file matches")
          .font(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(matches, selection: $selection) { file in
          HStack(spacing: 7) {
            FileTypeIcon(path: file.path)
            VStack(alignment: .leading, spacing: 1) {
              Text(file.name)
                .lineLimit(1)
              // The repo moves in here now that its colour is no longer the row's
              // marker, so it is still clear which of the workspace's repos a file
              // belongs to.
              HStack(spacing: 4) {
                RepoSwatch(repo: file.repo, size: 6)
                Text(file.path)
                  .lineLimit(1)
                  .truncationMode(.head)
              }
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
          }
          .tag(file)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
      }

      Divider().overlay(Theme.divider)
      HStack {
        Text(countLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
    }
    .frame(minWidth: 220, idealWidth: 300, maxWidth: 420)
    .background(Theme.surface.opacity(0.55))
    .onAppear { searchFocused = true }
  }

  private var countLabel: String {
    let shown = matches.count
    return shown == index.count ? "\(index.count) files" : "\(shown) of \(index.count) files"
  }

  @ViewBuilder
  private var detail: some View {
    if let selection {
      VStack(spacing: 0) {
        header(for: selection)
        Divider().overlay(Theme.divider)
        body(for: selection)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // Re-read when wrapping changes too: the paragraph style is part of the text, so
      // the colouring has to be redone to change it.
      .task(id: TextRequest(file: selection, wraps: wraps)) { await read(selection) }
    } else {
      VStack(spacing: 6) {
        Text("Select a file")
          .foregroundStyle(.secondary)
        Text("Read-only. ⌘ + E opens the selected file in your editor.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func header(for file: FileMatch) -> some View {
    HStack(spacing: 10) {
      // The name first and plainly, then everything above it dimmed. The eye wants the
      // file; the path is where it lives, which is context rather than the headline.
      Button {
        copy(file)
      } label: {
        HStack(spacing: 6) {
          FileTypeIcon(path: file.path, size: 12)
          Text(file.name)
            .fontWeight(.medium)
          Text(parent(of: file))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.head)
            // Gives way before the button does, rather than shouldering it aside.
            .layoutPriority(-1)
        }
        .font(.caption)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Copy \(copyable(file))")

      // Beside the path, because that is what it copies. It moves with the path's length,
      // which for a control usually argues against it — but a button that copies the thing
      // next to it belongs next to it.
      Button {
        copy(file)
      } label: {
        Image(systemName: copied == file ? "checkmark" : "doc.on.doc")
          .font(.caption)
          .foregroundStyle(copied == file ? Theme.confirm : Theme.detail)
      }
      .buttonStyle(.plain)
      .help("Copy \(copyable(file))")

      Spacer(minLength: 12)

      HStack(spacing: 12) {
        Button {
          model.library.wrapsSourceText = !wraps
          model.saveLibrary()
        } label: {
          Image(systemName: wraps ? "text.alignleft" : "arrow.left.and.right")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(wraps ? "Stop wrapping long lines" : "Wrap long lines")

        Button("Open in Editor") { model.openInEditor(url(of: file)) }
          .buttonStyle(.link)
          .font(.caption)
          .keyboardShortcut("e")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  /// The repo and directories above the file, as one dimmed trail.
  private func parent(of file: FileMatch) -> String {
    let directory = (file.path as NSString).deletingLastPathComponent
    return directory.isEmpty ? file.repo : "\(file.repo)/\(directory)"
  }

  /// What gets copied: the path from the workspace root, repo and all.
  ///
  /// Not the absolute path, which is long and mostly noise, and not the repo-relative
  /// one, which is ambiguous across a workspace's repos. This is what a shell or an
  /// agent started in the workspace can open as it stands.
  private func copyable(_ file: FileMatch) -> String {
    "\(file.repo)/\(file.path)"
  }

  private func copy(_ file: FileMatch) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(copyable(file), forType: .string)

    copied = file
    Task {
      try? await Task.sleep(for: .seconds(2))
      // Only clear it if nothing else has been copied since.
      if copied == file { copied = nil }
    }
  }

  @ViewBuilder
  private func body(for file: FileMatch) -> some View {
    switch contents {
    case .text:
      if let highlighted {
        SourceTextView(
          content: highlighted.text, background: highlighted.background, wraps: wraps)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    case .toolarge(let bytes):
      unavailable(
        "This file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), "
          + "too large to show here. Open it in your editor.")
    case .binary:
      unavailable("This is not a text file.")
    case .unreadable(let reason):
      unavailable(reason)
    case nil:
      ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func unavailable(_ message: String) -> some View {
    Text(message)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding()
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func url(of file: FileMatch) -> URL {
    workspace.url.appending(path: file.repo).appending(path: file.path)
  }

  /// Runs the search off the main actor, a beat after the typing stops.
  ///
  /// The pause is what stops a burst of keystrokes starting a search each: the task is
  /// cancelled and replaced before the sleep is over, so only the last one runs. The
  /// previous result is passed along so the search can narrow against it instead of
  /// starting from every file again.
  private func search() async {
    let typed = query
    if !typed.isEmpty {
      try? await Task.sleep(for: .milliseconds(25))
      guard !Task.isCancelled else { return }
    }

    let searching = index
    let previous = result
    let found = await Task.detached(priority: .userInitiated) {
      searching.search(typed, limit: 200, refining: previous)
    }.value

    guard !Task.isCancelled else { return }
    result = found
    // Keep a selection that is still on screen, and offer the best match otherwise.
    if let selection, !found.matches.contains(selection) {
      self.selection = nil
    }
  }

  private func load() async {
    let found = await model.workspaceFiles(in: workspace)
    // Built off the main actor: twenty-five thousand paths is enough preparation to be
    // worth not doing where the window is drawn.
    index = await Task.detached(priority: .userInitiated) { FileIndex(found) }.value
    isLoading = false
    await search()
  }

  /// Reads and colours the file, both away from the main actor.
  ///
  /// Once per selection rather than per redraw. A megabyte of Python is around a second
  /// of highlighting, so doing it where the window is drawn would freeze it, and doing
  /// it in the view's body would repeat it for every unrelated change.
  private func read(_ file: FileMatch) async {
    contents = nil
    highlighted = nil

    let target = url(of: file)
    let read = await Task.detached(priority: .userInitiated) { SourceFile().read(target) }.value
    guard !Task.isCancelled else { return }
    contents = read

    guard case .text(let text) = read else { return }
    let font = model.terminalFont
    let coloured = await SourceHighlighter.shared.highlight(
      text, path: file.path, fontName: font.fontName, fontSize: font.pointSize, wraps: wraps)
    guard !Task.isCancelled else { return }
    highlighted = coloured
  }
}
