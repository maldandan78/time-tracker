import SwiftUI
import AppKit

@main
struct TimeTrackerApp: App {
    @State private var store = DataStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single-instance Window (not WindowGroup): openWindow(id:"main") focuses the existing
        // window or recreates it if closed, instead of spawning duplicates.
        Window("Time Tracker", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent()
                .environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Global ⌃⌥⌘1…N → toggle the project in that position of the sidebar list: start it, or
        // stop it if it's already running.
        HotKeyManager.shared.onFire = { number in
            DataStore.shared.toggleProject(at: number - 1)
        }
        // Global ⇧⌃⌥⌘→ / ⇧⌃⌥⌘← → add / reduce working time on the running timer by moving its
        // start earlier / later; ⇧⌃⌥⌘⌦ → stop the running timer and throw the entry away. All are
        // no-ops when no timer is running.
        HotKeyManager.shared.onCommand = { command in
            switch command {
            case .runningStartEarlier:
                DataStore.shared.nudgeRunningStart(by: -DataStore.startNudgeStep)
            case .runningStartLater:
                DataStore.shared.nudgeRunningStart(by: DataStore.startNudgeStep)
            case .discardRunning:
                DataStore.shared.discardRunning()
            }
        }
        HotKeyManager.shared.register(projects: DataStore.shared.shortcutProjectCount)
    }

    // Stay alive when the window is closed so the global project hotkeys keep working.
    // The window reopens on dock-icon click; ⌘Q quits fully.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
