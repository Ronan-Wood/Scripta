import Foundation

/// Captions a screenshot with a local vision model (e.g. `qwen2.5vl:7b`) — for the charts,
/// diagrams, and dashboards OCR can't read. Runs only in the POST-call pass, never live (the
/// meeting-perf rule), and only when a vision model is assigned. Returns nil (skip) otherwise.
enum VLMCaptioner {
    static var model: String { AppSettings.visionModel }
    static var isConfigured: Bool {
        guard AppSettings.endpointEnabled, !AppSettings.visionModel.isEmpty, let url = AppSettings.endpointURL else { return false }
        return Locality.isAllowedForRequest(url, lanConfirmed: AppSettings.endpointLANConfirmed)
    }

    private static let prompt = """
    Describe this screen for a searchable meeting record. In 1–2 sentences, state what is shown \
    (app/document/chart), any title, and the key figures or data. Be concise and factual; no preamble.
    """

    static func caption(imageData: Data) async -> String? {
        guard isConfigured, let url = AppSettings.endpointURL else { return nil }
        let wire = OpenAIWire(baseURL: url, lanConfirmed: AppSettings.endpointLANConfirmed)
        return try? await wire.caption(model: model, imageData: imageData, prompt: prompt)
    }
}
