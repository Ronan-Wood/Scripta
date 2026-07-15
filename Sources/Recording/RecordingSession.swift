import Foundation
import OSLog

/// Orchestrates one recording end-to-end: captures system + microphone audio to a private
/// temp directory, then on stop transcribes each track separately (mic = "You", system =
/// "Them"), interleaves the segments by timestamp, writes a Markdown transcript to the
/// configured output folder, and deletes the raw audio.
///
/// Raw capture lives only under `NSTemporaryDirectory()`; it is deleted immediately after a
/// transcript is successfully written. `sweepOrphans()` clears anything a crash left behind.
final class RecordingSession {
    enum State { case idle, recording, processing }

    static let sessionPrefix = "CallTranscriber-session-"

    private(set) var state: State = .idle

    private let sessionDir: URL
    private let systemURL: URL
    private let micURL: URL
    private let youWavURL: URL
    private let themWavURL: URL

    private var micCapture: MicrophoneCapture?
    private var systemCapture: SystemAudioCapture?
    private var screenCapturer: ScreenContextCapturer?
    private var liveTranscriber: LiveTranscriber?
    private var activityToken: NSObjectProtocol?
    private var startedAt = Date()

    private let log = Logger(subsystem: "com.ronanwood.CallTranscriber", category: "Session")

    init() {
        sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(Self.sessionPrefix + UUID().uuidString, isDirectory: true)
        systemURL = sessionDir.appendingPathComponent("system.caf")
        micURL = sessionDir.appendingPathComponent("mic.caf")
        youWavURL = sessionDir.appendingPathComponent("you.wav")
        themWavURL = sessionDir.appendingPathComponent("them.wav")
    }

