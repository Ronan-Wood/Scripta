import AVFoundation
import ScreenCaptureKit
import OSLog
import os

/// Captures system (other participants') audio via ScreenCaptureKit and writes it
/// to a CAF file in the stream's native format. Video is configured minimally and
/// never consumed — this is an audio-only use of SCStream.
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private let outputURL: URL
    private let queue = DispatchQueue(label: "com.ronanwood.Scripta.systemAudio")
    private let log = Logger(subsystem: "com.ronanwood.Scripta", category: "SystemAudio")

    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var paused = false
    // Both queue-confined. `stopped` blocks straggler buffers SCK may still dispatch after
    // stopCapture() from re-creating (and truncating) the finished file.
    private var stopped = false
    private var failed = false

    /// When paused, buffers are dropped so the track omits that interval (stays aligned with mic).
    func setPaused(_ value: Bool) { queue.sync { paused = value } }

    /// Fired at most once, on the capture queue, if capture fails after it has started
    /// (e.g. the stream stops unexpectedly). Never fired for an intentional `stop()`.
    var onError: ((Error) -> Void)?

    /// Per-buffer peak amplitude (0–1) on the capture queue, for the level meter when the system
    /// track is the live source (a system-audio conference). Set before `start()`.
    var onLevel: ((Float) -> Void)?

    /// Per-buffer PCM on the capture queue, for live transcription of the system track. Locked
    /// because live transcription attaches it after capture is already running.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { bufferCallback.withLock { $0 } }
        set { bufferCallback.withLock { $0 = newValue } }
    }
    private let bufferCallback = OSAllocatedUnfairLock<((AVAudioPCMBuffer) -> Void)?>(initialState: nil)

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    /// Starts capture. Requesting shareable content triggers the Screen Recording
    /// permission prompt on first use; if not granted this throws.
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "Scripta", code: 100,
                          userInfo: [NSLocalizedDescriptionKey: "No display is available to capture system audio from."])
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true   // don't record our own notification sounds
        // Minimize the (unused) video path.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        queue.sync { stopped = true }
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        // Close the file on the same queue that writes it.
        queue.sync { audioFile = nil }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !paused, !stopped,
              CMSampleBufferDataIsReady(sampleBuffer),
              let pcm = sampleBuffer.toPCMBuffer()
        else { return }

        do {
            if audioFile == nil {
                audioFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: pcm.format.settings,
                    commonFormat: pcm.format.commonFormat,
                    interleaved: pcm.format.isInterleaved
                )
            }
            try audioFile?.write(from: pcm)
        } catch {
            log.error("system audio write failed: \(error.localizedDescription, privacy: .public)")
            reportFailure(error)
        }

        // Live transcript + meter, when the system track is the live source.
        onBuffer?(pcm)
        if let onLevel { onLevel(Self.peak(of: pcm)) }
    }

    /// Peak magnitude (0–1) across all channels of a PCM buffer, handling float or int16 samples.
    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            for c in 0..<channels {
                let ptr = data[c]
                for i in 0..<frames { peak = max(peak, abs(ptr[i])) }
            }
        } else if let data = buffer.int16ChannelData {
            for c in 0..<channels {
                let ptr = data[c]
                for i in 0..<frames { peak = max(peak, abs(Float(ptr[i]) / 32768)) }
            }
        }
        return peak
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("system audio stream stopped: \(error.localizedDescription, privacy: .public)")
        // The delegate fires on an SCStream-internal queue; hop to ours for the flags.
        queue.async { [weak self] in self?.reportFailure(error) }
    }

    /// Queue-confined. Collapses repeated write failures / a stop-with-error into one report.
    private func reportFailure(_ error: Error) {
        guard !stopped, !failed else { return }
        failed = true
        onError?(error)
    }
}
