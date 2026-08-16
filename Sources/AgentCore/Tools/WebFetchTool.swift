import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Fetch the text of an HTTP(S) URL (HTML crudely stripped to text). Read-only web access for
/// the agent — bounded in size and HARDENED against SSRF: the host is resolved and any
/// every non-global/special-purpose address is refused. Redirects are followed only by the
/// pinned public-web transport, one revalidated hop at a time.
public struct WebFetchTool: AgentTool {
    typealias Fetcher = @Sendable (_ url: URL, _ maxBytes: Int) async throws -> PublicWebHTTPResponse

    public let name = "fetch_url"
    public let description = "Fetch the text content of an http(s) URL (HTML stripped to readable text). " +
        "Use to read documentation or web pages. Private/loopback addresses are refused."
    public let parameters = [
        ToolParameter(name: "url", type: "string", description: "The http(s) URL to fetch.", required: true),
        ToolParameter(name: "allowed_hosts", type: "array", description: "Optional per-call host allowlist that can only narrow the tool's configured allowlist.", required: false),
        ToolParameter(name: "max_bytes", type: "integer", description: "Optional bounded prefix size, 4096...256000 bytes.", required: false),
    ]
    public static let maxBytes = 256_000
    public static let minimumRequestedBytes = 4_096
    /// Some documentation servers ignore Range. Permit one still-bounded response large enough to
    /// recover common single-page manuals, then persist only the caller's requested UTF-8 prefix.
    static let rangeFallbackTransportBytes = 2 * 1_024 * 1_024
    private let allowedHosts: Set<String>
    private let configuredAllowlistIsValid: Bool
    private let fetcher: Fetcher?

    public init(allowedHosts: [String] = []) {
        let policy = Self.normalizedHostPatterns(allowedHosts)
        self.allowedHosts = policy.patterns
        self.configuredAllowlistIsValid = policy.isValid
        self.fetcher = nil
    }

    init(allowedHosts: [String] = [], fetcher: @escaping Fetcher) {
        let policy = Self.normalizedHostPatterns(allowedHosts)
        self.allowedHosts = policy.patterns
        self.configuredAllowlistIsValid = policy.isValid
        self.fetcher = fetcher
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let urlStr = try requireString("url", from: arguments)
        guard configuredAllowlistIsValid else {
            return .failure("refused (host allowlist): configured fetch host allowlist contains an invalid pattern")
        }
        guard urlStr.utf8.count <= PublicWebTransport.maxURLBytes else {
            return .failure("refused: URL exceeds the public-web byte limit")
        }
        guard let url = URL(string: urlStr), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host,
              url.user == nil, url.password == nil else {
            return .failure("provide an http(s) URL")
        }
        var callAllowlist: Set<String> = []
        if let raw = arguments["allowed_hosts"] {
            guard let hosts = raw as? [String], !hosts.isEmpty else {
                return .failure("refused (host allowlist): allowed_hosts must be a non-empty string array when provided")
            }
            let normalized = hosts.compactMap(Self.normalizedHostPattern)
            guard normalized.count == hosts.count else {
                return .failure("refused (host allowlist): allowed_hosts contains an invalid host pattern")
            }
            callAllowlist = Set(normalized)
        }
        let requestMaxBytes: Int
        if let raw = arguments["max_bytes"] {
            guard let value = raw as? Int,
                  (Self.minimumRequestedBytes...Self.maxBytes).contains(value) else {
                return .failure("max_bytes must be an integer from \(Self.minimumRequestedBytes) through \(Self.maxBytes)")
            }
            requestMaxBytes = value
        } else {
            requestMaxBytes = Self.maxBytes
        }
        // Both configured and per-call policies are pure string checks and must run
        // before the transport performs DNS. An empty configured set still means
        // arbitrary PUBLIC hosts; a non-empty per-call set only narrows that policy.
        if let reason = Self.allowlistBlockReason(host: host, configured: allowedHosts, perCall: callAllowlist) {
            return .failure("refused (host allowlist): \(reason)")
        }
        let response: PublicWebHTTPResponse
        do {
            if let fetcher {
                response = try await fetcher(url, requestMaxBytes)
            } else {
                let transportMaxBytes = arguments["max_bytes"] == nil
                    ? requestMaxBytes : max(requestMaxBytes, Self.rangeFallbackTransportBytes)
                response = try await PublicWebTransport.fetch(
                    url: url,
                    maxBytes: transportMaxBytes,
                    headerLines: arguments["max_bytes"] == nil
                        ? [] : ["Range: bytes=0-\(requestMaxBytes - 1)"],
                    configuredAllowedHosts: allowedHosts,
                    perCallAllowedHosts: callAllowlist
                )
            }
        }
        catch { return .failure("fetch failed: \(error.localizedDescription)") }
        guard (200...299).contains(response.statusCode) else {
            return .failure("HTTP \(response.statusCode) from \(host)")
        }

        let text = response.body
        let readable = Self.htmlToText(text)
        let bounded = Self.boundedUTF8Prefix(readable, maxBytes: requestMaxBytes)
        let stripped = bounded.text
        let partial = response.statusCode == 206 || bounded.truncated
        return ToolResult(success: true, output: stripped.isEmpty ? "(empty)" : stripped,
                          metadata: [
                            "url": urlStr,
                            "status": String(response.statusCode),
                            "bytes": String(stripped.utf8.count),
                            "response_bytes": String(text.utf8.count),
                            "fetch_status": partial ? "partial" : "complete",
                            "truncated": String(bounded.truncated),
                          ])
    }

