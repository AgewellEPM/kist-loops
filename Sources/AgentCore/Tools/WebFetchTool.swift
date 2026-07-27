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
/// loopback / private / link-local IP is refused (blocks `localhost`, `169.254.169.254` cloud
/// metadata, RFC1918, ULA/link-local v6), and HTTP redirects are NOT followed (so a 3xx can't
/// bounce the request to an internal address after the check).
public struct WebFetchTool: AgentTool {
    public let name = "fetch_url"
    public let description = "Fetch the text content of an http(s) URL (HTML stripped to readable text). " +
        "Use to read documentation or web pages. Private/loopback addresses are refused."
    public let parameters = [
        ToolParameter(name: "url", type: "string", description: "The http(s) URL to fetch.", required: true),
        ToolParameter(name: "allowed_hosts", type: "array", description: "Optional per-call host allowlist that can only narrow the tool's configured allowlist.", required: false),
    ]
    public static let maxBytes = 256_000
    private let allowedHosts: Set<String>

    public init(allowedHosts: [String] = []) {
        self.allowedHosts = Set(allowedHosts.compactMap(Self.normalizedHostPattern))
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let urlStr = try requireString("url", from: arguments)
        guard let url = URL(string: urlStr), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host else {
            return .failure("provide an http(s) URL")
        }
        let callAllowlist = (arguments["allowed_hosts"] as? [String])?
            .compactMap(Self.normalizedHostPattern) ?? []
        if let reason = Self.allowlistBlockReason(host: host, configured: allowedHosts, perCall: Set(callAllowlist)) {
            return .failure("refused (host allowlist): \(reason)")
        }
        if let reason = Self.ssrfBlockReason(host: host) { return .failure("refused (SSRF guard): \(reason)") }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(from: url) }
        catch { return .failure("fetch failed: \(error.localizedDescription)") }

        guard let http = response as? HTTPURLResponse else { return .failure("no HTTP response") }
        guard (200...299).contains(http.statusCode) else { return .failure("HTTP \(http.statusCode) from \(host)") }

        let text = String(decoding: data.prefix(Self.maxBytes), as: UTF8.self)
        let stripped = String(Self.htmlToText(text).prefix(Self.maxBytes))
        return ToolResult(success: true, output: stripped.isEmpty ? "(empty)" : stripped,
                          metadata: ["url": urlStr, "status": String(http.statusCode), "bytes": String(min(data.count, Self.maxBytes))])
    }

    // MARK: - SSRF guard

    /// Host allowlist. Empty configured set means unrestricted public hosts; non-empty means the
    /// host must match it. A per-call list can only narrow (intersection), never broaden.
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
        let host = normalizeHost(raw)
        guard !host.isEmpty else { return nil }
        if host.hasPrefix("*.") {
            let bare = String(host.dropFirst(2))
            return bare.isEmpty || bare.contains("*") ? nil : "*." + bare
        }
        return host.contains("*") ? nil : host
    }

    private static func normalizeHost(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    /// Returns a block reason if `host` resolves to (or literally is) a non-public address.
    static func ssrfBlockReason(host: String) -> String? {
        if host.lowercased() == "localhost" { return "localhost is not allowed" }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let head = res else {
            return nil   // unresolvable → the fetch will simply fail; not an SSRF risk
        }
        defer { freeaddrinfo(res) }
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let n = node {
            if let addr = n.pointee.ai_addr, isNonPublic(addr) {
                return "\(host) resolves to a private/loopback address"
            }
            node = n.pointee.ai_next
        }
        return nil
    }

    /// True for loopback / private / link-local IPv4 + IPv6 (inspecting the raw address bytes).
    static func isNonPublic(_ sa: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            let net = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let ip = UInt32(bigEndian: net)                       // host byte order
            return isNonPublicIPv4(UInt8((ip >> 24) & 0xff), UInt8((ip >> 16) & 0xff))
        case AF_INET6:
            var bytes = [UInt8](repeating: 0, count: 16)
            sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                withUnsafeBytes(of: p.pointee.sin6_addr) { raw in
                    for i in 0..<16 { bytes[i] = raw[i] }
                }
            }
            if bytes == Array(repeating: 0, count: 16) { return true }        // :: unspecified
            if bytes == Array(repeating: 0, count: 15) + [1] { return true }  // ::1 loopback
            if (bytes[0] & 0xfe) == 0xfc { return true }                      // fc00::/7 unique-local
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }  // fe80::/10 link-local
            // IPv4-mapped (::ffff:a.b.c.d) / IPv4-compatible (::a.b.c.d): apply IPv4 rules to the tail,
            // so ::ffff:127.0.0.1 / ::ffff:169.254.169.254 can't slip past the v6 checks.
            if Array(bytes[0..<10]) == Array(repeating: 0, count: 10),
               (bytes[10] == 0xff && bytes[11] == 0xff) || (bytes[10] == 0 && bytes[11] == 0) {
                return isNonPublicIPv4(bytes[12], bytes[13])
            }
            return false
        default:
            return false
        }
    }

    /// IPv4 loopback / RFC1918 / link-local (+ cloud metadata 169.254). Shared by the v4 path AND the
    /// IPv4-mapped-IPv6 path so the two classifications can't diverge.
    static func isNonPublicIPv4(_ a: UInt8, _ b: UInt8) -> Bool {
        if a == 127 || a == 10 || a == 0 { return true }      // loopback / RFC1918-10 / "this host"
        if a == 192 && b == 168 { return true }               // RFC1918
        if a == 169 && b == 254 { return true }               // link-local + cloud metadata
        if a == 172 && (16...31).contains(b) { return true }  // RFC1918
        if a == 100 && (64...127).contains(b) { return true } // 100.64/10 carrier-grade NAT (Codex)
        if a == 198 && (18...19).contains(b) { return true }  // 198.18/15 benchmarking
        if a >= 224 { return true }                           // 224/4 multicast + 240/4 reserved + 255 broadcast
        return false
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

/// Blocks HTTP redirects so a 3xx can't bounce the request to an internal address after the
/// SSRF check passed for the original host.
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
