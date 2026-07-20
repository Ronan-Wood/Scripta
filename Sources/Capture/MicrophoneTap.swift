import AVFoundation

/// A microphone tap that only surfaces buffers — no file is ever written. Quick Capture's audio
/// path is deliberately more ephemeral than a recording's: the buffers go straight to the live
/// transcriber and cease to exist (M14 — "raw audio never touches disk on this path").
/// `MicrophoneCapture` is not reused here precisely because it always writes a track file.
///
/// Contract: set `onBuffer` before `start()` and don't mutate it after — the capture flow wires
/// the transcriber feed first (its setup can include a model download), then starts the tap, so
/// the audio thread never races a write.
final class MicrophoneTap {
    private let engine = AVAudioEngine()

    /// Called on the audio thread with each captured buffer.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    func start() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Scripta", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
