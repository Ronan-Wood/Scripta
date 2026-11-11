import Foundation

/// Which MCP clients may write notes through the engine, as `substrate grants --json` reports it.
///
/// The engine owns the grants (`substrate.grants`): this app lists them and changes them only
/// through the engine's CLI (`grant`, `revoke`), the boundary it already keeps for `refresh`. A
/// client that tried to write without a grant is listed under `requested`, which is what the
/// Settings pane offers to allow.
public struct EngineGrants: Decodable, Equatable, Sendable {
    public struct Granted: Decodable, Equatable, Sendable, Identifiable {
        public let client: String
        public let generation: Int
        public let scopes: [String]
        public let issuedAt: String
        public var id: String { client }

        enum CodingKeys: String, CodingKey {
            case client, generation, scopes
            case issuedAt = "issued_at"
        }
    }

    public struct Requested: Decodable, Equatable, Sendable, Identifiable {
        public struct Info: Decodable, Equatable, Sendable {
            public let name: String?
            public let version: String?
        }

        public let client: String
        public let clientInfo: Info?
        public let at: String
        public var id: String { client }

        enum CodingKeys: String, CodingKey {
            case client, at
            case clientInfo = "client_info"
        }
    }

    public let granted: [Granted]
    public let requested: [Requested]

    public init(granted: [Granted] = [], requested: [Requested] = []) {
        self.granted = granted
        self.requested = requested
    }

    /// The listing in `stdout`, or nil when it is not one: an engine too old for `grants`, or a
    /// failed run. Nil is "unknown", never "nobody is granted".
    public static func parse(_ stdout: String) -> EngineGrants? {
        try? JSONDecoder().decode(EngineGrants.self, from: Data(stdout.utf8))
    }

    /// Whether `name` is one the engine takes as a client name (`grants.CLIENT_NAME`): lowercase
    /// letters, digits, `.`, `_` and `-`, starting with a letter or digit, at most 64. Checked here so
    /// the field says so before the CLI is run, not instead of the CLI's own refusal.
    public static func isClientName(_ name: String) -> Bool {
        name.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil
    }
}
