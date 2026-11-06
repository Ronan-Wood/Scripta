import Foundation

/// A model the local server offers, described as far as the server will say. The names come from
/// the OpenAI-wire `/v1/models` every server answers; on Ollama, `/api/tags` adds the on-disk size,
/// the capabilities, and whether the model runs in Ollama's cloud. A server that won't describe its
/// models still yields names.
public struct ServerModel: Codable, Equatable, Sendable {
    public let name: String
    /// Ollama's capability list ("completion", "vision", "embedding", …), or nil when unknown.
    public let capabilities: [String]?
    /// On-disk size in bytes, or nil when unknown.
    public let sizeBytes: Int64?
    /// Served by Ollama's cloud through the local server: whatever is sent to it leaves the machine.
    public let isRemote: Bool

    public init(name: String, capabilities: [String]? = nil, sizeBytes: Int64? = nil, isRemote: Bool = false) {
        self.name = name
        self.capabilities = capabilities
        self.sizeBytes = sizeBytes
        self.isRemote = isRemote
    }
}

/// The local-model bindings in Settings → Local model. `search` is the model the retrieval engine
/// expands vault searches with (HyDE); unlike the others it runs in the engine, not in the app.
public enum ModelRole: Sendable {
    case ask, enrich, vision, search
}

/// What a binding resolves to when a task is dispatched.
public enum ResolvedModel: Equatable, Sendable {
    /// No local model: Apple Intelligence for Ask and enrichment, captioning off for vision.
    case none
    case model(String, Reason)

    public enum Reason: Equatable, Sendable {
        /// The user's pick, and the server has it.
        case asSaved
        /// The binding is Auto.
        case auto
        /// The user's pick is gone from the server; this model stands in for it.
        case substituted(for: String)
    }

    public var name: String? {
        if case .model(let name, _) = self { return name }
        return nil
    }
}

/// What the engine says about its Search model (`list_scopes` → `retrieval_arms`), in the terms the
/// Search picker needs. ScriptaCore cannot see SubstrateKit's wire types; the app maps them onto
/// this once.
public enum EngineSearchReport: Equatable, Sendable {
    /// No engine answered, or it is older than the report.
    case unknown
    /// The engine's HyDE is off.
    case off
    /// What HyDE was asked for (`auto` or a model name) and what that resolved to, if anything.
    case asked(String, resolved: String?)
}

/// Turns a stored binding into the model a task actually runs on. A saved pick used to go to the
/// server as-is, so removing that model from the server broke Ask outright and quietly switched
/// captioning off. A binding now resolves against the last catalog the server reported.
public enum ModelResolver {
    /// The stored binding meaning "the best model the server has for this role".
    public static let auto = "auto"

    /// `binding` is what Settings stores: "" for none, `auto`, or a model name. `catalog` is the
    /// last one fetched, or nil if it never was — then a named pick is trusted as-is (there is
    /// nothing to check it against) and Auto resolves to none (there is nothing to choose from).
    public static func resolve(binding: String, role: ModelRole, catalog: [ServerModel]?) -> ResolvedModel {
        if binding.isEmpty { return .none }
        guard let catalog else {
            return binding == auto ? .none : .model(binding, .asSaved)
        }
        if binding == auto {
            return best(for: role, in: catalog).map { .model($0, .auto) } ?? .none
        }
        // A cloud model is never Search's, even when saved: the query carries what is being
        // searched for in the vault. It is treated as gone. For Search nothing is resolved in its
        // place here (`best` has no Search rule): the engine's own Auto stands in.
        if let present = catalog.first(where: { sameModel($0.name, binding) }),
           !(role == .search && isRemote(present)) {
            return .model(present.name, .asSaved)
        }
        return best(for: role, in: catalog).map { .model($0, .substituted(for: binding)) } ?? .none
    }

    /// Auto's choice for a role: the largest model on disk for Ask, where answer quality matters
    /// most, and the smallest for enrichment and captions, which run after every call. Size on disk
    /// rather than parameter count, because a 1-bit 27B model is smaller and weaker than a 4-bit 9B
    /// one, and MLX builds report no parameter count at all. Equal or unknown sizes fall back to
    /// name order so the choice is stable across launches.
    ///
    /// NEVER FOR SEARCH. Search's Auto runs in the engine, against the engine's Ollama, and the
    /// engine reports what it picked (`list_scopes` → `retrieval_arms`). A copy of its rule here,
    /// run against the Settings server's catalog, is a second answer that can disagree with the one
    /// that runs. `searchAutoLabel` draws the engine's answer instead.
    public static func best(for role: ModelRole, in catalog: [ServerModel]) -> String? {
        guard role != .search else { return nil }
        return catalog.filter { canRun(role, on: $0) }
            .sorted { a, b in
                switch (a.sizeBytes, b.sizeBytes) {
                case let (x?, y?) where x != y: return role == .ask ? x > y : x < y
                case (.some, .none): return true
                case (.none, .some): return false
                default: return a.name < b.name
                }
            }
            .first?.name
    }

    /// The engine's word for "no query expansion": a choice it reports as off, not as a model it
    /// could not reach.
    public static let searchOff = "off"

