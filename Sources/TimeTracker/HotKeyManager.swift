import AppKit
import Carbon.HIToolbox

/// Registers up to nine system-wide hotkeys — Control+Option+Command+1…9 — using the Carbon
/// hotkey API. Carbon hotkeys are global and require no Accessibility/Input-Monitoring permission;
/// they fire as long as the app process is alive, even when it isn't frontmost. Exactly the
/// configured number of hotkeys is registered, so unused shortcuts stay free for other apps.
final class HotKeyManager {
    /// Accessed only on the main thread (launch wiring + main-thread Carbon callback).
    nonisolated(unsafe) static let shared = HotKeyManager()

    /// Called on the main thread with the 1-based pin number (1…9) when its hotkey fires.
    var onFire: ((Int) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x5454524B // 'TTRK'

    /// ⌃⌥⌘1 … ⌃⌥⌘9, in order. Only the first `count` are ever registered.
    private static let allKeyCodes: [Int] = [
        kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
        kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9
    ]

    private init() {}

    /// Registers exactly `count` global hotkeys (⌃⌥⌘1 … ⌃⌥⌘count), unregistering any previous set
    /// first so re-registration never duplicates or leaks refs. Safe to call repeatedly. Unused
    /// shortcuts (count+1 … 9) are left free for other apps. Main thread only.
    func register(count: Int) {
        installHandlerIfNeeded()
        unregisterAll()

        let clamped = min(Self.allKeyCodes.count, max(0, count))
        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        for index in 0..<clamped {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(UInt32(Self.allKeyCodes[index]),
                                             modifiers,
                                             id,
                                             GetApplicationEventTarget(),
                                             0,
                                             &ref)
            if status == noErr {
                hotKeyRefs.append(ref)
            } else {
                NSLog("TimeTracker: failed to register hotkey \(index + 1) (status \(status))")
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
                guard status == noErr, hotKeyID.signature == HotKeyManager.signature else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers hotkey events on the main thread, so call straight through.
                manager.onFire?(Int(hotKeyID.id))
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}
