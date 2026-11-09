import Foundation

/// What an engine root states about itself: `engine-manifest.json`, written by the engine's
/// `tools/build-bundled-engine` and `tools/substrate-deploy` (`tools/engine-manifest.py` says what
/// each field means).
///
/// The app used to decide what an engine could do by looking for the engine's source files:
/// `substrate/refresh.py` meant `substrate serve` refreshes. That tied the app to the engine's
/// layout, which the engine should be free to change once the two ship apart. A root with a
/// manifest is asked through it.
///
/// A root without one is checked for those files as before (`Feature.implementedBy`). A release
/// build never needs that: it runs only the engine bundled with it, which the same build stated.
/// The fallback is for the DEBUG pinned deployment, which `substrate-deploy` can roll back to a
/// commit from before the manifest. It can go when such rollbacks no longer need to run.
///
/// ONLY `features` IS READ. The engine also states its version, commit and wire, and nothing here
/// decides on them, so a change to their shape must not make the app stop reading the features.
public struct EngineManifest: Decodable, Equatable, Sendable {
    public enum Feature: String, CaseIterable, Sendable {
        /// `substrate-mcp --socket PATH` answers on the socket.
        case serve
        /// `substrate serve --socket PATH` answers on it and keeps every scope current.
        case refresh
        /// `substrate-mcp --connect PATH` bridges stdio to that socket.
        case connectUnix = "connect-unix"

        /// The engine files that implemented this before engines stated it: the fallback for a
        /// root with no manifest. `bridge.py` alone is the TCP-only bridge, which exits 2 on a
        /// socket path, so connecting needs `local_socket.py` too.
        var implementedBy: [String] {
            switch self {
            case .serve: ["substrate/mcp/server.py"]
            case .refresh: ["substrate/refresh.py"]
            case .connectUnix: ["substrate/mcp/bridge.py", "substrate/local_socket.py"]
            }
        }
    }

    public static let fileName = "engine-manifest.json"

    /// By name, so a feature this app does not know is ignored rather than a failure to decode.
    public let features: [String]

    public init(features: [String]) {
        self.features = features
    }

    public func offers(_ feature: Feature) -> Bool { features.contains(feature.rawValue) }

    /// The manifest at `root`. Nil when there is none, and when its `features` cannot be read: a
    /// statement this app cannot read is no statement, so the root is checked as before.
    public static func at(_ root: URL) -> EngineManifest? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(fileName)) else {
            return nil
        }
        return try? JSONDecoder().decode(EngineManifest.self, from: data)
    }

    /// Whether the engine at `root` offers `feature`: what its manifest states, or, without one,
    /// whether the files that implemented it are there.
    public static func offers(_ feature: Feature, at root: URL) -> Bool {
        if let manifest = at(root) { return manifest.offers(feature) }
        return feature.implementedBy.allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }
}
