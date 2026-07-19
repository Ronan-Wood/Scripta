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
        .executable(name: "scripta-eval", targets: ["scripta-eval"]),
    ],
    targets: [
        .target(name: "ScriptaShared"),
        .target(
            name: "ScriptaCore",
            dependencies: ["ScriptaShared"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "scripta-eval", dependencies: ["ScriptaCore", "ScriptaShared"]),
        .testTarget(name: "ScriptaCoreTests", dependencies: ["ScriptaCore", "ScriptaShared"]),
    ]
)
