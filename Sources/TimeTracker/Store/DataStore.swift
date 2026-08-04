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

    /// Positional global shortcuts available per list — one per digit key (1…9).
    static let maxShortcuts = HotKeyManager.maxPerGroup

    /// Hard cap on pins — one per ⌃⌥⌘1…9.
    static let maxPins = maxShortcuts

    private(set) var projects: [Project] = []
    private(set) var entries: [TimeEntry] = []
    /// Dense, ordered, reorderable pins (0…9 elements). Index i is bound to ⌃⌥⌘(i+1); reordering the
    /// array re-maps the shortcuts. Reorderable exactly like `favorites`. Observable so the
    /// sidebar/menu lists and the hotkey layer react.
    private(set) var pins: [Pin] = []
    /// Unlimited, reorderable saved sessions. The first `maxShortcuts` are bound to ⇧⌃⌥⌘1…9 by the
    /// same positional rule as pins (index i → ⇧⌃⌥⌘(i+1)); any beyond that are start-by-click only.
    private(set) var favorites: [Favorite] = []

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

    /// Deletes a project and cascades to all of its time entries, pins, and favorites.
    func deleteProject(_ id: UUID) {
        projects.removeAll { $0.id == id }
        entries.removeAll { $0.projectID == id }
        pins.removeAll { $0.projectID == id }
        favorites.removeAll { $0.projectID == id }
        save()
    }

    /// Reorders projects in the sidebar. The array order is the persisted display order.
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

    // MARK: - Timer

    /// Starts tracking. Stops any currently-running entry first (single-timer rule).
    func start(projectID: UUID, note: String) {
        let now = Date()
        stopRunning(asOf: now)
        let entry = TimeEntry(
            projectID: projectID,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            start: now,
            end: nil
        )
        entries.append(entry)
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

    /// Edits a finished entry's project, description, start, and end. `end` is clamped to be no
    /// earlier than `start`. (Pass `end: nil` only when you intend the entry to be running.)
    func updateEntry(_ id: UUID, projectID: UUID, note: String, start: Date, end: Date?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].projectID = projectID
        entries[idx].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[idx].start = start
        entries[idx].end = end.map { max($0, start) }
        save()
    }

    /// Edits project/description/start while leaving the entry's running/finished state untouched.
    /// Used by the running-timer editor so that if the entry is stopped underneath an open sheet
    /// (e.g. a pin hotkey fires), saving can't resurrect it into a second concurrent running timer.
    func updateEntryDetails(_ id: UUID, projectID: UUID, note: String, start: Date) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].projectID = projectID
        entries[idx].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[idx].start = start
        if let end = entries[idx].end { entries[idx].end = max(end, start) }
        save()
    }

    /// Retitles several entries at once — sets a new project + description on all of them while
    /// leaving each entry's start/end untouched. Backs the grouped-entry editor, which edits a whole
    /// cluster's project/description but never its times.
    func updateEntries(_ ids: [UUID], projectID: UUID, note: String) {
        let set = Set(ids)
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = false
        for i in entries.indices where set.contains(entries[i].id) {
            entries[i].projectID = projectID
            entries[i].note = trimmed
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Running helpers

    /// Whether the currently-running entry matches this project + description.
    func isRunning(projectID: UUID, note: String) -> Bool {
        guard let running = runningEntry else { return false }
        return running.projectID == projectID && running.note == note
    }

    func isRunning(pin: Pin) -> Bool { isRunning(projectID: pin.projectID, note: pin.note) }

    func isRunning(favorite: Favorite) -> Bool {
        isRunning(projectID: favorite.projectID, note: favorite.note)
    }

    // MARK: - Pins (dense, ordered, capped at 9 — mirrors Favorites)

    /// Adds a pin (inserted at `index`, or appended). Skips exact (project, description)
    /// duplicates and is a no-op once at `maxPins`, so ⌃⌥⌘N never maps to an ambiguous or
    /// overflowed session. Array order == badge order (pin i → ⌃⌥⌘(i+1)).
    func addPin(at index: Int? = nil, projectID: UUID, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pins.contains(where: { $0.projectID == projectID && $0.note == trimmed }) else { return }
        guard pins.count < Self.maxPins else { return }
        let pin = Pin(projectID: projectID, note: trimmed)
        if let index, index >= 0, index <= pins.count {
            pins.insert(pin, at: index)
        } else {
            pins.append(pin)
        }
        save()
    }

    /// Removes the pin with this id (signature unchanged so the drag-out remove in MainPane works).
    func removePin(_ id: UUID) {
        pins.removeAll { $0.id == id }
        save()
    }

    /// Edits a pin's project + description in place (used by the edit sheet).
    func updatePin(_ id: UUID, projectID: UUID, note: String) {
        guard let idx = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[idx].projectID = projectID
        pins[idx].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    /// Reorders pins via the List's native drag (System insertion indicator). Reorder does NOT change
    /// pins.count, so no hotkey re-registration is needed; only the index→pin (⌃⌥⌘N) mapping shifts.
    func movePins(fromOffsets source: IndexSet, toOffset destination: Int) {
        pins.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Starts the pin at `index` (stops + saves any running entry first). Index- and project-guarded.
    func startPin(at index: Int) {
        guard pins.indices.contains(index),
              projects.contains(where: { $0.id == pins[index].projectID }) else { return }
        start(projectID: pins[index].projectID, note: pins[index].note)
    }

    /// Toggles the pin at `index`: stops it if it's the running session, otherwise starts it.
    /// A stale hotkey id past the current end of the list is a safe no-op.
    func togglePin(at index: Int) {
        guard pins.indices.contains(index) else { return }
        if isRunning(pin: pins[index]) { stop() } else { startPin(at: index) }
    }

    // MARK: - Favorites (unlimited; the first 9 also carry a ⇧⌃⌥⌘N shortcut)

    /// How many favorites currently have a ⇧⌃⌥⌘N shortcut. Favorites are unlimited but only nine
    /// digit keys exist, so the list's first `maxShortcuts` entries are the ones bound to hotkeys.
    var shortcutFavoriteCount: Int { min(favorites.count, Self.maxShortcuts) }

    /// Whether the favorite at `index` has a ⇧⌃⌥⌘N shortcut (used for badges/tooltips).
    func favoriteHasShortcut(at index: Int) -> Bool { index < Self.maxShortcuts }

    /// Adds a favorite (at `index`, or appended). Skips exact (project, description) duplicates.
    func addFavorite(at index: Int? = nil, projectID: UUID, note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !favorites.contains(where: { $0.projectID == projectID && $0.note == trimmed }) else { return }
        let favorite = Favorite(projectID: projectID, note: trimmed)
        if let index, index >= 0, index <= favorites.count {
            favorites.insert(favorite, at: index)
        } else {
            favorites.append(favorite)
        }
        save()
    }

    func removeFavorite(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        save()
    }

    /// Reorders favorites via the List's native drag (system insertion indicator). Reorder does NOT
    /// change favorites.count, so no hotkey re-registration is needed; only the index→favorite
    /// (⇧⌃⌥⌘N) mapping shifts — dragging a favorite into the top nine gives it a shortcut.
    func moveFavorites(fromOffsets source: IndexSet, toOffset destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Starts the favorite at `index` (stops + saves any running entry first). Index- and
    /// project-guarded, exactly like `startPin(at:)`.
    func startFavorite(at index: Int) {
        guard favorites.indices.contains(index),
              projects.contains(where: { $0.id == favorites[index].projectID }) else { return }
        start(projectID: favorites[index].projectID, note: favorites[index].note)
    }

    /// Toggles the favorite at `index`: stops it if it's the running session, otherwise starts it.
    /// A stale hotkey id past the current end of the list is a safe no-op.
    func toggleFavorite(at index: Int) {
        guard favorites.indices.contains(index) else { return }
        if isRunning(favorite: favorites[index]) { stop() } else { startFavorite(at: index) }
    }

    // MARK: - Pin sanitisation

    /// Dedups persisted pins by (project, description) and caps to `maxPins`, PRESERVING array order.
    /// Replaces the old slot mapping — legacy per-pin `slot` keys are already ignored at decode, so
    /// order is simply the stored array order. Guards a hand-edited file with duplicates or > 9 pins.
    private static func sanitizedPins(from raw: [Pin]) -> [Pin] {
        var result: [Pin] = []
        var seen = Set<String>()
        for pin in raw {
            guard result.count < maxPins else { break }
            guard seen.insert("\(pin.projectID.uuidString)|\(pin.note)").inserted else { continue }
            result.append(pin)
        }
        return result
    }

    // MARK: - Export

    /// Writes the whole data document as JSON to ~/Downloads and returns the file URL.
    @discardableResult
    func exportData() -> URL? {
        let snapshot = AppData(projects: projects, entries: entries, pins: pins, favorites: favorites)
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
            self.pins = Self.sanitizedPins(from: decoded.pins)
            self.favorites = decoded.favorites
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
        let snapshot = AppData(projects: projects, entries: entries, pins: pins, favorites: favorites)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder.appEncoder.encode(snapshot)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("TimeTracker: could not save data: \(error)")
        }
    }
}
