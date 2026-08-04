import GroveCore
import SwiftUI

struct CreateWorkspaceSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var branch = ""
  @State private var branchEdited = false
  @State private var link = ""
  @State private var chosen: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("New Workspace")
        .font(.title3.weight(.semibold))
        .padding(20)

      Divider()

      Form {
        Section {
          TextField("Name", text: $name, prompt: Text("Improve TiDB performance"))
            .onChange(of: name) { _, new in
              if !branchEdited { branch = model.library.suggestedBranch(for: new) }
            }

          TextField("Branch", text: $branch, prompt: Text("branch for every repo"))
            .font(.system(.body, design: .monospaced))
            .onChange(of: branch) { _, _ in branchEdited = true }

          TextField("Link", text: $link, prompt: Text("optional — ticket, doc, PR"))
        } footer: {
          if !name.isEmpty {
            Text(
              "\(model.library.workspaceRoot)/\(WorkspaceNaming.slug(name))"
            )
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
          }
        }

        Section("Repos") {
          ForEach(model.library.repos) { repo in
            Toggle(isOn: binding(for: repo.name)) {
              HStack {
                RepoSwatch(repo: repo.name)
                Text(repo.name)
                Spacer()
                Text(repo.base)
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        if chosen.isEmpty {
          Label("Pick at least one repo", systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Create") {
          let request = (name, branch, link, chosen)
          dismiss()
          Task {
            await model.createWorkspace(
              name: request.0, branch: request.1, link: request.2, repoNames: request.3)
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!canCreate)
      }
      .padding(16)
    }
    .frame(width: 480, height: 500)
  }

  private var canCreate: Bool {
    !WorkspaceNaming.slug(name).isEmpty
      && !branch.trimmingCharacters(in: .whitespaces).isEmpty
      && !chosen.isEmpty
  }

  private func binding(for repoName: String) -> Binding<Bool> {
    Binding(
      get: { chosen.contains(repoName) },
      set: { isOn in
        if isOn {
          chosen.insert(repoName)
        } else {
          chosen.remove(repoName)
        }
      }
    )
  }
}