    static func boundedUTF8Prefix(_ text: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        let bytes = Data(text.utf8)
        guard bytes.count > maxBytes else { return (text, false) }
        var end = maxBytes
        while end > 0 {
            if let prefix = String(data: bytes.prefix(end), encoding: .utf8) {
                return (prefix, true)
            }
            end -= 1
        }
        return ("", true)
    }

    // MARK: - SSRF guard

    /// Host allowlist. Empty configured set means unrestricted public hosts; non-empty means the
    /// host must match it. A per-call list can only narrow the effective policy, never broaden it.
    static func allowlistBlockReason(host: String, configured: Set<String>, perCall: Set<String>) -> String? {
        let normalized = normalizeHost(host)
        if !configured.isEmpty && !hostMatches(normalized, patterns: configured) {
            return "\(host) is not in configured fetch host allowlist"
        }
        if !perCall.isEmpty && !hostMatches(normalized, patterns: perCall) {
            return "\(host) is not in per-call fetch host allowlist"
        }
        return nil
    }

    static func hostMatches(_ host: String, patterns: Set<String>) -> Bool {
        patterns.contains { pattern in
            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1))   // ".example.com"
                return host.hasSuffix(suffix) && host.count > suffix.count
            }
            return host == pattern
        }
    }

    static func normalizedHostPattern(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, host.utf8.count <= 255,
              !host.utf8.contains(where: { $0 < 0x21 || $0 == 0x7f }),
              !host.contains("/"), !host.contains("\\"), !host.contains("@"),
              !host.contains("?"), !host.contains("#") else { return nil }
        if host.hasSuffix(".") {
            host.removeLast()
            guard !host.isEmpty, !host.hasSuffix(".") else { return nil }
        }
        let wildcard = host.hasPrefix("*.")
        if wildcard { host = String(host.dropFirst(2)) }
        guard !host.isEmpty, !host.contains("*") else { return nil }

        if let address = parsedIPAddress(host) {
            return wildcard ? nil : address.literal
        }
        guard !host.contains(":"),
              !host.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 }) else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-" else { return false }
            return label.utf8.allSatisfy {
                ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
            }
        }) else { return nil }
        return wildcard ? "*." + host : host
    }

    private static func normalizeHost(_ raw: String) -> String {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return parsedIPAddress(host)?.literal ?? host
    }

    static func normalizedHostPatterns(_ raw: [String]) -> (patterns: Set<String>, isValid: Bool) {
        guard !raw.isEmpty else { return ([], true) }
        var patterns = Set<String>()
        for entry in raw {
            guard let normalized = normalizedHostPattern(entry) else { return (patterns, false) }
            patterns.insert(normalized)
        }
        return (patterns, true)
    }

    /// Returns a block reason if `host` resolves to (or literally is) a non-public address.
    static func ssrfBlockReason(host: String) -> String? {
        publicAddressSet(host: host).reason
    }

    /// Resolves a host to a stable, comparable set of raw socket addresses. Resolution failures are blocked,
    /// not deferred to URLSession, because a second resolver result could otherwise turn a failed preflight
    /// into a private-address connection.
    static func publicAddressSet(host: String) -> (addresses: Set<Data>, reason: String?) {
        let resolution = PublicWebTransport.resolvePublicAddresses(host: host)
        let addresses = Set(resolution.addresses.compactMap { parsedIPAddress($0)?.data })
        return (addresses, resolution.reason)
    }

    static func publicAddressLiterals(
        host: String, timeoutSeconds: Int = PublicWebTransport.resolverTimeoutSeconds
    ) -> (addresses: [String], reason: String?) {
        PublicWebTransport.resolvePublicAddresses(host: host, timeoutSeconds: timeoutSeconds)
    }

    struct ParsedIPAddress: Sendable {
        let family: Int32
        let bytes: [UInt8]
        let literal: String
        var data: Data { Data([family == AF_INET ? 4 : 6] + bytes) }
    }

    static func parsedIPAddress(_ raw: String) -> ParsedIPAddress? {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard !candidate.isEmpty, !candidate.contains("%") else { return nil }

        var v4 = in_addr()
        if candidate.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return ParsedIPAddress(
                family: AF_INET,
                bytes: withUnsafeBytes(of: v4) { Array($0) },
                literal: numericLiteral(family: AF_INET, address: &v4, size: MemoryLayout<in_addr>.size)
                    ?? candidate
            )
        }
        var v6 = in6_addr()
        if candidate.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return ParsedIPAddress(
                family: AF_INET6,
                bytes: withUnsafeBytes(of: v6) { Array($0) },
                literal: numericLiteral(family: AF_INET6, address: &v6, size: MemoryLayout<in6_addr>.size)
                    ?? candidate
            )
        }
        return nil
    }

    private static func numericLiteral<T>(
        family: Int32, address: inout T, size: Int
    ) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let result = withUnsafePointer(to: &address) { pointer in
            buffer.withUnsafeMutableBufferPointer { output in
                inet_ntop(family, UnsafeRawPointer(pointer), output.baseAddress, socklen_t(output.count))
            }
        }
        guard result != nil, size > 0 else { return nil }
        return String(cString: buffer)
    }

    static func isGlobalUnicastAddress(_ address: ParsedIPAddress) -> Bool {
        if address.family == AF_INET {
            guard address.bytes.count == 4 else { return false }
            return !isNonPublicIPv4(
                address.bytes[0], address.bytes[1], address.bytes[2], address.bytes[3])
        }
        guard address.family == AF_INET6, address.bytes.count == 16 else { return false }
        let bytes = address.bytes
        // Positive policy: only the allocated IPv6 global-unicast block is admitted.
        guard bytes[0] & 0xe0 == 0x20 else { return false } // 2000::/3
        let special: [([UInt8], Int)] = [
            ([0x20, 0x01, 0x00], 23),                   // IETF protocol assignments/transition
            ([0x20, 0x01, 0x0d, 0xb8], 32),             // documentation
            ([0x20, 0x02], 16),                         // 6to4 transition
            ([0x26, 0x20, 0x00, 0x4f, 0x80, 0x00], 48), // AS112 special-purpose
            ([0x3f, 0xff, 0x00], 20),                   // documentation
        ]
        return !special.contains { matchesPrefix(bytes, prefix: $0.0, bits: $0.1) }
    }

    /// True unless the raw socket address is admitted by the positive global-unicast policy.
    static func isNonPublic(_ sa: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            let bytes = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
            }
            guard bytes.count == 4 else { return true }
            return isNonPublicIPv4(bytes[0], bytes[1], bytes[2], bytes[3])
        case AF_INET6:
            let bytes = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
            return !isGlobalUnicastAddress(
                ParsedIPAddress(family: AF_INET6, bytes: bytes, literal: ""))
        default:
            return true
        }
    }

    /// IANA IPv4 Special-Purpose Address Registry, conservatively rejecting every special prefix
    /// (including the few globally reachable anycast entries) rather than maintaining exceptions.
    static func isNonPublicIPv4(
        _ a: UInt8, _ b: UInt8, _ c: UInt8 = 0, _ d: UInt8 = 0
    ) -> Bool {
        let address = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
        let special: [(UInt32, Int)] = [
            (0x00000000, 8), (0x0a000000, 8), (0x64400000, 10), (0x7f000000, 8),
            (0xa9fe0000, 16), (0xac100000, 12), (0xc0000000, 24), (0xc0000200, 24),
            (0xc01fc400, 24), (0xc034c100, 24), (0xc0586300, 24), (0xc0a80000, 16),
            (0xc0af3000, 24), (0xc6120000, 15), (0xc6336400, 24), (0xcb007100, 24),
            (0xe0000000, 4), (0xf0000000, 4),
        ]
        return special.contains { network, bits in
            let mask = UInt32.max << UInt32(32 - bits)
            return address & mask == network & mask
        }
    }

    private static func matchesPrefix(_ bytes: [UInt8], prefix: [UInt8], bits: Int) -> Bool {
        guard bits >= 0, bits <= bytes.count * 8, prefix.count * 8 >= bits else { return false }
        let whole = bits / 8
        if whole > 0, Array(bytes.prefix(whole)) != Array(prefix.prefix(whole)) { return false }
        let remainder = bits % 8
        guard remainder > 0 else { return true }
        let mask = UInt8.max << UInt8(8 - remainder)
        return bytes[whole] & mask == prefix[whole] & mask
    }

    // MARK: - HTML → text (crude but dependency-free)

    static func htmlToText(_ html: String) -> String {
        var s = html
        for block in ["script", "style"] {
            s = s.replacingOccurrences(of: "(?is)<\(block).*?</\(block)>", with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)   // strip tags
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"]
        for (e, v) in entities { s = s.replacingOccurrences(of: e, with: v) }
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "(\\s*\\n\\s*){2,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
