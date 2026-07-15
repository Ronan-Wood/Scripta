import AppKit
import Carbon.HIToolbox

/// Registers a system-wide hotkey (⌥⌘R) to start/stop recording from anywhere. Uses Carbon's
/// RegisterEventHotKey, which needs no accessibility permission for a registered combo.
final class HotKeyManager {
    static let shared = HotKeyManager()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func setEnabled(_ enabled: Bool) {
        enabled ? register() : unregister()
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKeyManager.shared.onTrigger?()
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let id = EventHotKeyID(signature: fourCharCode("CTrx"), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for byte in string.utf8.prefix(4) { result = (result << 8) + OSType(byte) }
    return result
}
