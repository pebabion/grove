import GroveCore
import SwiftUI

/// The settings window.
///
/// A sidebar of categories and rows of title, description and control, rather than a
/// `TabView` of `Form`s. Two things the old shape could not do: say what a setting does
/// without being asked — a `Form` footer describes a whole section, so half the settings had
/// no explanation of their own — and be searched, which is the only way to find a setting
/// whose group you cannot guess.
struct SettingsView: View {
  var body: some View { SettingsShell() }
}

// MARK: - Repos

/// The repo library: what Grove can make worktrees from, and how to set each up.
struct LibrarySettings: View {
  @Environment(AppModel.self) private var model
  @State private var selection: String?
  @State private var showingPicker = false
  @State private var removing: String?

  var body: some View {
    SettingBlock("library") {
      VStack(spacing: 0) {
        if model.library.repos.isEmpty {
          Text("No repos yet. Add a clone to get started.")
            .font(.system(size: 11.5))
            .foregroundStyle(SettingsTheme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
        }

        ForEach(model.library.repos) { repo in
          repoRow(repo)
          if repo.name != model.library.repos.last?.name {
            Divider().overlay(SettingsTheme.divider.opacity(0.6))
          }
        }
      }
      .background(RoundedRectangle(cornerRadius: 8).fill(SettingsTheme.surface.opacity(0.5)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsTheme.divider, lineWidth: 1))

      HStack(spacing: 8) {
        Button("Add a repo…") { showingPicker = true }
          .buttonStyle(SettingsButtonStyle())
        if let selection, model.library[selection] != nil {
          Button("Remove \(selection)") { removing = selection }
            .buttonStyle(SettingsButtonStyle())
        }
        Spacer()
        Text("\(model.library.repos.count) in the library")
          .font(.system(size: 11))
          .foregroundStyle(SettingsTheme.faint)
      }

      // The editor sits under the list rather than beside it: the pane already scrolls,
      // and a split view inside it would be a second thing to scroll.
      if let selection, model.library[selection] != nil {
        RepoEditor(name: selection)
          .padding(.top, 4)
      }
    }
    .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result {
        Task { await model.addRepoToLibrary(at: url) }
      }
    }
    // Removing a repo used to happen on one click with no word about what it does
    // to the worktrees already made from it.
    .confirmationDialog(
      "Remove \(removing ?? "") from the library?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    ) {
      Button("Remove", role: .destructive) {
        if let removing {
          model.removeRepoFromLibrary(removing)
          if selection == removing { selection = nil }
        }
        removing = nil
      }
      Button("Cancel", role: .cancel) { removing = nil }
    } message: {
      Text(
        "The clone and any worktrees already made from it stay where they are. "
          + "Grove just stops offering it for new workspaces."
      )
    }
  }

