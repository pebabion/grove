import GroveCore
import SwiftUI

struct SettingsView: View {
  var body: some View {
    TabView {
      LibrarySettings()
        .tabItem { Label("Repos", systemImage: "shippingbox") }
      GeneralSettings()
        .tabItem { Label("General", systemImage: "gearshape") }
      ToolSettings()
        .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
    }
    .frame(width: 620, height: 480)
  }
}

/// The repo library: what Grove can make worktrees from, and how to set each up.
struct LibrarySettings: View {
  @Environment(AppModel.self) private var model
  @State private var selection: String?
  @State private var showingPicker = false

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
            if let selection {
              model.removeRepoFromLibrary(selection)
              self.selection = nil
            }
          } label: {
            Image(systemName: "minus")
          }
          .disabled(selection == nil)
          .help("Remove from the library. The clone itself is untouched.")

          Spacer()
        }
        .buttonStyle(.borderless)
        .padding(6)
      }
      .frame(minWidth: 200, idealWidth: 220)

      Group {
        if let name = selection,
          let index = model.library.repos.firstIndex(where: { $0.name == name })
        {
          RepoEditor(index: index)
        } else {
          Text("Select a repo")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(minWidth: 340)
    }
    .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder]) { result in
      if case .success(let url) = result {
        Task { await model.addRepoToLibrary(at: url) }
      }
    }
  }
}

/// Editor for one library entry.
struct RepoEditor: View {
  @Environment(AppModel.self) private var model
  let index: Int

  var body: some View {
    Form {
      Section {
        LabeledContent("Name", value: model.library.repos[index].name)
        LabeledContent("Clone") {
          Text(model.library.repos[index].path)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
        }
        TextField("Base branch", text: binding(\.base), prompt: Text("origin/main"))
          .font(.system(.body, design: .monospaced))
      } footer: {
        Text("New worktrees fork from this. Read from origin/HEAD when the repo was added.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Setup") {
        TextEditor(text: optionalBinding(\.setupCommand))
          .font(.system(.caption, design: .monospaced))
          .frame(minHeight: 70)
      }

      Section {
        TextEditor(text: optionalBinding(\.teardownCommand))
          .font(.system(.caption, design: .monospaced))
          .frame(minHeight: 50)
      } header: {
        Text("Teardown")
      } footer: {
        Text(HookEnvironment.reference)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onDisappear { model.saveLibrary() }
  }

  private func binding(_ path: WritableKeyPath<RepoEntry, String>) -> Binding<String> {
    Binding(
      get: { model.library.repos[index][keyPath: path] },
      set: {
        model.library.repos[index][keyPath: path] = $0
        model.saveLibrary()
      }
    )
  }

  private func optionalBinding(_ path: WritableKeyPath<RepoEntry, String?>) -> Binding<String> {
    Binding(
      get: { model.library.repos[index][keyPath: path] ?? "" },
      set: {
        model.library.repos[index][keyPath: path] = $0.isEmpty ? nil : $0
        model.saveLibrary()
      }
    )
  }
}

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
            Spacer()
            Button("Choose…") { showingPicker = true }
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
              model.saveLibrary()
            }),
          prompt: Text("ada — or leave it empty")
        )
        .font(.system(.body, design: .monospaced))
      } footer: {
        Text("Suggested branches become prefix/workspace-name.")
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

struct ToolSettings: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section {
        ForEach(model.toolPaths.inventory(), id: \.tool) { entry in
          LabeledContent(entry.tool) {
            Text(entry.path ?? "not found")
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(entry.path == nil ? Color.secondary : Color.primary)
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
      } header: {
        Text("Resolved from a login shell")
      } footer: {
        Text(
          "An app launched from Finder inherits almost no PATH, so Grove asks your "
            + "login shell where these live."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Button("Rescan") { Task { await model.load() } }
    }
    .formStyle(.grouped)
  }
}
