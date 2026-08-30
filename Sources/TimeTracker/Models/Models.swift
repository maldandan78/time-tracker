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

// MARK: - Goals

/// What a daily goal asks of a project's day total: reach the target, or stay within it.
enum GoalKind: String, Codable, CaseIterable, Sendable {
    /// Work *at least* this long per day — met once the day's total reaches the target.
    case atLeast
    /// Work *at most* this long per day — violated once the day's total exceeds the target.
    case atMost
}

/// A per-project daily target. `target` is seconds per day, always within `targetRange`, and
/// at most one goal exists per (project, kind) pair — both enforced by DataStore and repaired
/// on load for hand-edited files.
struct Goal: Identifiable, Codable, Hashable, Sendable {
    /// The meaningful range for a daily target — a minute to a full day. DataStore enforces it
    /// on add/update and drops stray values on load, so rendering code can trust `target`:
    /// no zero-division in progress fractions, and no hand-edited absurdity (say 1e19) left to
    /// overflow TimeFormat's Int conversions.
    static let targetRange: ClosedRange<TimeInterval> = 60...86_400

    let id: UUID
    var projectID: UUID
    var kind: GoalKind
    var target: TimeInterval

    init(id: UUID = UUID(), projectID: UUID, kind: GoalKind, target: TimeInterval) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.target = target
    }

    /// Whether a day's `total` currently satisfies the goal. Both kinds are satisfied at
    /// exactly the target: "at least 5h" reads as "reach 5h", and sitting exactly on an
    /// "at most" limit hasn't exceeded it.
    func isSatisfied(total: TimeInterval) -> Bool {
        switch kind {
        case .atLeast: return total >= target
        case .atMost: return total <= target
        }
    }

    /// How far the day has come toward the target/limit, clamped to 0…1 for progress bars.
    func fraction(total: TimeInterval) -> Double {
        min(1, max(0, total / target))
    }
}

/// Decodes a Goal but swallows element-level failures, so one malformed goal — or one written
/// by a future version with a kind this build doesn't know — is dropped instead of failing the
/// whole document. Deliberately no fallback kind: misreading an unknown kind as `atLeast`
/// could invert an "at most" goal's meaning.
private struct FailableGoal: Decodable {
    let goal: Goal?
    init(from decoder: any Decoder) {
        goal = try? Goal(from: decoder)
    }
}

/// The persisted root document.
struct AppData: Codable, Sendable {
    var projects: [Project] = []
    var entries: [TimeEntry] = []
    var goals: [Goal] = []

    // The hand-written decoder tolerates a partial or hand-edited file: a missing `projects`,
    // `entries`, or `goals` key decodes to [] instead of throwing (which would trip the
    // corrupt-file quarantine). `goals` goes further: a wrong-typed value also decodes to []
    // and a bad element is dropped (see FailableGoal) — unlike projects and entries, whose
    // malformed values still quarantine the file. Legacy keys from the pin/favorite era —
    // `pins`, `favorites`, `pinSlotCount`, and the per-entry `note` — are simply not read,
    // so old files load and are rewritten clean.
    enum CodingKeys: String, CodingKey { case projects, entries, goals }

    init() {}

    /// `goals` deliberately has no default — save() and exportData() must pass it, so adding
    /// the field can't leave a snapshot call site silently writing `goals: []` forever.
    init(projects: [Project], entries: [TimeEntry], goals: [Goal]) {
        self.projects = projects
        self.entries = entries
        self.goals = goals
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        entries = try c.decodeIfPresent([TimeEntry].self, forKey: .entries) ?? []
        goals = ((try? c.decode([FailableGoal].self, forKey: .goals)) ?? []).compactMap(\.goal)
    }
}

// MARK: - Sidebar selection

enum SidebarItem: Hashable {
    case all
    case goals
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

    /// Hours+minutes with unit letters for goal targets: "5h", "2h 30m", "45m". Unambiguous
    /// where a bare "5:00" could read as five minutes or a clock time.
    static func abbreviated(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        return "\(m)m"
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
