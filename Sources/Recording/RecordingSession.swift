import Foundation
import ScriptaCore
import AVFoundation
import OSLog
import os

/// Orchestrates one recording end-to-end: captures system + microphone audio to a private
/// temp directory, then on stop transcribes each track separately (mic = "You", system =
/// "Them"), interleaves the segments by timestamp, writes a Markdown transcript to the
/// configured output folder, and deletes the raw audio.
///
/// Raw capture lives only under `NSTemporaryDirectory()`; it is deleted immediately after a
/// transcript is successfully written. `sweepOrphans()` clears anything a crash left behind.
final class RecordingSession {
    enum State { case idle, starting, recording, processing }

    static let sessionPrefix = "Scripta-session-"

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
    private var liveStartTask: Task<Void, Never>?
    /// Set (under `lock`) when stop() begins teardown, so the live-transcription start task — which
    /// may still be inside a first-use model download stop() must not block on — won't resurrect the
    /// transcriber after teardown (audit L6).
    private var isStopping = false
    private var activityToken: NSObjectProtocol?
    private var startedAt = Date()
    private var mode: RecordingMode = .call
    private var group = ""   // captured at start (calendar group or active workspace)
    private var extraVocab: [String] = []   // names to bias ASR toward (attendees, confirmed entities)
    private var captionDir: URL?            // ephemeral retained screenshots, if a vision model is on

    /// Retained screenshots awaiting the post-call VLM caption pass (nil if none). The app layer
    /// captions + deletes this after stop; it lives outside the session dir so `cleanup()` (which
    /// deletes the audio) doesn't take it.
    var pendingCaptionDir: URL? { captionDir }

