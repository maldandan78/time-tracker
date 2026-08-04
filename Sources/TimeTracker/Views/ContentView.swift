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
        // Re-register the global pin (⌃⌥⌘N) and favorite (⇧⌃⌥⌘N) hotkeys whenever either count
        // changes (add/remove — reorder keeps the counts and so needs no re-register). The favorite
        // count is the clamped one, so adding a tenth favorite doesn't churn the registrations.
        // Kept out of the model so Carbon/AppKit never leak into DataStore; onChange runs on the
        // main thread (which HotKeyManager requires). Pins/favorites are only added and removed from
        // the sidebar + main pane, so ContentView is always alive.
        .onChange(of: hotKeyCounts) { _, counts in
            HotKeyManager.shared.register(pins: counts.pins, favorites: counts.favorites)
        }
    }

    /// The two registration counts, bundled so one `onChange` covers both lists.
    private struct HotKeyCounts: Equatable {
        let pins: Int
        let favorites: Int
    }

    private var hotKeyCounts: HotKeyCounts {
        HotKeyCounts(pins: store.pins.count, favorites: store.shortcutFavoriteCount)
    }
}

/// The right-hand pane: the always-visible tracker bar over the day-grouped entry list.
struct MainPane: View {
    @Environment(DataStore.self) private var store
    let selection: SidebarItem?
    /// Live search query from the toolbar field. Filters the entry list (and therefore the
    /// day/cluster grouping and every subtotal, which all derive from the filtered set) by
    /// matching entry descriptions and project names. Empty = show everything.
    @State private var searchText = ""

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
                    EntryListView(selection: selection, searchText: searchText)
                }
            }
        }
        .navigationTitle(title)
        // Native toolbar search field (⌘F focuses it). Matches descriptions + project names.
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search descriptions or projects")
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