    /// Removes temp session directories orphaned by a previous crash. Call on launch.
    static func sweepOrphans() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(sessionPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func start(screenSource: ScreenSource) async throws {
        guard state == .idle else { return }
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording call audio"
        )

        startedAt = Date()

        let mic = MicrophoneCapture(outputURL: micURL)
        mic.onLevel = { level in
            Task { @MainActor in AppModel.shared.micLevel = min(1, level) }
        }

        // Live transcript from the mic (best-effort — never blocks the recording).
        if AppSettings.liveTranscriptionEnabled {
            let live = LiveTranscriber()
            live.onUpdate = { finalized, partial in
                AppModel.shared.liveFinalized = finalized
                AppModel.shared.livePartial = partial
            }
            do {
                try await live.start()
                mic.onBuffer = { [weak live] buffer in live?.feed(buffer) }
                liveTranscriber = live
            } catch {
                log.error("live transcription unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        let system = SystemAudioCapture(outputURL: systemURL)

        try mic.start()
        do {
            try await system.start()
        } catch {
            mic.stop()
            endActivity()
            throw error
        }
        micCapture = mic
        systemCapture = system

        if screenSource != .off {
            let capturer = ScreenContextCapturer(
                interval: TimeInterval(AppSettings.screenCaptureInterval),
                sessionStart: startedAt,
                focus: AppSettings.screenFocus,
                source: screenSource
            )
            await capturer.start()
            screenCapturer = capturer
        }

        state = .recording
    }

    /// Pauses/resumes capture. Paused intervals are simply omitted from both tracks, so they stay
    /// aligned and the transcript has no silent gap.
    func pause() async {
        micCapture?.isPaused = true
        systemCapture?.setPaused(true)
        await screenCapturer?.setPaused(true)
    }
    func resume() async {
        micCapture?.isPaused = false
        systemCapture?.setPaused(false)
        await screenCapturer?.setPaused(false)
    }

    /// Stops capture and runs the mix → transcribe → write pipeline. Returns the transcript
    /// URL on success. On success the raw audio is deleted; on failure it is left for the
    /// launch-time sweep so nothing persists indefinitely.
    func stop() async throws -> URL {
        guard state == .recording else {
            throw NSError(domain: "CallTranscriber", code: 300,
                          userInfo: [NSLocalizedDescriptionKey: "No recording is in progress."])
        }
        state = .processing

        micCapture?.stop()
        await systemCapture?.stop()
        let snippets = await screenCapturer?.stop() ?? []
        await liveTranscriber?.stop()
        micCapture = nil
        systemCapture = nil
        screenCapturer = nil
        liveTranscriber = nil
        endActivity()

        let systemURL = self.systemURL
        let micURL = self.micURL
        let youWavURL = self.youWavURL
        let themWavURL = self.themWavURL
        let startedAt = self.startedAt
        let duration = Date().timeIntervalSince(startedAt)

        do {
            // Heavy work (audio conversion + transcription) runs off the main actor.
            let transcriptURL = try await Task.detached(priority: .userInitiated) { () -> URL in
                // Convert each captured track to the transcription format. The peak tells us
                // whether the track actually carried speech.
                let micPeak = try AudioConverter.prepareTrack(inputURL: micURL, outputURL: youWavURL)
                let systemPeak = try AudioConverter.prepareTrack(inputURL: systemURL, outputURL: themWavURL)

                guard micPeak > 0 || systemPeak > 0 else {
                    throw NSError(domain: "CallTranscriber", code: 201,
                                  userInfo: [NSLocalizedDescriptionKey: "Recording produced no audio to transcribe."])
                }

                // Transcribe each side separately (sequential — avoids double locale reservation).
                let youSegments = micPeak > 0 ? try await SpeechEngine.transcribe(audioURL: youWavURL) : []
                let themSegments = systemPeak > 0 ? try await SpeechEngine.transcribe(audioURL: themWavURL) : []

                // Label + interleave only when both sides have speech — otherwise a single side
                // (in-person, or a one-sided call) would be mislabeled, so leave it unlabeled.
                let rawSegments: [TranscriptSegment]
                if !youSegments.isEmpty && !themSegments.isEmpty {
                    rawSegments = Self.merge(you: youSegments, them: themSegments)
                } else {
                    rawSegments = youSegments.isEmpty ? themSegments : youSegments
                }

                // Deterministically strip filler words; drop any segment left empty. Preserve labels.
                let segments = rawSegments
                    .map { TranscriptSegment(startMs: $0.startMs, text: FillerCleaner.clean($0.text), speaker: $0.speaker) }
                    .filter { !$0.text.isEmpty }

                // Zero segments must fail like any other pipeline error — writing a placeholder
                // transcript would count as "success" and delete the only copy of the audio.
                guard !segments.isEmpty else {
                    throw NSError(domain: "CallTranscriber", code: 202,
                                  userInfo: [NSLocalizedDescriptionKey: "No speech was recognized in the recording."])
                }

                // Optional on-device title + summary + topics — additive, never rewrites the transcript.
                var title: String?
                var summary: String?
                var tags = ["call"]
                if AppSettings.summarizeEnabled {
                    let plain = segments.map { segment in
                        segment.speaker.map { "\($0.rawValue): \(segment.text)" } ?? segment.text
                    }.joined(separator: "\n")
                    if let digest = await TranscriptEnricher.enrich(plain) {
                        title = digest.title
                        summary = digest.summary
                        // Concept topics become tags — they power topic search (find "baseball"
                        // even when only "home runs" was said) and the tag index.
                        tags += digest.topics.filter { $0 != "call" }
                    }
                }

                return try TranscriptWriter.write(segments: segments,
                                                  startedAt: startedAt, duration: duration,
                                                  tags: tags, title: title, summary: summary,
                                                  screenSnippets: snippets)
            }.value

            // Success: raw audio is no longer needed.
            cleanup()
            state = .idle
            return transcriptURL
        } catch {
            // Leave raw audio for the launch-time sweep; surface the failure.
            state = .idle
            throw error
        }
    }

    /// Labels each side and interleaves the two transcripts by start time. Both tracks share the
    /// session's t=0, so their timestamps are directly comparable.
    private static func merge(you: [TranscriptSegment], them: [TranscriptSegment]) -> [TranscriptSegment] {
        let labeled = you.map { TranscriptSegment(startMs: $0.startMs, text: $0.text, speaker: .you) }
                    + them.map { TranscriptSegment(startMs: $0.startMs, text: $0.text, speaker: .them) }
        return labeled.sorted { $0.startMs < $1.startMs }
    }

    /// Deletes this session's entire temp directory.
    func cleanup() {
        try? FileManager.default.removeItem(at: sessionDir)
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}
