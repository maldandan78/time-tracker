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
        } else {
            Text("No timer running")
        }

        if !store.pins.isEmpty {
            Divider()
            ForEach(Array(store.pins.enumerated()), id: \.element.id) { index, pin in
                Button {
                    store.togglePin(at: index)
                } label: {
                    let title = pin.note.isEmpty ? store.projectName(pin.projectID) : pin.note
                    Text("\(store.isRunning(pin: pin) ? "⏹" : "▶") \(title)  (⌃⌥⌘\(index + 1))")
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
}
