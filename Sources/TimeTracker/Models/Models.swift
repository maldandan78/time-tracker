import Foundation

// MARK: - Domain models

/// A project that time entries are grouped under. Name-only, names unique (case-insensitive).
/// The array order in `AppData.projects` is the display order *and* the shortcut order: the project
/// at index i (for i < 9) is bound to Control+Option+Command+(i+1).
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

/// A single tracked interval — a project and a span of time, nothing else.
/// `end == nil` means the timer is still running.
struct TimeEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var projectID: UUID
    var start: Date
    var end: Date?

    init(id: UUID = UUID(), projectID: UUID, start: Date, end: Date? = nil) {
        self.id = id
        self.projectID = projectID
        self.start = start
        self.end = end
    }

    var isRunning: Bool { end == nil }

    /// Elapsed duration. For a running entry this grows toward `now`.
    func duration(asOf now: Date = Date()) -> TimeInterval {
        max(0, (end ?? now).timeIntervalSince(start))
    }
}

/// The persisted root document.
struct AppData: Codable, Sendable {
    var projects: [Project] = []
    var entries: [TimeEntry] = []

    // The hand-written decoder tolerates a partial or hand-edited file: a missing `projects` or
    // `entries` key decodes to [] instead of throwing (which would trip the corrupt-file
    // quarantine). Legacy keys from the pin/favorite era — `pins`, `favorites`, `pinSlotCount`,
    // and the per-entry `note` — are simply not read, so old files load and are rewritten clean.
    enum CodingKeys: String, CodingKey { case projects, entries }

    init() {}

    init(projects: [Project], entries: [TimeEntry]) {
        self.projects = projects
        self.entries = entries
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        entries = try c.decodeIfPresent([TimeEntry].self, forKey: .entries) ?? []
    }
}

// MARK: - Sidebar selection

enum SidebarItem: Hashable {
    case all
    case project(UUID)
}

// MARK: - Formatting

enum TimeFormat {
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
