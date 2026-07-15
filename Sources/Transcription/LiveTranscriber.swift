import Speech
import AVFoundation

/// Streams a live transcript while recording: mic buffers are fed into an on-device
/// `SpeechAnalyzer` with volatile results, so text appears as it's spoken. Runs alongside the
/// file-based capture (which still produces the saved 2-track You/Them transcript on stop).
final class LiveTranscriber {
    /// Called on the main actor with the finalized lines and the current in-progress (volatile) line.
    var onUpdate: (@MainActor (_ finalized: [String], _ partial: String) -> Void)?

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
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
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

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
                        let lines = self.finalized
                        await MainActor.run { self.onUpdate?(lines, text) }
                    }
                }
            } catch { /* stream ended */ }
        }
    }

    /// Feed one captured mic buffer (called on the audio thread). Converts to the analyzer's format.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let analyzerFormat, let inputBuilder else { return }
        if converter == nil { converter = AVAudioConverter(from: buffer.format, to: analyzerFormat) }
        guard let converter else { return }

        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

        var error: NSError?
        var fed = false
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if output.frameLength > 0 { inputBuilder.yield(AnalyzerInput(buffer: output)) }
    }

    func stop() async {
        inputBuilder?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultsTask?.cancel()
        resultsTask = nil
    }
}
