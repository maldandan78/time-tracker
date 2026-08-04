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

        // Global ⌃⌥⌘1…N → toggle the matching pin, ⇧⌃⌥⌘1…N → the matching favorite:
        // start it, or stop it if it's already running.
        HotKeyManager.shared.onFire = { group, number in
            switch group {
            case .pin: DataStore.shared.togglePin(at: number - 1)
            case .favorite: DataStore.shared.toggleFavorite(at: number - 1)
            }
        }
        // Global ⇧⌃⌥⌘→ / ⇧⌃⌥⌘← → add / reduce working time on the running timer by moving its
        // start earlier / later. Both are no-ops when no timer is running.
        HotKeyManager.shared.onCommand = { command in
            switch command {
            case .runningStartEarlier:
                DataStore.shared.nudgeRunningStart(by: -DataStore.startNudgeStep)
            case .runningStartLater:
                DataStore.shared.nudgeRunningStart(by: DataStore.startNudgeStep)
            }
        }
        HotKeyManager.shared.register(pins: DataStore.shared.pins.count,
                                      favorites: DataStore.shared.shortcutFavoriteCount)
    }

    // Stay alive when the window is closed so the global pin/favorite hotkeys keep working.
    // The window reopens on dock-icon click; ⌘Q quits fully.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}
