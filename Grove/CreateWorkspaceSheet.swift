import GroveCore
import SwiftUI

struct CreateWorkspaceSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var chosen: Set<String> = []

  /// A branch typed by hand. `nil` means it follows the name.
  ///
  /// Derived rather than stored, so typing the name writes one piece of state and
  /// nothing else. Keeping the branch in its own `@State` meant every keystroke in
  /// the name field wrote to it too, rebuilding the form mid-edit — which is why a
  /// typed space did not appear until the next character.
  @State private var branchOverride: String?

  private var branch: String {
    branchOverride ?? model.library.suggestedBranch(for: name)
  }

  /// Placeholder work, picked when the sheet opens.
  ///
  /// A concrete example teaches more than a question does: the name and the branch
  /// below it show the same words, so the kebab-casing explains itself without a
  /// caption saying so.
  private static let examples = [
    "Tame the flaky tests",
    "Rip out the old cache",
    "Make search fast again",
    "Fix the Friday deploy",
    "Teach billing about refunds",
    "Stop the double emails",
  ]

  @State private var example = CreateWorkspaceSheet.examples.randomElement() ?? "Fix the thing"

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("New Workspace")
        .font(.title3.weight(.semibold))
        .padding(20)

      Divider()

      Form {
        Section {
          // Left-aligned. A grouped Form right-aligns its values, and in
          // right-aligned text a trailing space has nothing after it to push, so
          // typing one looks like nothing happened until the next character
          // arrives. Growing from a fixed left edge makes the space visible as it
          // is typed.
          TextField("Name", text: $name, prompt: Text(example))
            .multilineTextAlignment(.leading)

          // Kebab-cased as it is typed. Safe here in a way it was not for the
          // name: a space becomes a hyphen, which is a visible character, so it
          // appears at once even though a grouped Form aligns the text right. A
          // space typed into the name stays a space and has nothing to push.
          TextField(
            "Branch",
            text: Binding(
              get: { branch },
              // Only a real change counts as typing. SwiftUI writes the field's
              // current text back through the binding when it commits or loses
              // focus, and taking that as an edit set the override to whatever was
              // merely on display — after which the branch never followed the name
              // again.
              set: { typed in
                let cleaned = WorkspaceNaming.branchName(typed)
                guard cleaned != branch else { return }
                branchOverride = cleaned
              }
            ),
            prompt: Text(model.library.suggestedBranch(for: example))
          )
          .font(.system(.body, design: .monospaced))
          .multilineTextAlignment(.leading)
        } footer: {
          VStack(alignment: .leading, spacing: 2) {
            if !name.isEmpty {
              Text("\(model.library.workspaceRoot)/\(WorkspaceNaming.slug(name))")
            }
            // Only worth saying when it differs from what is typed.
            if finalBranch != branch, !finalBranch.isEmpty {
              Text("branch: \(finalBranch)")
            }
          }
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
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
            .toggleStyle(ThemedToggleStyle())
          }
        }
      }
      .formStyle(.grouped)
      // The form draws the system's own grouped background, a neutral grey panel in the
      // middle of a warm window.
      .scrollContentBackground(.hidden)

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
          let request = (name, finalBranch, chosen)
          dismiss()
          Task {
            await model.createWorkspace(
              name: request.0, branch: request.1, repoNames: request.2)
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(ThemedButtonStyle(prominent: true))
        .disabled(!canCreate)
      }
      .padding(16)
    }
    .frame(width: 480, height: 500)
    .groveWindow()
  }

  /// The branch that will actually be created.
  private var finalBranch: String {
    WorkspaceNaming.finalBranchName(branch)
  }

  private var canCreate: Bool {
    !WorkspaceNaming.slug(name).isEmpty && !finalBranch.isEmpty && !chosen.isEmpty
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
