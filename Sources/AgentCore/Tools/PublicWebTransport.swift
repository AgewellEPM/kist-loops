import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct PublicWebHTTPResponse: Sendable {
    let statusCode: Int
    let body: String
    let redirectLocation: String?
    let finalURL: URL?

    init(statusCode: Int, body: String, redirectLocation: String? = nil, finalURL: URL? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.redirectLocation = redirectLocation
        self.finalURL = finalURL
    }
}

private enum PublicWebTransportError: LocalizedError {
    case invalid(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message), .transport(let message): return message
        }
    }
}

/// Fail-closed, DNS-pinned transport for bounded public HTTP(S) reads.
/// DNS runs in a disposable, timed system helper. Every returned address is classified before
/// each address is tried with curl `--resolve`. Redirects are never delegated to curl: each hop
/// is resolved, policy-checked, pinned, and charged to one wall-clock/body budget.
enum PublicWebTransport {
    static let statusMarker = "__KIST_HTTP_STATUS__:"
    static let redirectMarker = "__KIST_HTTP_REDIRECT__:"
    static let maxURLBytes = 16_384
    static let defaultMaxRedirects = 5
    static let resolverTimeoutSeconds = 3
    static let overallTimeoutSeconds = 20
    static let maxResolvedAddresses = 64
    private static let resolverOutputCap = 65_536

