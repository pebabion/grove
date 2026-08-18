import GroveCore
import SwiftUI

/// What a workspace is about to lose, or which repo is being removed from it.
enum TeardownTarget: Identifiable {
  case whole(Workspace)
  case member(WorkspaceMember, Workspace)

  var id: String {
    switch self {
    case .whole(let workspace): "workspace:\(workspace.url.path)"
    case .member(let member, let workspace): "member:\(workspace.url.path)|\(member.repoName)"
    }
  }
}

/// One colour per repo, so the same repo reads the same everywhere it appears —
/// sidebar, workspace detail, the create checklist, settings.
///
/// Slots come from the library rather than a hash of the name. Hashing was
/// tried and put backend, frontend and kubernetes on the same green: with a
/// dozen slots and a handful of repos, collisions are likely enough to ruin the
/// one job the colour has.
enum RepoPalette {
  static let colors: [Color] = [
    .init(red: 0.18, green: 0.55, blue: 0.34),  // sea green
    .init(red: 0.42, green: 0.35, blue: 0.80),  // slate blue
    .init(red: 0.80, green: 0.52, blue: 0.25),  // peru
    .init(red: 0.13, green: 0.59, blue: 0.64),  // dark cyan
    .init(red: 0.75, green: 0.23, blue: 0.17),  // brick
    .init(red: 0.48, green: 0.41, blue: 0.68),  // muted purple
    .init(red: 0.83, green: 0.52, blue: 0.16),  // amber
    .init(red: 0.23, green: 0.49, blue: 0.65),  // steel blue
    .init(red: 0.55, green: 0.37, blue: 0.24),  // sienna
    .init(red: 0.37, green: 0.62, blue: 0.63),  // cadet
    .init(red: 0.63, green: 0.32, blue: 0.18),  // burnt orange
    .init(red: 0.29, green: 0.46, blue: 0.43),  // sage
  ]

  /// Colour for a palette slot, or grey for a repo the library does not hold.
  static func color(slot: Int?) -> Color {
    guard let slot else { return .secondary }
    return colors[slot % colors.count]
  }
}

/// A repo's colour swatch. Greys out for a worktree whose clone is not in the
/// library, which is how an adopted stray reads as unmanaged.
struct RepoSwatch: View {
  @Environment(AppModel.self) private var model
  let repo: String
  var size: CGFloat = 8

  var body: some View {
    RoundedRectangle(cornerRadius: size / 3)
      .fill(RepoPalette.color(slot: model.library.colorIndex(for: repo)))
      .frame(width: size, height: size)
  }
}

/// The actions relevant to a workspace, shared by the sidebar's right-click menu
/// and the detail pane's menu so the two never drift apart.
struct WorkspaceActions: View {
  @Environment(AppModel.self) private var model
  let workspace: Workspace

  var body: some View {
    Button("Open") { model.openInEditor(workspace.url) }
    Button("Reveal in Finder") { model.revealInFinder(workspace.url) }
    Button("Open in Terminal") { model.openInTerminal(workspace.url) }
    if let link = workspace.file.link, let url = URL(string: link) {
      Link("Open Link", destination: url)
    }

    Divider()

    Button("Rename…") { model.renameTarget = workspace }
    Button(model.sizes[workspace.url] == nil ? "Measure Disk Usage" : "Measure Again") {
      Task { await model.measure([workspace]) }
    }

    let present = Set(workspace.members.map(\.repoName))
    let available = model.library.repos.filter { !present.contains($0.name) }
    if !available.isEmpty {
      Menu("Add Repo") {
        ForEach(available) { repo in
          Button(repo.name) {
            Task { await model.addRepo(named: repo.name, to: workspace) }
          }
        }
      }
    }

    if !workspace.members.isEmpty {
      Menu("Re-run Setup") {
        ForEach(workspace.members) { member in
          Button(member.repoName) {
            Task { await model.rerunSetup(for: member, in: workspace) }
          }
        }
      }
      Menu("Remove Repo") {
        ForEach(workspace.members) { member in
          Button("\(member.repoName)…") {
            model.teardownTarget = .member(member, workspace)
          }
        }
      }
    }

    Divider()

    Button("Delete Workspace…", role: .destructive) {
      model.teardownTarget = .whole(workspace)
    }
  }
}

/// Renaming moves the workspace folder, so it says so.
struct RenameSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss

  let workspace: Workspace
  @State private var name = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Rename Workspace")
        .font(.title3.weight(.semibold))

      TextField("Name", text: $name, prompt: Text("Something you'll recognise in a week"))
        .textFieldStyle(ThemedFieldStyle())
        .onSubmit { commit() }

      VStack(alignment: .leading, spacing: 4) {
        if movesFolder {
          Label(
            "The folder moves and every worktree inside it is repaired.",
            systemImage: "folder.badge.gearshape"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Text(destinationPath)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.head)
      }

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Rename") { commit() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(ThemedButtonStyle(prominent: true))
          .disabled(WorkspaceNaming.slug(name).isEmpty)
      }
    }
    .padding(20)
    .frame(width: 460)
    .groveWindow()
    .onAppear { name = workspace.file.name }
  }

  private var slug: String { WorkspaceNaming.slug(name) }

  private var movesFolder: Bool {
    !slug.isEmpty && slug != workspace.url.lastPathComponent
  }

  private var destinationPath: String {
    let root = model.library.workspaceRoot
    return slug.isEmpty ? "\(root)/…" : "\(root)/\(slug)"
  }

  private func commit() {
    guard !slug.isEmpty else { return }
    let newName = name
    dismiss()
    Task { await model.rename(workspace, to: newName) }
  }
}