  private func repoRow(_ repo: RepoEntry) -> some View {
    let chosen = selection == repo.name
    return Button {
      selection = chosen ? nil : repo.name
    } label: {
      HStack(spacing: 8) {
        RepoSwatch(repo: repo.name, size: 8)
        Text(repo.name)
          .font(.system(size: 12.5, weight: chosen ? .semibold : .regular))
          .foregroundStyle(SettingsTheme.title)
        Text(repo.path)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(SettingsTheme.faint)
          .lineLimit(1)
          .truncationMode(.head)
        Spacer(minLength: 8)
        if !FileManager.default.fileExists(atPath: repo.url.path) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(SettingsTheme.warning)
            .help("This clone is no longer at that path")
        }
        Image(systemName: chosen ? "chevron.down" : "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(SettingsTheme.faint)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(chosen ? SettingsTheme.selection.opacity(0.6) : .clear)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// Editor for one library entry.
///
/// Identified by name rather than by position. A view holding an index outlives the
/// arrangement it was resolved from: deleting a repo left this one subscripting past
/// the end of the array, which crashed the app.
struct RepoEditor: View {
  @Environment(AppModel.self) private var model
  let name: String

  @State private var showingVariables = false

  private var repo: RepoEntry? { model.library[name] }

  var body: some View {
    if let repo {
      editor(for: repo)
    } else {
      // Removed while its editor was open. Nothing to edit and nothing to report.
      SettingNote(text: "This repo is no longer in the library.")
    }
  }

  private func editor(for repo: RepoEntry) -> some View {
    VStack(alignment: .leading, spacing: 14) {
      field("Clone") {
        HStack(spacing: 8) {
          Text(repo.path)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(SettingsTheme.detail)
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
          Spacer(minLength: 8)
          Button("Reveal") { model.revealInFinder(repo.url) }
            .buttonStyle(SettingsButtonStyle())
        }
      }

      field("Base branch", note: "New worktrees fork from here.") {
        HStack(spacing: 8) {
          TextField("", text: binding(\.base), prompt: Text("origin/main"))
            .textFieldStyle(SettingsFieldStyle())
            .frame(maxWidth: 220)
          Button("Detect") {
            Task { await model.redetectBase(for: repo.name) }
          }
          .buttonStyle(SettingsButtonStyle())
          .help("Read it again from the remote's origin/HEAD")
          Spacer(minLength: 0)
        }
      }

      hook(
        title: "Setup",
        note: "Runs after the worktree is created.",
        script: GroveLocations.setupScriptName,
        text: optionalBinding(\.setupCommand)
      )

      hook(
        title: "Teardown",
        note: "Runs before the worktree is removed. Undo anything setup did outside it.",
        script: GroveLocations.teardownScriptName,
        text: optionalBinding(\.teardownCommand)
      )

      Button {
        showingVariables.toggle()
      } label: {
        HStack(spacing: 5) {
          Image(systemName: showingVariables ? "chevron.down" : "chevron.right")
            .font(.system(size: 9, weight: .semibold))
          Text("Variables a hook receives")
            .font(.system(size: 11.5))
        }
        .foregroundStyle(SettingsTheme.detail)
      }
      .buttonStyle(.plain)

      if showingVariables {
        Text(HookEnvironment.reference)
          .font(.system(size: 10.5, design: .monospaced))
          .foregroundStyle(SettingsTheme.faint)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 8).fill(SettingsTheme.surface.opacity(0.35)))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsTheme.divider, lineWidth: 1))
    // A last write in case the coalesced one has not fired yet.
    .onDisappear { model.saveLibrary() }
  }

  /// One labelled thing inside the editor. Not a `SettingRow`: these belong to the selected
  /// repo rather than to Grove, so they are not settings to be searched for.
  private func field<Content: View>(
    _ label: String, note: String? = nil, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(SettingsTheme.title)
      content()
      if let note {
        Text(note)
          .font(.system(size: 11))
          .foregroundStyle(SettingsTheme.faint)
      }
    }
  }

  /// One hook, with a warning when a committed script will win over this command.
  @ViewBuilder
  private func hook(
    title: String, note: String, script: String, text: Binding<String>
  ) -> some View {
    let committed = repo?.url
      .appending(path: GroveLocations.hookDirectoryName)
      .appending(path: script)
    let exists = committed.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    let executable =
      committed.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false

    field(title, note: note) {
      VStack(alignment: .leading, spacing: 5) {
        TextEditor(text: text)
          .font(.system(size: 11, design: .monospaced))
          .scrollContentBackground(.hidden)
          .foregroundStyle(SettingsTheme.title)
          .frame(minHeight: 52)
          .padding(6)
          .background(RoundedRectangle(cornerRadius: 6).fill(SettingsTheme.background))
          .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsTheme.divider))

        if text.wrappedValue.isEmpty {
          Text("Nothing runs for this repo.")
            .font(.system(size: 11))
            .foregroundStyle(SettingsTheme.faint)
        }
        // The resolver prefers a committed script, so a command typed here can be
        // silently dead. Worth saying out loud, including the not-executable case.
        if exists, executable {
          Label(
            "This clone commits .grove/\(script), which runs instead of the above.",
            systemImage: "exclamationmark.triangle"
          )
          .font(.system(size: 11))
          .foregroundStyle(SettingsTheme.warning)
        } else if exists {
          Label(
            ".grove/\(script) exists but is not executable, so the command above runs.",
            systemImage: "info.circle"
          )
          .font(.system(size: 11))
          .foregroundStyle(SettingsTheme.detail)
        }
      }
    }
  }

  private func binding(_ path: WritableKeyPath<RepoEntry, String>) -> Binding<String> {
    Binding(
      get: { model.library[name]?[keyPath: path] ?? "" },
      set: { value in
        model.library.update(name) { $0[keyPath: path] = value }
        model.saveLibrarySoon()
      }
    )
  }

  private func optionalBinding(_ path: WritableKeyPath<RepoEntry, String?>) -> Binding<String> {
    Binding(
      get: { model.library[name]?[keyPath: path] ?? "" },
      set: { value in
        model.library.update(name) { $0[keyPath: path] = value.isEmpty ? nil : value }
        model.saveLibrarySoon()
      }
    )
  }
}

