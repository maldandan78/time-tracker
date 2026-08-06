import SwiftUI

/// The running-timer bar at the top of the main pane: the project, a live clock, and Stop.
///
/// It *draws* only while a timer is running — idle, it takes no space at all and the history list
/// fills the pane. Starting a timer happens elsewhere: the play button on a sidebar project row,
/// the global ⌃⌥⌘1…9 shortcuts, the menu-bar extra, or the ▶ button on a history row.
///
/// The view itself stays mounted even when idle, because it also hosts the running-timer editor
/// sheet. Several paths stop the timer from outside this bar (a project hotkey, ⇧⌃⌥⌘⌦, the sidebar
/// stop button, the menu-bar extra); if the bar were added and removed by a conditional in its
/// parent, any of those would tear down an open editor mid-edit and silently drop the user's
/// unsaved correction. Keeping it mounted keeps the sheet's host alive across a stop — which is the
/// case `DataStore.updateEntryDetails` and `EntryEditorSheet.save()` are written to survive.
struct TrackerBar: View {
    @Environment(DataStore.self) private var store

    @State private var editingEntry: TimeEntry?

    var body: some View {
        Group {
            if let running = store.runningEntry {
                VStack(spacing: 0) {
                    runningView(running)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .background(.bar)
                    Divider()
                }
            } else {
                // Idle: no bar, but keep a zero-height node so the sheet below always has a live
                // host — including at the instant the timer stops with the editor open.
                Color.clear.frame(height: 0)
            }
        }
        .sheet(item: $editingEntry) { entry in
            EntryEditorSheet(entry: entry).environment(store)
        }
    }

    @ViewBuilder
    private func runningView(_ running: TimeEntry) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.green)
                .frame(width: 10, height: 10)
            Text(store.projectName(running.projectID))
                .font(.headline)
                .lineLimit(1)
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
            .help(DataStore.discardRunningHint)
        }
    }
}
