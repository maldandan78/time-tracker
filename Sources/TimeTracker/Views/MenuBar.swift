import SwiftUI
import AppKit

/// UserDefaults key for the menu-bar display toggle (shared by the label + the menu).
enum MenuBarPrefs {
    static let showProjectKey = "menuBarShowProject"
}

/// The status-bar label: a stopwatch symbol, plus the running timer's hours+minutes when active,
/// and — when enabled in the menu — the project name.
struct MenuBarLabel: View {
    var store: DataStore

    @AppStorage(MenuBarPrefs.showProjectKey) private var showProject = false

    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.runningEntry == nil ? "stopwatch" : "stopwatch.fill")
            if let running = store.runningEntry {
                Text(labelText(for: running))
                    .monospacedDigit()
            }
        }
        .onReceive(timer) { now = $0 }
    }

    private func labelText(for running: TimeEntry) -> String {
        var parts = [TimeFormat.hourMinute(running.duration(asOf: now))]
        if showProject {
            parts.append(store.projectName(running.projectID))
        }
        return parts.joined(separator: " · ")
    }
}

/// The dropdown shown when the menu-bar item is clicked.
struct MenuBarContent: View {
    @Environment(DataStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @AppStorage(MenuBarPrefs.showProjectKey) private var showProject = false

    var body: some View {
        if let running = store.runningEntry {
            Text("Tracking: \(store.projectName(running.projectID))")
            Button("Stop Timer") { store.stop() }
            // Disabled hint rows — these are global shortcuts, not menu actions.
            Text(DataStore.startNudgeHint)
            Text(DataStore.discardRunningHint)
        } else {
            Text("No timer running")
        }

        // Today's goal status — one disabled line per goal, in the same order as the Goals
        // pane. Computed when the menu's body is evaluated (each open, and on any store
        // change); no ticking, matching the rest of the dropdown.
        if !store.goals.isEmpty {
            Divider()
            Section("Goals") {
                // One instant for the whole section, so a project's two rows can't disagree.
                let now = Date()
                ForEach(store.orderedGoals) { goal in
                    Text(goalLine(goal, asOf: now))
                }
            }
        }

        // The project list is the quick-launch list, so only the first nine carry a ⌃⌥⌘N
        // shortcut — the rest are listed without one and start on click. Reordering the sidebar
        // list is how the user picks which nine those are.
        if !store.projects.isEmpty {
            Divider()
            Section("Projects") {
                ForEach(Array(store.projects.enumerated()), id: \.element.id) { index, project in
                    Button {
                        store.toggleProject(at: index)
                    } label: {
                        Text(rowTitle(name: project.name,
                                      running: store.isRunning(projectID: project.id),
                                      shortcut: store.projectHasShortcut(at: index)
                                          ? ProjectHotKey.shortcutLabel(index: index)
                                          : nil))
                    }
                }
            }
        }

        Divider()
        Section("Menu Bar") {
            Toggle("Show project name", isOn: $showProject)
        }

        Divider()
        Button("Open Time Tracker") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Button("Quit Time Tracker") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// One goal status line: "✓ Deep Work  5:12 / 5h" (an "at least" goal met),
    /// "! Email  3:20 / 3h — over" (an "at most" limit exceeded), "· Reading  2:10 / 5h"
    /// otherwise. Deliberately none of this menu's action glyphs (▶/⏹) — these rows are
    /// status, not buttons.
    private func goalLine(_ goal: Goal, asOf now: Date) -> String {
        let total = store.todayTotal(projectID: goal.projectID, asOf: now)
        let pair = "\(TimeFormat.hourMinute(total)) / \(TimeFormat.abbreviated(goal.target))"
        let name = store.projectName(goal.projectID)
        switch goal.kind {
        case .atLeast where goal.isSatisfied(total: total):
            return "✓ \(name)  \(pair)"
        case .atMost where !goal.isSatisfied(total: total):
            return "! \(name)  \(pair) — over"
        default:
            return "· \(name)  \(pair)"
        }
    }

    /// One quick-launch row: a ▶/⏹ state glyph, the project name, and the project's global
    /// shortcut when its position has one.
    private func rowTitle(name: String, running: Bool, shortcut: String?) -> String {
        let row = "\(running ? "⏹" : "▶") \(name)"
        guard let shortcut else { return row }
        return "\(row)  (\(shortcut))"
    }
}
