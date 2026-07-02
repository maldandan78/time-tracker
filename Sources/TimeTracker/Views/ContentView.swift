import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(DataStore.self) private var store
    @State private var selection: SidebarItem? = .all
    // Force the sidebar open on launch — the two-column default can render it collapsed.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            MainPane(selection: selection)
        }
        .frame(minWidth: 720, minHeight: 420)
        // Re-register global pin hotkeys whenever the pin count changes (add/remove — reorder keeps
        // the count and so needs no re-register). Kept out of the model so Carbon/AppKit never leak
        // into DataStore; onChange runs on the main thread (which HotKeyManager requires). Pins are
        // only added/removed from the sidebar + main pane, so ContentView is always alive.
        .onChange(of: store.pins.count) { _, newCount in
            HotKeyManager.shared.register(count: newCount)
        }
    }
}

/// The right-hand pane: the always-visible tracker bar over the day-grouped entry list.
struct MainPane: View {
    @Environment(DataStore.self) private var store
    let selection: SidebarItem?

    var body: some View {
        Group {
            if store.projects.isEmpty {
                // Single unified onboarding state (no redundant tracker-bar + list empty views).
                ContentUnavailableView {
                    Label("No projects yet", systemImage: "folder.badge.plus")
                } description: {
                    Text("Use “New Project” at the bottom of the sidebar to start tracking time.")
                }
            } else {
                VStack(spacing: 0) {
                    TrackerBar(preferredProjectID: preferredProjectID)
                        .background(.bar)
                    Divider()
                    EntryListView(selection: selection)
                }
            }
        }
        .navigationTitle(title)
        // Drag a pin OR a favorite out here to remove it. One low-level multi-type drop target.
        // Stacking two .dropDestination(for:) modifiers is
        // NOT reliable on macOS 14 — the outer one shadows the inner, so only one payload type
        // gets accepted. Loading inside the async closure and mutating DataStore.shared keeps any
        // non-Sendable value from crossing the closure boundary.
        .onDrop(of: [.timeTrackerPin, .timeTrackerFavorite], isTargeted: nil) { providers in
            handleRemoveDrop(providers)
        }
    }

    /// A pin payload unpins it; a favorite payload removes the favorite. Uses `DataStore.shared`
    /// inside the async load so no non-Sendable value crosses the closure.
    private func handleRemoveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.timeTrackerPin.identifier) {
            _ = provider.loadTransferable(type: PinDrag.self) { result in
                guard case .success(let drag) = result else { return }
                DispatchQueue.main.async {
                    DataStore.shared.removePin(drag.pinID)
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.timeTrackerFavorite.identifier) {
            _ = provider.loadTransferable(type: FavoriteDrag.self) { result in
                guard case .success(let drag) = result else { return }
                DispatchQueue.main.async {
                    DataStore.shared.removeFavorite(drag.favoriteID)
                }
            }
            return true
        }
        return false
    }

    /// The tracker's project picker defaults to the selected project, else the first project.
    private var preferredProjectID: UUID? {
        if case .project(let id) = selection { return id }
        return store.projects.first?.id
    }

    private var title: String {
        switch selection {
        case .project(let id): return store.projectName(id)
        default: return "All Projects"
        }
    }
}
