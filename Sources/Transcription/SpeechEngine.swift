import Speech
import AVFoundation
import Foundation

/// Which side of the conversation a segment came from. `you` = the local microphone,
/// `them` = the far side captured as system audio. `nil` when the split isn't meaningful
/// (e.g. an in-person recording where everyone is on the mic) — then no label is shown.
enum Speaker: String {
    case you = "You"
    case them = "Them"
}

/// One timestamped chunk of transcript.
struct TranscriptSegment {
    let startMs: Int
    let text: String
    let speaker: Speaker?

    init(startMs: Int, text: String, speaker: Speaker? = nil) {
        self.startMs = startMs
        self.text = text
        self.speaker = speaker
    }
}

/// Transcribes audio with Apple's on-device SpeechTranscriber (macOS 26+). The speech model
/// is managed by the OS — nothing to bundle or download ourselves. Fully local. Returns
/// timestamped segments, and biases recognition with the user's domain vocabulary.
enum SpeechEngine {

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Transcribes the audio file. Call off the main thread.
    static func transcribe(audioURL: URL) async throws -> [TranscriptSegment] {
        let locale = try await resolvedLocale()
        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [])

        // Ensure the on-device model for this locale is installed (OS-managed; usually present).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        // Bias recognition toward the user's domain vocabulary.
        let context = AnalysisContext()
        let vocab = AppSettings.domainVocabulary.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !vocab.isEmpty {
            context.contextualStrings = [.general: vocab]
        }

        let file = try AVAudioFile(forReading: audioURL)

        // Collect finalized, timestamped segments as they arrive.
        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let seconds = result.range.start.seconds
                let startMs = seconds.isFinite ? max(0, Int(seconds * 1000)) : 0
                segments.append(TranscriptSegment(startMs: startMs, text: text))
            }
            return segments
        }

        // Creating the analyzer with the file starts analysis; finishAfterFile ends the stream.
        let analyzer = try await SpeechAnalyzer(inputAudioFile: file, modules: [transcriber],
                                                analysisContext: context, finishAfterFile: true)
        _ = analyzer
        return try await collector.value
    }

    /// Resolves the user's language setting to a locale the on-device model actually supports.
    /// `SpeechTranscriber.supportedLocales` are region-qualified (e.g. `en-US`, never bare `en`),
    /// so a raw `Locale(identifier:)` won't reserve — we match by BCP-47, falling back to the
    /// best same-language variant (current region → installed → any). Shared with `LiveTranscriber`.
    static func resolvedLocale() async throws -> Locale {
        let requested = AppSettings.language == "auto"
            ? Locale.current
            : Locale(identifier: AppSettings.language)
        let supported = await SpeechTranscriber.supportedLocales
        let installed = Set((await SpeechTranscriber.installedLocales).map { $0.identifier(.bcp47) })

        // Exact BCP-47 match (honors an explicit "en-GB" etc.).
        if let exact = supported.first(where: { $0.identifier(.bcp47) == requested.identifier(.bcp47) }) {
            return exact
        }

        // Same language, no region specified: prefer the current region, then any installed, then any.
        let reqLang = requested.language.languageCode?.identifier
        let sameLang = supported.filter { $0.language.languageCode?.identifier == reqLang }
        if !sameLang.isEmpty {
            let currentRegion = Locale.current.region?.identifier
            if let regional = sameLang.first(where: { $0.region?.identifier == currentRegion }) { return regional }
            if let inst = sameLang.first(where: { installed.contains($0.identifier(.bcp47)) }) { return inst }
            return sameLang[0]
        }

        let list = supported.map { $0.identifier(.bcp47) }.sorted().joined(separator: ", ")
        throw EngineError(message: "No on-device speech model supports language “\(AppSettings.language)”. "
            + "Choose one of: \(list).")
    }
}