// MARK: - General

struct GeneralSettings: View {
  @Environment(AppModel.self) private var model
  @State private var showingPicker = false

  var body: some View {
    SettingRow("workspaceRoot", controlWidth: 300) {
      HStack(spacing: 8) {
        Text(model.library.workspaceRoot)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(SettingsTheme.detail)
          .lineLimit(1)
          .truncationMode(.head)
        if !FileManager.default.fileExists(atPath: model.library.workspaceRootURL.path) {
          Text("will be created")
            .font(.system(size: 10))
            .foregroundStyle(SettingsTheme.faint)
        }
        Button("Choose…") { showingPicker = true }
          .buttonStyle(SettingsButtonStyle())
      }
    }
    .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result {
        let home = NSHomeDirectory()
        let path = url.path
        model.library.workspaceRoot =
          path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        model.saveLibrary()
        Task { await model.rescan() }
      }
    }

    SettingRow("branchPrefix") {
      VStack(alignment: .trailing, spacing: 4) {
        TextField(
          "",
          text: Binding(
            get: { model.library.branchPrefix ?? "" },
            set: {
              model.library.branchPrefix = $0.isEmpty ? nil : $0
              model.saveLibrarySoon()
            }),
          prompt: Text("ada — or leave it empty")
        )
        .textFieldStyle(SettingsFieldStyle())
        // Worth showing rather than describing: the answer depends on what is typed.
        Text(
          model.library.branchPrefix?.isEmpty == false
            ? model.library.suggestedBranch(for: "Fix Search")
            : "fix-search"
        )
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(SettingsTheme.faint)
      }
    }

    SettingRow("editorApp") {
      ApplicationPicker(
        title: "",
        fallback: "Finder",
        path: Binding(
          get: { model.library.editorPath },
          set: {
            model.library.editorPath = $0
            model.saveLibrary()
          })
      )
    }

    SettingRow("terminalApp") {
      ApplicationPicker(
        title: "",
        fallback: "Terminal",
        path: Binding(
          get: { model.library.terminalPath },
          set: {
            model.library.terminalPath = $0
            model.saveLibrary()
          })
      )
    }
  }
}

// MARK: - Terminal

struct TerminalSettings: View {
  @Environment(AppModel.self) private var model

  private var size: Double { model.library.terminalFontSize ?? TerminalFont.defaultSize }

