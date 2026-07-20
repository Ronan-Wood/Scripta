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

    /// Notes-merge (M16): same task bucket, model, and fallback as `enrich` — a user's assigned
    /// "capable" local model applies here too, not just to title/summary. Always backgrounded by
    /// the caller (a separate note file, not the transcript write), so no defer-flag is needed.
    static func mergeNotes(transcript: String, notes: String) async -> String? {
        if let endpoint = endpointEngine(for: .enrich) {
            if let body = await endpoint.mergeNotes(transcript: transcript, notes: notes, sizeClass: endpoint.sizeClass) {
                return body
            }
        }
        let apple = AppleFMEngine()
        return await apple.mergeNotes(transcript: transcript, notes: notes, sizeClass: apple.sizeClass)
    }

    /// Commitment extraction (M17): same task bucket, model, and fallback as `enrich`. Always
    /// backgrounded by the caller (a frontmatter patch after the write, not the write itself).
    static func extractCommitments(transcript: String) async -> [ExtractedCommitment]? {
        if let endpoint = endpointEngine(for: .enrich) {
            if let items = await endpoint.extractCommitments(transcript: transcript, sizeClass: endpoint.sizeClass) {
                return items
            }
        }
        let apple = AppleFMEngine()
        return await apple.extractCommitments(transcript: transcript, sizeClass: apple.sizeClass)
    }

    /// The reranker (gated experiment). nil unless rerank is enabled AND an endpoint model is
    /// assigned for Ask — Apple FM deliberately doesn't rerank (measured too weak).
    static func rerankEngine() -> RerankEngine? {
        guard AppSettings.rerankEnabled else { return nil }
        return endpointEngine(for: .ask)
    }

    /// The embedding engine (Phase B), or nil to stay FTS-only. Requires the endpoint on + local +
    /// an embed model assigned. Apple FM doesn't embed.
    static func embeddingEngine() -> EmbeddingEngine? {
        guard AppSettings.endpointEnabled, !AppSettings.embedModel.isEmpty,
              let url = AppSettings.endpointURL,
              Locality.isAllowedForRequest(url, lanConfirmed: AppSettings.endpointLANConfirmed) else { return nil }
        return EndpointEngine(baseURL: url, model: AppSettings.embedModel, lanConfirmed: AppSettings.endpointLANConfirmed)
    }

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
