import GroveCore
import SwiftUI

/// What the user has typed into the settings search, read by every row.
///
/// An environment value rather than a parameter threaded through six views: a row decides
/// for itself whether it is still on screen, which is what keeps the search working without
/// each category having to know how to filter its own contents.
private struct SettingsQueryKey: EnvironmentKey {
  static let defaultValue = ""
}

extension EnvironmentValues {
  var settingsQuery: String {
    get { self[SettingsQueryKey.self] }
    set { self[SettingsQueryKey.self] = newValue }
  }
}

/// One setting: its name, what it does, and the control on the right.
///
/// The words come from the catalogue rather than the call site, so a search cannot look for
/// text the row does not show.
struct SettingRow<Control: View>: View {
  @Environment(\.settingsQuery) private var query
  let entry: SettingEntry
  /// A cap for a control that would otherwise stretch. Most take what they need.
  var controlWidth: CGFloat?
  @ViewBuilder let control: () -> Control

  init(
    _ id: String, controlWidth: CGFloat? = nil,
    @ViewBuilder control: @escaping () -> Control
  ) {
    self.entry = SettingsCatalogue.entry(id)
    self.controlWidth = controlWidth
    self.control = control
  }

  var body: some View {
    if entry.matches(query) {
      HStack(alignment: .top, spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text(entry.title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(SettingsTheme.title)
          Text(entry.detail)
            .font(.system(size: 12))
            .foregroundStyle(SettingsTheme.detail)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // `maxWidth` expands a view rather than capping it, so setting one on every
        // control took 210pt off every description and wrapped them two words early.
        control()
          .frame(width: controlWidth, alignment: .trailing)
          .fixedSize(horizontal: controlWidth == nil, vertical: false)
      }
      .padding(.vertical, SettingsTheme.rowSpacing)
      Divider().overlay(SettingsTheme.divider)
    }
  }
}

/// A row whose control needs the full width — a list, a preview, a stack of paths.
///
/// The title and description sit above rather than beside it. Same search behaviour, since
/// it reads the same entry.
struct SettingBlock<Content: View>: View {
  @Environment(\.settingsQuery) private var query
  let entry: SettingEntry
  @ViewBuilder let content: () -> Content

  init(_ id: String, @ViewBuilder content: @escaping () -> Content) {
    self.entry = SettingsCatalogue.entry(id)
    self.content = content
  }

  var body: some View {
    if entry.matches(query) {
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          Text(entry.title)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(SettingsTheme.title)
          Text(entry.detail)
            .font(.system(size: 12))
            .foregroundStyle(SettingsTheme.detail)
            .fixedSize(horizontal: false, vertical: true)
        }
        content()
      }
      .padding(.vertical, SettingsTheme.rowSpacing)
      Divider().overlay(SettingsTheme.divider)
    }
  }
}

/// A note under a row: a warning, a live value, whatever the row has to add.
struct SettingNote: View {
  let text: String
  var tint: Color = SettingsTheme.faint

  var body: some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(tint)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The settings window: categories down the left, the chosen one on the right.
struct SettingsShell: View {
  @State private var category: SettingsCategory = .repos
  @State private var query = ""
  @FocusState private var searching: Bool

  /// While searching, every category with a hit is shown at once — hunting for a setting
  /// you cannot name is exactly when you do not know which group it is in.
  private var shown: [SettingsCategory] {
    query.trimmingCharacters(in: .whitespaces).isEmpty
      ? [category]
      : SettingsCatalogue.categories(matching: query)
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider().overlay(SettingsTheme.divider)
      content
    }
    .background(SettingsTheme.background)
    .frame(width: 880, height: 620)
    .onAppear { searching = true }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      searchField
        .padding(10)

      ScrollView {
        VStack(spacing: 1) {
          ForEach(SettingsCategory.allCases) { item in
            categoryRow(item)
          }
        }
        .padding(.horizontal, 8)
      }

      Spacer(minLength: 0)

      // What the search is doing, or how much there is to search. Not a keyboard hint:
      // the menu bar is offered a key before any view is, so a ⌘F drawn here would be
      // claiming something this window cannot do.
      HStack(spacing: 6) {
        Text(footnote)
          .font(.system(size: 11))
        Spacer()
      }
      .foregroundStyle(SettingsTheme.faint)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .overlay(alignment: .top) { Divider().overlay(SettingsTheme.divider) }
    }
    .frame(width: SettingsTheme.sidebarWidth)
    .background(SettingsTheme.surface.opacity(0.55))
  }

  /// A count rather than a shortcut, and it changes as the search narrows.
  private var footnote: String {
    let total = SettingsCatalogue.entries.count
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
      return "\(total) settings"
    }
    return "\(SettingsCatalogue.matching(query).count) of \(total) match"
  }

  private var searchField: some View {
    HStack(spacing: 6) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundStyle(SettingsTheme.faint)
      TextField("Search settings…", text: $query)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(SettingsTheme.title)
        .focused($searching)
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(SettingsTheme.faint)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: SettingsTheme.corner).fill(SettingsTheme.background))
    .overlay(
      RoundedRectangle(cornerRadius: SettingsTheme.corner)
        .strokeBorder(searching ? SettingsTheme.accent : SettingsTheme.divider, lineWidth: 1)
    )
    .onExitCommand { query = "" }
  }

  private func categoryRow(_ item: SettingsCategory) -> some View {
    let chosen = item == category && query.isEmpty
    return Button {
      query = ""
      category = item
    } label: {
      HStack(spacing: 8) {
        Image(systemName: item.symbol)
          .font(.system(size: 11))
          .frame(width: 14)
        Text(item.label)
          .font(.system(size: 12.5))
        Spacer(minLength: 0)
        if !query.isEmpty {
          // How many of this group's settings the search matched, so the sidebar says
          // where the results are rather than only the list below.
          let hits = SettingsCatalogue.matching(query).filter { $0.category == item }.count
          if hits > 0 {
            Text("\(hits)")
              .font(.system(size: 10, weight: .medium, design: .monospaced))
              .foregroundStyle(SettingsTheme.faint)
          }
        }
      }
      .foregroundStyle(chosen ? SettingsTheme.title : SettingsTheme.detail)
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 5).fill(chosen ? SettingsTheme.selection : .clear)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var content: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(shown) { item in
          VStack(alignment: .leading, spacing: 4) {
            Text(item.label)
              .font(.system(size: 20, weight: .semibold))
              .foregroundStyle(SettingsTheme.title)
            Text(item.blurb)
              .font(.system(size: 12))
              .foregroundStyle(SettingsTheme.detail)
          }
          .padding(.top, item == shown.first ? 0 : 24)
          .padding(.bottom, 6)

          body(of: item)
        }

        if shown.isEmpty {
          VStack(spacing: 6) {
            Text("Nothing matches “\(query)”")
              .font(.system(size: 13, weight: .medium))
              .foregroundStyle(SettingsTheme.title)
            Text("Try a word from the setting's name, or the group it might be in.")
              .font(.system(size: 11.5))
              .foregroundStyle(SettingsTheme.detail)
          }
          .frame(maxWidth: .infinity)
          .padding(.top, 60)
        }
      }
      .padding(.horizontal, SettingsTheme.contentPadding)
      .padding(.vertical, 20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .environment(\.settingsQuery, query)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  @ViewBuilder
  private func body(of category: SettingsCategory) -> some View {
    switch category {
    case .repos: LibrarySettings()
    case .general: GeneralSettings()
    case .terminal: TerminalSettings()
    case .notifications: NotificationSettings()
    case .tools: ToolSettings()
    case .about: AboutSettings()
    }
  }
}
