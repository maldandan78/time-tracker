import SwiftUI

/// The control at the top of the main pane: start/stop the single live timer.
/// Both a project and a description are required to start.
struct TrackerBar: View {
    @Environment(DataStore.self) private var store
    let preferredProjectID: UUID?

    @State private var pickedProjectID: UUID?
    @State private var note = ""
    @State private var editingEntry: TimeEntry?

    var body: some View {
        Group {
            if let running = store.runningEntry {
                runningView(running)
            } else {
                idleView
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .onAppear(perform: syncPicked)
        .onChange(of: preferredProjectID) { syncPicked() }
        .onChange(of: store.projects.map(\.id)) { syncPicked() }
        .sheet(item: $editingEntry) { entry in
            EntryEditorSheet(entry: entry).environment(store)
        }
    }

    /// Keep the picker pointed at a valid project, preferring the sidebar selection.
    private func syncPicked() {
        if let preferred = preferredProjectID,
           store.projects.contains(where: { $0.id == preferred }) {
            pickedProjectID = preferred
        } else if let current = pickedProjectID,
                  store.projects.contains(where: { $0.id == current }) {
            // current pick is still valid — leave it
        } else {
            pickedProjectID = store.projects.first?.id
        }
    }

    // MARK: - Running

    @ViewBuilder
    private func runningView(_ running: TimeEntry) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.green)
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(store.projectName(running.projectID))
                    .font(.headline)
                if !running.note.isEmpty {
                    Text(running.note)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(TimeFormat.clock(running.duration(asOf: context.date)))
                    .font(.system(.title2, design: .monospaced))
                    .monospacedDigit()
            }
            .help(DataStore.startNudgeHint)
            Button {
                editingEntry = running
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit the running timer")
            Button(role: .destructive) {
                store.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(".", modifiers: .command)
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        HStack(spacing: 12) {
            Picker("Project", selection: $pickedProjectID) {
                ForEach(store.projects) { project in
                    Text(project.name).tag(Optional(project.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 200)

            TextField("What are you working on?", text: $note)
                .textFieldStyle(.roundedBorder)
                .onSubmit(startIfPossible)

            Button(action: startIfPossible) {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canStart)
        }
    }

    // MARK: - Helpers

    private var canStart: Bool {
        pickedProjectID != nil &&
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startIfPossible() {
        guard canStart, let projectID = pickedProjectID else { return }
        store.start(projectID: projectID, note: note)
        note = ""
    }
}
