import AppKit
import Carbon.HIToolbox

/// The one positional global-shortcut group: the project list. The project at array index i is
/// bound to number (i+1), i.e. ⌃⌥⌘1…9 — reordering the sidebar list is how the user chooses which
/// nine projects get a shortcut. Only the labels are public; the Carbon details stay in this file.
enum ProjectHotKey {
    /// Modifier glyphs shown in the sidebar badges, tooltips, and the menu-bar menu.
    static let symbolPrefix = "⌃⌥⌘"

    /// The user-facing shortcut for position `index` (0-based), e.g. "⌃⌥⌘1".
    static func shortcutLabel(index: Int) -> String { "\(symbolPrefix)\(index + 1)" }

    /// Carbon modifier mask for these shortcuts (⌃⌥⌘, no Shift — Shift is the command group).
    fileprivate static var carbonModifiers: UInt32 { UInt32(cmdKey | optionKey | controlKey) }

    /// Base for the Carbon hotkey id, so the one shared handler can tell positions from commands.
    /// Ids are `base + number`, with number in 1…9 — well clear of the 300 command range.
    fileprivate static let idBase: UInt32 = 100
}

/// A global shortcut that runs one fixed command instead of driving the positional list. All of
/// them act on the running timer. ⇧⌃⌥⌘→/← nudge its start time, in the direction the elapsed time
/// moves: → adds working time by pulling the start earlier (for when you started working before you
/// hit Start) and ← reduces it by pushing the start later. ⇧⌃⌥⌘⌦ throws the session away entirely.
/// Unlike the positional shortcuts these are registered unconditionally, and do nothing when no
/// timer is running.
enum HotKeyCommand: CaseIterable, Sendable {
    case runningStartEarlier
    case runningStartLater
    case discardRunning

    /// The modifier glyphs every command shares — exactly the set `carbonModifiers` registers.
    /// Public so a hint can spell the modifiers once and then list several keys after them.
    static let symbolPrefix = "⇧⌃⌥⌘"

    /// Discard is on ⌦ (forward delete) rather than ⌫ (backspace): ⌫ is a popular target for
    /// utilities that grab keys system-wide, and one holding ⇧⌃⌥⌘⌫ swallows it before it ever
    /// reaches us — the registration still succeeds, so the shortcut just silently does nothing.
    /// ⌦ is reached as fn+delete on a laptop.
    fileprivate var keyCode: Int {
        switch self {
        case .runningStartEarlier: return kVK_RightArrow
        case .runningStartLater: return kVK_LeftArrow
        case .discardRunning: return kVK_ForwardDelete
        }
    }

    /// ⇧⌃⌥⌘ — the project shortcuts' modifiers plus Shift, on non-digit keys.
    fileprivate var carbonModifiers: UInt32 {
        UInt32(cmdKey | optionKey | controlKey | shiftKey)
    }

    /// Carbon hotkey id, in a 300 range so it can never collide with the 100 positional range.
    fileprivate var hotKeyID: UInt32 {
        switch self {
        case .runningStartEarlier: return 301
        case .runningStartLater: return 302
        case .discardRunning: return 303
        }
    }

    /// The key glyph alone, without modifiers — for hints that share one modifier prefix.
    var keyLabel: String {
        switch self {
        case .runningStartEarlier: return "→"
        case .runningStartLater: return "←"
        case .discardRunning: return "⌦"
        }
    }

    /// The user-facing shortcut, e.g. for tooltips and the menu-bar menu.
    var shortcutLabel: String { Self.symbolPrefix + keyLabel }
}

/// Registers up to nine system-wide hotkeys for the project list — ⌃⌥⌘1…9 — plus the fixed command
/// shortcuts (⇧⌃⌥⌘←/→/⌦), using the Carbon hotkey API. Carbon hotkeys are global and require no
/// Accessibility/Input-Monitoring permission; they fire as long as the app process is alive, even
/// when it isn't frontmost. Exactly as many digit hotkeys are registered as there are projects, so
/// unused shortcuts stay free for other apps.
final class HotKeyManager {
    /// Accessed only on the main thread (launch wiring + main-thread Carbon callback).
    nonisolated(unsafe) static let shared = HotKeyManager()

