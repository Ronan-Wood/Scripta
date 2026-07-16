import Foundation

/// Resolves task → engine from settings at dispatch (so switching engines is live). Apple FM is
/// always the default and the automatic downward fallback; nothing constructs a URLSession unless
/// the endpoint is enabled, configured, and local.
enum EngineRouter {

    /// The chat engine for a task — the assigned local model if usable, else Apple FM.
    static func chatEngine(for task: EngineTask) -> ChatEngine {
        endpointEngine(for: task) ?? AppleFMEngine()
    }

    /// True when a task is configured to use the endpoint but will fall back to Apple FM (endpoint
    /// off/unreachable/unassigned) — drives the "using Apple Intelligence" UI notice.
    static func usesEndpoint(for task: EngineTask) -> Bool {
        endpointEngine(for: task) != nil
    }

    /// Enrichment: endpoint if assigned (silent fallback to Apple FM on any failure), else Apple FM.
    /// Never blocks the transcript write — a nil result just means no title/summary.
    static func enrich(_ transcript: String) async -> TranscriptDigest? {
        if let endpoint = endpointEngine(for: .enrich) {
            if let digest = await endpoint.digest(transcript: transcript, sizeClass: endpoint.sizeClass) {
                return digest
            }
        }
        let apple = AppleFMEngine()
        return await apple.digest(transcript: transcript, sizeClass: apple.sizeClass)
    }

    /// True when enrichment will run on the endpoint — the recording pipeline defers frontmatter
    /// enrichment in that case (the endpoint's 60–240s digest must not delay the write).
    static var enrichmentIsDeferred: Bool { endpointEngine(for: .enrich) != nil }

    // MARK: -

    private static func endpointEngine(for task: EngineTask) -> EndpointEngine? {
        guard AppSettings.endpointEnabled,
              let url = AppSettings.endpointURL,
              Locality.isAllowedForRequest(url, lanConfirmed: AppSettings.endpointLANConfirmed) else { return nil }
        let model = AppSettings.endpointModel(for: task)
        guard let model, !model.isEmpty else { return nil }
        return EndpointEngine(baseURL: url, model: model, lanConfirmed: AppSettings.endpointLANConfirmed)
    }
}
