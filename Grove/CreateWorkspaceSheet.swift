import GroveCore
import SwiftUI

struct CreateWorkspaceSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var branch = ""
  @State private var link = ""
  @State private var chosen: Set<String> = []

  /// The last branch Grove filled in by itself.
  ///
  /// The branch follows the name until it is edited by hand, and telling those
  /// two apart needs this. An earlier version flipped an "edited" flag from the
  /// branch field's own onChange, which its own programmatic updates then
  /// tripped — so the branch froze after the first letter typed.
  @State private var suggested = ""

  private var branchEdited: Bool { branch != suggested }

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
              guard !branchEdited else { return }
              suggested = model.library.suggestedBranch(for: new)
              branch = suggested
            }

          // Kebab-cased as it is typed. Git rejects spaces outright, so leaving
          // them for the create step to complain about would be unkind.
          TextField(
            "Branch",
            text: Binding(
              get: { branch },
              set: { branch = WorkspaceNaming.branchName($0) }
            ),
            prompt: Text("branch for every repo")
          )
          .font(.system(.body, design: .monospaced))

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