    /// What the app passes the retrieval engine as `--hyde-model`, or nil to pass nothing and let
    /// the engine choose for itself — its own Auto, applied to what its Ollama lists NOW and
    /// re-applied by its background re-check.
    ///
    /// So only a choice the app can vouch for is passed: Off, or a named pick the catalog still
    /// has (or that there is no catalog yet to doubt). Auto, and a stale pick's stand-in, are left
    /// to the engine. Resolving them here would pin a name from a catalog that may be stale, would
    /// turn "nothing suitable yet" into an Off the user never chose — which the engine never
    /// re-checks — and would be a second copy of a rule that must not drift from the engine's.
    /// `servesEngine` is whether the Settings server is the local Ollama the engine reads; a pick
    /// from any other server's catalog may not exist where the engine looks.
    ///
    /// Off is passed whatever the server: it names no model, so no catalog can make it wrong. A
    /// cloud pick is never passed, even with no catalog to recognise it by — the name still says so.
    public static func searchArgument(binding: String, catalog: [ServerModel]?, servesEngine: Bool) -> String? {
        if binding.isEmpty { return searchOff }
        guard servesEngine, binding != auto, !isRemote(ServerModel(name: binding)) else { return nil }
        if case .model(let name, .asSaved) = resolve(binding: binding, role: .search, catalog: catalog) {
            return name
        }
        return nil
    }

    /// The Search picker's Auto row, from what the ENGINE reports. Only an engine running Auto can
    /// say what Auto picked.
    public static func searchAutoLabel(_ report: EngineSearchReport) -> String {
        switch report {
        case .unknown: return "Auto (chosen by the engine)"
        case .asked(auto, resolved: let model?): return "Auto (\(model))"
        // Nothing to pick, an Ollama that is down, a pick that would not start: the engine's
        // `unavailable` says which, so this does not guess.
        case .asked(auto, resolved: nil): return "Auto (not running in the engine yet)"
        case .off, .asked: return "Auto (the engine picks once this is chosen)"
        }
    }

    /// What runs instead of a Search pick the server no longer has: nothing is passed for it
    /// (`searchArgument`), so the engine's own Auto. Named only when the engine says so.
    public static func searchStandIn(_ report: EngineSearchReport) -> String {
        guard case .asked(auto, resolved: let model?) = report else {
            return "the engine's Auto runs instead"
        }
        return "the engine's Auto runs instead: \(model)"
    }

    /// What the Search picker shows: the binding, except a named pick the engine is not running.
    /// When the Settings server is not the engine's, a named pick is not passed (`searchArgument`)
    /// and the engine's Auto runs — so Auto is what is shown, never a choice it is not in.
    public static func searchShown(binding: String, servesEngine: Bool) -> String {
        servesEngine || binding.isEmpty ? binding : auto
    }

    /// Whether Auto may pick `model` for `role` — for the roles whose Auto runs in the app; Search's
    /// runs in the engine (`best`). Stricter than `offers`: it never picks a cloud
    /// model, because the user didn't choose to send transcripts or screenshots off the machine;
    /// and with no capabilities to go on it never picks a vision model, because a wrong guess sends
    /// screenshots to a model that can't see them.
    public static func canRun(_ role: ModelRole, on model: ServerModel) -> Bool {
        !isRemote(model) && suits(model, role)
    }

    /// Whether the picker lists `model` for `role`. Hides what the server says can't do the job,
    /// and rerankers; a model the server won't describe stays listed, and so does a cloud model,
    /// since an explicit pick is the user's to make — except for Search, whose every query carries
    /// what is being looked for in the vault, to an engine that is loopback-only by design.
    public static func offers(_ model: ServerModel, for role: ModelRole) -> Bool {
        if role == .search && isRemote(model) { return false }
        return model.capabilities == nil ? !isReranker(model.name) : suits(model, role)
    }

    /// A cloud model, by the server's word or by Ollama's naming (`gpt-oss:120b-cloud`,
    /// `glm-4.6:cloud`). The name still says so when the server's description couldn't be read.
    public static func isRemote(_ model: ServerModel) -> Bool {
        if model.isRemote { return true }
        let name = model.name.lowercased()
        let tag = name.split(separator: ":").last.map(String.init) ?? name
        return tag == "cloud" || tag.hasSuffix("-cloud")
    }

    private static func suits(_ model: ServerModel, _ role: ModelRole) -> Bool {
        if isReranker(model.name) { return false }
        guard let caps = model.capabilities else {
            return role != .vision && !isEmbedder(model.name)
        }
        guard caps.contains("completion"), !caps.contains("embedding") else { return false }
        return role != .vision || caps.contains("vision")
    }

    /// Ollama answers to `name` and `name:latest` alike.
    public static func sameModel(_ a: String, _ b: String) -> Bool {
        stripLatest(a) == stripLatest(b)
    }

    private static func stripLatest(_ name: String) -> String {
        name.hasSuffix(":latest") ? String(name.dropLast(":latest".count)) : name
    }

    /// Rerankers report `completion` on Ollama but only score passages, and nothing in their
    /// capabilities says so; the name is the only signal.
    static func isReranker(_ name: String) -> Bool {
        name.lowercased().contains("rerank")
    }

    static func isEmbedder(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("embed") || n.contains("bge-") || n.contains("minilm")
    }
}
