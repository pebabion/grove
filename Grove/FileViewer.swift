import AppKit
import GroveCore
import SwiftUI

/// Read-only text view holding an already-coloured string.
///
/// AppKit rather than SwiftUI's `Text`: a `Text` holding a few thousand attributed
/// lines lays out every one of them on every pass, and a source file is exactly that.
/// `NSTextView` also brings the things reading needs anyway — selection, copy, find.
struct SourceTextView: NSViewRepresentable {
  let content: NSAttributedString
  let background: NSColor

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    guard let text = scroll.documentView as? NSTextView else { return scroll }

    text.isEditable = false
    text.isSelectable = true
    text.isRichText = false
    text.drawsBackground = true
    text.textContainerInset = NSSize(width: 8, height: 8)
    // No wrapping: source is written in lines, and folding them makes code unreadable.
    text.isHorizontallyResizable = true
    text.textContainer?.widthTracksTextView = false
    text.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    scroll.hasHorizontalScroller = true
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let text = scroll.documentView as? NSTextView else { return }
    text.backgroundColor = background
    scroll.backgroundColor = background
    guard text.attributedString() != content else { return }
    text.textStorage?.setAttributedString(content)
    text.scroll(.zero)
  }
}

/// Find a file in the workspace and read it.
///
/// Deliberately not an editor. Agents rewrite these files while they are on screen, so
/// anything that could save would need to know what changed underneath it — and Grove
/// already opens a real editor in one click.
struct FileViewer: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let workspace: Workspace

  /// Prepared once when the sheet opens. Searching the raw list instead would redo the
  /// preparation on every keystroke, which is the whole cost.
  @State private var index = FileIndex([])
  @State private var query = ""
  @State private var selection: FileMatch?
  @State private var contents: SourceContents?
  /// Held rather than recomputed: highlighting is about a millisecond per kilobyte, and
  /// a computed property would redo it on every pass over the body.
  @State private var highlighted: HighlightedSource?
  @State private var isLoading = true
  @FocusState private var searchFocused: Bool

  private var matches: [FileMatch] {
    index.matches(for: query)
  }

  var body: some View {
    HSplitView {
      list
      detail
    }
    .frame(minWidth: 900, minHeight: 520)
    .task { await load() }
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
      Divider()

      if isLoading {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(matches, selection: $selection) { file in
          HStack(spacing: 6) {
            RepoSwatch(repo: file.repo, size: 7)
            VStack(alignment: .leading, spacing: 1) {
              Text(file.name)
                .lineLimit(1)
              Text(file.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            }
          }
          .tag(file)
        }
        .listStyle(.sidebar)
      }

      Divider()
      HStack {
        Text(countLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
    }
    .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
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
        Divider()
        body(for: selection)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .task(id: selection) { await read(selection) }
    } else {
      VStack(spacing: 6) {
        Text("Select a file")
          .foregroundStyle(.secondary)
        Text("Read-only. Press ⌘ + E to open it in your editor.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func header(for file: FileMatch) -> some View {
    HStack(spacing: 8) {
      RepoSwatch(repo: file.repo, size: 8)
      Text(file.path)
        .font(.system(.caption, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.head)
        .textSelection(.enabled)
      Spacer()
      Button("Open in Editor") { model.openInEditor(url(of: file)) }
        .buttonStyle(.link)
        .keyboardShortcut("e")
      Button("Done") { dismiss() }
        .keyboardShortcut(.escape, modifiers: [])
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
  }

  @ViewBuilder
  private func body(for file: FileMatch) -> some View {
    switch contents {
    case .text:
      if let highlighted {
        SourceTextView(content: highlighted.text, background: highlighted.background)
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

  private func load() async {
    let found = await model.workspaceFiles(in: workspace)
    // Built off the main actor: twenty-five thousand paths is enough preparation to be
    // worth not doing where the window is drawn.
    index = await Task.detached(priority: .userInitiated) { FileIndex(found) }.value
    isLoading = false
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
      text, path: file.path, fontName: font.fontName, fontSize: font.pointSize)
    guard !Task.isCancelled else { return }
    highlighted = coloured
  }
}