    struct CurlInvocation: Sendable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
        let stdinData: Data?
        let outputCap: Int
    }

    typealias AddressResolver = @Sendable (
        _ host: String, _ timeoutSeconds: Int
    ) async -> (addresses: [String], reason: String?)
    typealias InvocationRunner = @Sendable (
        _ invocation: CurlInvocation, _ timeoutSeconds: Int
    ) async -> ProcessGroupRunner.Outcome

    static func fetch(
        url: URL,
        maxBytes: Int,
        headerLines: [String] = [],
        configuredAllowedHosts: Set<String> = [],
        perCallAllowedHosts: Set<String> = [],
        maxRedirects: Int = defaultMaxRedirects,
        resolver: AddressResolver? = nil,
        runner: InvocationRunner? = nil,
        curlPath overrideCurlPath: String? = nil
    ) async throws -> PublicWebHTTPResponse {
        guard maxBytes > 0 else {
            throw PublicWebTransportError.invalid("public-web byte limit must be positive")
        }
        guard (0...10).contains(maxRedirects) else {
            throw PublicWebTransportError.invalid("public-web redirect limit is invalid")
        }
        guard hostPolicyIsNormalized(configuredAllowedHosts),
              hostPolicyIsNormalized(perCallAllowedHosts) else {
            throw PublicWebTransportError.invalid("refused (host allowlist): invalid transport host policy")
        }
        try validateHeaders(headerLines)
        let curlPath: String
        if let overrideCurlPath {
            curlPath = overrideCurlPath
        } else if let trusted = systemCurlPath() {
            curlPath = trusted
        } else {
            throw PublicWebTransportError.transport(
                "secure public-web transport unavailable: trusted system curl not found")
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let deadline = started + UInt64(overallTimeoutSeconds) * 1_000_000_000
        func remainingWallSeconds() -> Int {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return 0 }
            // ProcessGroupRunner accepts whole seconds. Round down so no helper can run
            // past the aggregate deadline; the final fractional second is intentionally unused.
            return Int((deadline - now) / 1_000_000_000)
        }

        let resolve = resolver ?? defaultResolver
        let execute = runner ?? defaultRunner
        var currentURL = url
        var redirectsFollowed = 0
        var remainingBodyBytes = maxBytes
        var visited = Set<String>()
        visited.insert(try canonicalRedirectKey(url))

        while true {
            guard !Task.isCancelled else {
                throw PublicWebTransportError.transport("public-web request cancelled")
            }
            let validated = try validateURL(currentURL, headerLines: headerLines)
            if let reason = WebFetchTool.allowlistBlockReason(
                host: validated.host,
                configured: configuredAllowedHosts,
                perCall: perCallAllowedHosts
            ) {
                throw PublicWebTransportError.invalid("refused (host allowlist): \(reason)")
            }
            guard remainingBodyBytes > 0 else {
                throw PublicWebTransportError.invalid(
                    "public-web aggregate response exceeded the \(maxBytes)-byte limit")
            }
            let wallBeforeDNS = remainingWallSeconds()
            guard wallBeforeDNS > 0 else {
                throw PublicWebTransportError.transport("public-web aggregate request timed out")
            }
            let resolution = await resolve(
                validated.host, min(resolverTimeoutSeconds, wallBeforeDNS))
            guard !Task.isCancelled else {
                throw PublicWebTransportError.transport("public-web request cancelled")
            }
            guard remainingWallSeconds() > 0 else {
                throw PublicWebTransportError.transport("public-web aggregate request timed out")
            }
            if let reason = resolution.reason {
                throw PublicWebTransportError.invalid("refused (SSRF guard): \(reason)")
            }
            guard resolution.addresses.count <= maxResolvedAddresses else {
                throw PublicWebTransportError.invalid(
                    "refused (SSRF guard): DNS returned too many addresses")
            }

            var addresses: [String] = []
            var seenAddresses = Set<String>()
            for rawAddress in resolution.addresses {
                guard let parsed = WebFetchTool.parsedIPAddress(rawAddress) else {
                    throw PublicWebTransportError.invalid(
                        "refused (SSRF guard): DNS returned an unparseable address")
                }
                guard WebFetchTool.isGlobalUnicastAddress(parsed) else {
                    throw PublicWebTransportError.invalid(
                        "refused (SSRF guard): \(validated.host) resolves to a non-global address")
                }
                if seenAddresses.insert(parsed.literal).inserted { addresses.append(parsed.literal) }
            }
            guard !addresses.isEmpty else {
                throw PublicWebTransportError.invalid(
                    "refused (SSRF guard): DNS returned no usable global address")
            }

            var response: PublicWebHTTPResponse?
            var lastTransportError: PublicWebTransportError?
            for address in addresses {
                let wall = remainingWallSeconds()
                guard wall > 0 else {
                    throw PublicWebTransportError.transport("public-web aggregate request timed out")
                }
                let attemptByteBudget = remainingBodyBytes
                let attemptTimeout = min(18, wall)
                let invocation = try makeInvocation(
                    url: currentURL,
                    address: address,
                    maxBytes: attemptByteBudget,
                    headerLines: headerLines,
                    curlPath: curlPath,
                    timeoutSeconds: attemptTimeout
                )
                let outcome = await execute(invocation, attemptTimeout)
                guard !Task.isCancelled else {
                    throw PublicWebTransportError.transport("public-web request cancelled")
                }
                guard remainingWallSeconds() > 0 else {
                    throw PublicWebTransportError.transport("public-web aggregate request timed out")
                }
                // Invalid UTF-8 must not become a free retry because its display String is empty.
                let capturedBytes = max(outcome.stdoutByteCount, outcome.stdout.utf8.count)
                guard capturedBytes <= remainingBodyBytes else {
                    throw PublicWebTransportError.invalid(
                        "public-web aggregate response exceeded the \(maxBytes)-byte limit")
                }
                remainingBodyBytes -= capturedBytes
                do {
                    response = try parseOutcome(outcome, maxBytes: attemptByteBudget)
                    break
                } catch let error as PublicWebTransportError {
                    switch error {
                    case .transport:
                        lastTransportError = error
                        continue
                    case .invalid:
                        throw error
                    }
                }
            }
            guard let hopResponse = response else {
                if let lastTransportError { throw lastTransportError }
                throw PublicWebTransportError.transport(
                    "all validated addresses failed for \(validated.host)")
            }

            guard isRedirect(hopResponse.statusCode) else {
                return PublicWebHTTPResponse(
                    statusCode: hopResponse.statusCode,
                    body: hopResponse.body,
                    redirectLocation: hopResponse.redirectLocation,
                    finalURL: currentURL)
            }
            guard let location = hopResponse.redirectLocation, !location.isEmpty else {
                throw PublicWebTransportError.invalid(
                    "public-web redirect omitted a valid Location")
            }
            guard redirectsFollowed < maxRedirects else {
                throw PublicWebTransportError.invalid("public-web redirect hop limit exceeded")
            }
            let nextURL = try resolveRedirect(location, relativeTo: currentURL)
            let nextValidated = try validateURL(nextURL, headerLines: headerLines)
            if validated.scheme == "https", nextValidated.scheme == "http" {
                throw PublicWebTransportError.invalid("public-web HTTPS redirect downgrade is refused")
            }
            if !headerLines.isEmpty, !sameOrigin(currentURL, nextURL) {
                throw PublicWebTransportError.invalid(
                    "credential-bearing public-web request cannot redirect across origins")
            }
            if let reason = WebFetchTool.allowlistBlockReason(
                host: nextValidated.host,
                configured: configuredAllowedHosts,
                perCall: perCallAllowedHosts
            ) {
                throw PublicWebTransportError.invalid("refused (host allowlist): \(reason)")
            }
            let key = try canonicalRedirectKey(nextURL)
            guard visited.insert(key).inserted else {
                throw PublicWebTransportError.invalid("public-web redirect cycle detected")
            }
            redirectsFollowed += 1
            currentURL = nextURL
        }
    }

    static func makeInvocation(
        url: URL,
        address: String,
        maxBytes: Int,
        headerLines: [String],
        curlPath: String,
        timeoutSeconds: Int = 18
    ) throws -> CurlInvocation {
        guard maxBytes > 0, maxBytes < Int.max, timeoutSeconds > 0 else {
            throw PublicWebTransportError.invalid("invalid public-web request")
        }
        let validated = try validateURL(url, headerLines: headerLines)
        try validateHeaders(headerLines)
        guard let parsedAddress = WebFetchTool.parsedIPAddress(address),
              WebFetchTool.isGlobalUnicastAddress(parsedAddress) else {
            throw PublicWebTransportError.invalid("invalid pinned public-web address")
        }

        let resolveHost = validated.host.contains(":") ? "[\(validated.host)]" : validated.host
        let resolveAddress = parsedAddress.literal.contains(":")
            ? "[\(parsedAddress.literal)]" : parsedAddress.literal
        let port = url.port ?? (validated.scheme == "https" ? 443 : 80)
        var arguments = [
            "-q",
            "--silent",
            "--show-error",
            "--request", "GET",
            "--proto", "=http,https",
            "--proto-redir", "=http,https",
            "--max-redirs", "0",
            "--connect-timeout", String(min(10, timeoutSeconds)),
            "--max-time", String(timeoutSeconds),
            "--proxy", "",
            "--noproxy", "*",
            "--compressed",
            "--max-filesize", String(maxBytes),
            "--resolve", "\(resolveHost):\(port):\(resolveAddress)",
            "--user-agent", "Kist-PublicWeb/1.0",
            "--write-out", "%{stderr}\n\(redirectMarker)%{redirect_url}\n\(statusMarker)%{http_code}\n",
            "--output", "-"
        ]

        // The URL may contain signed query credentials. Keep it, and all headers, out of
        // argv by feeding a strictly quoted curl config on the private unlinked stdin FD.
        // `validateURL`/`validateHeaders` reject controls before this encoder runs.
        var configLines = ["url = \(curlConfigQuoted(url.absoluteString))"]
        configLines.append(contentsOf: headerLines.map { "header = \(curlConfigQuoted($0))" })
        let stdinData = Data((configLines.joined(separator: "\n") + "\n").utf8)
        arguments.append(contentsOf: ["--config", "-"])

        return CurlInvocation(
            executable: curlPath,
            arguments: arguments,
            environment: [
                "HOME": "/var/empty", "LANG": "C", "LC_ALL": "C",
                "NO_PROXY": "*", "no_proxy": "*"
            ],
            stdinData: stdinData,
            outputCap: maxBytes + 1
        )
    }

    static func parseOutcome(
        _ outcome: ProcessGroupRunner.Outcome,
        maxBytes: Int
    ) throws -> PublicWebHTTPResponse {
        if outcome.stdoutTruncated || outcome.stderrTruncated || outcome.exitCode == 63 {
            throw PublicWebTransportError.invalid(
                "public-web response exceeded the \(maxBytes)-byte limit")
        }
        if outcome.timedOut {
            throw PublicWebTransportError.transport("public-web request timed out")
        }
        guard outcome.exitCode == 0 else {
            throw PublicWebTransportError.transport(
                "pinned public-web request failed (curl exit \(outcome.exitCode))")
        }
        guard max(outcome.stdoutByteCount, outcome.stdout.utf8.count) <= maxBytes else {
            throw PublicWebTransportError.invalid(
                "public-web response exceeded the \(maxBytes)-byte limit")
        }
        guard let statusRange = outcome.stderr.range(of: statusMarker, options: .backwards) else {
            throw PublicWebTransportError.invalid(
                "secure public-web transport did not report an HTTP status")
        }
        let statusSuffix = outcome.stderr[statusRange.upperBound...]
        let digits = statusSuffix.prefix(3)
        guard digits.count == 3, digits.allSatisfy(\.isNumber),
              statusSuffix.dropFirst(3).allSatisfy(\.isWhitespace),
              let statusCode = Int(digits) else {
            throw PublicWebTransportError.invalid(
                "secure public-web transport reported an invalid HTTP status")
        }
        let framingPrefix = outcome.stderr[..<statusRange.lowerBound]
        var location: String?
        if let redirectRange = framingPrefix.range(of: redirectMarker, options: .backwards) {
            let raw = framingPrefix[redirectRange.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty {
                guard raw.utf8.count <= maxURLBytes else {
                    throw PublicWebTransportError.invalid("public-web redirect URL is too large")
                }
                location = raw
            }
        }
        return PublicWebHTTPResponse(
            statusCode: statusCode, body: outcome.stdout, redirectLocation: location)
    }

    static func resolvePublicAddresses(
        host: String, timeoutSeconds: Int = resolverTimeoutSeconds
    ) -> (addresses: [String], reason: String?) {
        let stripped = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let literal = WebFetchTool.parsedIPAddress(stripped) {
            guard WebFetchTool.isGlobalUnicastAddress(literal) else {
                return ([], "\(host) is a non-global/special-purpose address")
            }
            return ([literal.literal], nil)
        }
        guard let normalized = WebFetchTool.normalizedHostPattern(stripped),
              !normalized.hasPrefix("*."), normalized != "localhost",
              !normalized.hasSuffix(".localhost") else {
            return ([], "\(host) is not a valid public hostname")
        }
        guard timeoutSeconds > 0 else { return ([], "DNS resolution timed out for \(host)") }
        guard let command = systemResolverCommand(host: normalized) else {
            return ([], "secure bounded DNS resolver is unavailable")
        }
        let outcome = ProcessGroupRunner.run(
            launchPath: command.path,
            launchArgs: command.arguments,
            cwd: "/",
            env: ["HOME": "/var/empty", "LANG": "C", "LC_ALL": "C"],
            timeoutSeconds: timeoutSeconds,
            capPerStream: resolverOutputCap
        )
        return parseResolverOutcome(outcome, host: host)
    }

    static func parseResolverOutcome(
        _ outcome: ProcessGroupRunner.Outcome, host: String
    ) -> (addresses: [String], reason: String?) {
        if outcome.timedOut { return ([], "DNS resolution timed out for \(host)") }
        if outcome.stdoutTruncated || outcome.stderrTruncated || outcome.outputTruncated {
            return ([], "DNS resolution output exceeded its bound for \(host)")
        }
        guard outcome.exitCode == 0 else { return ([], "DNS resolution failed for \(host)") }
        var addresses: [String] = []
        var seen = Set<String>()
        for line in outcome.stdout.split(whereSeparator: \.isNewline) {
            for token in line.split(whereSeparator: \.isWhitespace) {
                guard let parsed = WebFetchTool.parsedIPAddress(String(token)) else { continue }
                guard WebFetchTool.isGlobalUnicastAddress(parsed) else {
                    return ([], "\(host) resolves to a non-global/special-purpose address")
                }
                if seen.insert(parsed.literal).inserted { addresses.append(parsed.literal) }
                guard addresses.count <= maxResolvedAddresses else {
                    return ([], "DNS returned too many addresses for \(host)")
                }
            }
        }
        guard !addresses.isEmpty else { return ([], "DNS returned no usable addresses for \(host)") }
        return (addresses, nil)
    }

    /// Preserve the trusted executable and argv exactly. The process-group runner already
    /// supplies wall/output bounds; a `/bin/sh -c` resource wrapper adds a needless parser.
    static func directLaunch(
        for invocation: CurlInvocation
    ) -> (launchPath: String, launchArgs: [String]) {
        (invocation.executable, invocation.arguments)
    }

    static func systemCurlPath(candidates: [String] = ["/usr/bin/curl", "/bin/curl"]) -> String? {
        trustedSystemPath(candidates: candidates)
    }

    private static var defaultResolver: AddressResolver {
        { host, timeoutSeconds in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: resolvePublicAddresses(
                        host: host, timeoutSeconds: timeoutSeconds))
                }
            }
        }
    }

    private static var defaultRunner: InvocationRunner {
        { invocation, timeoutSeconds in
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let launch = directLaunch(for: invocation)
                    continuation.resume(returning: ProcessGroupRunner.run(
                        launchPath: launch.launchPath,
                        launchArgs: launch.launchArgs,
                        cwd: "/",
                        env: invocation.environment,
                        timeoutSeconds: max(1, timeoutSeconds),
                        capPerStream: invocation.outputCap,
                        stdinData: invocation.stdinData
                    ))
                }
            }
        }
    }

    private static func validateHeaders(_ headerLines: [String]) throws {
        guard headerLines.count <= 32,
              headerLines.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
              headerLines.allSatisfy({ line in
                  line.utf8.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
              }) else {
            throw PublicWebTransportError.invalid("public-web headers are invalid or too large")
        }
    }

    static func curlConfigQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func validateURL(
        _ url: URL, headerLines: [String]
    ) throws -> (scheme: String, host: String) {
        let absolute = url.absoluteString
        guard absolute.utf8.count <= maxURLBytes,
              absolute.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }),
              !absolute.contains("\\"),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let rawHost = url.host,
              url.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw PublicWebTransportError.invalid(
                "public-web URL must be bounded http(s), without credentials or ambiguous syntax")
        }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard let normalized = WebFetchTool.normalizedHostPattern(host),
              !normalized.hasPrefix("*.") else {
            throw PublicWebTransportError.invalid("public-web URL contains an invalid host")
        }
        if !headerLines.isEmpty, scheme != "https" {
            throw PublicWebTransportError.invalid(
                "credential-bearing public-web requests require HTTPS")
        }
        return (scheme, normalized)
    }

    private static func hostPolicyIsNormalized(_ patterns: Set<String>) -> Bool {
        patterns.allSatisfy { WebFetchTool.normalizedHostPattern($0) == $0 }
    }

    private static func isRedirect(_ status: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(status)
    }

    private static func resolveRedirect(_ raw: String, relativeTo base: URL) throws -> URL {
        guard raw.utf8.count <= maxURLBytes,
              raw.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }),
              let resolved = URL(string: raw, relativeTo: base)?.absoluteURL,
              resolved.absoluteString.utf8.count <= maxURLBytes else {
            throw PublicWebTransportError.invalid("public-web redirect Location is invalid")
        }
        return resolved
    }

    private static func canonicalRedirectKey(_ url: URL) throws -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            throw PublicWebTransportError.invalid("public-web redirect URL is invalid")
        }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        guard let key = components.string else {
            throw PublicWebTransportError.invalid("public-web redirect URL is invalid")
        }
        return key
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func origin(_ url: URL) -> (String, String, Int)? {
            guard let scheme = url.scheme?.lowercased(),
                  let host = url.host?.lowercased() else { return nil }
            return (scheme, host, url.port ?? (scheme == "https" ? 443 : 80))
        }
        guard let left = origin(lhs), let right = origin(rhs) else { return false }
        return left.0 == right.0 && left.1 == right.1 && left.2 == right.2
    }

    private static func systemResolverCommand(host: String) -> (path: String, arguments: [String])? {
        #if canImport(Darwin)
        guard let path = trustedSystemPath(candidates: ["/usr/bin/dscacheutil"]) else { return nil }
        return (path, ["-q", "host", "-a", "name", host])
        #else
        guard let path = trustedSystemPath(candidates: ["/usr/bin/getent", "/bin/getent"]) else {
            return nil
        }
        return (path, ["ahosts", host])
        #endif
    }

    private static func trustedSystemPath(candidates: [String]) -> String? {
        var checked = Set<String>()
        for candidate in candidates {
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard checked.insert(resolved).inserted else { continue }
            var info = stat()
            guard stat(resolved, &info) == 0,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  info.st_uid == 0,
                  info.st_mode & mode_t(0o022) == 0,
                  access(resolved, X_OK) == 0 else { continue }
            return resolved
        }
        return nil
    }
}
