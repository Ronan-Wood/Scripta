import AppKit
import Carbon.HIToolbox

/// Registers system-wide hotkeys — ⌥⌘R to start/stop recording, ⌥⌘N to jot a quick note —
/// from anywhere. Uses Carbon's RegisterEventHotKey, which needs no accessibility permission for
/// a registered combo.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onTrigger: (() -> Void)?
    var onNote: (() -> Void)?

    private static let recordID: UInt32 = 1
    private static let noteID: UInt32 = 2

    private var recordRef: EventHotKeyRef?
    private var noteRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    /// Re-registers both hotkeys against their CURRENT `AppSettings` combos (M25) — call after
    /// either combo changes in Settings. `register()`'s own `handlerRef == nil` guard makes
    /// calling it a second time a no-op, so refreshing needs an explicit unregister first, not
    /// just another `register()` call. A no-op while hotkeys are currently disabled — nothing to
    /// refresh; the new combo is simply what gets registered next time the user re-enables them.
    func reregister() {
        guard handlerRef != nil else { return }
        unregister()
        register()
    }

    private func register() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            switch hotKeyID.id {
            case HotKeyManager.recordID: HotKeyManager.shared.onTrigger?()
            case HotKeyManager.noteID:   HotKeyManager.shared.onNote?()
            default: break
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let sig = fourCharCode("CTrx")
        let recordCombo = AppSettings.recordHotkeyCombo
        let noteCombo = AppSettings.quickCaptureHotkeyCombo
        RegisterEventHotKey(recordCombo.keyCode, recordCombo.modifiers,
                            EventHotKeyID(signature: sig, id: Self.recordID),
                            GetApplicationEventTarget(), 0, &recordRef)
        RegisterEventHotKey(noteCombo.keyCode, noteCombo.modifiers,
                            EventHotKeyID(signature: sig, id: Self.noteID),
                            GetApplicationEventTarget(), 0, &noteRef)
    }

    private func unregister() {
        if let recordRef { UnregisterEventHotKey(recordRef) }
        recordRef = nil
        if let noteRef { UnregisterEventHotKey(noteRef) }
        noteRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for byte in string.utf8.prefix(4) { result = (result << 8) + OSType(byte) }
    return result
}
