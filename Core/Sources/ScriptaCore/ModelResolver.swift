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

/// The local-model bindings in Settings → Local model.
public enum ModelRole: Sendable {
    case ask, enrich, vision
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
        if let present = catalog.first(where: { sameModel($0.name, binding) }) {
            return .model(present.name, .asSaved)
        }
        return best(for: role, in: catalog).map { .model($0, .substituted(for: binding)) } ?? .none
    }

    /// Auto's choice for a role: the largest model on disk for Ask, where answer quality matters
    /// most, and the smallest for enrichment and captions, which run after every call. Size on disk
    /// rather than parameter count, because a 1-bit 27B model is smaller and weaker than a 4-bit 9B
    /// one, and MLX builds report no parameter count at all. Equal or unknown sizes fall back to
    /// name order so the choice is stable across launches.
    public static func best(for role: ModelRole, in catalog: [ServerModel]) -> String? {
        catalog.filter { canRun(role, on: $0) }
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

    /// Whether Auto may pick `model` for `role`. Stricter than `offers`: it never picks a cloud
    /// model, because the user didn't choose to send transcripts or screenshots off the machine;
    /// and with no capabilities to go on it never picks a vision model, because a wrong guess sends
    /// screenshots to a model that can't see them.
    public static func canRun(_ role: ModelRole, on model: ServerModel) -> Bool {
        !isRemote(model) && suits(model, role)
    }

    /// Whether the picker lists `model` for `role`. Hides what the server says can't do the job,
    /// and rerankers; a model the server won't describe stays listed, and so does a cloud model,
    /// since an explicit pick is the user's to make.
    public static func offers(_ model: ServerModel, for role: ModelRole) -> Bool {
        model.capabilities == nil ? !isReranker(model.name) : suits(model, role)
    }

    /// A cloud model, by the server's word or by Ollama's naming (`gpt-oss:120b-cloud`,
    /// `glm-4.6:cloud`). The name still says so when the server's description couldn't be read.
    public static func isRemote(_ model: ServerModel) -> Bool {
        if model.isRemote { return true }
        let tag = model.name.split(separator: ":").last.map(String.init) ?? model.name
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
