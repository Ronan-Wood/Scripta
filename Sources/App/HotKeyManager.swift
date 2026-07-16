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
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey),
                            EventHotKeyID(signature: sig, id: Self.recordID),
                            GetApplicationEventTarget(), 0, &recordRef)
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey),
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
