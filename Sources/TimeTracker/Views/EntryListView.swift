import SwiftUI

/// Day-grouped list of time entries for the current sidebar selection.
///
/// Entries that share a project within a day are clustered (Toggl-style) into one expandable row
/// with a count and combined duration. Every row has a ▶ button that starts a new entry for that
/// project. Durations show seconds (H:MM:SS).
struct EntryListView: View {
    @Environment(DataStore.self) private var store
    let selection: SidebarItem?
    /// Toolbar search query (owned by MainPane). Space-separated tokens are matched (AND) against
    /// each entry's project name; empty means no filtering.
    var searchText: String = ""

    @State private var expanded: Set<String> = []
    @State private var pendingDelete: PendingDelete?
    @State private var editingEntry: TimeEntry?
    @State private var editingGroup: EditingGroup?

    /// The current day, used to label sections "Today"/"Yesterday". Held in state (rather than read
    /// from `Date()` at render time) so the labels refresh when the calendar day rolls over while the
    /// app stays open — otherwise "Today" stays pinned to whatever day the view last rendered on.
    @Environment(\.scenePhase) private var scenePhase
    @State private var today = Calendar.current.startOfDay(for: .now)

    var body: some View {
        Group {
            if visibleEntries.isEmpty {
                if isSearching {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView(
                        "No time entries yet",
                        systemImage: "clock",
                        // Names a start path that actually exists: this empty state can only show
                        // when nothing is running, so there is no tracker bar above the list.
                        description: Text("Press ▶ next to a project in the sidebar — or "
                                          + "\(ProjectHotKey.symbolPrefix)1…\(DataStore.maxShortcuts) "
                                          + "from any app — to track your first entry.")
                    )
                }
            } else {
                list
            }
        }
        // Fill the pane so the empty state centers in the whole detail area instead of collapsing
        // to its intrinsic height (and so the running-timer bar, when there is one, stays pinned
        // at the top rather than floating with the list).
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Refresh the "Today" reference when the day rolls over. `NSCalendarDayChanged` fires at
        // midnight (and on wake if the day changed while asleep); re-checking on scene activation
        // covers the case where that notification was missed during sleep.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshToday()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshToday() }
        }
    }

    /// Advance the cached day if the wall-clock day has moved on, invalidating `body` so the
    /// section labels ("Today"/"Yesterday") recompute.
    private func refreshToday() {
        let start = Calendar.current.startOfDay(for: .now)
        if start != today { today = start }
    }

    private var list: some View {
        List {
            summaryHeader
            ForEach(dayGroups) { group in
                Section {
                    ForEach(group.clusters) { cluster in
                        clusterView(cluster)
                    }
                } header: {
                    daySubtotalHeader(group)
                }
            }
        }
        .confirmationDialog(
            deleteTitle,
            isPresented: pendingDeleteBinding,
            titleVisibility: .visible
        ) {
            if let pending = pendingDelete {
                Button(pending.confirmLabel, role: .destructive) {
                    pending.perform(store)
                    pendingDelete = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(pendingDelete?.count == 1
                 ? "This permanently deletes the entry. This cannot be undone."
                 : "This permanently deletes these entries. This cannot be undone.")
        }
        .sheet(item: $editingEntry) { entry in
            EntryEditorSheet(entry: entry).environment(store)
        }
        .sheet(item: $editingGroup) { group in
            GroupEditorSheet(entryIDs: group.entryIDs, count: group.count,
                             projectID: group.projectID)
                .environment(store)
        }
    }

    // MARK: - Cluster rows

    @ViewBuilder
    private func clusterView(_ cluster: EntryCluster) -> some View {
        if cluster.count == 1 {
            entryRow(cluster.entries[0], indented: false)
        } else {
            clusterHeader(cluster)
            if expanded.contains(cluster.id) {
                ForEach(cluster.entries) { entry in
                    entryRow(entry, indented: true)
                }
            }
        }
    }

    private func clusterHeader(_ cluster: EntryCluster) -> some View {
        HStack(spacing: 10) {
            Button {
                toggle(cluster.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded.contains(cluster.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text("\(cluster.count)")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.secondary.opacity(0.18)))
                }
            }
            .buttonStyle(.plain)
            .help(expanded.contains(cluster.id) ? "Collapse" : "Expand")

            Text(store.projectName(cluster.projectID))

            Spacer(minLength: 12)
            duration(of: { cluster.total(asOf: $0) }, live: cluster.hasRunning, running: cluster.hasRunning)
            // No ▶ when this cluster's session is running (kept invisible to preserve alignment).
            startButton(projectID: cluster.projectID)
                .opacity(cluster.hasRunning ? 0 : 1)
                .allowsHitTesting(!cluster.hasRunning)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit \(cluster.count) Entries…") {
                editingGroup = EditingGroup(cluster: cluster)
            }
            Button("Delete \(cluster.count) Entries…", role: .destructive) {
                pendingDelete = .cluster(ids: cluster.entries.map(\.id), count: cluster.count)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                editingGroup = EditingGroup(cluster: cluster)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.deleteEntries(cluster.entries.map(\.id))
            } label: {
                Label("Delete \(cluster.count)", systemImage: "trash")
            }
        }
    }

    private func entryRow(_ entry: TimeEntry, indented: Bool) -> some View {
        HStack(spacing: 10) {
            if indented {
                Text(timeRange(entry))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if entry.isRunning {
                    Text("· running").font(.caption).foregroundStyle(.green)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.projectName(entry.projectID))
                    HStack(spacing: 6) {
                        Text(timeRange(entry))
                        if entry.isRunning {
                            Text("· running").foregroundStyle(.green)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            duration(of: { entry.duration(asOf: $0) }, live: entry.isRunning, running: entry.isRunning)
            // No ▶ on the running entry itself (kept invisible to preserve alignment).
            startButton(projectID: entry.projectID)
                .opacity(entry.isRunning ? 0 : 1)
                .allowsHitTesting(!entry.isRunning)
        }
        .padding(.vertical, 2)
        .padding(.leading, indented ? 26 : 0)
        .contextMenu {
            Button("Edit…") { editingEntry = entry }
            Button("Delete…", role: .destructive) {
                pendingDelete = .single(id: entry.id)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                editingEntry = entry
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.deleteEntry(entry.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// ▶ Start a new entry for the same project (stops any running timer).
    private func startButton(projectID: UUID) -> some View {
        Button {
            store.start(projectID: projectID)
        } label: {
            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .buttonStyle(.borderless)
        .help("Start a new entry with this project")
    }

    // MARK: - Durations

    /// A duration label. Ticks every second when `live`; green when `running`.
    @ViewBuilder
    private func duration(of value: @escaping (Date) -> TimeInterval, live: Bool, running: Bool) -> some View {
        if live {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(TimeFormat.hms(value(context.date)))
                    .monospacedDigit()
                    .foregroundStyle(running ? Color.green : Color.primary)
            }
        } else {
            Text(TimeFormat.hms(value(Date())))
                .monospacedDigit()
        }
    }

    // MARK: - Headers

    /// Top summary: today's total and the current week's total for the selection. Ticks live.
    private var summaryHeader: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = context.date
                VStack(spacing: 4) {
                    HStack {
                        Text("Today").font(.headline)
                        Spacer()
                        Text(TimeFormat.hms(todayTotal(asOf: now)))
                            .font(.headline)
                            .monospacedDigit()
                    }
                    HStack {
                        Text("This week").foregroundStyle(.secondary)
                        Spacer()
                        Text(TimeFormat.hms(weekTotal(asOf: now)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func daySubtotalHeader(_ group: DayGroup) -> some View {
        if group.hasRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                dayHeaderRow(group, asOf: context.date)
            }
        } else {
            dayHeaderRow(group, asOf: Date())
        }
    }

    private func dayHeaderRow(_ group: DayGroup, asOf now: Date) -> some View {
        HStack {
            Text(dayLabel(group.day))
            Spacer()
            Text(TimeFormat.hms(group.total(asOf: now)))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Helpers

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func timeRange(_ entry: TimeEntry) -> String {
        let start = entry.start.formatted(.dateTime.hour().minute())
        if let end = entry.end {
            return "\(start) – \(end.formatted(.dateTime.hour().minute()))"
        }
        return "\(start) – …"
    }

    // MARK: - Delete plumbing

    private enum PendingDelete: Identifiable {
        case single(id: UUID)
        case cluster(ids: [UUID], count: Int)

        var id: String {
            switch self {
            case .single(let id): return "s-\(id.uuidString)"
            case .cluster(let ids, _): return "c-\(ids.first?.uuidString ?? "")"
            }
        }
        var count: Int {
            switch self {
            case .single: return 1
            case .cluster(_, let count): return count
            }
        }
        var confirmLabel: String {
            count == 1 ? "Delete Entry" : "Delete \(count) Entries"
        }
        func perform(_ store: DataStore) {
            switch self {
            case .single(let id): store.deleteEntry(id)
            case .cluster(let ids, _): store.deleteEntries(ids)
            }
        }
    }

    /// A snapshot of the grouped-entry cluster currently being edited (project only).
    /// Captures the member ids up front so the edit applies even if the list recomputes underneath.
    private struct EditingGroup: Identifiable {
        let id: String
        let entryIDs: [UUID]
        let count: Int
        let projectID: UUID

        init(cluster: EntryCluster) {
            id = cluster.id
            entryIDs = cluster.entries.map(\.id)
            count = cluster.count
            projectID = cluster.projectID
        }
    }

    private var pendingDeleteBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var deleteTitle: String {
        guard let pending = pendingDelete else { return "Delete?" }
        return pending.count == 1 ? "Delete this entry?" : "Delete these \(pending.count) entries?"
    }

    // MARK: - Data

    private var visibleEntries: [TimeEntry] {
        let scoped: [TimeEntry]
        switch selection {
        case .project(let id): scoped = store.entries.filter { $0.projectID == id }
        default: scoped = store.entries
        }
        return filtered(scoped)
    }

    /// Whether a non-blank search query is active.
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Case-insensitive boolean search over each entry's project name. Adjacent terms AND together,
    /// and `&`, `|`, `!`, `( )` are honored (see `SearchQuery`). So `time track` matches
    /// "Time Tracker", `client | admin` matches either, and `web !legacy` excludes "Legacy Web".
    private func filtered(_ entries: [TimeEntry]) -> [TimeEntry] {
        let query = SearchQuery(searchText)
        guard query.isActive else { return entries }
        return entries.filter { query.matches(store.projectName($0.projectID)) }
    }

    private func todayTotal(asOf now: Date) -> TimeInterval {
        let cal = Calendar.current
        return visibleEntries
            .filter { cal.isDateInToday($0.start) }
            .reduce(0) { $0 + $1.duration(asOf: now).rounded(.down) }
    }

    /// Total for the calendar week containing `now`, using the locale's first weekday. Derived from
    /// `now` on every tick, so it rolls over on its own when the week changes while the app is open.
    private func weekTotal(asOf now: Date) -> TimeInterval {
        let cal = Calendar.current
        guard let week = cal.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return visibleEntries
            .filter { week.contains($0.start) }
            .reduce(0) { $0 + $1.duration(asOf: now).rounded(.down) }
    }

    /// What makes two same-day entries the same cluster. With descriptions gone, that is the
    /// project alone.
    private struct ClusterKey: Hashable {
        let projectID: UUID
    }

    private struct EntryCluster: Identifiable {
        let day: Date
        let projectID: UUID
        let entries: [TimeEntry]   // sorted by start descending

        var id: String { "\(Int(day.timeIntervalSinceReferenceDate))|\(projectID.uuidString)" }
        var count: Int { entries.count }
        var hasRunning: Bool { entries.contains { $0.isRunning } }
        var latestStart: Date { entries.first?.start ?? .distantPast }
        // Floor each member before summing so the displayed total equals the sum of the
        // (individually floored) member rows — avoids an off-by-up-to-(N-1)-seconds mismatch.
        func total(asOf now: Date) -> TimeInterval {
            entries.reduce(0) { $0 + $1.duration(asOf: now).rounded(.down) }
        }
    }

    private struct DayGroup: Identifiable {
        let day: Date
        let clusters: [EntryCluster]
        var id: Date { day }
        var hasRunning: Bool { clusters.contains { $0.hasRunning } }
        func total(asOf now: Date) -> TimeInterval {
            clusters.reduce(0) { $0 + $1.total(asOf: now) }
        }
    }

    private var dayGroups: [DayGroup] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: visibleEntries) { cal.startOfDay(for: $0.start) }
        return byDay.map { day, dayEntries in
            let byCluster = Dictionary(grouping: dayEntries) {
                ClusterKey(projectID: $0.projectID)
            }
            let clusters = byCluster
                .map { key, entries in
                    EntryCluster(day: day,
                                 projectID: key.projectID,
                                 entries: entries.sorted { $0.start > $1.start })
                }
                .sorted { $0.latestStart > $1.latestStart }
            return DayGroup(day: day, clusters: clusters)
        }
        .sorted { $0.day > $1.day }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        // Compare against the cached `today` (not `Date()`) so labels stay correct across a day
        // boundary while the app is open — `today` is refreshed on day-change / activation above.
        if cal.isDate(day, inSameDayAs: today) { return "Today" }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: today),
           cal.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}