    /// Called on the main thread with the 1-based project position (1…9) when a hotkey fires.
    var onFire: ((Int) -> Void)?

    /// Called on the main thread when one of the fixed command shortcuts fires.
    var onCommand: ((HotKeyCommand) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x5454524B // 'TTRK'

    /// Key codes for positions 1…9, in order. Only the first `count` are ever registered.
    private static let allKeyCodes: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ]

    /// The most positional shortcuts there can be — one per digit key.
    static var maxShortcuts: Int { allKeyCodes.count }

    private init() {}

    /// Registers exactly `count` project hotkeys (⌃⌥⌘1…N) plus every command shortcut,
    /// unregistering any previous set first so re-registration never duplicates or leaks refs.
    /// Safe to call repeatedly. Unused shortcuts are left free for other apps. Main thread only.
    func register(projects count: Int) {
        installHandlerIfNeeded()
        unregisterAll()
        registerProjects(count: count)
        registerCommands()
    }

    private func registerProjects(count: Int) {
        let clamped = min(Self.allKeyCodes.count, max(0, count))
        for index in 0..<clamped {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature,
                                   id: ProjectHotKey.idBase + UInt32(index + 1))
            let status = RegisterEventHotKey(UInt32(Self.allKeyCodes[index]),
                                             ProjectHotKey.carbonModifiers,
                                             id,
                                             GetApplicationEventTarget(),
                                             0,
                                             &ref)
            if status == noErr {
                hotKeyRefs.append(ref)
            } else {
                NSLog("TimeTracker: failed to register project hotkey \(index + 1) (status \(status))")
            }
        }
    }

    /// Registers every command shortcut. Always all of them — they don't depend on the project
    /// list's length — and re-registered on each `register(projects:)` so they survive the
    /// `unregisterAll()` that a project-count change triggers.
    private func registerCommands() {
        for command in HotKeyCommand.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: command.hotKeyID)
            let status = RegisterEventHotKey(UInt32(command.keyCode),
                                             command.carbonModifiers,
                                             id,
                                             GetApplicationEventTarget(),
                                             0,
                                             &ref)
            if status == noErr {
                hotKeyRefs.append(ref)
            } else {
                NSLog("TimeTracker: failed to register \(command) hotkey (status \(status))")
            }
        }
    }

    /// Unregisters and clears all currently-registered hotkeys (keeps the shared handler installed).
    private func unregisterAll() {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotKeyRefs.removeAll()
    }

    /// What a fired hotkey id maps back to: a project position, or a fixed command.
    private enum Fired {
        case project(Int)
        case command(HotKeyCommand)
    }

    /// Maps a fired hotkey id back to its 1-based project position, or its command.
    /// Nil for an id we didn't mint.
    private static func decode(_ id: UInt32) -> Fired? {
        if let command = HotKeyCommand.allCases.first(where: { $0.hotKeyID == id }) {
            return .command(command)
        }
        if id > ProjectHotKey.idBase {
            let number = Int(id - ProjectHotKey.idBase)
            if number <= allKeyCodes.count { return .project(number) }
        }
        return nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(event,
                                               EventParamName(kEventParamDirectObject),
                                               EventParamType(typeEventHotKeyID),
                                               nil,
                                               MemoryLayout<EventHotKeyID>.size,
                                               nil,
                                               &hotKeyID)
                guard status == noErr, hotKeyID.signature == HotKeyManager.signature,
                      let fired = HotKeyManager.decode(hotKeyID.id) else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hotkey events on the main thread, so call straight through.
                switch fired {
                case .project(let number): manager.onFire?(number)
                case .command(let command): manager.onCommand?(command)
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}
