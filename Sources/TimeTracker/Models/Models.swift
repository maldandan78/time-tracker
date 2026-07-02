import Foundation

// MARK: - Domain models

/// A project that time entries are grouped under. Name-only, names unique (case-insensitive).
struct Project: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// A single tracked interval. `end == nil` means the timer is still running.
/// Entries are immutable once stopped (no editing), but may be deleted.
struct TimeEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var projectID: UUID
    var note: String
    var start: Date
    var end: Date?

    init(id: UUID = UUID(), projectID: UUID, note: String, start: Date, end: Date? = nil) {
        self.id = id
        self.projectID = projectID
        self.note = note
        self.start = start
        self.end = end
    }

    var isRunning: Bool { end == nil }

    /// Elapsed duration. For a running entry this grows toward `now`.
    func duration(asOf now: Date = Date()) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }
}

/// A quick-launch pin: a saved (project + description) that can be started instantly, including
/// via a global keyboard shortcut. Pins are a dense, freely-reorderable list capped at 9; the pin
/// at array index i is bound to Control+Option+Command+(i+1). (Older files carry a legacy `slot`
/// key — the synthesized decoder simply ignores it, and order now comes from array position.)
struct Pin: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var projectID: UUID
    var note: String

    init(id: UUID = UUID(), projectID: UUID, note: String) {
        self.id = id
        self.projectID = projectID
        self.note = note
    }
}

/// A saved (project + description) session that can be started any time. Unlike a Pin it has no
/// keyboard shortcut and no fixed slot — favorites are an unlimited, freely-reorderable list.
struct Favorite: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var projectID: UUID
    var note: String

    init(id: UUID = UUID(), projectID: UUID, note: String) {
        self.id = id
        self.projectID = projectID
        self.note = note
    }
}

/// The persisted root document.
struct AppData: Codable, Sendable {
    var projects: [Project] = []
    var entries: [TimeEntry] = []
    var pins: [Pin] = []
    var favorites: [Favorite] = []

    // Tolerate older files that predate `pins` / `favorites` (and that still carry the retired
    // `pinSlotCount` key — unknown keys are ignored by the keyed container).
    enum CodingKeys: String, CodingKey { case projects, entries, pins, favorites }
    init() {}
    init(projects: [Project], entries: [TimeEntry], pins: [Pin], favorites: [Favorite]) {
        self.projects = projects
        self.entries = entries
        self.pins = pins
        self.favorites = favorites
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        entries = try c.decodeIfPresent([TimeEntry].self, forKey: .entries) ?? []
        pins = try c.decodeIfPresent([Pin].self, forKey: .pins) ?? []
        favorites = try c.decodeIfPresent([Favorite].self, forKey: .favorites) ?? []
    }
}

// MARK: - Sidebar selection

enum SidebarItem: Hashable {
    case all
    case project(UUID)
}

// MARK: - Formatting

enum TimeFormat {
    /// Human-readable duration, always in "Xh Ym" form (e.g. "2h 14m", "0h 38m").
    static func hm(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        return "\(h)h \(m)m"
    }

    /// Ticking clock for the running timer: "01:23:45".
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Compact hours+minutes for the menu bar: "1:23", "0:05".
    static func hourMinute(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return "\(total / 3600):" + String(format: "%02d", (total % 3600) / 60)
    }

    /// Duration with seconds, Toggl-style "H:MM:SS" (e.g. "2:14:33", "0:38:00", "0:00:45").
    static func hms(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%d:%02d:%02d", h, m, s)
    }
}

// MARK: - JSON coders

extension JSONEncoder {
    static var appEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var appDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
