import GroveCore
import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      LibrarySettings()
        .tabItem { Label("Repos", systemImage: "shippingbox") }
      GeneralSettings()
        .tabItem { Label("General", systemImage: "gearshape") }
      TerminalSettings()
        .tabItem { Label("Terminal", systemImage: "apple.terminal") }
      ToolSettings()
        .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
    }
    .frame(width: 680, height: 540)
  }
}

// MARK: - Repos

/// The repo library: what Grove can make worktrees from, and how to set each up.
struct LibrarySettings: View {
  @Environment(AppModel.self) private var model
  @State private var selection: String?
  @State private var showingPicker = false
  @State private var removing: String?

  var body: some View {
    HSplitView {
      VStack(spacing: 0) {
        List(selection: $selection) {
          ForEach(model.library.repos) { repo in
            HStack(spacing: 8) {
              RepoSwatch(repo: repo.name, size: 10)
              VStack(alignment: .leading, spacing: 1) {
                Text(repo.name)
                Text(repo.path)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .truncationMode(.head)
              }
              Spacer()
              if !FileManager.default.fileExists(atPath: repo.url.path) {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(.orange)
                  .help("This clone is no longer at that path")
              }
            }
            .tag(repo.name)
          }
        }
        .overlay {
          if model.library.repos.isEmpty {
            VStack(spacing: 4) {
              Text("No repos").font(.headline)
              Text("Add a clone to get started.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }

        Divider()
        HStack(spacing: 2) {
          Button {
            showingPicker = true
          } label: {
            Image(systemName: "plus")
          }
          .help("Add a repository")

          Button {
            removing = selection
          } label: {
            Image(systemName: "minus")
          }
          .disabled(selection == nil)
          .help("Remove from the library")

          Spacer()
          Text("\(model.library.repos.count) repos")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .padding(6)
      }
      .frame(minWidth: 220, idealWidth: 240)

      Group {
        if let name = selection, model.library[name] != nil {
          RepoEditor(name: name)
        } else {
          VStack(spacing: 6) {
            Text("Select a repo")
              .foregroundStyle(.secondary)
            Text(
              "Each one records where its clone is, what to fork from, and how to\nprepare a fresh worktree."
            )
            .font(.caption)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(minWidth: 360)
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
      Text("This repo is no longer in the library.")
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func editor(for repo: RepoEntry) -> some View {
    Form {
      Section {
        LabeledContent("Name", value: repo.name)
        LabeledContent("Clone") {
          HStack {
            Text(repo.path)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.head)
              .textSelection(.enabled)
            Spacer()
            Button("Reveal") { model.revealInFinder(repo.url) }
              .controlSize(.small)
          }
        }
        LabeledContent("Base branch") {
          HStack {
            TextField("", text: binding(\.base), prompt: Text("origin/main"))
              .font(.system(.body, design: .monospaced))
            Button("Detect") {
              Task { await model.redetectBase(for: repo.name) }
            }
            .controlSize(.small)
            .help("Read it again from the remote's origin/HEAD")
          }
        }
      } footer: {
        Text("New worktrees fork from the base branch.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      hookSection(
        title: "Setup",
        note: "Runs after the worktree is created.",
        script: GroveLocations.setupScriptName,
        text: optionalBinding(\.setupCommand)
      )

      hookSection(
        title: "Teardown",
        note: "Runs before the worktree is removed. Undo anything setup did outside it.",
        script: GroveLocations.teardownScriptName,
        text: optionalBinding(\.teardownCommand)
      )

      Section {
        DisclosureGroup("Variables a hook receives", isExpanded: $showingVariables) {
          Text(HookEnvironment.reference)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .formStyle(.grouped)
    // A last write in case the coalesced one has not fired yet.
    .onDisappear { model.saveLibrary() }
  }

  /// One hook, with a warning when a committed script will win over this command.
  @ViewBuilder
  private func hookSection(
    title: String, note: String, script: String, text: Binding<String>
  ) -> some View {
    let committed = repo?.url
      .appending(path: GroveLocations.hookDirectoryName)
      .appending(path: script)
    let exists = committed.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    let executable =
      committed.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false

    Section {
      TextEditor(text: text)
        .font(.system(.caption, design: .monospaced))
        .frame(minHeight: 64)
        .padding(4)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
      if text.wrappedValue.isEmpty {
        Text("Nothing runs for this repo.")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    } header: {
      Text(title)
    } footer: {
      VStack(alignment: .leading, spacing: 4) {
        Text(note)
        // The resolver prefers a committed script, so a command typed here can be
        // silently dead. Worth saying out loud, including the not-executable case.
        if exists, executable {
          Label(
            "This clone commits .grove/\(script), which runs instead of the above.",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(.orange)
        } else if exists {
          Label(
            ".grove/\(script) exists but is not executable, so the command above runs.",
            systemImage: "info.circle"
          )
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
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
    Form {
      Section {
        LabeledContent("Workspace root") {
          HStack {
            Text(model.library.workspaceRoot)
              .font(.system(.caption, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.head)
            if !FileManager.default.fileExists(atPath: model.library.workspaceRootURL.path) {
              Text("will be created")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") { showingPicker = true }
              .controlSize(.small)
          }
        }
      } footer: {
        Text("Where workspace folders are created.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        TextField(
          "Branch prefix",
          text: Binding(
            get: { model.library.branchPrefix ?? "" },
            set: {
              model.library.branchPrefix = $0.isEmpty ? nil : $0
              model.saveLibrarySoon()
            }),
          prompt: Text("ada — or leave it empty")
        )
        .font(.system(.body, design: .monospaced))
      } footer: {
        Text(
          model.library.branchPrefix?.isEmpty == false
            ? "A workspace called Fix Search gets \(model.library.suggestedBranch(for: "Fix Search"))."
            : "A workspace called Fix Search gets fix-search."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        ApplicationPicker(
          title: "Open with",
          fallback: "Finder",
          path: Binding(
            get: { model.library.editorPath },
            set: {
              model.library.editorPath = $0
              model.saveLibrary()
            })
        )
        ApplicationPicker(
          title: "Terminal",
          fallback: "Terminal",
          path: Binding(
            get: { model.library.terminalPath },
            set: {
              model.library.terminalPath = $0
              model.saveLibrary()
            })
        )
      } header: {
        Text("Opening")
      } footer: {
        Text("The Open button hands the workspace folder to this application.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
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
  }
}

// MARK: - Terminal

struct TerminalSettings: View {
  @Environment(AppModel.self) private var model

  private var size: Double { model.library.terminalFontSize ?? TerminalFont.defaultSize }

  var body: some View {
    Form {
      Section {
        Picker(
          "Font",
          selection: Binding(
            get: { TerminalFont.resolve(model.library.terminalFont) },
            set: {
              model.library.terminalFont = $0
              model.saveLibrary()
              model.applyTerminalFont()
            })
        ) {
          ForEach(TerminalFont.monospacedFamilies, id: \.self) { family in
            Text(family).tag(family)
          }
        }

        Stepper(
          "Size: \(Int(size)) pt",
          value: Binding(
            get: { size },
            set: {
              model.library.terminalFontSize = $0
              model.saveLibrary()
              model.applyTerminalFont()
            }),
          in: 9...24,
          step: 1
        )
      } header: {
        Text("Font")
      } footer: {
        Text(
          "A prompt built from Nerd Font glyphs needs a font that has them, or macOS "
            + "substitutes them one at a time and the sizes stop matching."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle(
          "Tell me when a session is waiting",
          isOn: Binding(
            get: { model.notificationsEnabled },
            set: { model.setNotifications($0) })
        )
        if let problem = model.hookError {
          Text(problem)
            .font(.caption)
            .foregroundStyle(.red)
        }
      } header: {
        Text("Notifications")
      } footer: {
        Text(
          "Grove tells you when a session finishes or stops to ask you something, "
            + "unless you are already looking at it. Either way, a session waiting for "
            + "you keeps a dot in the sidebar.\n\n"
            + "Claude Code cannot tell Grove on its own, so this registers a small "
            + "script in its settings and removes it again when you switch this off. "
            + "Hooks you already have are left alone, and the file is copied first."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Toggle(
          "Send mouse events to programs",
          isOn: Binding(
            get: { model.library.terminalMouseReporting ?? false },
            set: {
              model.library.terminalMouseReporting = $0
              model.saveLibrary()
              model.applyTerminalMouseReporting()
            })
        )
      } header: {
        Text("Mouse")
      } footer: {
        Text(
          "Leave this off to select text. SwiftTerm throws the selection away on every "
            + "chunk of output while mouse events are being sent, so a selection lasts "
            + "only until the next line prints. Turn it on for programs that read the "
            + "mouse themselves, such as vim or lazygit — Claude Code does not."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        ColorPicker(
          "Text",
          selection: Binding(
            get: { Color(nsColor: model.terminalForeground) },
            set: {
              model.library.terminalForeground = TerminalPalette.hex(NSColor($0))
              model.saveLibrary()
              model.applyTerminalForeground()
            }),
          supportsOpacity: false
        )
        Button("Use the default") {
          model.library.terminalForeground = nil
          model.saveLibrary()
          model.applyTerminalForeground()
        }
        .controlSize(.small)
        .disabled(model.library.terminalForeground == nil)
      } header: {
        Text("Colour")
      } footer: {
        Text(
          "Applies to text a program leaves uncoloured. SwiftTerm's own default is a "
            + "mid-grey, which reads as dim on a dark background."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      // Worth showing rather than describing: the list has hundreds of families and
      // their names say nothing about whether the glyphs are there.
      Section("Preview") {
        Text(verbatim: "❯ git status  ~/code/grove  \u{ea71} main \u{f00c} ✔ 42%")
          .font(Font(model.terminalFont))
          .foregroundStyle(Color(nsColor: model.terminalForeground))
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
          .background(.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
      }

    }
    .formStyle(.grouped)
  }
}

// MARK: - Tools

struct ToolSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section {
        ForEach(model.toolPaths.inventory(), id: \.tool) { entry in
          ToolRow(tool: entry.tool, resolved: entry.path)
        }
      } header: {
        Text("Resolved from a login shell")
      } footer: {
        Text(
          "An app launched from Finder inherits almost no PATH, so Grove asks your "
            + "login shell where these live. Point one at a path yourself if it is "
            + "somewhere unusual. Only git is required."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section {
        Button("Search again") { Task { await model.reloadToolPaths() } }
      }
    }
    .formStyle(.grouped)
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
    LabeledContent(tool) {
      HStack(spacing: 8) {
        Image(systemName: resolved == nil ? "xmark.circle" : "checkmark.circle.fill")
          .foregroundStyle(resolved == nil ? Color.secondary : Color.green)
        Text(resolved ?? "not found")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(resolved == nil ? .secondary : .primary)
          .lineLimit(1)
          .truncationMode(.head)
        if isOverridden {
          Text("set by you")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Choose…") { choosing = true }
          .controlSize(.small)
        if isOverridden {
          Button("Clear") {
            model.library.toolOverrides.removeValue(forKey: tool)
            model.saveLibrary()
            model.applyToolOverrides()
          }
          .controlSize(.small)
        }
      }
    }
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