    /// Root for ephemeral caption dirs — swept at launch so a crash can't leave screenshots behind.
    static var pendingCaptionsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scripta", isDirectory: true)
            .appendingPathComponent("pending-captions", isDirectory: true)
        return base
    }

    /// Deletes any leftover caption dirs from a previous run (their transcripts already have OCR
    /// screen text; only the nice-to-have captions are lost). Call on launch.
    static func sweepPendingCaptions() {
        try? FileManager.default.removeItem(at: pendingCaptionsRoot)
    }
    // Paused intervals are spliced out of the audio tracks, so wall-clock duration must
    // splice them out too or the frontmatter overstates the call.
    private var pausedAccum: TimeInterval = 0
    private var pauseBegan: Date?

    // Session mutable state is touched from the main actor (addNote) and off-main (start/pause/
    // resume/stop are nonisolated async and hop off the caller's actor per SE-0338). `lock`
    // serializes the timing fields (startedAt/pausedAccum/pauseBegan), the lifecycle `state`, the
    // notes hand-off, and the capture reference slots (micCapture/systemCapture/screenCapturer/
    // liveTranscriber/liveStartTask) — the latter so pause/resume/stop can't race the ARC
    // retain/release on those shared vars (memory-unsafe, distinct from the capture objects' own
    // thread-safety). Readers copy a reference out under the lock, then act on the local, so the
    // lock is never held across an `await` — without pinning the whole session to an actor.
    private let lock = NSLock()
    private var notes: [CallNote] = []

    /// Fired at most once, on the main actor, if system-audio capture dies mid-recording.
    /// The owner should stop the session so the mic track (and partial system track) survive.
    var onSystemAudioFailure: ((Error) -> Void)?

    private let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Session")

    init() {
        sessionDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(Self.sessionPrefix + UUID().uuidString, isDirectory: true)
        systemURL = sessionDir.appendingPathComponent("system.caf")
        micURL = sessionDir.appendingPathComponent("mic.caf")
        youWavURL = sessionDir.appendingPathComponent("you.wav")
        themWavURL = sessionDir.appendingPathComponent("them.wav")
    }

    /// Recovers recordings orphaned by a crash or forced logout: any leftover session dir with
    /// non-silent audio is transcribed into a real note (tagged `recovered`) before its temp dir
    /// is removed. Empty/silent orphans are just deleted. A transient failure leaves the audio in
    /// place to retry next launch, so a real call is never lost to a one-off error. Call on launch.
    static func recoverOrphans() async {
        let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Recovery")
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        for dir in entries where dir.lastPathComponent.hasPrefix(sessionPrefix) {
            let systemURL = dir.appendingPathComponent("system.caf")
            let micURL = dir.appendingPathComponent("mic.caf")
            let hasAudio = [systemURL, micURL].contains { isNonEmptyFile($0) }
            guard hasAudio else {
                try? FileManager.default.removeItem(at: dir)   // nothing to recover
                continue
            }

            let startedAt = (try? dir.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
            let duration = max(audioDuration(systemURL), audioDuration(micURL))
            // A call captures both tracks; a conference captures one — so a single track present
            // means it was a conference (leave it unlabeled and mark it as such).
            let fm = FileManager.default
            let wasConference = !(fm.fileExists(atPath: micURL.path) && fm.fileExists(atPath: systemURL.path))
            do {
                let url = try await produceTranscript(
                    systemURL: systemURL, micURL: micURL,
                    youWavURL: dir.appendingPathComponent("you.wav"),
                    themWavURL: dir.appendingPathComponent("them.wav"),
                    startedAt: startedAt, duration: duration, snippets: [],
                    extraTags: ["recovered"], isConference: wasConference)
                log.notice("recovered orphaned recording → \(url.lastPathComponent, privacy: .public)")
                try? FileManager.default.removeItem(at: dir)
            } catch let error as NSError where error.domain == "Scripta"
                && (error.code == noAudioCode || error.code == noSpeechCode) {
                try? FileManager.default.removeItem(at: dir)   // genuinely nothing spoken
            } catch {
                // Transient — keep the audio, retry next launch rather than lose the call.
                log.error("orphan recovery deferred: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func isNonEmptyFile(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size > 0
    }

    private static func audioDuration(_ url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let sr = file.processingFormat.sampleRate
        return sr > 0 ? Double(file.length) / sr : 0
    }

    func start(mode: RecordingMode, screenSource: ScreenSource, group: String = "", extraVocab: [String] = []) async throws {
        // Transitional state before the first await: the idle guard is check-then-act, so a
        // second start() arriving mid-await must see "not idle" — do the check-and-set atomically.
        lock.lock()
        guard state == .idle else { lock.unlock(); return }
        state = .starting
        isStopping = false
        lock.unlock()
        self.mode = mode
        self.group = group
        self.extraVocab = extraVocab
        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        } catch {
            lock.lock(); state = .idle; lock.unlock()
            throw error
        }

        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording call audio"
        )

        lock.lock(); startedAt = Date(); lock.unlock()

        // Conference mode captures a single source; a call captures both. Capturing only one
        // track is what stops a hybrid room being transcribed twice — and the merge step below
        // leaves a single track unlabeled, which is exactly what a conference should be.
        var mic: MicrophoneCapture?
        if mode.capturesMic {
            mic = MicrophoneCapture(outputURL: micURL)
        }

        var system: SystemAudioCapture?
        if mode.capturesSystem {
            let s = SystemAudioCapture(outputURL: systemURL)
            s.onError = { [weak self] error in
                guard let self else { return }
                Task { @MainActor in self.onSystemAudioFailure?(error) }
            }
            system = s
        }

        // The level meter (and, below, the live transcript) follow the mic when it's captured,
        // otherwise the system track — so a system-audio conference still shows a live meter.
        // Coalesce meter updates: keep the latest peak and keep at most ONE pending main-actor update
        // in flight, so the audio callback thread doesn't allocate a Task per buffer and can't back up
        // the main actor under load (audit L7).
        let meterState = OSAllocatedUnfairLock<(peak: Float, pending: Bool)>(initialState: (0, false))
        let meterSink: (Float) -> Void = { level in
            let schedule = meterState.withLock { s -> Bool in
                s.peak = min(1, level)
                if s.pending { return false }
                s.pending = true
                return true
            }
            guard schedule else { return }
            Task { @MainActor in
                let peak = meterState.withLock { s -> Float in s.pending = false; return s.peak }
                AppModel.shared.meter.level = peak
            }
        }
        if mode.capturesMic { mic?.onLevel = meterSink } else { system?.onLevel = meterSink }

        do {
            try mic?.start()
            try await system?.start()
        } catch {
            mic?.stop()
            endActivity()
            lock.lock(); state = .idle; lock.unlock()
            throw error
        }
        lock.lock()
        micCapture = mic
        systemCapture = system
        lock.unlock()

        if screenSource != .off {
            // If a vision model is assigned, retain frame PNGs to an ephemeral caption dir OUTSIDE
            // the session temp dir (so it survives `cleanup()` for the post-call caption pass; the
            // captioner deletes it, and the launch sweep clears any crash leftovers).
            if !AppSettings.visionModel.isEmpty {
                let dir = Self.pendingCaptionsRoot.appendingPathComponent(sessionDir.lastPathComponent, isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                captionDir = dir
            }
            let capturer = ScreenContextCapturer(
                interval: TimeInterval(AppSettings.screenCaptureInterval),
                sessionStart: startedAt,
                focus: AppSettings.screenFocus,
                source: screenSource,
                imageDir: captionDir
            )
            await capturer.start()
            lock.lock(); screenCapturer = capturer; lock.unlock()
        }

        lock.lock(); state = .recording; lock.unlock()

        // Live transcript from the live source — best-effort, brought up in the background AFTER
        // capture is rolling: its setup can include a model download (first use per locale), which
        // must never delay the recording itself. The task is cancelled by stop() if it loses the
        // race. Fed by the mic when captured, otherwise the system track (system-audio conference).
        if AppSettings.liveTranscriptionEnabled {
            let live = LiveTranscriber()
            live.onUpdate = { finalized, partial in
                if let finalized { AppModel.shared.live.finalized = finalized }
                AppModel.shared.live.partial = partial
            }
            let feedsMic = mode.capturesMic
            let startTask = Task { [weak self] in
                do {
                    try await live.start()
                } catch {
                    self?.log.error("live transcription unavailable: \(error.localizedDescription, privacy: .public)")
                    return
                }
                guard let self, let feed = live.feed, !Task.isCancelled else {
                    await live.stop()
                    return
                }
                // If stop() already began teardown, don't resurrect the transcriber — stop this
                // instance ourselves so it can't outlive the session (audit L6). Wire onBuffer INSIDE
                // the lock too: the lock handshake then orders this write before stop()'s (also
                // lock-guarded) isStopping=true, hence before its capture teardown, so the onBuffer
                // assignment can't race stop() niling micCapture/systemCapture.
                self.lock.lock()
                let claimed = !self.isStopping
                if claimed {
                    self.liveTranscriber = live
                    if feedsMic { self.micCapture?.onBuffer = feed } else { self.systemCapture?.onBuffer = feed }
                }
                self.lock.unlock()
                guard claimed else { await live.stop(); return }
            }
            // Publish the task under the lock so stop()'s read/cancel/nil can't race this assignment.
            lock.lock(); liveStartTask = startTask; lock.unlock()
        }
    }

    /// Pauses/resumes capture. Paused intervals are simply omitted from both tracks, so they stay
    /// aligned and the transcript has no silent gap.
    func pause() async {
        lock.lock()
        let mic = micCapture
        let system = systemCapture
        let screen = screenCapturer
        lock.unlock()
        mic?.isPaused = true
        system?.setPaused(true)
        await screen?.setPaused(true)
        lock.lock()
        if pauseBegan == nil { pauseBegan = Date() }
        lock.unlock()
    }
    func resume() async {
        lock.lock()
        if let began = pauseBegan {
            pausedAccum += Date().timeIntervalSince(began)
            pauseBegan = nil
        }
        let mic = micCapture
        let system = systemCapture
        let screen = screenCapturer
        lock.unlock()
        mic?.isPaused = false
        system?.setPaused(false)
        await screen?.setPaused(false)
    }

    /// Records a manual note at the current point in the call. Timestamp excludes paused time,
    /// mirroring the audio tracks (a note typed while paused lands at the pause boundary). Ignored
    /// unless a recording is live; blank notes are dropped. Returns whether the note was stored,
    /// so the caller can keep a running count. Safe to call from the main actor.
    @discardableResult
    func addNote(_ text: String) -> Bool {
        let clean = text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }

        // Read the timing fields and the recording gate under the lock so a note's timestamp can't
        // tear against a concurrent pause()/resume()/stop() (all off-main). Appending here too keeps
        // the note atomic with the timestamp it was computed against.
        lock.lock(); defer { lock.unlock() }
        guard state == .recording else { return false }
        var elapsedPaused = pausedAccum
        if let began = pauseBegan { elapsedPaused += Date().timeIntervalSince(began) }
        let ms = max(0, Int((Date().timeIntervalSince(startedAt) - elapsedPaused) * 1000))
        notes.append(CallNote(startMs: ms, text: clean))
        return true
    }

    private func drainNotes() -> [CallNote] {
        lock.lock(); defer { lock.unlock() }
        return notes
    }

    /// Stops capture and runs the mix → transcribe → write pipeline. Returns the transcript
    /// URL on success. On success the raw audio is deleted; on failure it is left for the
    /// launch-time sweep so nothing persists indefinitely.
    func stop() async throws -> URL {
        lock.lock()
        guard state == .recording else {
            lock.unlock()
            throw NSError(domain: "Scripta", code: 300,
                          userInfo: [NSLocalizedDescriptionKey: "No recording is in progress."])
        }
        state = .processing
        isStopping = true
        // Detach every capture reference and clear its slot in the SAME critical section, so tearing
        // them down below can't race pause()/resume() reading the slots or the liveStartTask closure
        // assigning them — all of which touch these vars only under `lock`. We then operate solely on
        // the locals, never the stored slots, across the awaits (the lock is not held there).
        // isStopping (set above) already blocks the closure from resurrecting a transcriber past here.
        let mic = micCapture
        let system = systemCapture
        let screen = screenCapturer
        let live = liveTranscriber
        let startTask = liveStartTask
        micCapture = nil
        systemCapture = nil
        screenCapturer = nil
        liveTranscriber = nil
        liveStartTask = nil
        lock.unlock()

        mic?.stop()
        await system?.stop()
        let snippets = await screen?.stop() ?? []
        startTask?.cancel()
        // Don't await .value — a first-use model download inside live.start() may not cancel promptly
        // and would block stop()/quit. The isStopping flag stops any live instance the task assigns,
        // and this stops one already assigned; so the transcriber is torn down exactly once (audit L6).
        await live?.stop()
        endActivity()

        let systemURL = self.systemURL
        let micURL = self.micURL
        let youWavURL = self.youWavURL
        let themWavURL = self.themWavURL
        let isConference = mode != .call
        let extraVocab = self.extraVocab
        let group = self.group
        lock.lock()
        let startedAt = self.startedAt   // read under the lock so the guarantee stays local
        if let began = pauseBegan {   // stopped while paused
            pausedAccum += Date().timeIntervalSince(began)
            pauseBegan = nil
        }
        let duration = Date().timeIntervalSince(startedAt) - pausedAccum
        lock.unlock()
        let notes = drainNotes()

        do {
            // Heavy work (audio conversion + transcription) runs off the main actor.
            let transcriptURL = try await Task.detached(priority: .userInitiated) {
                try await Self.produceTranscript(
                    systemURL: systemURL, micURL: micURL, youWavURL: youWavURL, themWavURL: themWavURL,
                    startedAt: startedAt, duration: duration, snippets: snippets,
                    notes: notes, isConference: isConference, group: group, extraVocab: extraVocab)
            }.value

            // Success: raw audio is no longer needed.
            cleanup()
            lock.lock(); state = .idle; lock.unlock()
            return transcriptURL
        } catch {
            // Leave raw audio for the launch-time sweep; surface the failure.
            lock.lock(); state = .idle; lock.unlock()
            throw error
        }
    }

    /// Error codes that mean "nothing worth keeping" — the recovery sweep deletes the raw audio
    /// for these, but keeps it (to retry next launch) for any transient failure.
    static let noAudioCode = 201
    static let noSpeechCode = 202

    /// The convert → transcribe → merge → enrich → write pipeline, shared by `stop()` and the
    /// launch-time orphan recovery. Not main-actor bound; call from a detached task. `extraTags`
    /// lets recovery mark a call as recovered.
    static func produceTranscript(
        systemURL: URL, micURL: URL, youWavURL: URL, themWavURL: URL,
        startedAt: Date, duration: TimeInterval,
        snippets: [ScreenSnippet], notes: [CallNote] = [], extraTags: [String] = [],
        isConference: Bool = false, group: String = "", extraVocab: [String] = []
    ) async throws -> URL {
        // Convert each captured track to the transcription format. The peak tells us whether the
        // track actually carried speech.
        let micPeak = try AudioConverter.prepareTrack(inputURL: micURL, outputURL: youWavURL)
        let systemPeak = try AudioConverter.prepareTrack(inputURL: systemURL, outputURL: themWavURL)

        guard micPeak > 0 || systemPeak > 0 else {
            throw NSError(domain: "Scripta", code: noAudioCode,
                          userInfo: [NSLocalizedDescriptionKey: "Recording produced no audio to transcribe."])
        }

        // Transcribe each side separately (sequential — avoids double locale reservation).
        let youSegments = micPeak > 0 ? try await SpeechEngine.transcribe(audioURL: youWavURL, extraVocab: extraVocab) : []
        let themSegments = systemPeak > 0 ? try await SpeechEngine.transcribe(audioURL: themWavURL, extraVocab: extraVocab) : []

        // Label + interleave only when both sides have speech — otherwise a single side
        // (in-person, or a one-sided call) would be mislabeled, so leave it unlabeled.
        let rawSegments: [TranscriptSegment]
        if !youSegments.isEmpty && !themSegments.isEmpty {
            rawSegments = merge(you: youSegments, them: themSegments)
        } else {
            rawSegments = youSegments.isEmpty ? themSegments : youSegments
        }

        // Deterministically strip filler words; drop any segment left empty. Preserve labels.
        let segments = rawSegments
            .map { TranscriptSegment(startMs: $0.startMs, text: FillerCleaner.clean($0.text), speaker: $0.speaker) }
            .filter { !$0.text.isEmpty }

        // Zero segments must fail like any other pipeline error — writing a placeholder
        // transcript would count as "success" and delete the only copy of the audio. But a call
        // the user annotated with notes is worth keeping even if no speech was recognized.
        guard !segments.isEmpty || !notes.isEmpty else {
            throw NSError(domain: "Scripta", code: noSpeechCode,
                          userInfo: [NSLocalizedDescriptionKey: "No speech was recognized in the recording."])
        }

        // Optional on-device title + summary + topics — additive, never rewrites the transcript.
        var title: String?
        var summary: String?
        var tags = ["call"] + extraTags
        let plain = segments.map { segment in
            segment.speaker.map { "\($0.rawValue): \(segment.text)" } ?? segment.text
        }.joined(separator: "\n")

        // Apple FM enrichment (seconds) runs inline, exactly as before. A slow local endpoint is
        // DEFERRED: `TranscriptWriter.uniqueURL` bakes the title into the filename and the launch
        // sweep deletes crash leftovers, so every second of pre-write model time is a data-loss
        // window — write immediately with a generic name, then patch title/topics/summary after.
        let deferEnrichment = AppSettings.summarizeEnabled && EngineRouter.enrichmentIsDeferred
        if AppSettings.summarizeEnabled && !deferEnrichment {
            if let digest = await TranscriptEnricher.enrich(plain) {
                title = digest.title
                summary = digest.summary
                tags += digest.topics.filter { $0 != "call" }
            }
        }

        let url = try TranscriptWriter.write(to: AppSettings.outputFolder, segments: segments,
                                             startedAt: startedAt, duration: duration,
                                             tags: tags, title: title, summary: summary,
                                             screenSnippets: snippets, notes: notes,
                                             isConference: isConference, group: group)

        if deferEnrichment {
            Task.detached(priority: .utility) {
                guard let digest = await TranscriptEnricher.enrich(plain) else { return }
                try? TranscriptMetadataEditor.applyDigest(url: url, digest: digest)
                if let store = IndexStore.shared { IndexBuilder.index(url, into: store) }
                await MainActor.run { AppModel.shared.reloadCalls() }
            }
        }
        return url
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
