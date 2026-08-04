import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SidebarView: View {
    @Environment(DataStore.self) private var store
    @Binding var selection: SidebarItem?

    @State private var editor: ProjectEditor?
    @State private var deleting: Project?
    @State private var pinEditor: PinEditorMode?
    @State private var exportedFileName: String?
    @State private var showExportConfirmation = false
    @State private var showFavoriteEditor = false
    /// Accent highlight for the empty-state rows while a session drag hovers them (the non-empty
    /// lists get the system's own insertion indicator via .onMove / .onInsert).
    @State private var pinsDropTargeted = false
    @State private var favoritesDropTargeted = false

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("All Projects", systemImage: "tray.full")
                    .tag(SidebarItem.all)
            }
            Section {
                if store.pins.isEmpty {
                    emptyPinsRow
                } else {
                    ForEach(Array(store.pins.enumerated()), id: \.element.id) { index, pin in
                        pinRow(pin, index: index)
                    }
                    // Native List reordering (system insertion line) + drop a session in to add a pin.
                    .onMove { source, destination in
                        store.movePins(fromOffsets: source, toOffset: destination)
                    }
                    .onInsert(of: [.timeTrackerEntry]) { index, providers in
                        insert(providers, at: index, into: .pins)
                    }
                }
            } header: {
                HStack {
                    Text("Pins")
                    Spacer()
                    Button {
                        pinEditor = .add
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(store.pins.count >= DataStore.maxPins)
                    .help(store.pins.count >= DataStore.maxPins ? "Pins are full (9 max)" : "Add a pin")
                }
            }
            Section("Projects") {
                ForEach(store.projects) { project in
                    Label(project.name, systemImage: "folder")
                        .tag(SidebarItem.project(project.id))
                        .contextMenu {
                            Button("Rename…") { editor = .rename(project) }
                            Button("Delete…", role: .destructive) { deleting = project }
                        }
                }
                .onMove { indices, newOffset in
                    store.moveProjects(fromOffsets: indices, toOffset: newOffset)
                }
                if store.projects.isEmpty {
                    Text("No projects yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            Section {
                if store.favorites.isEmpty {
                    emptyFavoritesRow
                } else {
                    ForEach(Array(store.favorites.enumerated()), id: \.element.id) { index, favorite in
                        favoriteRow(favorite, index: index)
                    }
                    .onMove { source, destination in
                        store.moveFavorites(fromOffsets: source, toOffset: destination)
                    }
                    .onInsert(of: [.timeTrackerEntry]) { index, providers in
                        insert(providers, at: index, into: .favorites)
                    }
                }
            } header: {
                HStack {
                    Text("Favorites")
                    Spacer()
                    Button {
                        showFavoriteEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a favorite (the first \(DataStore.maxShortcuts) get ⇧⌃⌥⌘1…\(DataStore.maxShortcuts))")
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
        .sheet(item: $pinEditor) { mode in
            PinEditorSheet(mode: mode).environment(store)
        }
        .sheet(isPresented: $showFavoriteEditor) {
            FavoriteEditorSheet().environment(store)
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

    // MARK: - Shared drop-highlight helpers

    private enum SidebarList { case pins, favorites }

    /// Loads a dropped session (EntryDrag) and adds it as a pin/favorite at `index`. Backs both the
    /// non-empty lists' `.onInsert` and the empty-state rows' `.onDrop`.
    private func insert(_ providers: [NSItemProvider], at index: Int, into list: SidebarList) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.timeTrackerEntry.identifier) {
            _ = provider.loadTransferable(type: EntryDrag.self) { result in
                guard case .success(let drag) = result else { return }
                DispatchQueue.main.async {
                    switch list {
                    case .pins: DataStore.shared.addPin(at: index, projectID: drag.projectID, note: drag.note)
                    case .favorites: DataStore.shared.addFavorite(at: index, projectID: drag.projectID, note: drag.note)
                    }
                }
            }
            return
        }
    }

    // MARK: - Pins

    private var emptyPinsRow: some View {
        HStack(spacing: 8) {
            SlotBadge(group: .pin, index: 0, dim: true)
            Text("Empty — drop a session")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
        }
        .padding(.vertical, 1)
        .background(dropHighlight(pinsDropTargeted))
        .contentShape(Rectangle())
        .onDrop(of: [.timeTrackerEntry], isTargeted: $pinsDropTargeted) { providers in
            insert(providers, at: 0, into: .pins)
            return true
        }
    }

    private func pinRow(_ pin: Pin, index: Int) -> some View {
        let running = store.isRunning(pin: pin)
        let shortcut = HotKeyGroup.pin.shortcutLabel(index: index)
        return HStack(spacing: 8) {
            SlotBadge(group: .pin, index: index, dim: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(pin.note.isEmpty ? store.projectName(pin.projectID) : pin.note)
                    .lineLimit(1)
                Text(store.projectName(pin.projectID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                store.togglePin(at: index)
            } label: {
                Image(systemName: running ? "stop.circle.fill" : "play.circle.fill")
                    .foregroundStyle(running ? Color.red : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(running ? "Stop (\(shortcut))" : "Start (\(shortcut))")
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Edit…") { pinEditor = .edit(pin) }
            Button("Remove", role: .destructive) { store.removePin(pin.id) }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.removePin(pin.id) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    // MARK: - Favorites

    private var emptyFavoritesRow: some View {
        HStack(spacing: 8) {
            SlotBadge(group: .favorite, index: 0, dim: true)
            Text("Empty — drop a session")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 6)
        }
        .padding(.vertical, 1)
        .background(dropHighlight(favoritesDropTargeted))
        .contentShape(Rectangle())
        .onDrop(of: [.timeTrackerEntry], isTargeted: $favoritesDropTargeted) { providers in
            insert(providers, at: 0, into: .favorites)
            return true
        }
    }

    private func favoriteRow(_ favorite: Favorite, index: Int) -> some View {
        let running = store.isRunning(favorite: favorite)
        // Only the first nine favorites get a ⇧⌃⌥⌘N shortcut — there are just nine digit keys.
        let shortcut = store.favoriteHasShortcut(at: index)
            ? HotKeyGroup.favorite.shortcutLabel(index: index)
            : nil
        return HStack(spacing: 8) {
            favoriteBadge(index: index)
            VStack(alignment: .leading, spacing: 1) {
                Text(favorite.note.isEmpty ? store.projectName(favorite.projectID) : favorite.note)
                    .lineLimit(1)
                Text(store.projectName(favorite.projectID))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                store.toggleFavorite(at: index)
            } label: {
                Image(systemName: running ? "stop.circle.fill" : "play.circle.fill")
                    .foregroundStyle(running ? Color.red : Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help(helpText(running: running, shortcut: shortcut))
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove", role: .destructive) { store.removeFavorite(favorite.id) }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { store.removeFavorite(favorite.id) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    /// The ⇧⌃⌥⌘N badge for a favorite. Past the ninth favorite there's no digit key left, so the
    /// badge is rendered hidden — keeping those rows' text aligned with the shortcut-carrying ones.
    @ViewBuilder
    private func favoriteBadge(index: Int) -> some View {
        if store.favoriteHasShortcut(at: index) {
            SlotBadge(group: .favorite, index: index, dim: false)
        } else {
            SlotBadge(group: .favorite, index: 0, dim: true).hidden()
        }
    }

    /// Tooltip for a pin/favorite's play-stop button, naming the shortcut when it has one.
    private func helpText(running: Bool, shortcut: String?) -> String {
        let action = running ? "Stop" : "Start this session"
        guard let shortcut else { return action }
        return "\(action) (\(shortcut))"
    }

    /// Accent tint for an empty-state row while a session drag is over it.
    private func dropHighlight(_ targeted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(targeted ? Color.accentColor.opacity(0.18) : Color.clear)
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

/// The positional shortcut badge — ⌃⌥⌘N for pins, ⇧⌃⌥⌘N for favorites. Shared by the filled rows
/// of both lists and by their empty-state rows.
private struct SlotBadge: View {
    let group: HotKeyGroup
    let index: Int
    let dim: Bool
    var body: some View {
        Text(group.shortcutLabel(index: index))
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

/// Which pin-editor sheet to present.
enum PinEditorMode: Identifiable {
    case add
    case edit(Pin)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let pin): return pin.id.uuidString
        }
    }
}

/// Creates or edits a quick-launch pin: a project + a required description.
struct PinEditorSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let mode: PinEditorMode

    @State private var projectID: UUID?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEdit ? "Edit Pin" : "New Pin")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project").font(.caption).foregroundStyle(.secondary)
                    Picker("Project", selection: $projectID) {
                        ForEach(store.projects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    TextField("What are you working on?", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            switch mode {
            case .add:
                projectID = store.projects.first?.id
                note = ""
            case .edit(let pin):
                projectID = pin.projectID
                note = pin.note
            }
        }
    }

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var trimmed: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        projectID != nil && !trimmed.isEmpty
    }

    private func save() {
        guard canSave, let projectID else { return }
        switch mode {
        case .add:
            store.addPin(projectID: projectID, note: trimmed)
        case .edit(let pin):
            store.updatePin(pin.id, projectID: projectID, note: trimmed)
        }
        dismiss()
    }
}

/// Adds a favorite: pick a project + a required description.
struct FavoriteEditorSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: UUID?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Favorite").font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Project").font(.caption).foregroundStyle(.secondary)
                    Picker("Project", selection: $projectID) {
                        ForEach(store.projects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    TextField("What are you working on?", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { projectID = store.projects.first?.id }
    }

    private var trimmed: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { projectID != nil && !trimmed.isEmpty }

    private func save() {
        guard canSave, let projectID else { return }
        store.addFavorite(projectID: projectID, note: trimmed)
        dismiss()
    }
}
