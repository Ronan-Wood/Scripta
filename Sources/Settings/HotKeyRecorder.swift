import SwiftUI
import AppKit
import Carbon.HIToolbox

/// A native-styled control (M25) for capturing a global hotkey combo — click to enter a
/// "Press keys…" state, then the next key event becomes the new binding. Matches
/// `SettingsView`'s existing native SwiftUI styling (not Carbon) since it lives in that section.
struct HotKeyRecorderButton: View {
    @Binding var combo: HotKeyCombo
    let defaultCombo: HotKeyCombo
    /// The OTHER hotkey's current combo, so a conflicting rebind can be flagged instead of
    /// silently letting two app actions share one combo (SPEC M25 validation requirement).
    let conflictsWith: HotKeyCombo
    let onChange: (HotKeyCombo) -> Void

    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Text(isRecording ? "Press keys…" : combo.label)
                    .frame(minWidth: 96)
                HotKeyRecorderField(isRecording: $isRecording) { newCombo in apply(newCombo) }
                    .frame(width: 0, height: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor)))
            .onTapGesture { isRecording = true }

            if combo == conflictsWith {
                // Reachable, not just defensive (crosscheck): rebind A off its default, rebind B
                // onto A's now-vacated default, then Reset A — see `apply(_:)`'s comment.
                Text("Conflicts with the other shortcut")
                    .font(.caption).foregroundStyle(.red)
            } else if combo != defaultCombo {
                Button("Reset") {
                    // Also leaves recording state (crosscheck): Reset's own visibility doesn't
                    // depend on `isRecording`, so clicking it mid-recording used to finalize the
                    // combo while the field kept showing "Press keys…" and stayed first responder
                    // — the next stray keystroke would then silently overwrite what Reset just set.
                    isRecording = false
                    apply(defaultCombo)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
    }

    /// The one place a new combo gets written — used by both the recorder's capture-accept path
    /// and Reset, so "can't collide with the sibling hotkey" (SPEC M25) is enforced exactly once.
    /// Crosscheck: Reset used to bypass this check entirely (it just assigned `defaultCombo`
    /// directly), so rebinding hotkey A away from its default, then rebinding hotkey B onto A's
    /// now-vacated default, then clicking Reset on A, landed both hotkeys on the identical combo
    /// with no UI path back out except re-recording one of them from scratch.
    @discardableResult
    private func apply(_ newCombo: HotKeyCombo) -> Bool {
        guard newCombo != conflictsWith else {
            NSSound.beep()
            return false
        }
        combo = newCombo
        onChange(newCombo)
        return true
    }
}

/// The first-responder capture surface behind `HotKeyRecorderButton`'s label. The first
/// `NSViewRepresentable` in this codebase that makes itself first responder and captures keyboard
/// input — `VisualEffectView` (Theme/CarbonKit.swift) wraps `NSVisualEffectView` passively and
/// never touches the responder chain.
private struct HotKeyRecorderField: NSViewRepresentable {
    @Binding var isRecording: Bool
    /// Return true to accept the combo and stop recording; false to reject it (e.g. a conflict)
    /// and keep listening for another attempt.
    let onCapture: (HotKeyCombo) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        // Refreshed every update (not just once in makeNSView) so these always close over the
        // CURRENT `isRecording`/`onCapture` — a representable struct is re-created on every parent
        // render, but `makeNSView` runs once, so binding into it directly would go stale.
        context.coordinator.onCapture = { combo in
            if onCapture(combo) { isRecording = false }
        }
        context.coordinator.onCancel = { isRecording = false }

        if isRecording {
            if nsView.window?.firstResponder !== nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
        } else if nsView.window?.firstResponder === nsView {
            nsView.window?.makeFirstResponder(nil)
        }
    }

    final class Coordinator {
        var onCapture: ((HotKeyCombo) -> Void)?
        var onCancel: (() -> Void)?
    }
}

private final class RecorderNSView: NSView {
    weak var coordinator: HotKeyRecorderField.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    // `keyDown(with:)` alone misses combos that double as standing menu-bar equivalents (⌘Q, ⌘W,
    // ⌘, …) — NSWindow offers those to the view hierarchy's performKeyEquivalent BEFORE falling
    // back to the main menu, so intercepting here (while this view actually holds first responder)
    // lets the recorder capture them instead of triggering Quit/Close/Preferences mid-recording.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        coordinator?.onCancel?()
        return super.resignFirstResponder()
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            coordinator?.onCancel?()
            return
        }
        let modifiers = event.modifierFlags.carbonModifiers
        // Command or Control required, not just "any modifier" (crosscheck): Shift-alone or
        // Option-alone doesn't prevent hijacking ordinary typing the way SPEC M25's rationale
        // intends — Shift+letter types a capital letter, Option+letter composes an accented/
        // special character on most layouts, so either alone would still register as a global
        // hotkey that also fires during normal text entry.
        guard modifiers & UInt32(cmdKey | controlKey) != 0 else {
            NSSound.beep()
            return
        }
        coordinator?.onCapture?(HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }
}

private extension NSEvent.ModifierFlags {
    /// AppKit and Carbon use different bit positions for the same physical modifier keys;
    /// `RegisterEventHotKey` (HotKeyManager) expects Carbon's.
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        return result
    }
}
