import Foundation

/// Whether a host app may use an engine it did not start, decided from what the engine says about
/// itself (`list_scopes` → `server`).
///
/// An engine already answering on the shared socket used to be reported and never used: adopting
/// it meant the app's lifetime and the engine's had come apart. With `substrate serve` able to run
/// on its own, that engine is often exactly the one the app would have started, so it is used, but
/// only when it is that kind of engine. The wire version is checked before this ever runs (a reply
/// in another version is refused by `SubstrateClient`), and the socket's owner is checked before a
/// byte is sent (`UnixSocketHTTP`).
public enum EngineAttach {
    public enum Verdict: Equatable, Sendable {
        case attach
        /// Not this one, and why, in a sentence the reader can act on.
        case refuse(String)
    }

    /// What this app's own build is, for the checks an attached engine must pass: the registry its
    /// CLI resolves and the index schema it writes. An attached engine's indexes are written by
    /// THIS app's CLI (the Library, recordings, "Refresh now"), so a different registry or schema
    /// would have the two maintaining different things, or rebuilding each other's indexes.
    public struct Expectation: Equatable, Sendable {
        /// Nil when this app's CLI could not say which registry it writes.
        public let registry: String?
        /// Nil when this app's CLI could not say which schema it writes (one from before
        /// `substrate version`).
        public let schema: Int?

        public init(registry: String?, schema: Int?) {
            self.registry = registry
            self.schema = schema
        }
    }

    public static func verdict(_ list: WireScopeList, engineSchema: Int?,
                               expecting expected: Expectation) -> Verdict {
        guard let server = list.server else {
            return .refuse("it is older than the report that says what kind of server it is, so "
                           + "there is no way to tell whether it is read-only")
        }
        if server.agentMode {
            return .refuse("it is an agent-mode server, which answers from published snapshots "
                           + "for a narrower account, not from this user's vaults")
        }
        if !server.readOnly {
            return .refuse("it accepts writes over the socket, which any process of this user "
                           + "can reach, and the engine this app runs never does")
        }
        // The app schedules no refresh of its own any more, so attaching to an engine that has no
        // loop would leave every index ageing with nothing running to refresh it.
        if server.refreshEvery == nil {
            return .refuse("it refreshes nothing on its own (it is not `substrate serve`), and "
                           + "Scripta no longer refreshes indexes itself")
        }
        guard let mine = expected.schema, let myRegistry = expected.registry else {
            return .refuse("this app's own substrate command did not report the registry and "
                           + "index schema it writes (it may predate `substrate version`), so there "
                           + "is nothing to hold the engine to")
        }
        let theirs = list.registry.map { Self.canonical($0) }
        guard theirs == Self.canonical(myRegistry) else {
            return .refuse("it serves the registry \(list.registry ?? "(none)"), and this app writes "
                           + "\(myRegistry), so the calls it records would never reach it")
        }
        guard let engineSchema else {
            return .refuse("it did not report its index schema, and this app would be writing its "
                           + "indexes")
        }
        guard engineSchema == mine else {
            return .refuse("it reads index schema v\(engineSchema) and this app writes v\(mine), so "
                           + "each would rebuild the other's indexes")
        }
        return .attach
    }

    /// Whether the engine passes every check that needs nothing from this app's CLI or a schema
    /// probe: what kind of server it is. For a host deciding whether a refusal was only a missing
    /// answer, worth asking again, or a verdict on the engine itself.
    public static func qualifiesByRoster(_ list: WireScopeList) -> Bool {
        guard let registry = list.registry else { return false }
        return verdict(list, engineSchema: 0,
                       expecting: Expectation(registry: registry, schema: 0)) == .attach
    }

    /// A path compared as a file, not as a string: `~`, `..` and symlinks resolved.
    static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }
}