  var body: some View {
    SettingRow("terminalFont") {
      SettingsPicker(
        selection: Binding(
          get: { TerminalFont.resolve(model.library.terminalFont) },
          set: {
            model.library.terminalFont = $0
            model.saveLibrary()
            model.applyTerminalFont()
          }),
        options: TerminalFont.monospacedFamilies.map { ($0, $0) }
      )
    }

    SettingRow("terminalFontSize") {
      HStack(spacing: 8) {
        Text("\(Int(size)) pt")
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(SettingsTheme.title)
        HStack(spacing: 2) {
          stepButton("minus", enabled: size > 9) { setSize(size - 1) }
          stepButton("plus", enabled: size < 24) { setSize(size + 1) }
        }
      }
    }

    SettingRow("terminalBackground", controlWidth: 260) {
      SettingsSegments(
        selection: Binding(
          get: { model.terminalBackgroundLevel },
          set: {
            model.library.terminalBackground = $0.rawValue
            model.saveLibrary()
            model.applyTerminalBackground()
          }),
        options: TerminalBackground.allCases.map { ($0, $0.label) }
      )
    }

    SettingRow("terminalForeground") {
      HStack(spacing: 8) {
        if let ratio = model.terminalContrastRatio {
          // The number the two colours together produce, and what it has to clear.
          Text(String(format: "%.1f:1", ratio))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(ratio >= 7 ? SettingsTheme.faint : SettingsTheme.warning)
            .help("WCAG asks 7:1 for body text")
        }
        ColorPicker(
          "",
          selection: Binding(
            get: { Color(nsColor: model.terminalForeground) },
            set: {
              model.library.terminalForeground = TerminalPalette.hex(NSColor($0))
              model.saveLibrary()
              model.applyTerminalForeground()
            }),
          supportsOpacity: false
        )
        .labelsHidden()
        Button("Reset") {
          model.library.terminalForeground = nil
          model.library.terminalBackground = nil
          model.saveLibrary()
          model.applyTerminalForeground()
          model.applyTerminalBackground()
        }
        .buttonStyle(SettingsButtonStyle())
        .disabled(
          model.library.terminalForeground == nil && model.library.terminalBackground == nil)
      }
    }

    SettingRow("terminalMouse") {
      Toggle(
        "",
        isOn: Binding(
          get: { model.library.terminalMouseReporting ?? false },
          set: {
            model.library.terminalMouseReporting = $0
            model.saveLibrary()
            model.applyTerminalMouseReporting()
          })
      )
      .toggleStyle(SettingsToggleStyle())
      .labelsHidden()
    }

    // Worth showing rather than describing: the font list has hundreds of families and
    // their names say nothing about whether the glyphs are there.
    Text(verbatim: "❯ git status  ~/code/grove  \u{ea71} main \u{f00c} ✔ 42%")
      .font(Font(model.terminalFont))
      .foregroundStyle(Color(nsColor: model.terminalForeground))
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(10)
      .background(
        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: model.terminalBackground))
      )
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsTheme.divider))
      .padding(.top, 14)
  }

  private func setSize(_ value: Double) {
    model.library.terminalFontSize = value
    model.saveLibrary()
    model.applyTerminalFont()
  }

  private func stepButton(
    _ symbol: String, enabled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .semibold))
        .frame(width: 18, height: 18)
    }
    .buttonStyle(SettingsButtonStyle())
    .disabled(!enabled)
    .opacity(enabled ? 1 : 0.4)
  }
}

// MARK: - Notifications

/// When Grove interrupts you.
///
/// Its own category rather than a section under Terminal: notifications are about what an
/// agent is doing, not about how the terminal looks, and filed under Terminal they were
/// somewhere nobody thought to look.
struct NotificationSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SettingRow("notify") {
      Toggle(
        "", isOn: Binding(get: { model.notificationsEnabled }, set: { model.setNotifications($0) })
      )
      .toggleStyle(SettingsToggleStyle())
      .labelsHidden()
    }

    if let problem = model.hookError {
      SettingNote(text: problem, tint: SettingsTheme.danger)
        .padding(.top, 4)
    }

    SettingNote(
      text: "Claude Code cannot tell Grove on its own, so this registers a small script in "
        + "its settings and removes it again when you switch this off. Hooks you already "
        + "have are left alone, and the file is copied first."
    )
    .padding(.top, 10)
  }
}

// MARK: - Tools

struct ToolSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SettingBlock("toolPaths") {
      VStack(spacing: 0) {
        let inventory = model.toolPaths.inventory()
        ForEach(inventory, id: \.tool) { entry in
          ToolRow(tool: entry.tool, resolved: entry.path)
          if entry.tool != inventory.last?.tool {
            Divider().overlay(SettingsTheme.divider.opacity(0.6))
          }
        }
      }
      .background(RoundedRectangle(cornerRadius: 8).fill(SettingsTheme.surface.opacity(0.5)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsTheme.divider, lineWidth: 1))

