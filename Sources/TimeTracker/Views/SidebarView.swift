import SwiftUI

struct SidebarView: View {
    @Environment(DataStore.self) private var store
    @Binding var selection: SidebarItem?

    @State private var editor: ProjectEditor?
    @State private var deleting: Project?
    @State private var exportedFileName: String?
    @State private var showExportConfirmation = false

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("All Projects", systemImage: "tray.full")
                    .tag(SidebarItem.all)
            }
            // The project list *is* the quick-launch list: each row starts/stops its own timer and
            // the first nine carry ⌃⌥⌘1…9, assigned by position.
            Section("Projects") {
                ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                    projectRow(project, index: index)
                }
                // Native List reordering (system insertion line). Reordering re-maps the positional
                // shortcuts — that's how the user picks which nine projects get one.
                .onMove { indices, newOffset in
                    store.moveProjects(fromOffsets: indices, toOffset: newOffset)
                }
                if store.projects.isEmpty {
                    Text("No projects yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
        }
        .listStyle(.sidebar)
        // A stable bottom bar (like Reminders' "New List") — the toolbar "+" was collapsing
        // into the overflow chevron at narrow widths / when the sidebar toggled.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button {
                        editor = .add
                    } label: {
                        Label("New Project", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button {
                        if let url = store.exportData() {
                            exportedFileName = url.lastPathComponent
                            showExportConfirmation = true
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("Export all data as JSON to your Downloads folder")
                    .popover(isPresented: $showExportConfirmation, arrowEdge: .top) {
                        VStack(spacing: 6) {
                            Label("Exported to Downloads", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout.weight(.medium))
                            if let exportedFileName {
                                Text(exportedFileName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .task {
                            try? await Task.sleep(for: .seconds(2))
                            showExportConfirmation = false
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .background(.bar)
        }
        // Add / rename project — a sheet with inline validation (avoids the re-entrant-alert
        // pitfall where an error alert fired from a dismissing alert never shows).
        .sheet(item: $editor) { mode in
            ProjectEditorSheet(mode: mode) { committedID in
                selection = .project(committedID)
            }
            .environment(store)
        }
        // Delete confirmation (cascades to entries).
        .confirmationDialog(
            deleting.map { "Delete “\($0.name)”?" } ?? "Delete project?",
            isPresented: deletingBinding,
            titleVisibility: .visible
        ) {
            if let project = deleting {
                let count = store.entryCount(for: project.id)
                Button("Delete project and \(count) \(count == 1 ? "entry" : "entries")", role: .destructive) {
                    commitDelete(project)
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("This permanently deletes the project and all of its time entries. This cannot be undone.")
        }
    }

    // MARK: - Projects

    /// One project row: its positional shortcut badge, the name, and a play/stop button. The row
    /// still carries a `.tag`, so clicking anywhere but the button selects the project and filters
    /// the history; the button needs `.buttonStyle(.borderless)` to stay clickable inside a
    /// selectable row (the default style lets the row swallow the click).
    private func projectRow(_ project: Project, index: Int) -> some View {
        let running = store.isRunning(projectID: project.id)
        // Only the first nine projects get a ⌃⌥⌘N shortcut — there are just nine digit keys.
        let shortcut = store.projectHasShortcut(at: index)
            ? ProjectHotKey.shortcutLabel(index: index)
            : nil
        return HStack(spacing: 8) {
            projectBadge(index: index)
            Label(project.name, systemImage: "folder")
                .lineLimit(1)
            Spacer(minLength: 6)
            Button {
                store.toggleProject(at: index)
            } label: {
                Image(systemName: running ? "stop.circle.fill" : "play.circle.fill")
                    .foregroundStyle(running ? Color.red : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(helpText(running: running, shortcut: shortcut))
        }
        .padding(.vertical, 1)
        .tag(SidebarItem.project(project.id))
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename…") { editor = .rename(project) }
            Button("Delete…", role: .destructive) { deleting = project }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleting = project } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// The ⌃⌥⌘N badge for a project. Past the ninth project there's no digit key left, so the badge
    /// is rendered hidden — keeping those rows' names aligned with the shortcut-carrying ones.
    @ViewBuilder
    private func projectBadge(index: Int) -> some View {
        if store.projectHasShortcut(at: index) {
            SlotBadge(index: index, dim: false)
        } else {
            SlotBadge(index: 0, dim: true).hidden()
        }
    }

    /// Tooltip for a project's play-stop button, naming the shortcut when it has one.
    private func helpText(running: Bool, shortcut: String?) -> String {
        let action = running ? "Stop" : "Start"
        guard let shortcut else { return action }
        return "\(action) (\(shortcut))"
    }

    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    private func commitDelete(_ project: Project) {
        if case .project(let id) = selection, id == project.id {
            selection = .all
        }
        store.deleteProject(project.id)
        deleting = nil
    }
}

/// The positional shortcut badge — ⌃⌥⌘N for the project at index N. Rendered dim (and hidden) for
/// the projects past the ninth, which have no shortcut but still need the leading space so every
/// name lines up.
private struct SlotBadge: View {
    let index: Int
    let dim: Bool
    var body: some View {
        Text(ProjectHotKey.shortcutLabel(index: index))
            .font(.caption2)
            .monospaced()
            .foregroundStyle(dim ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(dim ? 0.08 : 0.15)))
    }
}

/// Identifies which editor sheet to present.
enum ProjectEditor: Identifiable {
    case add
    case rename(Project)

    var id: String {
        switch self {
        case .add: return "add"
        case .rename(let project): return project.id.uuidString
        }
    }
}

/// A small sheet for creating or renaming a project, with live duplicate/empty validation.
struct ProjectEditorSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let mode: ProjectEditor
    /// Called with the created/renamed project's id so the caller can select it.
    let onCommit: (UUID) -> Void

    @State private var name = ""
    /// True once we've committed a save. Suppresses the duplicate warning so it can't flash
    /// red for a frame after addProject() makes the just-typed name "exist" pre-dismiss.
    @State private var committing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isRename ? "Rename Project" : "New Project")
                .font(.headline)

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canSave { save() } }

            if showsDuplicateWarning {
                Label("A project named “\(trimmed)” already exists.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRename ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            // Reset for BOTH modes — otherwise a reused sheet keeps the previously typed
            // name, making a fresh "New Project" appear pre-filled (and falsely "already exists").
            committing = false
            switch mode {
            case .add: name = ""
            case .rename(let project): name = project.name
            }
        }
    }

    private var isRename: Bool {
        if case .rename = mode { return true }
        return false
    }

    private var existingID: UUID? {
        if case .rename(let project) = mode { return project.id }
        return nil
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsDuplicateWarning: Bool {
        !committing && !trimmed.isEmpty && store.projectNameExists(trimmed, excluding: existingID)
    }

    private var canSave: Bool {
        !trimmed.isEmpty && !store.projectNameExists(trimmed, excluding: existingID)
    }

    private func save() {
        guard canSave else { return }
        committing = true
        switch mode {
        case .add:
            if store.addProject(name: trimmed),
               let created = store.projects.last(where: {
                   $0.name.compare(trimmed, options: .caseInsensitive) == .orderedSame
               }) {
                onCommit(created.id)
            }
        case .rename(let project):
            // A case-only change (e.g. "work" → "Work") is allowed: projectNameExists
            // excludes this project's own id, so canSave is true and the rename applies.
            if store.renameProject(project.id, to: trimmed) {
                onCommit(project.id)
            }
        }
        dismiss()
    }
}
