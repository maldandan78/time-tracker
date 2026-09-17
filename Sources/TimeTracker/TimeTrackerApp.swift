import SwiftUI
import AppKit

@main
struct TimeTrackerApp: App {
    @State private var store = DataStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // A single-instance Window (not WindowGroup): openWindow(id:"main") focuses the existing
        // window or recreates it if closed, instead of spawning duplicates.
        Window("Time Tracker", id: MainWindow.id) {
            ContentView()
                .environment(store)
                .frame(minWidth: 720, minHeight: 420)
                .captureMainWindowOpener()
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

/// How a closed main window gets back on screen.
///
/// The app deliberately outlives its window so the global hotkeys keep working, and closing that
/// window only orders it out — so a Dock-icon click has nothing for AppKit's default reopen to
/// restore, and the app comes forward as a menu bar and nothing else unless someone puts the
/// window back. Ordering it front again is enough for that case; should SwiftUI ever discard the
/// window instead, recreating it takes `openWindow`, which exists only inside a view — so the
/// views hand their action over here for the delegate (and the menu-bar item) to fall back on.
@MainActor
enum MainWindow {
    static let id = "main"

    private static var opener: (() -> Void)?

    /// Called by every view that carries the action, so one is on file before the window is ever
    /// closed — see `captureMainWindowOpener()`.
    static func capture(_ openWindow: OpenWindowAction) {
        opener = { openWindow(id: id) }
    }

    /// Put the main window back in front: deminiaturized and ordered front if AppKit still has
    /// it, recreated through SwiftUI if not.
    static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let window = existing {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            opener?()
        }
    }

    /// The main window, while AppKit still has it — which survives a close, but not necessarily
    /// forever. `MenuBarExtra`'s status-item window and any panel can't become main, which is
    /// what tells them apart from ours.
    private static var existing: NSWindow? {
        NSApp.windows.first { $0.canBecomeMain && !($0 is NSPanel) }
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

    /// A Dock-icon click (or `open -a`). AppKit's default reopen won't bring back a window that
    /// was closed rather than minimized, so put it back here and return false to keep AppKit
    /// from also trying.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}

extension View {
    /// Files this view's `openWindow` action with `MainWindow`, so the app delegate can reopen the
    /// main window from outside SwiftUI. Applied to both the window's own content and the
    /// menu-bar label: the label outlives every window, so an action is always on file, and the
    /// action stays usable for the life of the app.
    func captureMainWindowOpener() -> some View {
        modifier(CaptureMainWindowOpener())
    }
}

private struct CaptureMainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { MainWindow.capture(openWindow) }
    }
}
