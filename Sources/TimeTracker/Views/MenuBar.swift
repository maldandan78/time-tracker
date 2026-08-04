import SwiftUI
import AppKit

/// UserDefaults keys for the menu-bar display toggles (shared by the label + the menu).
enum MenuBarPrefs {
    static let showProjectKey = "menuBarShowProject"
    static let showDescriptionKey = "menuBarShowDescription"
}

/// The status-bar label: a stopwatch symbol, plus the running timer's hours+minutes when active,
/// and — when enabled in the menu — the project name and/or the task description.
struct MenuBarLabel: View {
    var store: DataStore

    @AppStorage(MenuBarPrefs.showProjectKey) private var showProject = false
    @AppStorage(MenuBarPrefs.showDescriptionKey) private var showDescription = false

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
        if showDescription, !running.note.isEmpty {
            parts.append(running.note)
        }
        return parts.joined(separator: " · ")
    }
}

/// The dropdown shown when the menu-bar item is clicked.
struct MenuBarContent: View {
    @Environment(DataStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @AppStorage(MenuBarPrefs.showProjectKey) private var showProject = false
    @AppStorage(MenuBarPrefs.showDescriptionKey) private var showDescription = false

    var body: some View {
        if let running = store.runningEntry {
            Text("Tracking: \(store.projectName(running.projectID))")
            if !running.note.isEmpty {
                Text(running.note)
            }
            Button("Stop Timer") { store.stop() }
            // Disabled hint row — the nudge itself is a global shortcut, not a menu action.
            Text(DataStore.startNudgeHint)
        } else {
            Text("No timer running")
        }

        if !store.pins.isEmpty {
            Divider()
            Section("Pins") {
                ForEach(Array(store.pins.enumerated()), id: \.element.id) { index, pin in
                    Button {
                        store.togglePin(at: index)
                    } label: {
                        Text(rowTitle(note: pin.note,
                                      projectID: pin.projectID,
                                      running: store.isRunning(pin: pin),
                                      shortcut: HotKeyGroup.pin.shortcutLabel(index: index)))
                    }
                }
            }
        }

        // Favorites are unlimited, so only the first nine carry a ⇧⌃⌥⌘N shortcut — the rest are
        // listed without one and start on click.
        if !store.favorites.isEmpty {
            Divider()
            Section("Favorites") {
                ForEach(Array(store.favorites.enumerated()), id: \.element.id) { index, favorite in
                    Button {
                        store.toggleFavorite(at: index)
                    } label: {
                        Text(rowTitle(note: favorite.note,
                                      projectID: favorite.projectID,
                                      running: store.isRunning(favorite: favorite),
                                      shortcut: store.favoriteHasShortcut(at: index)
                                          ? HotKeyGroup.favorite.shortcutLabel(index: index)
                                          : nil))
                    }
                }
            }
        }

        Divider()
        Section("Menu Bar") {
            Toggle("Show project name", isOn: $showProject)
            Toggle("Show description", isOn: $showDescription)
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

    /// One quick-launch row: a ▶/⏹ state glyph, the description (or project name when blank), and
    /// the item's global shortcut when it has one.
    private func rowTitle(note: String, projectID: UUID, running: Bool, shortcut: String?) -> String {
        let title = note.isEmpty ? store.projectName(projectID) : note
        let row = "\(running ? "⏹" : "▶") \(title)"
        guard let shortcut else { return row }
        return "\(row)  (\(shortcut))"
    }
}
