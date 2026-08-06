import Foundation
import Observation

/// Owns all app state and persists it to a JSON file in Application Support.
///
/// Confined to the main thread by convention (all access is from SwiftUI views).
/// Writes happen on start/stop/create/delete — never on the live timer tick,
/// which is computed from `start` in the views.
@Observable
final class DataStore {
    /// Single shared instance — the SwiftUI views and the global-hotkey layer both use it.
    /// Only ever accessed on the main thread, so opting out of the global-actor check is safe.
    nonisolated(unsafe) static let shared = DataStore()

    /// Positional global shortcuts available for the project list — one per digit key (1…9).
    static let maxShortcuts = HotKeyManager.maxShortcuts

    /// How much working time one press of the ⇧⌃⌥⌘→/← global shortcuts adds or removes, by moving
    /// the running timer's start.
    static let startNudgeStep: TimeInterval = 60

    /// One-line hint naming those shortcuts, shown in the tracker bar and the menu-bar menu so
    /// they're discoverable. Deliberately terse: it names the keys, not what each one does.
    static var startNudgeHint: String {
        "Adjust running time: \(HotKeyCommand.symbolPrefix)"
            + "\(HotKeyCommand.runningStartLater.keyLabel)\(HotKeyCommand.runningStartEarlier.keyLabel)"
    }

    /// One-line hint for the discard shortcut, shown next to the nudge hint so it's discoverable.
    static var discardRunningHint: String {
        "Discard running timer: \(HotKeyCommand.discardRunning.shortcutLabel)"
    }

    /// Ordered, reorderable projects — this list *is* the quick-launch list. Index i (for
    /// i < `maxShortcuts`) is bound to ⌃⌥⌘(i+1); reordering the array re-maps the shortcuts, which
    /// is how the user chooses which nine projects get one. Observable so the sidebar, the menu-bar
    /// menu, and the hotkey layer all react.
    private(set) var projects: [Project] = []
    private(set) var entries: [TimeEntry] = []

    @ObservationIgnored private let directoryURL: URL
    @ObservationIgnored private let fileURL: URL
    /// Disabled if we loaded unreadable data we couldn't quarantine — so we never
    /// overwrite a possibly-recoverable file with empty state.
    @ObservationIgnored private var canPersist = true

