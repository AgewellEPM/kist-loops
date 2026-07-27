import Foundation

// The SAFETY SPINE of the pentest tool: an allowlist of targets the operator has
// explicitly authorized to scan. The agent can NEVER add to it (the tool only READS this
// file; the human edits it out-of-band), and it is FAIL-CLOSED — a missing, empty, or
// unreadable list authorizes NOTHING. Combined with approval-gating + audit logging, this
// is what keeps an autonomous agent from scanning a third party.
//
// File format (default ~/.kist/authorized-targets.conf), one entry per line, `#` comments:
//   example.com            exact host
//   10.0.0.5               exact IPv4
//   10.0.0.0/24            IPv4 CIDR range
//   *.tinky.com            domain + all subdomains
public struct AuthorizedTargets: Sendable {
    public let hosts: Set<String>          // exact hostnames + literal IPs
    public let domains: [String]           // suffix-match domains (from `*.domain`)
    public let cidrs: [CIDRv4]

    public init(hosts: Set<String>, domains: [String], cidrs: [CIDRv4]) {
        self.hosts = hosts; self.domains = domains; self.cidrs = cidrs
    }

    public var isEmpty: Bool { hosts.isEmpty && domains.isEmpty && cidrs.isEmpty }

    public static func defaultPath() -> String {
        if let override = ProcessInfo.processInfo.environment["KIST_AUTHORIZED_TARGETS"], !override.isEmpty {
            return override
        }
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? (NSHomeDirectory() + "/.kist")
        return base + "/authorized-targets.conf"
    }

    /// Load and parse. Returns nil if the file is missing/unreadable — the caller MUST treat
    /// nil (and an empty list) as "authorize nothing" (fail closed).
    public static func load(path: String = defaultPath()) -> AuthorizedTargets? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> AuthorizedTargets {
        var hosts = Set<String>(); var domains: [String] = []; var cidrs: [CIDRv4] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(rawLine)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            let entry = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard !entry.isEmpty else { continue }
            if entry.hasPrefix("*.") {
                // A wildcard MUST name a real multi-label domain. `*.` (empty) or `*.com`
                // (single label) are rejected — an empty/too-broad suffix would fail open
                // (e.g. `*.` → hasSuffix(".") matches every FQDN). (Codex HIGH.)
                let d = canonHost(String(entry.dropFirst(2)))
                if !d.isEmpty, d.contains(".") { domains.append(d) }
            } else if entry.contains("/"), let cidr = CIDRv4(entry) {
                cidrs.append(cidr)
            } else {
                hosts.insert(canonHost(entry))
            }
        }
        return AuthorizedTargets(hosts: hosts, domains: domains, cidrs: cidrs)
    }

    /// Extract the bare host from a user-supplied target (URL, host:port, host, IP, or CIDR).
    /// Returns nil if it can't be reduced to a clean host/CIDR token.
    public static func hostFor(_ target: String) -> String? {
        var t = target.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if let range = t.range(of: "://") { t = String(t[range.upperBound...]) }   // strip scheme
        if !isCIDR(t), let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) } // strip path (keep CIDR mask)
        if t.filter({ $0 == ":" }).count == 1 { t = String(t[..<t.firstIndex(of: ":")!]) } // strip :port
        if t.contains(":") { return nil }   // IPv6 or malformed → refuse (fail closed)
        return t.isEmpty ? nil : t
    }

    static func isCIDR(_ s: String) -> Bool { s.contains("/") && CIDRv4(s) != nil }

    /// Canonicalize a host: lowercase + strip trailing dots (FQDN root). Trailing-dot forms
    /// like `evil.com.` must not desync authorization from what gets scanned. (Codex HIGH.)
    static func canonHost(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespaces).lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    /// Authoritative decision: is `target` authorized? Default-DENY on anything unparseable.
    public func authorizes(_ target: String) -> Bool {
        guard !isEmpty else { return false }                       // empty list → nothing allowed
        let raw = target.trimmingCharacters(in: .whitespaces).lowercased()

        // CIDR target: must be fully contained in an authorized CIDR.
        if Self.isCIDR(raw), let t = CIDRv4(raw) {
            return cidrs.contains { $0.contains(range: t) }
        }
        guard let rawHost = Self.hostFor(target) else { return false }
        let host = Self.canonHost(rawHost)   // strip trailing dot so `evil.com.` can't desync
        guard !host.isEmpty else { return false }

        // Literal IPv4 target: exact host OR inside an authorized CIDR.
        if let ip = CIDRv4.parseIPv4(host) {
            if hosts.contains(host) { return true }
            return cidrs.contains { $0.contains(ip: ip) }
        }
        // Hostname target: exact OR a subdomain of an authorized domain.
        if hosts.contains(host) { return true }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Minimal IPv4 CIDR (parse + membership). IPv6 is intentionally unsupported → such targets
/// are refused (fail closed), which is safer than a half-correct implementation.
public struct CIDRv4: Sendable, Equatable {
    public let network: UInt32
    public let prefix: Int          // 0...32
    public var mask: UInt32 { prefix == 0 ? 0 : ~UInt32(0) << (32 - prefix) }

    public init?(_ text: String) {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let ip = CIDRv4.parseIPv4(String(parts[0])),
              let p = Int(parts[1]), (0...32).contains(p) else { return nil }
        self.prefix = p
        self.network = ip & (p == 0 ? 0 : ~UInt32(0) << (32 - p))
    }

    public func contains(ip: UInt32) -> Bool { (ip & mask) == network }

    /// True if `range` is a subset of self (a /24 inside a /16, etc.).
    public func contains(range other: CIDRv4) -> Bool {
        other.prefix >= prefix && (other.network & mask) == network
    }

    public static func parseIPv4(_ s: String) -> UInt32? {
        let octets = s.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for o in octets {
            guard let n = UInt32(o), n <= 255 else { return nil }
            value = (value << 8) | n
        }
        return value
    }
}
