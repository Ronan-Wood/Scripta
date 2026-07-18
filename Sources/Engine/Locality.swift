import Foundation

/// Enforces "everything local": a model endpoint may only be loopback or a private LAN address.
/// Public hosts are refused outright with no override. Checked both when the URL is saved in
/// Settings and again on every request (belt and suspenders), and the URLSession delegate rejects
/// any redirect that would leave the host.
///
/// Two layers, because a hostname is not its address:
///   1. `classify` — a *string* classifier. IP literals are classified by range; the only names
///      allowed are `localhost` and `*.local` (mDNS). Any other bare hostname is refused, because
///      it could resolve to a public address. Crucially, IP-literal detection is a STRICT dotted-quad
///      parse — a multi-label DNS name like `127.0.0.1.attacker.com` is NOT an IP and is refused.
///   2. `resolvedIsLocal` — a *resolution* check for the allowed names. Before any bytes leave the
///      box, the name is resolved and EVERY resolved address must itself be loopback/private, so a
///      name pointed at a public IP (a static `/etc/hosts` entry, a misconfiguration, or a naive
///      always-public spoof) is refused. Residual gap: URLSession re-resolves independently at
///      connect time, so an on-path attacker who rebinds a *name* between this check and the connect
///      is not fully closed here — IP-literal configs (no re-resolution) and https names (TLS binds
///      the name) are unaffected; pinning the vetted IP would close it for http names (follow-up).
enum Locality {
    enum Kind: Equatable {
        case loopback   // 127.0.0.0/8 / ::1 / localhost — allowed silently
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

        if host == "localhost" { return .loopback }

        // IPv4 literal — classify by range, NEVER by string prefix (a prefix test would misread
        // "127.evil.com" / "127.0.0.1.attacker.com" as loopback).
        if let o = ipv4Octets(host) {
            if o[0] == 127 { return .loopback }               // 127.0.0.0/8
            if o[0] == 10 { return .lan }                     // 10.0.0.0/8
            if o[0] == 172, (16...31).contains(o[1]) { return .lan }  // 172.16.0.0/12
            if o[0] == 192, o[1] == 168 { return .lan }       // 192.168.0.0/16
            if o[0] == 169, o[1] == 254 { return .lan }       // 169.254.0.0/16 link-local
            return .refused                                   // any other IPv4 literal is public
        }

        // IPv6 literal.
        if host.contains(":") {
            if host == "::1" { return .loopback }
            let head = host.prefix(2).lowercased()
            if head == "fc" || head == "fd" { return .lan }   // fc00::/7 unique-local
            // fe80::/10 link-local — the address a *.local name commonly resolves to on a dual-stack
            // LAN (mirrors the IPv4 169.254 case). Second byte 0x80–0xbf ⇒ 3rd hex nibble 8/9/a/b.
            if ["fe8", "fe9", "fea", "feb"].contains(host.prefix(3).lowercased()) { return .lan }
            return .refused
        }

        if host.hasSuffix(".local") { return .lan }           // mDNS — resolved-address checked at request time

        // A bare hostname that isn't *.local and isn't an IP literal — refuse (could resolve public).
        return .refused
    }

    /// Parses a strict dotted-quad IPv4 literal: exactly four decimal octets, each 1–3 ASCII digits
    /// in 0...255. Returns nil for anything else — in particular a multi-label DNS name whose first
    /// label happens to be numeric ("127.0.0.1.attacker.com") is NOT an IP literal.
    static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out = [Int]()
        out.reserveCapacity(4)
        for p in parts {
            guard (1...3).contains(p.count), p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let v = Int(p), (0...255).contains(v) else { return nil }
            out.append(v)
        }
        return out
    }

    /// A URL is usable for a request only if it's loopback or an already-confirmed LAN address.
    /// This is the cheap string gate; the request path additionally calls `resolvedIsLocal`.
    static func isAllowedForRequest(_ url: URL, lanConfirmed: Bool) -> Bool {
        switch classify(url) {
        case .loopback: return true
        case .lan: return lanConfirmed
        case .refused: return false
        }
    }

    /// Resolves `host` and returns true only if EVERY resolved address is itself loopback/private.
    /// IP-literal hosts short-circuit true (classification is already authoritative and no DNS
    /// occurs). Called on the request path so a name that resolves to a public IP — via mDNS/DNS
    /// spoofing on a hostile LAN, DNS rebinding, or an `/etc/hosts` entry — is refused before any
    /// data leaves the machine. Fails closed on resolution failure or an empty result.
    static func resolvedIsLocal(host raw: String) -> Bool {
        let host = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw
        if host.isEmpty { return false }
        // IP literal → no resolution needed, but stay self-authoritative: a public literal must
        // still be refused here even if a caller invokes this without the string gate first.
        if ipv4Octets(host) != nil || host.contains(":") { return classify(host: host) != .refused }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return false }
        defer { freeaddrinfo(res) }

        var sawAddress = false
        var cursor = res
        while let node = cursor {
            if let sa = node.pointee.ai_addr {
                sawAddress = true
                if !addressIsLocal(sa, len: node.pointee.ai_addrlen) { return false }
            }
            cursor = node.pointee.ai_next
        }
        return sawAddress
    }

    /// Formats a sockaddr to its numeric IP string and runs it back through `classify`.
    private static func addressIsLocal(_ sa: UnsafeMutablePointer<sockaddr>, len: socklen_t) -> Bool {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { return false }
        var ip = String(cString: buf).lowercased()
        if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }    // drop IPv6 zone id (fe80::1%en0)
        if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst(7)) }        // unwrap IPv4-mapped IPv6
        switch classify(host: ip) {
        case .loopback, .lan: return true
        case .refused: return false
        }
    }
}
