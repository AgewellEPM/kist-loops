import XCTest
@testable import AgentCore

final class PublicWebTransportTests: XCTestCase {
    func testCurlInvocationPinsAddressAndDisablesAmbientRouting() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/search?q=kist"))
        let invocation = try PublicWebTransport.makeInvocation(
            url: url,
            address: "93.184.216.34",
            maxBytes: 256,
            headerLines: [],
            curlPath: "/usr/bin/curl"
        )

        XCTAssertEqual(invocation.arguments.first, "-q")
        XCTAssertTrue(invocation.arguments.contains("example.com:443:93.184.216.34"))
        XCTAssertTrue(invocation.arguments.contains("=http,https"))
        XCTAssertTrue(
            invocation.arguments.contains {
                $0.contains(PublicWebTransport.redirectMarker + "%{redirect_url}")
            }
        )
        XCTAssertTrue(invocation.arguments.contains("--proxy"))
        XCTAssertTrue(invocation.arguments.contains("--noproxy"))
        XCTAssertFalse(invocation.arguments.contains("--location"))
        XCTAssertFalse(invocation.arguments.contains("-L"))
        XCTAssertEqual(Array(invocation.arguments.suffix(2)), ["--config", "-"])
        XCTAssertFalse(invocation.arguments.joined(separator: " ").contains(url.absoluteString))
        XCTAssertTrue(String(decoding: try XCTUnwrap(invocation.stdinData), as: UTF8.self)
            .contains("url = \"https://example.com/search?q=kist\""))
        XCTAssertEqual(invocation.outputCap, 257)
    }

    func testSensitiveHeadersStayOffArgumentVector() throws {
        let url = try XCTUnwrap(URL(string: "https://api.search.brave.com/res/v1/web/search?q=kist"))
        let invocation = try PublicWebTransport.makeInvocation(
            url: url,
            address: "1.1.1.1",
            maxBytes: 512,
            headerLines: ["X-Subscription-Token: secret-value"],
            curlPath: "/usr/bin/curl"
        )

        XCTAssertFalse(invocation.arguments.joined(separator: " ").contains("secret-value"))
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(invocation.stdinData), as: UTF8.self),
            "url = \"https://api.search.brave.com/res/v1/web/search?q=kist\"\n" +
            "header = \"X-Subscription-Token: secret-value\"\n"
        )
        XCTAssertTrue(invocation.arguments.contains("--config"))
    }

    func testSignedURLAndCurlConfigSyntaxStayPrivateAndQuoted() throws {
        let url = try XCTUnwrap(URL(string:
            "https://example.com/object?X-Amz-Signature=secret%22value&x=--output"))
        let invocation = try PublicWebTransport.makeInvocation(
            url: url, address: "93.184.216.34", maxBytes: 256,
            headerLines: ["X-Test: quote\" and \\ slash"], curlPath: "/usr/bin/curl")
        let argv = invocation.arguments.joined(separator: " ")
        XCTAssertFalse(argv.contains("X-Amz-Signature"))
        XCTAssertFalse(argv.contains("secret"))
        let config = String(decoding: try XCTUnwrap(invocation.stdinData), as: UTF8.self)
        XCTAssertTrue(config.contains("X-Amz-Signature=secret%22value"))
        XCTAssertTrue(config.contains("header = \"X-Test: quote\\\" and \\\\ slash\""))
    }

    func testParserAcceptsBoundedBodyAndStatusTrailer() throws {
        var outcome = ProcessGroupRunner.Outcome(combined: "", exitCode: 0, timedOut: false)
        outcome.stdout = "hello"
        outcome.stderr = "\n\(PublicWebTransport.statusMarker)200\n"

        let response = try PublicWebTransport.parseOutcome(outcome, maxBytes: 5)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, "hello")
    }

    func testParserExtractsRedirectLocationFromBoundedFraming() throws {
        var outcome = ProcessGroupRunner.Outcome(combined: "", exitCode: 0, timedOut: false)
        outcome.stderr = "\n\(PublicWebTransport.redirectMarker)/next\n" +
            "\(PublicWebTransport.statusMarker)302\n"

        let response = try PublicWebTransport.parseOutcome(outcome, maxBytes: 32)

        XCTAssertEqual(response.statusCode, 302)
        XCTAssertEqual(response.redirectLocation, "/next")
    }

    func testParserRejectsBodyCapTermination() {
        var outcome = ProcessGroupRunner.Outcome(combined: "", exitCode: 143, timedOut: false)
        outcome.stdout = "abcdef"
        outcome.stdoutTruncated = true

        XCTAssertThrowsError(try PublicWebTransport.parseOutcome(outcome, maxBytes: 5))
    }

    func testMissingTrustedCurlFailsClosed() {
        XCTAssertNil(PublicWebTransport.systemCurlPath(candidates: ["/definitely/not/a/system/curl"]))
    }

    func testResolverTimeoutOutcomeFailsClosed() {
        let outcome = ProcessGroupRunner.Outcome(combined: "", exitCode: 143, timedOut: true)
        let resolution = PublicWebTransport.parseResolverOutcome(outcome, host: "example.com")
        XCTAssertTrue(resolution.addresses.isEmpty)
        XCTAssertTrue((resolution.reason ?? "").contains("timed out"))
    }

    func testRetriesEveryValidatedAddress() async throws {
        let scenario = PublicWebScenario(outcomes: [
            Self.outcome(exitCode: 7),
            Self.outcome(status: 200, body: "ok"),
        ])
        let response = try await PublicWebTransport.fetch(
            url: try XCTUnwrap(URL(string: "https://multi.example/path")), maxBytes: 64,
            resolver: { _, _ in (["93.184.216.34", "1.1.1.1"], nil) },
            runner: { invocation, _ in await scenario.run(invocation) },
            curlPath: "/usr/bin/curl")
        let invocationCount = await scenario.invocationCount()

        XCTAssertEqual(response.body, "ok")
        XCTAssertEqual(invocationCount, 2)
        let resolveArguments = await scenario.resolveArguments()
        XCTAssertTrue(resolveArguments[0].contains("93.184.216.34"))
        XCTAssertTrue(resolveArguments[1].contains("1.1.1.1"))
    }

    func testResolverFailureFailsClosedBeforeAnyConnectionAttempt() async throws {
        let scenario = PublicWebScenario(outcomes: [])
        do {
            _ = try await PublicWebTransport.fetch(
                url: try XCTUnwrap(URL(string: "https://unresolved.example")), maxBytes: 64,
                resolver: { _, _ in ([], "DNS resolution failed") },
                runner: { invocation, _ in await scenario.run(invocation) },
                curlPath: "/usr/bin/curl")
            XCTFail("resolver failure must never reach curl")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("DNS resolution failed"))
        }
        let invocationCount = await scenario.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testRetriesShareOneRawBodyByteBudget() async throws {
        let scenario = PublicWebScenario(outcomes: [
            Self.outcome(body: String(repeating: "a", count: 40), exitCode: 7),
            Self.outcome(status: 200, body: String(repeating: "b", count: 30)),
        ])
        do {
            _ = try await PublicWebTransport.fetch(
                url: try XCTUnwrap(URL(string: "https://multi.example/path")), maxBytes: 64,
                resolver: { _, _ in (["93.184.216.34", "1.1.1.1"], nil) },
                runner: { invocation, _ in await scenario.run(invocation) },
                curlPath: "/usr/bin/curl")
            XCTFail("failed-address bodies must consume the aggregate budget")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("aggregate response exceeded"))
        }
        let outputCaps = await scenario.outputCaps()
        XCTAssertEqual(outputCaps, [65, 25])
    }

    func testAnyNonGlobalDNSAnswerRejectsWholeResolution() async throws {
        let scenario = PublicWebScenario(outcomes: [])
        do {
            _ = try await PublicWebTransport.fetch(
                url: try XCTUnwrap(URL(string: "https://mixed.example")), maxBytes: 64,
                resolver: { _, _ in (["93.184.216.34", "127.0.0.1"], nil) },
                runner: { invocation, _ in await scenario.run(invocation) },
                curlPath: "/usr/bin/curl")
            XCTFail("mixed public/private DNS answers must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("non-global"))
        }
        let invocationCount = await scenario.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testTooManyDNSAnswersRejectBeforeRetries() async throws {
        let scenario = PublicWebScenario(outcomes: [])
        let addresses = (1...PublicWebTransport.maxResolvedAddresses + 1).map {
            "93.184.216.\($0)"
        }
        do {
            _ = try await PublicWebTransport.fetch(
                url: try XCTUnwrap(URL(string: "https://example.com")), maxBytes: 64,
                resolver: { _, _ in (addresses, nil) },
                runner: { invocation, _ in await scenario.run(invocation) },
                curlPath: "/usr/bin/curl")
            XCTFail("oversized DNS answer set must fail closed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too many addresses"))
        }
        let invocationCount = await scenario.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testRedirectRevalidatesBothAllowlistsBeforeDNS() async throws {
        let scenario = PublicWebScenario(outcomes: [
            Self.outcome(status: 302, location: "https://next.example.com/final"),
        ])
        do {
            _ = try await PublicWebTransport.fetch(
                url: try XCTUnwrap(URL(string: "https://start.example.com")), maxBytes: 128,
                configuredAllowedHosts: ["*.example.com"],
                perCallAllowedHosts: ["start.example.com"],
                resolver: { _, _ in (["93.184.216.34"], nil) },
                runner: { invocation, _ in await scenario.run(invocation) },
                curlPath: "/usr/bin/curl")
            XCTFail("redirect must not broaden the per-call allowlist")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("per-call"))
        }
        let invocationCount = await scenario.invocationCount()
        XCTAssertEqual(invocationCount, 1)
    }

    func testRelativeRedirectIsResolvedAndPinnedOneHopAtATime() async throws {
        let scenario = PublicWebScenario(outcomes: [
            Self.outcome(status: 302, body: "r", location: "/final"),
            Self.outcome(status: 200, body: "done"),
        ])
        let response = try await PublicWebTransport.fetch(
            url: try XCTUnwrap(URL(string: "https://example.com/start")), maxBytes: 32,
            configuredAllowedHosts: ["example.com"],
            resolver: { _, _ in (["93.184.216.34"], nil) },
            runner: { invocation, _ in await scenario.run(invocation) },
            curlPath: "/usr/bin/curl")
        let requestURLs = await scenario.requestURLs()

        XCTAssertEqual(response.body, "done")
        XCTAssertEqual(response.finalURL?.absoluteString, "https://example.com/final")
        XCTAssertEqual(requestURLs, [
            "https://example.com/start", "https://example.com/final",
        ])
    }

    func testRedirectCycleAndHopLimitAreRejected() async throws {
        let cycle = PublicWebScenario(outcomes: [
            Self.outcome(status: 302, location: "https://b.example/two"),
            Self.outcome(status: 302, location: "https://a.example/one"),
        ])
        do {
            _ = try await PublicWebTransport.fetch(
                url: try XCTUnwrap(URL(string: "https://a.example/one")), maxBytes: 64,
                configuredAllowedHosts: ["*.example"],
                resolver: { _, _ in (["93.184.216.34"], nil) },
                runner: { invocation, _ in await cycle.run(invocation) },
                curlPath: "/usr/bin/curl")
            XCTFail("redirect cycle must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cycle")) }

        let hops = PublicWebScenario(outcomes: [
            Self.outcome(status: 302, location: "/1"),
            Self.outcome(status: 302, location: "/2"),
        ])
        do {
            _ = try await PublicWebTransport.fetch(
                url: try XCTUnwrap(URL(string: "https://a.example/0")), maxBytes: 64,
                maxRedirects: 1,
                resolver: { _, _ in (["93.184.216.34"], nil) },
                runner: { invocation, _ in await hops.run(invocation) },
                curlPath: "/usr/bin/curl")
            XCTFail("redirect hop limit must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("hop limit")) }
    }

    func testRedirectCredentialsDowngradeAndCrossOriginHeadersAreRejected() async throws {
        for location in [
            "https://user:password@next.example/",
            "http://next.example/",
        ] {
            let scenario = PublicWebScenario(outcomes: [Self.outcome(status: 302, location: location)])
            do {
                _ = try await PublicWebTransport.fetch(
                    url: try XCTUnwrap(URL(string: "https://start.example/")), maxBytes: 64,
                    configuredAllowedHosts: ["*.example"],
                    resolver: { _, _ in (["93.184.216.34"], nil) },
                    runner: { invocation, _ in await scenario.run(invocation) },
                    curlPath: "/usr/bin/curl")
                XCTFail("unsafe redirect must fail")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }

        let credentialed = PublicWebScenario(outcomes: [
            Self.outcome(status: 302, location: "https://next.example/final"),
        ])
        do {
            _ = try await PublicWebTransport.fetch(
                url: try XCTUnwrap(URL(string: "https://start.example/")), maxBytes: 64,
                headerLines: ["Authorization: secret"],
                configuredAllowedHosts: ["*.example"],
                resolver: { _, _ in (["93.184.216.34"], nil) },
                runner: { invocation, _ in await credentialed.run(invocation) },
                curlPath: "/usr/bin/curl")
            XCTFail("headers must not cross origins")
        } catch { XCTAssertTrue(error.localizedDescription.contains("across origins")) }
    }

    func testCurlChildLaunchPreservesTrustedExecutableAndArgvWithoutShell() throws {
        let invocation = try PublicWebTransport.makeInvocation(
            url: try XCTUnwrap(URL(string: "https://example.com")),
            address: "93.184.216.34", maxBytes: 64, headerLines: [],
            curlPath: "/usr/bin/curl")
        let launch = PublicWebTransport.directLaunch(for: invocation)
        XCTAssertEqual(launch.launchPath, "/usr/bin/curl")
        XCTAssertEqual(launch.launchArgs, invocation.arguments)
        XCTAssertNotEqual(launch.launchPath, "/bin/sh")
    }

    private static func outcome(
        status: Int = 0, body: String = "", location: String? = nil,
        exitCode: Int32 = 0
    ) -> ProcessGroupRunner.Outcome {
        var outcome = ProcessGroupRunner.Outcome(
            combined: "", exitCode: exitCode, timedOut: false)
        outcome.stdout = body
        if exitCode == 0 {
            outcome.stderr = "\n\(PublicWebTransport.redirectMarker)\(location ?? "")\n" +
                "\(PublicWebTransport.statusMarker)\(String(format: "%03d", status))\n"
        }
        outcome.stdoutByteCount = body.utf8.count
        return outcome
    }
}

private actor PublicWebScenario {
    private var outcomes: [ProcessGroupRunner.Outcome]
    private var invocations: [PublicWebTransport.CurlInvocation] = []

    init(outcomes: [ProcessGroupRunner.Outcome]) { self.outcomes = outcomes }

    func run(_ invocation: PublicWebTransport.CurlInvocation) -> ProcessGroupRunner.Outcome {
        invocations.append(invocation)
        guard !outcomes.isEmpty else {
            return ProcessGroupRunner.Outcome(combined: "missing outcome", exitCode: 1, timedOut: false)
        }
        return outcomes.removeFirst()
    }

    func invocationCount() -> Int { invocations.count }

    func resolveArguments() -> [String] {
        invocations.compactMap { invocation in
            guard let index = invocation.arguments.firstIndex(of: "--resolve"),
                  invocation.arguments.indices.contains(index + 1) else { return nil }
            return invocation.arguments[index + 1]
        }
    }

    func requestURLs() -> [String] {
        invocations.compactMap { invocation in
            guard let data = invocation.stdinData else { return nil }
            let config = String(decoding: data, as: UTF8.self)
            guard let line = config.split(separator: "\n")
                .first(where: { $0.hasPrefix("url = \"") }), line.hasSuffix("\"") else { return nil }
            return String(line.dropFirst(7).dropLast())
        }
    }

    func outputCaps() -> [Int] { invocations.map(\.outputCap) }
}
