import SwiftUI

/// Edits one time entry — project, description, and start/end.
/// For the running entry, the end is omitted (it stays running) and only the start is editable,
/// which lets you correct the elapsed time of the live timer.
struct EntryEditorSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let entry: TimeEntry

    @State private var projectID: UUID
    @State private var note: String
    @State private var start: Date
    @State private var end: Date

    init(entry: TimeEntry) {
        self.entry = entry
        _projectID = State(initialValue: entry.projectID)
        _note = State(initialValue: entry.note)
        _start = State(initialValue: entry.start)
        _end = State(initialValue: entry.end ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(entry.isRunning ? "Edit Running Timer" : "Edit Entry")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                field("Project") {
                    Picker("Project", selection: $projectID) {
                        ForEach(store.projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .labelsHidden()
                }
                field("Description") {
                    TextField("What are you working on?", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
                field("Start") {
                    DatePicker("Start", selection: $start, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                }
                field("End") {
                    if entry.isRunning {
                        Label("Running", systemImage: "stopwatch").foregroundStyle(.green)
                    } else {
                        DatePicker("End", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                    }
                }
            }

            if let problem = validationProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(validationProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            // Reuse-safety: re-seed from the entry each time the sheet appears.
            projectID = entry.projectID
            note = entry.note
            start = entry.start
            end = entry.end ?? Date()
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationProblem: String? {
        if store.project(projectID) == nil { return "Choose a project." }
        if trimmedNote.isEmpty { return "A description is required." }
        if entry.isRunning {
            if start > Date() { return "Start can’t be in the future for a running timer." }
        } else if end < start {
            return "End must be after start."
        }
        return nil
    }

    private func save() {
        guard validationProblem == nil else { return }
        if entry.isRunning {
            // Running editor: never force end=nil from this (possibly stale) snapshot — only update
            // details, preserving the entry's live state so a pin fired under the sheet can't
            // resurrect a stopped entry into a second running timer.
            store.updateEntryDetails(entry.id, projectID: projectID, note: trimmedNote, start: start)
        } else {
            store.updateEntry(entry.id, projectID: projectID, note: trimmedNote, start: start, end: end)
        }
        dismiss()
    }
}

/// Edits a whole group (cluster) of entries at once — project + description only, never time.
/// The new project/description is applied to every entry in the group; each entry keeps its own
/// start/end. (Retitling to another (project, description) simply re-groups the entries.)
struct GroupEditorSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let entryIDs: [UUID]
    let count: Int
    private let initialProjectID: UUID
    private let initialNote: String

    @State private var projectID: UUID
    @State private var note: String

    init(entryIDs: [UUID], count: Int, projectID: UUID, note: String) {
        self.entryIDs = entryIDs
        self.count = count
        self.initialProjectID = projectID
        self.initialNote = note
        _projectID = State(initialValue: projectID)
        _note = State(initialValue: note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(count) Entries")
                .font(.headline)
            Text("Applies to all \(count) sessions in this group. Their times are unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                field("Project") {
                    Picker("Project", selection: $projectID) {
                        ForEach(store.projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .labelsHidden()
                }
                field("Description") {
                    TextField("What are you working on?", text: $note)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let problem = validationProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(validationProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            // Reuse-safety: re-seed from the group each time the sheet appears (a reused
            // .sheet(item:) view otherwise keeps the previously edited group's values).
            projectID = initialProjectID
            note = initialNote
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private var trimmedNote: String {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationProblem: String? {
        if store.project(projectID) == nil { return "Choose a project." }
        if trimmedNote.isEmpty { return "A description is required." }
        return nil
    }

    private func save() {
        guard validationProblem == nil else { return }
        store.updateEntries(entryIDs, projectID: projectID, note: trimmedNote)
        dismiss()
    }
}
