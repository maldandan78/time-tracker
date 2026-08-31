import SwiftUI

/// The Goals pane: one row per daily goal, with live progress toward its target.
///
/// A goal is a per-project daily rule — work *at least* N a day (reach it) or *at most* N a
/// day (stay within it). A row ticks only while its project is the one running, matching the
/// entry list's live-only-when-needed pattern; any other row's total can change only through
/// a store mutation, which invalidates it anyway.
struct GoalsView: View {
    @Environment(DataStore.self) private var store

    @State private var editor: GoalEditor?

    /// Cached start-of-day, refreshed on day change / scene activation exactly like
    /// EntryListView's — without it, non-ticking rows would keep showing yesterday's
    /// progress after midnight.
    @Environment(\.scenePhase) private var scenePhase
    @State private var today = Calendar.current.startOfDay(for: .now)

    var body: some View {
        Group {
            if store.goals.isEmpty {
                ContentUnavailableView {
                    Label("No goals yet", systemImage: "target")
                } description: {
                    Text("Use “New Goal” below to set a daily target for a project — "
                         + "work at least some amount, or stay under a limit.")
                }
            } else {
                // Re-identified by `today` so every row recomputes when the day rolls over
                // (losing scroll position once a day is fine; stale progress is not).
                list.id(today)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Same stable bottom bar as the sidebar's "New Project".
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .sheet(item: $editor) { mode in
            GoalEditorSheet(mode: mode)
                .environment(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshToday()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshToday() }
        }
    }

    private func refreshToday() {
        let start = Calendar.current.startOfDay(for: .now)
        if start != today { today = start }
    }

    private var list: some View {
        List {
            ForEach(store.orderedGoals) { goal in
                goalRow(goal)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    editor = .add
                } label: {
                    Label("New Goal", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                // One goal per (project, kind): with every pair taken the sheet could never
                // be saved, so disable the way in rather than present a dead end.
                .disabled(!store.hasFreeGoalSlot)
                .help(store.hasFreeGoalSlot
                      ? "Add a daily goal for a project"
                      : "Every project already has both goals")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    // MARK: - Rows

    @ViewBuilder
    private func goalRow(_ goal: Goal) -> some View {
        let running = store.isRunning(projectID: goal.projectID)
        Group {
            if running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    rowContent(goal, asOf: context.date, running: true)
                }
            } else {
                rowContent(goal, asOf: Date(), running: false)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Edit…") { editor = .edit(goal) }
            // Direct delete with no confirmation anywhere — a deliberate divergence from the
            // entry list's confirm-on-button-path rule: a goal is a recreatable setting, not
            // recorded data. Hence also no "…" promising a dialog.
            Button("Delete", role: .destructive) { store.deleteGoal(goal.id) }
        }
        .swipeActions(edge: .leading) {
            Button {
                editor = .edit(goal)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.deleteGoal(goal.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func rowContent(_ goal: Goal, asOf now: Date, running: Bool) -> some View {
        let total = store.todayTotal(projectID: goal.projectID, asOf: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.projectName(goal.projectID))
                    Text(phrase(goal))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                statusGlyph(goal, total: total)
                Text("\(TimeFormat.hms(total)) / \(TimeFormat.abbreviated(goal.target))")
                    .monospacedDigit()
                    .foregroundStyle(running ? Color.green : Color.primary)
                // Every list in the app offers ▶; an unmet "at least" goal is an invitation
                // to start. Kept invisible while running to preserve alignment, like the
                // entry rows.
                startButton(projectID: goal.projectID)
                    .opacity(running ? 0 : 1)
                    .allowsHitTesting(!running)
            }
            ProgressView(value: goal.fraction(total: total))
                .tint(barTint(goal, total: total))
        }
    }

    private func phrase(_ goal: Goal) -> String {
        switch goal.kind {
        case .atLeast: return "At least \(TimeFormat.abbreviated(goal.target)) a day"
        case .atMost: return "At most \(TimeFormat.abbreviated(goal.target)) a day"
        }
    }

    /// A ✓ whenever the goal is satisfied — an "at least" goal reached, or an "at most" limit
    /// still respected: staying within a limit is the win, so it reads as one from the first
    /// second of the day. The ✓ gives way to a red ! only once an "at most" limit is exceeded.
    @ViewBuilder
    private func statusGlyph(_ goal: Goal, total: TimeInterval) -> some View {
        if goal.isSatisfied(total: total) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if goal.kind == .atMost {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    /// Green while the goal is satisfied — an "at least" goal met, or an "at most" limit not
    /// yet exceeded — accent while an "at least" goal is still short, red once an "at most"
    /// limit is blown.
    private func barTint(_ goal: Goal, total: TimeInterval) -> Color {
        if goal.isSatisfied(total: total) { return .green }
        return goal.kind == .atMost ? .red : .accentColor
    }

    /// ▶ Start a new entry for the goal's project (stops any running timer).
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
}

// MARK: - Editor

/// Identifies which goal editor sheet to present.
enum GoalEditor: Identifiable {
    case add
    case edit(Goal)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let goal): return goal.id.uuidString
        }
    }
}

/// A small sheet for creating or editing a goal — project, kind, and an hours+minutes daily
/// target — with live duplicate/conflict validation (same shape as ProjectEditorSheet).
struct GoalEditorSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let mode: GoalEditor

    @State private var projectID: UUID?
    @State private var kind: GoalKind = .atLeast
    @State private var hours = 1
    @State private var minutes = 0
    /// True once we've committed a save. Suppresses the duplicate warning so it can't flash
    /// red for a frame after addGoal() makes the just-chosen pair "exist" pre-dismiss.
    @State private var committing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isEdit ? "Edit Goal" : "New Goal")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                field("Project") {
                    Picker("Project", selection: $projectID) {
                        ForEach(store.projects) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                    .labelsHidden()
                }
                field("Goal") {
                    Picker("Goal", selection: $kind) {
                        Text("At least").tag(GoalKind.atLeast)
                        Text("At most").tag(GoalKind.atMost)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                field("Daily target") {
                    HStack(spacing: 8) {
                        Picker("Hours", selection: $hours) {
                            ForEach(hourOptions, id: \.self) { Text("\($0) h").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Picker("Minutes", selection: $minutes) {
                            ForEach(minuteOptions, id: \.self) { Text("\($0) m").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                }
            }

            if let problem = validationProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let caution = conflictCaution {
                Label(caution, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEdit ? "Save" : "Add") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(validationProblem != nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            // Reuse-safety: re-seed each time the sheet appears, like every other sheet here.
            committing = false
            switch mode {
            case .add:
                // Default to the first (project, kind) pair without a goal, so the sheet
                // never opens showing the duplicate warning.
                let slot = store.firstFreeGoalSlot
                projectID = slot?.projectID ?? store.projects.first?.id
                kind = slot?.kind ?? .atLeast
                hours = 1
                minutes = 0
            case .edit(let goal):
                projectID = goal.projectID
                kind = goal.kind
                let total = max(0, Int(goal.target))
                hours = total / 3600
                minutes = (total % 3600) / 60
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Options

    private var hourOptions: [Int] {
        var options = Array(0...23)
        // A full-day target (24h, the top of Goal.targetRange) seeds hours past the picker's
        // usual 0…23; offer it so opening the editor doesn't silently change the goal.
        if !options.contains(hours) { options.append(hours); options.sort() }
        return options
    }

    /// 5-minute steps — deliberately coarser than the app's minute-level editing, because
    /// goals are round targets. An odd value from a hand-edited file is offered too.
    private var minuteOptions: [Int] {
        var options = Array(stride(from: 0, through: 55, by: 5))
        if !options.contains(minutes) { options.append(minutes); options.sort() }
        return options
    }

    // MARK: - Validation

    private var isEdit: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var editedGoalID: UUID? {
        if case .edit(let goal) = mode { return goal.id }
        return nil
    }

    private var target: TimeInterval { TimeInterval(hours * 3600 + minutes * 60) }

    private var kindPhrase: String { kind == .atLeast ? "at least" : "at most" }

    private var validationProblem: String? {
        guard !committing else { return nil }
        guard let projectID, store.project(projectID) != nil else { return "Choose a project." }
        // The pickers' only way out of Goal.targetRange is 0h 0m, hence the wording.
        if !Goal.targetRange.contains(target) { return "Set a target above zero." }
        if store.goalExists(projectID: projectID, kind: kind, excluding: editedGoalID) {
            return "“\(store.projectName(projectID))” already has an “\(kindPhrase)” goal."
        }
        return nil
    }

    /// Non-blocking: an "at least" above the same project's "at most" (or vice versa) can
    /// never be satisfied together. Warn but allow saving — the user may be mid-adjusting both.
    private var conflictCaution: String? {
        guard !committing, let projectID else { return nil }
        let counterpart: GoalKind = kind == .atLeast ? .atMost : .atLeast
        guard let other = store.goals.first(where: {
            $0.projectID == projectID && $0.kind == counterpart && $0.id != editedGoalID
        }) else { return nil }
        let conflicts = kind == .atLeast ? target > other.target : target < other.target
        guard conflicts else { return nil }
        let phrase = counterpart == .atLeast ? "at least" : "at most"
        return "Can't be met together with the “\(phrase) "
            + "\(TimeFormat.abbreviated(other.target))” goal."
    }

    private func save() {
        guard validationProblem == nil, let projectID else { return }
        committing = true
        switch mode {
        case .add:
            store.addGoal(projectID: projectID, kind: kind, target: target)
        case .edit(let goal):
            // If the goal vanished under the sheet (its project was deleted from the sidebar,
            // cascading the goal away), updateGoal refuses — dismiss without resurrecting it.
            store.updateGoal(goal.id, projectID: projectID, kind: kind, target: target)
        }
        dismiss()
    }
}
