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
        for role in [ModelRole.ask, .enrich, .vision] {
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
        for role in [ModelRole.ask, .enrich, .vision] {
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
}
