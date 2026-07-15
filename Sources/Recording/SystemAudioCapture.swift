import AVFoundation
import ScreenCaptureKit
import OSLog

/// Captures system (other participants') audio via ScreenCaptureKit and writes it
/// to a CAF file in the stream's native format. Video is configured minimally and
/// never consumed — this is an audio-only use of SCStream.
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    private let outputURL: URL
    private let queue = DispatchQueue(label: "com.ronanwood.CallTranscriber.systemAudio")
    private let log = Logger(subsystem: "com.ronanwood.CallTranscriber", category: "SystemAudio")

    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var paused = false

    /// When paused, buffers are dropped so the track omits that interval (stays aligned with mic).
    func setPaused(_ value: Bool) { queue.sync { paused = value } }

    /// Fired if capture fails after it has started (e.g. the stream stops unexpectedly).
    var onError: ((Error) -> Void)?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    /// Starts capture. Requesting shareable content triggers the Screen Recording
    /// permission prompt on first use; if not granted this throws.
    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "CallTranscriber", code: 100,
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
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        // Close the file on the same queue that writes it.
        queue.sync { audioFile = nil }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, !paused,
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
            onError?(error)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("system audio stream stopped: \(error.localizedDescription, privacy: .public)")
        onError?(error)
    }
}
