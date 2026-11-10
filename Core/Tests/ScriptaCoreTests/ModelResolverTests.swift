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

    private func resolve(_ binding: String, _ role: ModelRole, _ catalog: [ServerModel]?,
                         cloudAllowed: Bool = false) -> ResolvedModel {
        ModelResolver.resolve(binding: binding, role: role, catalog: catalog, cloudAllowed: cloudAllowed)
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
        XCTAssertTrue(ModelResolver.offers(cloud, for: .vision))
    }

    // MARK: - Cloud models need the user's opt-in

    private lazy var cloud = ServerModel(name: "qwen3-vl:235b-cloud", capabilities: chat, sizeBytes: 400, isRemote: true)
    /// Cloud only by the server's word: nothing in the name says so.
    private lazy var remoteByListing = ServerModel(name: "big:latest", capabilities: chat, sizeBytes: 400, isRemote: true)

    /// A saved cloud pick used to run for Ask, titles and captions with nothing but "(cloud)" in
    /// Settings. Without the feature's opt-in it is treated as gone: a local model stands in.
    func testASavedCloudPickDoesNotRunWithoutConsent() {
        let catalog = ollama + [cloud, remoteByListing]
        for pick in [cloud.name, remoteByListing.name, "big"] {
            XCTAssertEqual(resolve(pick, .ask, catalog), .model("qwen3.5:9b-mlx", .substituted(for: pick)))
            XCTAssertEqual(resolve(pick, .enrich, catalog), .model("qwen3.5:4b-mlx", .substituted(for: pick)))
            XCTAssertEqual(resolve(pick, .vision, catalog), .model("qwen3.5:4b-mlx", .substituted(for: pick)))
            // Nothing local to stand in: nothing runs, rather than the cloud pick.
            XCTAssertEqual(resolve(pick, .ask, [cloud, remoteByListing]), .none)
        }
    }

    func testASavedCloudPickRunsOnceItsFeatureAllowsIt() {
        let catalog = ollama + [cloud, remoteByListing]
        for role in [ModelRole.ask, .enrich, .vision] {
            XCTAssertEqual(resolve(cloud.name, role, catalog, cloudAllowed: true),
                           .model(cloud.name, .asSaved))
            XCTAssertEqual(resolve("big", role, catalog, cloudAllowed: true),
                           .model("big:latest", .asSaved))
        }
    }

    /// Consent is to the model the user picked. Auto, and the stand-in for a pick the server no
    /// longer has, never choose a cloud model even where the feature allows one.
    func testConsentNeverLetsAutoOrTheStandInPickACloudModel() {
        let catalog = ollama + [cloud, remoteByListing]
        for role in [ModelRole.ask, .enrich, .vision] {
            for binding in ["auto", "qwen2.5:14b"] {
                let resolved = resolve(binding, role, catalog, cloudAllowed: true)
                XCTAssertNotNil(resolved.name, "\(role) \(binding)")
                XCTAssertFalse(ModelResolver.isCloud(resolved.name ?? "", in: catalog), "\(role) \(binding)")
            }
            for binding in ["auto", "qwen2.5:14b"] {
                XCTAssertEqual(ModelResolver.resolve(binding: binding, role: role, catalog: [cloud, remoteByListing],
                                                     cloudAllowed: true), .none, "\(role) \(binding)")
            }
        }
    }

    /// Search never runs one, consent or not: there is no Search opt-in to give.
    func testSearchIgnoresConsent() {
        let catalog = ollama + [cloud]
        XCTAssertEqual(resolve(cloud.name, .search, catalog, cloudAllowed: true), .none)
        XCTAssertEqual(resolve(cloud.name, .search, nil, cloudAllowed: true), .none)
        XCTAssertNil(ModelResolver.cloudWarning(for: .search))
    }

    /// No catalog says whether a named pick is local, and a cloud model's name need not say so. So
    /// it runs only where a cloud model would be allowed; Auto has nothing to choose from.
    func testWithoutACatalogANamedPickRunsOnlyWithConsent() {
        for role in [ModelRole.ask, .enrich, .vision] {
            XCTAssertEqual(resolve("qwen2.5:14b", role, nil), .none)
            XCTAssertEqual(resolve(cloud.name, role, nil), .none)
            XCTAssertEqual(resolve("qwen2.5:14b", role, nil, cloudAllowed: true),
                           .model("qwen2.5:14b", .asSaved))
            XCTAssertEqual(resolve("auto", role, nil), .none)
        }
        // Search's pick runs in the engine, which reads its own Ollama's listing.
        XCTAssertEqual(resolve("qwen2.5:14b", .search, nil), .model("qwen2.5:14b", .asSaved))
    }

    func testEachOptInSaysWhatIsSentAndToWhom() {
        for (role, what) in [(ModelRole.ask, "questions"), (.enrich, "transcript of every call"), (.vision, "20 screenshots per call")] {
            let warning = ModelResolver.cloudWarning(for: role) ?? ""
            XCTAssertTrue(warning.contains(what), warning)
            XCTAssertTrue(warning.contains("off this Mac") && warning.contains("Ollama"), warning)
        }
    }

    /// A "yes" covers the model it was given for, on the server it was given on. Picking another
    /// cloud model, or pointing Settings at another server, starts unallowed.
    func testConsentCoversOneModelOnOneServer() {
        let here = URL(string: "http://localhost:11434/v1")!
        let consent = CloudConsent(url: here.absoluteString, model: "glm-4.6:cloud")
        XCTAssertTrue(consent.covers(url: here, binding: "glm-4.6:cloud"))
        XCTAssertTrue(CloudConsent(url: here.absoluteString, model: "big").covers(url: here, binding: "big:latest"))
        XCTAssertFalse(consent.covers(url: here, binding: "gpt-oss:120b-cloud"))
        XCTAssertFalse(consent.covers(url: URL(string: "http://192.168.1.20:11434/v1")!, binding: "glm-4.6:cloud"))
        XCTAssertFalse(consent.covers(url: nil, binding: "glm-4.6:cloud"))
        XCTAssertFalse(CloudConsent(url: here.absoluteString, model: "auto").covers(url: here, binding: "auto"))
        XCTAssertFalse(CloudConsent(url: here.absoluteString, model: "").covers(url: here, binding: ""))
    }

    /// `/api/tags` failing leaves names alone. A model the last catalog marked cloud keeps the
    /// mark; a model it described as local does NOT keep that description, since its details are
    /// missing now: the pick waits for consent or the next full read.
    func testACatalogThatCouldNotDescribeAModelKeepsOnlyItsCloudMark() {
        let named = [ServerModel(name: "big:latest"), ServerModel(name: "qwen3.5:4b-mlx")]
        let carried = ModelResolver.carryingCloudMarks(named, from: ollama + [remoteByListing])
        XCTAssertEqual(carried.map(\.isRemote), [true, false])
        XCTAssertTrue(ModelResolver.isCloud("big", in: carried))
        XCTAssertTrue(ModelResolver.isUnconfirmed("qwen3.5:4b-mlx", in: carried))
        XCTAssertEqual(resolve("qwen3.5:4b-mlx", .enrich, carried), .none)
        XCTAssertEqual(resolve("big", .ask, carried), .none)
        // A model the fresh catalog does describe is taken as it says.
        let described = [ServerModel(name: "big:latest", capabilities: chat, sizeBytes: gb)]
        XCTAssertEqual(ModelResolver.carryingCloudMarks(described, from: [remoteByListing]), described)
        XCTAssertEqual(ModelResolver.carryingCloudMarks(named, from: nil), named)
    }

    /// A described entry whose NAME says cloud, with no `remote_host`: still never confirmed local.
    func testADescribedModelNamedCloudIsNeverConfirmedLocal() {
        let named = ServerModel(name: "glm-4.6:cloud", capabilities: chat, sizeBytes: 1)
        let catalog = ollama + [named]
        XCTAssertFalse(ModelResolver.isConfirmedLocal(named))
        XCTAssertEqual(resolve("glm-4.6:cloud", .ask, catalog), .model("qwen3.5:9b-mlx", .substituted(for: "glm-4.6:cloud")))
        XCTAssertEqual(resolve("auto", .enrich, [named]), .none)
    }

    /// FAIL CLOSED. A model the server only names is not confirmed local, whatever its name: on
    /// Ollama a cloud model's name need not say so (`ollama cp x:cloud big`), and a first catalog
    /// read without `/api/tags` has nothing to carry. It runs only with consent, and Auto and the
    /// stand-in never pick it.
    func testAModelTheServerOnlyNamesRunsOnlyWithConsent() {
        let namesOnly = ["big:latest", "llama3:8b"].map { ServerModel(name: $0) }
        for role in [ModelRole.ask, .enrich, .vision] {
            XCTAssertEqual(resolve("big", role, namesOnly), .none)
            XCTAssertEqual(resolve("big", role, namesOnly, cloudAllowed: true), .model("big:latest", .asSaved))
            XCTAssertEqual(resolve("auto", role, namesOnly, cloudAllowed: true), .none)
            // With a confirmed-local model beside it, that one stands in, never the unconfirmed one.
            XCTAssertEqual(resolve("big", role, namesOnly + ollama),
                           .model(role == .ask ? "qwen3.5:9b-mlx" : "qwen3.5:4b-mlx", .substituted(for: "big")))
        }
        XCTAssertTrue(ModelResolver.isUnconfirmed("big", in: namesOnly))
        XCTAssertFalse(ModelResolver.isUnconfirmed("qwen3.5:4b-mlx", in: ollama))
        XCTAssertFalse(ModelResolver.isUnconfirmed("glm-4.6:cloud", in: [ServerModel(name: "glm-4.6:cloud")]))
        XCTAssertNotNil(ModelResolver.unconfirmedWarning(for: .ask))
        XCTAssertNil(ModelResolver.unconfirmedWarning(for: .search))
        // Search's pick runs in the engine, which reads its own Ollama's listing.
        XCTAssertEqual(resolve("llama3:8b", .search, namesOnly), .model("llama3:8b", .asSaved))
    }

    func testTheWordShownWithAnAnswer() {
        XCTAssertEqual(ModelResolver.localityWord("qwen3.5:4b-mlx", in: ollama), "local")
        XCTAssertEqual(ModelResolver.localityWord("big", in: [remoteByListing]), "cloud")
        XCTAssertEqual(ModelResolver.localityWord("glm-4.6:cloud", in: nil), "cloud")
        XCTAssertEqual(ModelResolver.localityWord("llama3:8b", in: [ServerModel(name: "llama3:8b")]), "not confirmed local")
        XCTAssertEqual(ModelResolver.localityWord("llama3:8b", in: nil), "not confirmed local")
    }

    func testIsCloudReadsTheCatalogThenTheName() {
        XCTAssertTrue(ModelResolver.isCloud("big", in: [remoteByListing]))
        XCTAssertFalse(ModelResolver.isCloud("big", in: nil))
        XCTAssertTrue(ModelResolver.isCloud("glm-4.6:cloud", in: nil))
        XCTAssertFalse(ModelResolver.isCloud("qwen3.5:4b-mlx", in: ollama))
    }

    /// When `/api/tags` can't be read nothing marks a model remote, so the name has to.
    func testCloudNamesAreRecognisedWithoutTheServersWord() {
        let names = ["gpt-oss:120b-cloud", "glm-4.6:cloud", "llama3:8b"].map { ServerModel(name: $0) }
        XCTAssertTrue(ModelResolver.isCloud("gpt-oss:120b-cloud", in: names))
        XCTAssertTrue(ModelResolver.isCloud("glm-4.6:cloud", in: names))
        XCTAssertFalse(ModelResolver.isCloud("llama3:8b", in: names))
        // None is described, so none is confirmed local: Auto picks nothing.
        XCTAssertEqual(resolve("auto", .ask, names), .none)
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

    /// A non-Ollama server: names only, so nothing is confirmed local. Auto picks nothing, and a
    /// model the user picks runs once they allow it. The picker still hides embedders and rerankers
    /// by name, and still lists any other model, vision included.
    func testServerThatWontDescribeItsModels() {
        let names = ["bge-m3", "nomic-embed-text", "jina-reranker-v2", "llama3:8b"].map { ServerModel(name: $0) }
        XCTAssertEqual(resolve("auto", .ask, names), .none)
        XCTAssertEqual(resolve("auto", .vision, names), .none)
        XCTAssertEqual(resolve("llama3:8b", .ask, names), .none)
        XCTAssertEqual(resolve("llama3:8b", .ask, names, cloudAllowed: true), .model("llama3:8b", .asSaved))
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

    /// The app keeps NO copy of the engine's Search rule. It used to pick "the smallest chat model"
    /// itself, against the Settings server's catalog, and draw that as the Auto row: a second answer
    /// to a question the engine answers, wrong whenever the two looked at different servers. The
    /// engine now reports its pick, and the label is drawn from that.
    func testTheAppDoesNotPickTheEnginesSearchModel() {
        XCTAssertNil(ModelResolver.best(for: .search, in: ollama))
        XCTAssertEqual(resolve("auto", .search, ollama), .none)
    }

    func testTheSearchAutoRowSaysWhatTheEngineReported() {
        XCTAssertEqual(ModelResolver.searchAutoLabel(.asked("auto", resolved: "qwen3.5:4b-mlx")),
                       "Auto (qwen3.5:4b-mlx)")
        // Not "pull a model": nothing to pick and an Ollama that is down look alike from here.
        XCTAssertEqual(ModelResolver.searchAutoLabel(.asked("auto", resolved: nil)),
                       "Auto (not running in the engine yet)")
        // An engine running a named pick, or Off, has not run Auto, so it cannot say what Auto picks.
        for report in [EngineSearchReport.asked("mistral:7b", resolved: "mistral:7b"), .off] {
            XCTAssertEqual(ModelResolver.searchAutoLabel(report),
                           "Auto (the engine picks once this is chosen)")
        }
        XCTAssertEqual(ModelResolver.searchAutoLabel(.unknown), "Auto (chosen by the engine)")
    }

    func testAStaleSearchPicksStandInIsTheEnginesAuto() {
        XCTAssertEqual(ModelResolver.searchStandIn(.asked("auto", resolved: "qwen3.5:4b-mlx")),
                       "the engine's Auto runs instead: qwen3.5:4b-mlx")
        for report in [EngineSearchReport.unknown, .off, .asked("auto", resolved: nil)] {
            XCTAssertEqual(ModelResolver.searchStandIn(report), "the engine's Auto runs instead")
        }
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
    /// in — which the picker's stale row says, from the engine's own report.
    func testAStaleSearchPickIsNotPassed() {
        XCTAssertNil(ModelResolver.searchArgument(binding: "qwen2.5:7b", catalog: ollama, servesEngine: true))
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
    /// saved one behaves like a stale pick: not passed, with the engine's Auto standing in.
    func testSearchNeverUsesACloudModel() {
        let cloud = ServerModel(name: "qwen3-vl:235b-cloud", capabilities: chat, sizeBytes: 400, isRemote: true)
        let proxied = ServerModel(name: "big:latest", capabilities: chat, sizeBytes: 9 * gb, isRemote: true)
        let catalog = ollama + [cloud, proxied]
        XCTAssertFalse(ModelResolver.offers(cloud, for: .search))
        XCTAssertFalse(ModelResolver.offers(proxied, for: .search))
        XCTAssertTrue(ModelResolver.offers(cloud, for: .ask), "an explicit cloud pick stays the user's for Ask")
        for binding in ["big:latest", "qwen3-vl:235b-cloud"] {
            XCTAssertNil(ModelResolver.searchArgument(binding: binding, catalog: catalog, servesEngine: true))
        }
        // No catalog to recognise it by: the tag still says cloud, in any case.
        XCTAssertNil(ModelResolver.searchArgument(binding: "glm-4.6:cloud", catalog: nil, servesEngine: true))
        XCTAssertNil(ModelResolver.searchArgument(binding: "gpt-oss:120b-CLOUD", catalog: nil, servesEngine: true))
        XCTAssertTrue(ModelResolver.isRemote(ServerModel(name: "glm-4.6:Cloud")))
    }
}
