import SwiftUI

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
        // Re-register the global project hotkeys (⌃⌥⌘1…9) whenever the registration count changes
        // (add/remove — reordering keeps the count and re-maps the positions inside the same set of
        // registrations, so it needs no re-register). The count is the clamped one, so adding a
        // tenth project doesn't churn the registrations. Kept out of the model so Carbon/AppKit
        // never leak into DataStore; onChange runs on the main thread (which HotKeyManager
        // requires). Projects are only added and removed from the sidebar, so ContentView is
        // always alive.
        .onChange(of: store.shortcutProjectCount) { _, count in
            HotKeyManager.shared.register(projects: count)
        }
    }
}

/// The right-hand pane: the day-grouped entry list, topped by the tracker bar only while a timer
/// is running. Idle, the list fills the whole pane.
struct MainPane: View {
    @Environment(DataStore.self) private var store
    let selection: SidebarItem?
    /// Live search query from the toolbar field. Filters the entry list (and therefore the
    /// day/cluster grouping and every subtotal, which all derive from the filtered set) by
    /// matching project names. Empty = show everything.
    @State private var searchText = ""

    var body: some View {
        Group {
            if store.projects.isEmpty {
                // Single unified onboarding state — otherwise EntryListView's "No time entries yet"
                // shadows it with a message about starting a timer there are no projects for.
                ContentUnavailableView {
                    Label("No projects yet", systemImage: "folder.badge.plus")
                } description: {
                    Text("Use “New Project” at the bottom of the sidebar to start tracking time.")
                }
            } else {
                VStack(spacing: 0) {
                    // Always mounted, and takes no space while idle. It must not be wrapped in a
                    // `runningEntry != nil` conditional here: it hosts the running-timer editor
                    // sheet, which has to outlive a stop fired from elsewhere (see TrackerBar).
                    TrackerBar()
                    EntryListView(selection: selection, searchText: searchText)
                }
            }
        }
        .navigationTitle(title)
        // Native toolbar search field (⌘F focuses it). Matches project names.
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search projects")
    }

    private var title: String {
        switch selection {
        case .project(let id): return store.projectName(id)
        default: return "All Projects"
        }
    }
}
