import Foundation

/// Enforces "everything local": a model endpoint may only be loopback or a private LAN address.
/// Public hosts are refused outright with no override. Checked both when the URL is saved in
/// Settings and again on every request (belt and suspenders), and the URLSession delegate rejects
/// any redirect that would leave the host.
enum Locality {
    enum Kind: Equatable {
        case loopback   // 127.0.0.1 / ::1 / localhost — allowed silently
        case lan        // RFC1918 / IPv6-ULA / *.local — allowed behind one explicit confirmation
        case refused    // anything else — never allowed
    }

    static func classify(_ url: URL) -> Kind {
        guard let host = url.host?.lowercased() else { return .refused }
        return classify(host: host)
    }

    static func classify(host raw: String) -> Kind {
        // Strip IPv6 brackets if present.
        let host = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw

        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasPrefix("127.") {
            return .loopback
        }
        if host.hasSuffix(".local") { return .lan }

        // IPv4 private ranges.
        let octets = host.split(separator: ".").map { UInt8($0) }
        if octets.count == 4, octets.allSatisfy({ $0 != nil }) {
            let o = octets.map { $0! }
            if o[0] == 10 { return .lan }
            if o[0] == 172, (16...31).contains(o[1]) { return .lan }
            if o[0] == 192, o[1] == 168 { return .lan }
            if o[0] == 169, o[1] == 254 { return .lan }   // link-local
            return .refused   // any other literal IPv4 is public
        }

        // IPv6 unique-local (fc00::/7 → fc.. or fd..).
        if host.contains(":") {
            let head = host.prefix(2).lowercased()
            if head == "fc" || head == "fd" || host == "::1" { return .lan }
            return .refused
        }

        // A bare hostname that isn't *.local and isn't an IP literal — refuse (could resolve public).
        return .refused
    }

    /// A URL is usable for a request only if it's loopback or an already-confirmed LAN address.
    static func isAllowedForRequest(_ url: URL, lanConfirmed: Bool) -> Bool {
        switch classify(url) {
        case .loopback: return true
        case .lan: return lanConfirmed
        case .refused: return false
        }
    }
}
