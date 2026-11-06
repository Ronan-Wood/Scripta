import Foundation

/// The version of the shared socket's wire: the reply shapes `WirePayloads` decodes.
///
/// The engine's `substrate/substrate/wire.py` is the authority and says when to bump; this mirrors
/// it, and `WireParityTests` holds the two together. Each request states `Substrate-Wire`, and each
/// reply does too. The match is exact. A reply that states another version, or states one twice or
/// unreadably, is refused before its body is decoded. A reply that states none came from an engine
/// older than the header, which spoke version 1.
enum SubstrateWire {
    static let version = 1
    static let header = "Substrate-Wire"
    /// The JSON-RPC error code the engine answers a request in another version with.
    static let mismatchCode = -32010
    static let unstated = 1
    /// How much of an unreadable value is echoed. It came from the far end.
    static let shown = 32

    /// The version a `Substrate-Wire` value states: absent is `unstated`, and anything but one plain
    /// positive ASCII integer is nil. Only spaces and tabs around it are ignored (HTTP's optional
    /// whitespace), the same as the engine.
    static func declared(_ value: String?) -> Int? {
        guard let value else { return unstated }
        let text = value.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        // Nine digits at most, as the engine reads it.
        guard !text.isEmpty, text.count <= 9,
              text.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              let version = Int(text), version >= 1 else { return nil }
        return version
    }

    /// Why this client will not read a reply carrying these `Substrate-Wire` values, or nil.
    static func unread(_ values: [String]) -> String? {
        guard values.count <= 1 else {
            return "the engine stated \(header) \(values.count) times; one reply has one version"
        }
        guard let stated = declared(values.first) else {
            let value = values.first ?? ""
            let echo = value.count <= shown ? value : String(value.prefix(shown)) + "…"
            return "the engine stated \(header): \(echo), which is not a wire version"
        }
        guard stated == version else {
            return "the engine speaks substrate wire \(stated) and this app speaks \(version); "
                + "update whichever of the two is older"
        }
        return nil
    }
}
