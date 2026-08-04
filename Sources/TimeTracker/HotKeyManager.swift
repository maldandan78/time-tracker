import AppKit
import Carbon.HIToolbox

/// Which quick-launch list a global shortcut drives. Both use the same positional logic — the item
/// at array index i is bound to number (i+1) — and differ only by modifier: pins are ⌃⌥⌘N,
/// favorites add Shift (⇧⌃⌥⌘N).
enum HotKeyGroup: CaseIterable, Sendable {
    case pin
    case favorite

    /// Carbon modifier mask for this group's shortcuts.
    fileprivate var carbonModifiers: UInt32 {
        switch self {
        case .pin: return UInt32(cmdKey | optionKey | controlKey)
        case .favorite: return UInt32(cmdKey | optionKey | controlKey | shiftKey)
        }
    }

    /// Base for the Carbon hotkey id, so the one shared handler can tell the groups apart.
    /// Ids are `base + number`, with number in 1…9 — the bases are 100 apart so they never collide.
    fileprivate var idBase: UInt32 {
        switch self {
        case .pin: return 100
        case .favorite: return 200
        }
    }

    /// Modifier glyphs shown in the sidebar badges, tooltips, and the menu-bar menu.
    var symbolPrefix: String {
        switch self {
        case .pin: return "⌃⌥⌘"
        case .favorite: return "⇧⌃⌥⌘"
        }
    }

    /// The user-facing shortcut for position `index` (0-based), e.g. "⌃⌥⌘1" / "⇧⌃⌥⌘3".
    func shortcutLabel(index: Int) -> String { "\(symbolPrefix)\(index + 1)" }
}

/// Registers up to nine system-wide hotkeys per group — ⌃⌥⌘1…9 for pins and ⇧⌃⌥⌘1…9 for
/// favorites — using the Carbon hotkey API. Carbon hotkeys are global and require no
/// Accessibility/Input-Monitoring permission; they fire as long as the app process is alive, even
/// when it isn't frontmost. Exactly the configured number of hotkeys is registered in each group,
/// so unused shortcuts stay free for other apps.
final class HotKeyManager {
    /// Accessed only on the main thread (launch wiring + main-thread Carbon callback).
    nonisolated(unsafe) static let shared = HotKeyManager()

    /// Called on the main thread with the group and the 1-based position (1…9) when a hotkey fires.
    var onFire: ((HotKeyGroup, Int) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x5454524B // 'TTRK'

    /// Key codes for positions 1…9, in order. Only the first `count` of a group are ever registered.
    private static let allKeyCodes: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ]

    /// The most shortcuts a single group can have — one per digit key.
    static var maxPerGroup: Int { allKeyCodes.count }

    private init() {}

    /// Registers exactly `pins` pin hotkeys (⌃⌥⌘1…N) and `favorites` favorite hotkeys (⇧⌃⌥⌘1…M),
    /// unregistering any previous set first so re-registration never duplicates or leaks refs.
    /// Safe to call repeatedly. Unused shortcuts are left free for other apps. Main thread only.
    func register(pins: Int, favorites: Int) {
        installHandlerIfNeeded()
        unregisterAll()
        register(group: .pin, count: pins)
        register(group: .favorite, count: favorites)
    }

    private func register(group: HotKeyGroup, count: Int) {
        let clamped = min(Self.allKeyCodes.count, max(0, count))
        for index in 0..<clamped {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: group.idBase + UInt32(index + 1))
            let status = RegisterEventHotKey(UInt32(Self.allKeyCodes[index]),
                                             group.carbonModifiers,
                                             id,
                                             GetApplicationEventTarget(),
                                             0,
                                             &ref)
            if status == noErr {
                hotKeyRefs.append(ref)
            } else {
                NSLog("TimeTracker: failed to register \(group) hotkey \(index + 1) (status \(status))")
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

    /// Maps a fired hotkey id back to its group + 1-based position. Nil for an id we didn't mint.
    private static func decode(_ id: UInt32) -> (group: HotKeyGroup, number: Int)? {
        for group in HotKeyGroup.allCases where id > group.idBase {
            let number = Int(id - group.idBase)
            if number <= allKeyCodes.count { return (group, number) }
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
                manager.onFire?(fired.group, fired.number)
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}
