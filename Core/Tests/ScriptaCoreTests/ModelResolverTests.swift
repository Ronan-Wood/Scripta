import XCTest
@testable import ScriptaCore

/// Covers how a Settings model binding resolves against the server's catalog. The fixture is the
/// Ollama catalog this was built against: two qwen3.5 MLX chat models, a 1-bit 27B, a reranker that
/// reports `completion`, and a shelf of embedders.
final class ModelResolverTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private let chat = ["completion", "vision", "thinking", "tools"]

    private lazy var ollama: [ServerModel] = [
        ServerModel(name: "hf.co/prism-ml/Bonsai-27B-gguf:Q1_0", capabilities: ["tools", "thinking", "completion", "vision"], sizeBytes: 44 * gb / 10),
        ServerModel(name: "dengcao/Qwen3-Reranker-4B:Q4_K_M", capabilities: ["tools", "thinking", "completion"], sizeBytes: 25 * gb / 10),
        ServerModel(name: "qwen3.5:4b-mlx", capabilities: chat, sizeBytes: 4 * gb),
        ServerModel(name: "qwen3.5:9b-mlx", capabilities: chat, sizeBytes: 89 * gb / 10),
        ServerModel(name: "embeddinggemma:latest", capabilities: ["embedding"], sizeBytes: 6 * gb / 10),
        ServerModel(name: "qwen3-embedding:8b", capabilities: ["tools", "embedding"], sizeBytes: 47 * gb / 10),
        ServerModel(name: "nomic-embed-text:latest", capabilities: ["embedding"], sizeBytes: 3 * gb / 10),
    ]

    private func resolve(_ binding: String, _ role: ModelRole, _ catalog: [ServerModel]?) -> ResolvedModel {
        ModelResolver.resolve(binding: binding, role: role, catalog: catalog)
    }

    func testEmptyBindingIsNone() {
        for role in [ModelRole.ask, .enrich, .vision, .search] {
            XCTAssertEqual(resolve("", role, ollama), .none)
        }
    }

    func testAutoPicksLargestForAskAndSmallestForBackgroundWork() {
        XCTAssertEqual(resolve("auto", .ask, ollama), .model("qwen3.5:9b-mlx", .auto))
        XCTAssertEqual(resolve("auto", .enrich, ollama), .model("qwen3.5:4b-mlx", .auto))
        XCTAssertEqual(resolve("auto", .vision, ollama), .model("qwen3.5:4b-mlx", .auto))
    }

    /// The reranker is the smallest model reporting `completion`; capabilities alone would hand it
    /// every title and summary.
    func testRerankerIsNeverPicked() {
        let catalog = ollama.filter { $0.name.hasPrefix("dengcao") || $0.name == "qwen3.5:9b-mlx" }
        XCTAssertEqual(resolve("auto", .enrich, catalog), .model("qwen3.5:9b-mlx", .auto))
    }

    func testEmbeddersAreNeverPicked() {
        let embedders = ollama.filter { $0.capabilities?.contains("embedding") == true }
        for role in [ModelRole.ask, .enrich, .vision, .search] {
            XCTAssertEqual(resolve("auto", role, embedders), .none)
        }
    }

    /// A cloud model reports a near-zero size (only its manifest is local), so smallest-first would
    /// pick it for every title, summary and caption — and send them to Ollama's cloud.
    func testCloudModelsAreNeverPickedButStayOffered() {
        let cloud = ServerModel(name: "qwen3-vl:235b-cloud", capabilities: chat, sizeBytes: 400, isRemote: true)
        let catalog = ollama + [cloud]
        XCTAssertEqual(resolve("auto", .enrich, catalog), .model("qwen3.5:4b-mlx", .auto))
        XCTAssertEqual(resolve("auto", .vision, catalog), .model("qwen3.5:4b-mlx", .auto))
        XCTAssertEqual(resolve("qwen2.5vl:7b", .vision, catalog), .model("qwen3.5:4b-mlx", .substituted(for: "qwen2.5vl:7b")))
        XCTAssertEqual(resolve("auto", .vision, [cloud]), .none)
        XCTAssertEqual(resolve("qwen3-vl:235b-cloud", .vision, catalog), .model("qwen3-vl:235b-cloud", .asSaved))
        XCTAssertTrue(ModelResolver.offers(cloud, for: .vision))
    }

    /// When `/api/tags` can't be read nothing marks a model remote, so the name has to.
    func testCloudNamesAreRecognisedWithoutTheServersWord() {
        let names = ["gpt-oss:120b-cloud", "glm-4.6:cloud", "llama3:8b"].map { ServerModel(name: $0) }
        XCTAssertEqual(resolve("auto", .ask, names), .model("llama3:8b", .auto))
        XCTAssertEqual(resolve("auto", .enrich, names), .model("llama3:8b", .auto))
        XCTAssertEqual(resolve("qwen2.5:7b", .enrich, Array(names.prefix(2))), .none)
        XCTAssertTrue(ModelResolver.offers(names[0], for: .ask))
    }

    func testSavedPickOnTheServerWinsOverAuto() {
        XCTAssertEqual(resolve("qwen3.5:9b-mlx", .enrich, ollama), .model("qwen3.5:9b-mlx", .asSaved))
    }

    func testBareNameMatchesLatestTag() {
        let catalog = [ServerModel(name: "mistral:latest", capabilities: ["completion"], sizeBytes: gb)]
        XCTAssertEqual(resolve("mistral", .ask, catalog), .model("mistral:latest", .asSaved))
    }

    /// The case that prompted this: the saved picks were removed from the server.
    func testStalePickIsSubstituted() {
        XCTAssertEqual(resolve("qwen2.5:14b", .ask, ollama), .model("qwen3.5:9b-mlx", .substituted(for: "qwen2.5:14b")))
        XCTAssertEqual(resolve("qwen2.5:7b", .enrich, ollama), .model("qwen3.5:4b-mlx", .substituted(for: "qwen2.5:7b")))
        XCTAssertEqual(resolve("qwen2.5vl:7b", .vision, ollama), .model("qwen3.5:4b-mlx", .substituted(for: "qwen2.5vl:7b")))
    }

    func testStalePickWithNothingSuitableIsNone() {
        let noVision = [ServerModel(name: "mistral:latest", capabilities: ["completion"], sizeBytes: gb)]
        XCTAssertEqual(resolve("qwen2.5vl:7b", .vision, noVision), .none)
    }

    func testWithoutACatalogNamedPicksAreTrustedAndAutoIsNone() {
        XCTAssertEqual(resolve("qwen2.5:14b", .ask, nil), .model("qwen2.5:14b", .asSaved))
        XCTAssertEqual(resolve("auto", .ask, nil), .none)
    }

    /// A non-Ollama server: names only. Chat still avoids embedders and rerankers by name; vision
    /// is never guessed, though the user can still pick a model for it.
    func testServerThatWontDescribeItsModels() {
        let names = ["bge-m3", "nomic-embed-text", "jina-reranker-v2", "llama3:8b"].map { ServerModel(name: $0) }
        XCTAssertEqual(resolve("auto", .ask, names), .model("llama3:8b", .auto))
        XCTAssertEqual(resolve("auto", .vision, names), .none)
        XCTAssertTrue(ModelResolver.offers(ServerModel(name: "llama3:8b"), for: .vision))
        XCTAssertFalse(ModelResolver.offers(ServerModel(name: "jina-reranker-v2"), for: .ask))
    }

    func testOffersHidesWhatTheServerSaysCantDoTheJob() {
        let byName = Dictionary(uniqueKeysWithValues: ollama.map { ($0.name, $0) })
        XCTAssertFalse(ModelResolver.offers(byName["nomic-embed-text:latest"]!, for: .ask))
        XCTAssertFalse(ModelResolver.offers(byName["dengcao/Qwen3-Reranker-4B:Q4_K_M"]!, for: .enrich))
        XCTAssertTrue(ModelResolver.offers(byName["qwen3.5:9b-mlx"]!, for: .vision))
        let textOnly = ServerModel(name: "mistral:latest", capabilities: ["completion"], sizeBytes: gb)
        XCTAssertFalse(ModelResolver.offers(textOnly, for: .vision))
        XCTAssertTrue(ModelResolver.offers(textOnly, for: .ask))
    }

    func testTiesAndUnknownSizesAreStable() {
        let catalog = [
            ServerModel(name: "b-model", capabilities: ["completion"]),
            ServerModel(name: "z-model", capabilities: ["completion"], sizeBytes: gb),
            ServerModel(name: "a-model", capabilities: ["completion"], sizeBytes: gb),
        ]
        XCTAssertEqual(ModelResolver.best(for: .enrich, in: catalog), "a-model")
        XCTAssertEqual(ModelResolver.best(for: .ask, in: catalog), "a-model")
        XCTAssertEqual(ModelResolver.best(for: .ask, in: [ServerModel(name: "b", capabilities: ["completion"]),
                                                           ServerModel(name: "a", capabilities: ["completion"])]), "a")
    }

    // MARK: - Search (the engine's query expansion)

    /// Smallest chat model, as for enrichment: the 2026-11-01 sweep measured the 9B no better than
    /// the 4B at HyDE, and HyDE runs on every new query. The reranker, the smaller of the two, is
    /// skipped by name.
    func testAutoSearchPicksTheSmallestChatModel() {
        XCTAssertEqual(resolve("auto", .search, ollama), .model("qwen3.5:4b-mlx", .auto))
    }

    func testSearchArgumentPassesANamedPickTheServerHas() {
        XCTAssertEqual(ModelResolver.searchArgument(binding: "qwen3.5:9b-mlx", catalog: ollama, servesEngine: true), "qwen3.5:9b-mlx")
        // No catalog yet: nothing to doubt the pick against, so it goes as saved.
        XCTAssertEqual(ModelResolver.searchArgument(binding: "qwen3.5:9b-mlx", catalog: nil, servesEngine: true), "qwen3.5:9b-mlx")
    }

    /// Auto is the ENGINE's to resolve, against what its Ollama lists now: the app's catalog can be
    /// stale, and a name pinned from it outlives the model. The picker label still names the pick.
    func testAutoSearchIsLeftToTheEngine() {
        XCTAssertNil(ModelResolver.searchArgument(binding: "auto", catalog: ollama, servesEngine: true))
        XCTAssertNil(ModelResolver.searchArgument(binding: "auto", catalog: nil, servesEngine: true))
    }

    /// The bug this binding exists for: a pick the server no longer has went to the engine as-is,
    /// and search silently lost expansion. Nothing is passed instead, so the engine's Auto stands
    /// in — the model the picker's stale row names.
    func testAStaleSearchPickIsNotPassed() {
        XCTAssertNil(ModelResolver.searchArgument(binding: "qwen2.5:7b", catalog: ollama, servesEngine: true))
        XCTAssertEqual(resolve("qwen2.5:7b", .search, ollama), .model("qwen3.5:4b-mlx", .substituted(for: "qwen2.5:7b")))
    }

    /// Off is only ever the user's choice. "No suitable model yet" is not Off: the engine reports
    /// that as unavailable and re-checks it, so a model pulled later is used without a restart.
    func testOnlyAnEmptyBindingIsOff() {
        XCTAssertEqual(ModelResolver.searchArgument(binding: "", catalog: ollama, servesEngine: true), ModelResolver.searchOff)
        let embedders = ollama.filter { $0.capabilities?.contains("embedding") == true }
        XCTAssertNil(ModelResolver.searchArgument(binding: "auto", catalog: embedders, servesEngine: true))
        XCTAssertNil(ModelResolver.searchArgument(binding: "qwen2.5:7b", catalog: embedders, servesEngine: true))
    }

    /// A catalog from any server but the engine's own says nothing about what the engine can run,
    /// so no model NAME is passed then — but Off names no model, and is the user's either way.
    func testOnlyOffIsPassedUnlessSettingsServesTheEngine() {
        for binding in ["auto", "qwen3.5:9b-mlx"] {
            XCTAssertNil(ModelResolver.searchArgument(binding: binding, catalog: ollama, servesEngine: false))
        }
        XCTAssertEqual(ModelResolver.searchArgument(binding: "", catalog: ollama, servesEngine: false), ModelResolver.searchOff)
        XCTAssertEqual(ModelResolver.searchArgument(binding: "", catalog: nil, servesEngine: false), ModelResolver.searchOff)
    }

    /// The picker never shows a state the engine is not in: a named pick that is not passed shows
    /// as Auto, which is what runs; Off and Auto show as themselves.
    func testThePickerShowsWhatTheEngineRuns() {
        XCTAssertEqual(ModelResolver.searchShown(binding: "qwen3.5:9b-mlx", servesEngine: false), ModelResolver.auto)
        XCTAssertEqual(ModelResolver.searchShown(binding: "", servesEngine: false), "")
        XCTAssertEqual(ModelResolver.searchShown(binding: "auto", servesEngine: false), "auto")
        XCTAssertEqual(ModelResolver.searchShown(binding: "qwen3.5:9b-mlx", servesEngine: true), "qwen3.5:9b-mlx")
    }

    /// Search's query is vault content, and the engine is loopback-only by design; Ollama proxying a
    /// cloud model would defeat that while the socket stays local. So Search never offers one, and a
    /// saved one behaves like a stale pick: not passed, with Auto's local model standing in.
    func testSearchNeverUsesACloudModel() {
        let cloud = ServerModel(name: "qwen3-vl:235b-cloud", capabilities: chat, sizeBytes: 400, isRemote: true)
        let proxied = ServerModel(name: "big:latest", capabilities: chat, sizeBytes: 9 * gb, isRemote: true)
        let catalog = ollama + [cloud, proxied]
        XCTAssertFalse(ModelResolver.offers(cloud, for: .search))
        XCTAssertFalse(ModelResolver.offers(proxied, for: .search))
        XCTAssertTrue(ModelResolver.offers(cloud, for: .ask), "an explicit cloud pick stays the user's for Ask")
        XCTAssertEqual(resolve("big:latest", .search, catalog), .model("qwen3.5:4b-mlx", .substituted(for: "big:latest")))
        for binding in ["big:latest", "qwen3-vl:235b-cloud"] {
            XCTAssertNil(ModelResolver.searchArgument(binding: binding, catalog: catalog, servesEngine: true))
        }
        // No catalog to recognise it by: the tag still says cloud, in any case.
        XCTAssertNil(ModelResolver.searchArgument(binding: "glm-4.6:cloud", catalog: nil, servesEngine: true))
        XCTAssertNil(ModelResolver.searchArgument(binding: "gpt-oss:120b-CLOUD", catalog: nil, servesEngine: true))
        XCTAssertTrue(ModelResolver.isRemote(ServerModel(name: "glm-4.6:Cloud")))
    }
}