    /// The single currently-running entry, if any.
    var runningEntry: TimeEntry? {
        entries.first { $0.isRunning }
    }

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("TimeTracker", isDirectory: true)
        self.directoryURL = dir
        self.fileURL = dir.appendingPathComponent("data.json")
        load()
    }

    // MARK: - Projects

    /// Adds a project. Returns false if the (trimmed) name is empty or a duplicate.
    /// New projects are appended, so an existing project never loses its ⌃⌥⌘N.
    @discardableResult
    func addProject(name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !projectNameExists(trimmed, excluding: nil) else { return false }
        projects.append(Project(name: trimmed))
        save()
        return true
    }

    /// Renames a project. Returns false if empty or a duplicate of another project.
    @discardableResult
    func renameProject(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !projectNameExists(trimmed, excluding: id) else { return false }
        guard let idx = projects.firstIndex(where: { $0.id == id }) else { return false }
        projects[idx].name = trimmed
        save()
        return true
    }

    /// Deletes a project and cascades to all of its time entries — including a running one, which
    /// would otherwise keep ticking against a project that no longer exists.
    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        entries.removeAll { $0.projectID == id }
        save()
    }

    /// Reorders projects in the sidebar. The array order is the persisted display order *and* the
    /// ⌃⌥⌘1…9 mapping, so a drag can hand a shortcut to a different project. The count doesn't
    /// change, so no hotkey re-registration is needed.
    func moveProjects(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func projectNameExists(_ name: String, excluding: UUID?) -> Bool {
        projects.contains {
            $0.id != excluding &&
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
    }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    func projectName(_ id: UUID) -> String { project(id)?.name ?? "(deleted)" }

    func entryCount(for projectID: UUID) -> Int {
        entries.reduce(0) { $0 + ($1.projectID == projectID ? 1 : 0) }
    }

    // MARK: - Positional shortcuts

    /// How many projects currently have a ⌃⌥⌘N shortcut. Projects are unlimited but only nine digit
    /// keys exist, so the list's first `maxShortcuts` entries are the ones bound to hotkeys. This is
    /// also what the app re-registers on, so it must change only when the *count* changes.
    var shortcutProjectCount: Int { min(projects.count, Self.maxShortcuts) }

    /// Whether the project at `index` has a ⌃⌥⌘N shortcut (used for badges and tooltips).
    func projectHasShortcut(at index: Int) -> Bool { index < Self.maxShortcuts }

    // MARK: - Timer

    /// Starts tracking a project. Stops any currently-running entry first (single-timer rule), so
    /// re-starting the project that is already running simply begins a fresh entry — the only way
    /// to reach that is the ▶ button on a history row, and `toggleProject(at:)` covers the
    /// stop-instead case for the shortcuts and the sidebar buttons.
    func start(projectID: UUID) {
        let now = Date()
        stopRunning(asOf: now)
        entries.append(TimeEntry(projectID: projectID, start: now, end: nil))
        save()
    }

    /// Stops the running entry, if any.
    func stop() {
        stopRunning(asOf: Date())
        save()
    }

    private func stopRunning(asOf date: Date) {
        guard let idx = entries.firstIndex(where: { $0.isRunning }) else { return }
        // Guard against a clock that produced an end before start.
        entries[idx].end = max(date, entries[idx].start)
    }

    /// Shifts the running entry's start by `delta` (negative = earlier, i.e. a longer session) so a
    /// late Start can be corrected without opening the editor. Backs the ⇧⌃⌥⌘→/← global shortcuts.
    ///
    /// A no-op — with no save — when nothing is running, which is what makes the shortcuts inert
    /// while idle. Moving the start later never pushes it past now, matching the running-timer
    /// editor's rule that a live start can't be in the future: the last step before now is clamped
    /// to now (a zero-length session) instead of overshooting into negative elapsed time.
    /// Returns whether the start actually moved.
    @discardableResult
    func nudgeRunningStart(by delta: TimeInterval) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.isRunning }) else { return false }
        let newStart = min(entries[idx].start.addingTimeInterval(delta), Date())
        guard newStart != entries[idx].start else { return false }
        entries[idx].start = newStart
        save()
        return true
    }

    /// Stops the running entry *and* throws it away, so an accidental or mistaken session leaves no
    /// record. Backs the ⇧⌃⌥⌘⌦ global shortcut. Only ever touches the running entry — finished
    /// entries are never at risk — and is a no-op, with no save, when nothing is running, which is
    /// what makes the shortcut inert while idle. Returns whether an entry was discarded.
    @discardableResult
    func discardRunning() -> Bool {
        guard let idx = entries.firstIndex(where: { $0.isRunning }) else { return false }
        entries.remove(at: idx)
        save()
        return true
    }

    /// Starts the project at `index` (stops + saves any running entry first). Index-guarded, so a
    /// stale hotkey id past the current end of the list is a safe no-op.
    func startProject(at index: Int) {
        guard projects.indices.contains(index) else { return }
        start(projectID: projects[index].id)
    }

    /// Toggles the project at `index`: stops it if it's the running session, otherwise starts it.
    /// This is what ⌃⌥⌘N, the sidebar play/stop buttons, and the menu-bar rows all call, so the same
    /// key both starts and stops. A stale index is a safe no-op.
    func toggleProject(at index: Int) {
        guard projects.indices.contains(index) else { return }
        if isRunning(projectID: projects[index].id) { stop() } else { startProject(at: index) }
    }

    // MARK: - Entries

    /// Deletes a single entry.
    func deleteEntry(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Deletes several entries at once (e.g. a whole grouped cluster), with a single save.
    func deleteEntries(_ ids: [UUID]) {
        let set = Set(ids)
        entries.removeAll { set.contains($0.id) }
        save()
    }

    func entry(_ id: UUID) -> TimeEntry? { entries.first { $0.id == id } }

    /// Edits a finished entry's project, start, and end. `end` is clamped to be no earlier than
    /// `start`. (Pass `end: nil` only when you intend the entry to be running.)
    func updateEntry(_ id: UUID, projectID: UUID, start: Date, end: Date?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].projectID = projectID
        entries[idx].start = start
        entries[idx].end = end.map { max($0, start) }
        save()
    }

    /// Edits project/start while leaving the entry's running/finished state untouched.
    /// Used by the running-timer editor so that if the entry is stopped underneath an open sheet
    /// (e.g. a project hotkey fires), saving can't resurrect it into a second concurrent running
    /// timer.
    func updateEntryDetails(_ id: UUID, projectID: UUID, start: Date) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].projectID = projectID
        entries[idx].start = start
        if let end = entries[idx].end { entries[idx].end = max(end, start) }
        save()
    }

    /// Re-projects several entries at once — moves all of them to a new project while leaving each
    /// entry's start/end untouched. Backs the grouped-entry editor, which edits a whole cluster's
    /// project but never its times.
    func updateEntries(_ ids: [UUID], projectID: UUID) {
        let set = Set(ids)
        var changed = false
        for i in entries.indices where set.contains(entries[i].id) {
            entries[i].projectID = projectID
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Running helpers

    /// Whether the currently-running entry belongs to this project.
    func isRunning(projectID: UUID) -> Bool {
        runningEntry?.projectID == projectID
    }

    // MARK: - Export

    /// Writes the whole data document as JSON to ~/Downloads and returns the file URL.
    @discardableResult
    func exportData() -> URL? {
        let snapshot = AppData(projects: projects, entries: entries)
        guard let data = try? JSONEncoder.appEncoder.encode(snapshot) else { return nil }
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = downloads.appendingPathComponent("TimeTracker-\(stamp.string(from: Date())).json")
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            NSLog("TimeTracker: export failed: \(error)")
            return nil
        }
    }

    // MARK: - Persistence

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.appDecoder.decode(AppData.self, from: data)
            self.projects = decoded.projects
            self.entries = decoded.entries
        } catch {
            // Quarantine the unreadable file under a unique name (never delete a prior backup)
            // and start fresh. If we can't move it aside, disable persistence so the next
            // save() can't clobber a file that might still be recoverable.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = directoryURL.appendingPathComponent("data.corrupt-\(stamp).json")
            do {
                try fm.moveItem(at: fileURL, to: backup)
                NSLog("TimeTracker: unreadable data quarantined to \(backup.lastPathComponent) (\(error))")
            } catch {
                canPersist = false
                NSLog("TimeTracker: data unreadable and could not be quarantined — persistence disabled this session (\(error))")
            }
        }
    }

    private func save() {
        guard canPersist else { return }
        let snapshot = AppData(projects: projects, entries: entries)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.appEncoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("TimeTracker: could not save data: \(error)")
        }
    }
}
