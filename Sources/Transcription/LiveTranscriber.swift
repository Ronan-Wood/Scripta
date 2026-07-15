import Speech
import AVFoundation

/// Streams a live transcript while recording: mic buffers are fed into an on-device
/// `SpeechAnalyzer` with volatile results, so text appears as it's spoken. Runs alongside the
/// file-based capture (which still produces the saved 2-track You/Them transcript on stop).
final class LiveTranscriber {
    /// Called on the main actor with the current in-progress (volatile) line; `finalized` is
    /// non-nil only when a line was finalized, so volatile ticks don't republish the whole array.
    var onUpdate: (@MainActor (_ finalized: [String]?, _ partial: String) -> Void)?

    /// Feed for captured mic buffers, built once start() succeeds. It captures the analyzer
    /// plumbing immutably, so the audio thread never reads this object's mutable state.
    private(set) var feed: ((AVAudioPCMBuffer) -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    private var finalized: [String] = []

    func start() async throws {
        let locale = try await SpeechEngine.resolvedLocale()
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        self.transcriber = transcriber
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "CallTranscriber", code: 203,
                          userInfo: [NSLocalizedDescriptionKey: "No compatible audio format for live transcription."])
        }

        let (sequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
        inputBuilder = builder
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        do {
            try await analyzer.start(inputSequence: sequence)
        } catch {
            // Don't leave the input stream open — anything already wired would block forever.
            inputBuilder?.finish()
            inputBuilder = nil
            throw error
        }

        feed = Self.makeFeed(format: analyzerFormat, input: builder)

        // Created only after the analyzer is running: if start() threw, this task would retain
        // self and block in `transcriber.results` permanently. No audio is fed before start()
        // returns, so nothing is missed.
        resultsTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if result.isFinal {
                        self.finalized.append(text)
                        let lines = self.finalized
                        await MainActor.run { self.onUpdate?(lines, "") }
                    } else {
                        await MainActor.run { self.onUpdate?(nil, text) }
                    }
                }
            } catch { /* stream ended */ }
        }
    }

    /// Builds the audio-thread feed closure: converts each mic buffer to the analyzer's format
    /// and yields it. `format` and `input` are captured immutably; the lazily-created converter
    /// is confined to the closure (and therefore to the single audio thread that calls it).
    private static func makeFeed(format: AVAudioFormat,
                                 input: AsyncStream<AnalyzerInput>.Continuation) -> (AVAudioPCMBuffer) -> Void {
        var converter: AVAudioConverter?
        return { buffer in
            if converter == nil { converter = AVAudioConverter(from: buffer.format, to: format) }
            guard let converter else { return }

            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }

            var error: NSError?
            var fed = false
            converter.convert(to: output, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            if output.frameLength > 0 { input.yield(AnalyzerInput(buffer: output)) }
        }
    }

    func stop() async {
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
    }
}