      Button("Search again") { Task { await model.reloadToolPaths() } }
        .buttonStyle(SettingsButtonStyle())
    }
  }
}

/// One tool: where it was found, or a way to say where it is.
private struct ToolRow: View {
  @Environment(AppModel.self) private var model
  let tool: String
  let resolved: String?

  @State private var choosing = false

  private var isOverridden: Bool { model.library.toolOverrides[tool] != nil }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: resolved == nil ? "xmark.circle" : "checkmark.circle.fill")
        .font(.system(size: 10))
        .foregroundStyle(resolved == nil ? SettingsTheme.faint : SettingsTheme.confirm)
      Text(tool)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(SettingsTheme.title)
        .frame(width: 54, alignment: .leading)
      Text(resolved ?? "not found")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(resolved == nil ? SettingsTheme.faint : SettingsTheme.detail)
        .lineLimit(1)
        .truncationMode(.head)
      if isOverridden {
        Text("set by you")
          .font(.system(size: 10))
          .foregroundStyle(SettingsTheme.faint)
      }
      Spacer(minLength: 8)
      Button("Choose…") { choosing = true }
        .buttonStyle(SettingsButtonStyle())
      if isOverridden {
        Button("Clear") {
          model.library.toolOverrides.removeValue(forKey: tool)
          model.saveLibrary()
          model.applyToolOverrides()
        }
        .buttonStyle(SettingsButtonStyle())
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .fileImporter(isPresented: $choosing, allowedContentTypes: [.unixExecutable, .executable]) {
      result in
      if case .success(let url) = result {
        model.library.toolOverrides[tool] = url.path
        model.saveLibrary()
        model.applyToolOverrides()
      }
    }
  }
}

// MARK: - About

/// What this copy of Grove is, and whether there is a newer one.
///
/// The update pill only appears when there is something to install, which leaves no way to
/// ask. Here the question can be asked, and the answer includes "already current" — which
/// the pill has no way to say.
struct AboutSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    SettingRow("version", controlWidth: 300) {
      HStack(spacing: 8) {
        Text(model.currentVersion)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(SettingsTheme.title)

        if let update = model.availableUpdate {
          Text("→ \(update.version.description)")
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(SettingsTheme.confirm)
          Button(model.updateStage?.rawValue ?? "Install and restart") {
            Task { await model.installUpdate() }
          }
          .buttonStyle(SettingsButtonStyle(prominent: true))
          .disabled(model.isDownloadingUpdate)
          Link("What's new", destination: update.pageURL)
            .font(.system(size: 11))
            .foregroundStyle(SettingsTheme.detail)
        } else {
          Button(model.isCheckingForUpdate ? "Checking…" : "Check now") {
            Task { await model.checkForUpdateNow() }
          }
          .buttonStyle(SettingsButtonStyle())
          .disabled(model.isCheckingForUpdate)
        }
      }
    }

    if model.availableUpdate == nil {
      SettingNote(text: status).padding(.top, 4)
    }

    SettingBlock("locations") {
      VStack(alignment: .leading, spacing: 8) {
        location("Workspaces", path: model.library.workspaceRoot)
        HStack(spacing: 8) {
          location("Log", path: "~/Library/Logs/Grove.log")
          Button("Show") { model.revealInFinder(Log.file) }
            .buttonStyle(SettingsButtonStyle())
        }
      }
    }
  }

  private func location(_ label: String, path: String) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(SettingsTheme.title)
        .frame(width: 88, alignment: .leading)
      Text(path)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(SettingsTheme.detail)
        .lineLimit(1)
        .truncationMode(.head)
        .textSelection(.enabled)
    }
  }

  /// What the last check found, or that none has managed to happen yet.
  private var status: String {
    guard let checked = model.lastUpdateCheck else { return "Not checked yet." }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Up to date — checked \(formatter.localizedString(for: checked, relativeTo: Date()))."
  }
}
