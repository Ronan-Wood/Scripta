// swift-tools-version: 5.9
// The dependency-free core: parsing, indexing, retrieval, retention. Consumed by the app, the
// scripta-mcp helper (ScriptaShared only — it deploys to macOS 14), the test suite, and the eval
// harness. Tools-version 5.9 keeps targets in Swift 5 language mode until the strict-concurrency
// migration phase bumps it deliberately.
import PackageDescription

let package = Package(
    name: "ScriptaCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScriptaShared", targets: ["ScriptaShared"]),
        .library(name: "ScriptaCore", targets: ["ScriptaCore"]),
        .library(name: "SubstrateKit", targets: ["SubstrateKit"]),
        .executable(name: "scripta-eval", targets: ["scripta-eval"]),
    ],
    targets: [
        .target(name: "ScriptaShared"),
        // The substrate engine's wire vocabulary, and nothing else. Foundation only and no
        // dependency on the other two targets: it is the layer both the app's answer surfaces and a
        // future transport decode into, so anything it imported would become something they inherit.
        // Doc 3 §6 (an in-app query and the equivalent CLI query must agree) is only checkable while
        // this target holds no retrieval logic — see Sources/SubstrateKit/Passage.swift.
        .target(name: "SubstrateKit"),
        .target(
            name: "ScriptaCore",
            dependencies: ["ScriptaShared"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "scripta-eval", dependencies: ["ScriptaCore", "ScriptaShared"]),
        .testTarget(name: "ScriptaCoreTests", dependencies: ["ScriptaCore", "ScriptaShared"]),
        // Its OWN test target, not a dependency added to ScriptaCoreTests. SubstrateKit imports
        // nothing but Foundation on purpose, and a suite that could reach ScriptaCore would be the
        // first place that boundary quietly stopped holding.
        //
        // `Fixtures` is excluded rather than declared as a resource: they are captured engine
        // responses read from `#filePath` (see GoldenFixtures.swift), for the same reason
        // ThemeTokenSource reads Ink.swift from source — `swift test` and Xcode disagree about the
        // working directory, and a gate that silently finds no file is worse than one that cannot
        // run.
        .testTarget(name: "SubstrateKitTests", dependencies: ["SubstrateKit"],
                    exclude: ["Fixtures"]),
    ]
)
