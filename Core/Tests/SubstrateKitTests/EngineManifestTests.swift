import XCTest
@testable import SubstrateKit

/// What the app decides from an engine root: its `engine-manifest.json` when it has one, and the
/// files that used to say the same thing when it does not.
final class EngineManifestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func state(_ json: String) throws {
        try Data(json.utf8).write(to: root.appendingPathComponent(EngineManifest.fileName))
    }

    private func state(features: [String]) throws {
        let list = features.map { "\"\($0)\"" }.joined(separator: ", ")
        try state(#"{"version": "0.1.0", "commit": null, "wire": 1, "features": [\#(list)]}"#)
    }

    /// The files an engine from before the manifest had, so a test can show the manifest overrides
    /// them.
    private func place(_ paths: String...) throws {
        for path in paths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: file)
        }
    }

    // MARK: - Decoding

    /// The shape `tools/engine-manifest.py` writes, as it writes it. Only `features` is read.
    func testTheEngineWritersShapeDecodes() throws {
        try state("""
        {
          "version": "0.1.0",
          "commit": "44441391c99ee2a5b7a3572bc332e3a5a03a0666",
          "wire": 1,
          "features": [
            "serve",
            "refresh",
            "connect-unix"
          ]
        }
        """)
        XCTAssertEqual(EngineManifest.at(root),
                       EngineManifest(features: ["serve", "refresh", "connect-unix"]))
    }

    /// Nothing decides on the other fields, so a later engine reshaping them, or dropping them,
    /// must not make the app stop reading the features and fall back to the files.
    func testTheFieldsNothingReadsDoNotDecideWhetherItDecodes() throws {
        for body in [#"{"features": ["refresh"]}"#,
                     #"{"version": null, "commit": 7, "wire": {"speaks": [1, 2]}, "#
                     + #""features": ["refresh"]}"#] {
            try state(body)
            XCTAssertEqual(EngineManifest.at(root), EngineManifest(features: ["refresh"]), body)
        }
    }

    /// A newer engine may name features this app has never heard of.
    func testAFeatureThisAppDoesNotKnowIsIgnored() throws {
        try state(features: ["serve", "teleport"])
        let manifest = try XCTUnwrap(EngineManifest.at(root))
        XCTAssertTrue(manifest.offers(.serve))
        XCTAssertFalse(manifest.offers(.refresh))
    }

    /// The names the app acts on are the ones the engine may state (`contract.json`
    /// `engine_manifest`), so a renamed feature cannot quietly turn into "not offered".
    func testTheFeaturesAndFileAreTheEnginesOwn() throws {
        let contract = try EngineContract.load().engineManifest
        XCTAssertEqual(Set(EngineManifest.Feature.allCases.map(\.rawValue)), contract.features)
        XCTAssertEqual(EngineManifest.fileName, contract.file)
    }

    func testAManifestThatDoesNotDecodeIsNoManifest() throws {
        for body in ["", "not json", "[]", #"{"version": "0.1.0", "wire": 1}"#,
                     #"{"features": "refresh"}"#, #"{"features": null}"#,
                     #"{"version": "0.1.0", "commit": null, "wire": 1, "features": [1]}"#] {
            try state(body)
            XCTAssertNil(EngineManifest.at(root), body)
        }
    }

    // MARK: - Feature gating

    func testAManifestIsAnsweredFromRatherThanTheFiles() throws {
        try state(features: ["serve", "refresh", "connect-unix"])
        for feature in EngineManifest.Feature.allCases {
            XCTAssertTrue(EngineManifest.offers(feature, at: root), feature.rawValue)
        }
    }

    /// THE REGRESSION. The engine's `refresh.py` is there, so the old check said "serves and
    /// refreshes"; the engine says it does not. This is the answer that
    /// `SubstrateEngine.servesAndRefreshes` returns for an engine root, and on false
    /// `engineCommand` spawns `substrate-mcp --socket` rather than `substrate serve`. That last
    /// step is app code, which has no test target; this pins the decision it acts on.
    func testAManifestWithoutRefreshIsNotRefreshingEvenWithRefreshPyPresent() throws {
        try place("substrate/refresh.py", "substrate/mcp/server.py", "substrate/mcp/bridge.py",
                  "substrate/local_socket.py")
        try state(features: ["serve", "connect-unix"])
        XCTAssertFalse(EngineManifest.offers(.refresh, at: root))
        XCTAssertTrue(EngineManifest.offers(.serve, at: root))
        XCTAssertTrue(EngineManifest.offers(.connectUnix, at: root))
    }

    func testAManifestThatOmitsAFeatureWithdrawsIt() throws {
        try place("substrate/mcp/server.py", "substrate/mcp/bridge.py", "substrate/local_socket.py")
        try state(features: ["refresh"])
        XCTAssertFalse(EngineManifest.offers(.serve, at: root))
        XCTAssertFalse(EngineManifest.offers(.connectUnix, at: root))
        XCTAssertTrue(EngineManifest.offers(.refresh, at: root))
    }

    // MARK: - Without a manifest: the files, as before

    func testWithoutAManifestTheFilesAnswer() throws {
        for feature in EngineManifest.Feature.allCases {
            XCTAssertFalse(EngineManifest.offers(feature, at: root), feature.rawValue)
        }
        try place("substrate/refresh.py", "substrate/mcp/server.py", "substrate/mcp/bridge.py",
                  "substrate/local_socket.py")
        for feature in EngineManifest.Feature.allCases {
            XCTAssertTrue(EngineManifest.offers(feature, at: root), feature.rawValue)
        }
    }

    /// `bridge.py` alone is the TCP-only bridge, which exits 2 on a socket path.
    func testWithoutAManifestConnectingNeedsTheSocketModuleToo() throws {
        try place("substrate/mcp/bridge.py")
        XCTAssertFalse(EngineManifest.offers(.connectUnix, at: root))
    }

    func testAManifestThatDoesNotDecodeFallsBackToTheFiles() throws {
        try place("substrate/refresh.py")
        try state("{")
        XCTAssertTrue(EngineManifest.offers(.refresh, at: root))
        XCTAssertFalse(EngineManifest.offers(.serve, at: root))
    }
}
