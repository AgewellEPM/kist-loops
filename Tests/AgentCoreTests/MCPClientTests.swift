import XCTest
@testable import AgentCore

/// MCP CLIENT tests. Emphasis on the two trust boundaries: config validation (what we
/// will spawn) and output sanitization (what we feed the model). These are the surfaces
/// where a hostile config or server turns into a real-world compromise.
final class MCPClientTests: XCTestCase {

    private var dir: String!

    override func setUpWithError() throws {
        dir = NSTemporaryDirectory() + "agentcore-mcp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(atPath: dir) }
    }

    private func writeConfig(_ json: String) throws {
        try json.write(toFile: dir + "/.mcp.json", atomically: true, encoding: .utf8)
    }

    // MARK: - Config validation

    func testConfig_relativeCommandRejected() throws {
        try writeConfig(#"{"mcpServers":{"x":{"command":"node"}}}"#)
        let (servers, issues) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(issues.contains { $0.server == "x" && $0.reason.contains("absolute path") })
    }

    func testConfig_serverNameWithNamespaceSeparatorRejected() throws {
        // Codex HIGH (registration side): a server name embedding `__` breaks <server>__<tool> splitting and
        // lets a scoped specialist reach an unintended server. It must be rejected at load. Single _ is fine.
        try writeConfig(#"{"mcpServers":{"git__hub":{"command":"/bin/echo"}}}"#)
        let (servers, _) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertFalse(servers.contains { $0.name == "git__hub" }, "`__` server name refused")
        try writeConfig(#"{"mcpServers":{"git_hub":{"command":"/bin/echo"}}}"#)
        let (ok, _) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertTrue(ok.contains { $0.name == "git_hub" }, "single underscore still allowed")
    }

    func testConfig_traversalCommandRejected() throws {
        try writeConfig(#"{"mcpServers":{"x":{"command":"/usr/bin/../bin/node"}}}"#)
        let (servers, issues) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(issues.contains { $0.reason.contains("'..'") })
    }

    func testConfig_metacharacterInArgRejected() throws {
        // Use a real executable so we get past the existence/executable checks and
        // reach the arg-metacharacter check.
        let sh = FileManager.default.fileExists(atPath: "/bin/sh") ? "/bin/sh" : "/bin/bash"
        try writeConfig(#"{"mcpServers":{"x":{"command":"\#(sh)","args":["a; rm -rf /"]}}}"#)
        let (servers, issues) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(issues.contains { $0.reason.contains("forbidden character") })
    }

    // HTTP transport is now supported — but a url pointing at an INTERNAL/link-local host is refused by
    // the SSRF guard (e.g. the cloud-metadata endpoint), so a config can't turn the agent into an SSRF pivot.
    func testConfig_httpToInternalHostRejectedSSRF() throws {
        try writeConfig(#"{"mcpServers":{"x":{"url":"http://169.254.169.254/mcp"}}}"#)
        let (servers, issues) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(issues.contains { $0.reason.contains("SSRF") })
    }

    // A public HTTPS url with auth headers is accepted as an HTTP-transport server; ${ENV} in a header
    // value is expanded from the environment (secret stays out of the config file).
    func testConfig_httpServerAcceptedWithEnvExpandedHeader() throws {
        try writeConfig(#"{"mcpServers":{"remote":{"url":"https://example.com/mcp","headers":{"Authorization":"Bearer ${KIST_TEST_MCP_TOKEN}"}}}}"#)
        let (servers, _) = MCPClientConfig.load(
            projectRoot: dir, allowProjectConfig: true, includeUserConfig: false,
            hostEnvironment: ["KIST_TEST_MCP_TOKEN": "s3cr3t"],
            ssrfBlockReason: { _ in nil })
        XCTAssertEqual(servers.count, 1)
        guard let s = servers.first else { return }
        XCTAssertTrue(s.isHTTP)
        XCTAssertEqual(s.url, "https://example.com/mcp")
        XCTAssertEqual(s.headers["Authorization"], "Bearer s3cr3t")   // env-expanded, not literal ${...}
    }

    func testConfig_httpMissingUrlRejected() throws {
        try writeConfig(#"{"mcpServers":{"x":{"transport":"http"}}}"#)
        let (servers, issues) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(issues.contains { $0.reason.contains("requires a 'url'") })
    }

    // The Streamable-HTTP response can be an SSE stream; the reply is the data: line whose id matches ours.
    func testHTTPMatchingSSEMessagePicksOurId() {
        let sse = """
        event: message
        data: {"jsonrpc":"2.0","id":7,"result":{"tools":[]}}

        data: {"jsonrpc":"2.0","id":8,"result":{"other":true}}
        """.data(using: .utf8)!
        let m = MCPHTTPConnection.matchingSSEMessage(sse, id: 8)
        XCTAssertNotNil(m)
        XCTAssertNotNil(m?["result"] as? [String: Any])
        XCTAssertTrue((m?["result"] as? [String: Any])?["other"] as? Bool ?? false)
        XCTAssertNil(MCPHTTPConnection.matchingSSEMessage(sse, id: 99))   // no matching id
    }

    func testExpandEnvReplacesReferences() {
        let environment = ["KIST_X": "abc"]
        XCTAssertEqual(MCPClientConfig.expandEnv("Bearer ${KIST_X}", environment: environment), "Bearer abc")
        XCTAssertEqual(MCPClientConfig.expandEnv("${KIST_UNSET_ZZZ}!", environment: environment), "!")
        XCTAssertEqual(MCPClientConfig.expandEnv("no vars here", environment: environment), "no vars here")
    }

    // Codex hardening: cleartext http + auth headers is refused (token would go over the wire) UNLESS
    // the host is loopback (a local server, never leaves the machine).
    func testConfig_cleartextHttpWithAuthRejected() throws {
        try writeConfig(#"{"mcpServers":{"x":{"url":"http://example.com/mcp","headers":{"Authorization":"Bearer t"}}}}"#)
        let (servers, issues) = MCPClientConfig.load(
            projectRoot: dir, allowProjectConfig: true, includeUserConfig: false,
            hostEnvironment: [:], ssrfBlockReason: { _ in nil })
        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(issues.contains { $0.reason.contains("cleartext") })
    }

    func testConfig_httpsResolutionFailureFailsClosed() throws {
        try writeConfig(#"{"mcpServers":{"x":{"url":"https://example.com/mcp"}}}"#)
        let (servers, issues) = MCPClientConfig.load(
            projectRoot: dir, allowProjectConfig: true, includeUserConfig: false,
            hostEnvironment: [:], ssrfBlockReason: { _ in "DNS unavailable" })
        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(issues.contains { $0.reason.contains("DNS unavailable") })
    }

    func testConfig_loopbackHttpWithAuthAllowed() throws {
        try writeConfig(#"{"mcpServers":{"local":{"url":"http://127.0.0.1:9000/mcp","headers":{"Authorization":"Bearer t"}}}}"#)
        let (servers, _) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertEqual(servers.count, 1)          // a user's local server is fine
        XCTAssertTrue(servers[0].isHTTP)
    }

    // DeepSeek H1: an untrusted remote tool NAME (bidi/control chars) must be sanitized before it
    // becomes the model-facing tool id.
    func testRemoteToolNameSanitized() {
        let spec = RemoteToolSpec(name: "evil\u{202E}drop\u{0007}", description: "d", inputSchema: [:])
        let tool = RemoteMCPTool(serverName: "srv", spec: spec, manager: MCPClientManager())
        XCTAssertFalse(tool.name.contains("\u{202E}"), "bidi override must be stripped from the tool name")
        XCTAssertFalse(tool.name.contains("\u{0007}"), "control char must be stripped")
        XCTAssertTrue(tool.name.hasPrefix("srv"))
    }

    func testIsLoopbackHost() {
        XCTAssertTrue(MCPClientConfig.isLoopbackHost("localhost"))
        XCTAssertTrue(MCPClientConfig.isLoopbackHost("127.0.0.1"))
        XCTAssertTrue(MCPClientConfig.isLoopbackHost("127.5.5.5"))
        XCTAssertTrue(MCPClientConfig.isLoopbackHost("::1"))
        XCTAssertFalse(MCPClientConfig.isLoopbackHost("api.example.com"))
        XCTAssertFalse(MCPClientConfig.isLoopbackHost("169.254.169.254"))
    }

    // SSE parser: multi-line data events + string-typed JSON-RPC ids both resolve.
    func testHTTPSSEMultiLineAndStringId() {
        // Two data: lines (column 0) concatenated into one JSON object with a STRING id.
        let sse = "data: {\"jsonrpc\":\"2.0\",\ndata: \"id\":\"5\",\"result\":{\"ok\":true}}\n\n".data(using: .utf8)!
        let m = MCPHTTPConnection.matchingSSEMessage(sse, id: 5)
        XCTAssertNotNil(m, "should join multi-line data and match a string id")
        XCTAssertNotNil(m?["result"] as? [String: Any])
    }

    func testConfig_unsafeServerNameRejected() throws {
        try writeConfig(#"{"mcpServers":{"bad name!":{"command":"/bin/sh"}}}"#)
        let (servers, issues) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertTrue(servers.isEmpty)
        XCTAssertTrue(issues.contains { $0.reason.contains("safe identifier") })
    }

    func testConfig_validStdioServerAccepted() throws {
        let sh = FileManager.default.fileExists(atPath: "/bin/sh") ? "/bin/sh" : "/bin/bash"
        try writeConfig(#"{"mcpServers":{"echo":{"command":"\#(sh)","args":["-c","echo hi"]}}}"#)
        let (servers, _) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.name, "echo")
        XCTAssertEqual(servers.first?.command, sh)
    }

    func testConfig_computerUseMetadataSupportsDedicatedAndMixedServers() throws {
        let executable = FileManager.default.fileExists(atPath: "/bin/echo") ? "/bin/echo" : "/usr/bin/true"
        try writeConfig("""
        {"mcpServers":{
          "control":{"command":"\(executable)","computerUse":true},
          "lsp":{"command":"\(executable)","computerUse":false},
          "mixed":{"command":"\(executable)","computerUseTools":["vm_control","vm_launch"]}
        }}
        """)
        let (servers, issues) = MCPClientConfig.load(
            projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertTrue(issues.isEmpty, issues.map(\.reason).joined(separator: "; "))
        let policies = Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0.computerUsePolicy) })
        XCTAssertEqual(policies["control"], .allTools)
        XCTAssertEqual(policies["lsp"], .noTools)
        XCTAssertEqual(policies["mixed"], .selectedTools(["vm_control", "vm_launch"]))
        XCTAssertEqual(policies["mixed"]?.explicitRequirement(for: "vm_control"), true)
        XCTAssertNil(policies["mixed"]?.explicitRequirement(for: "unknown_future_tool"),
                     "unlisted mixed-server tools must retain heuristic defense in depth")
    }

    func testConfig_malformedComputerUseMetadataRejectsServerFailClosed() throws {
        let executable = FileManager.default.fileExists(atPath: "/bin/echo") ? "/bin/echo" : "/usr/bin/true"
        let invalidEntries = [
            "\"computerUse\":\"yes\"",
            "\"computerUse\":1",
            "\"computerUseTools\":\"vm_control\"",
            "\"computerUseTools\":[\"vm_control\",\"vm_control\"]",
            "\"computerUse\":true,\"computerUseTools\":[\"vm_control\"]",
            "\"computerUseTools\":[\"\"]",
        ]
        for invalid in invalidEntries {
            try writeConfig("{\"mcpServers\":{\"bad\":{\"command\":\"\(executable)\",\(invalid)}}}")
            let (servers, issues) = MCPClientConfig.load(
                projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
            XCTAssertTrue(servers.isEmpty, "malformed metadata must not leave a runnable server: \(invalid)")
            XCTAssertTrue(issues.contains { $0.server == "bad" }, "missing issue for: \(invalid)")
        }
    }

    func testConfig_secretEnvKeyWarnsButAccepts() throws {
        let sh = FileManager.default.fileExists(atPath: "/bin/sh") ? "/bin/sh" : "/bin/bash"
        try writeConfig(#"{"mcpServers":{"gh":{"command":"\#(sh)","env":{"GITHUB_TOKEN":"abc"}}}}"#)
        let (servers, issues) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertEqual(servers.count, 1)
        XCTAssertTrue(issues.contains { $0.reason.contains("looks like a secret") })
    }

    func testResolvedEnvironment_dropsHostSecretsKeepsAllowlist() {
        let cfg = MCPServerConfig(name: "x", command: "/bin/sh", args: [], env: ["OWN": "1"])
        let env = MCPClientConfig.resolvedEnvironment(
            for: cfg,
            hostEnvironment: [
                "PATH": "/usr/bin",
                "SNEAKY_API_KEY": "should-not-pass"
            ])
        XCTAssertEqual(env["OWN"], "1")               // explicit config env passes
        XCTAssertNotNil(env["PATH"])                  // allowlisted host var passes
        XCTAssertNil(env["SNEAKY_API_KEY"])           // non-allowlisted host secret dropped
    }

    // MARK: - Output sanitizer (trust boundary)

    func testSanitizer_stripsControlAndZeroWidthKeepsWhitespace() {
        let dirty = "ok\u{1B}[31mRED\u{0007}\u{200B}\tline\nnext"
        let clean = MCPOutputSanitizer.sanitize(dirty)
        XCTAssertFalse(clean.contains("\u{1B}"))      // ANSI ESC stripped
        XCTAssertFalse(clean.contains("\u{0007}"))    // BEL stripped
        XCTAssertFalse(clean.contains("\u{200B}"))    // zero-width stripped
        XCTAssertTrue(clean.contains("\t"))           // tab kept
        XCTAssertTrue(clean.contains("\n"))           // newline kept
        XCTAssertTrue(clean.contains("RED"))
    }

    func testSanitizer_boundsBySize() {
        let huge = String(repeating: "a", count: MCPOutputSanitizer.maxBytes + 5000)
        let clean = MCPOutputSanitizer.sanitize(huge)
        XCTAssertTrue(clean.utf8.count <= MCPOutputSanitizer.maxBytes + 100)  // + truncation note
        XCTAssertTrue(clean.contains("truncated"))
    }

    func testSanitizer_extractUsesStructuredIsErrorNotText() {
        let result: [String: Any] = ["content": [["type": "text", "text": "OK"]], "isError": true]
        let (text, isError) = MCPOutputSanitizer.extract(from: result)
        XCTAssertEqual(text, "OK")
        XCTAssertTrue(isError)   // honored the structured flag, not the spoofable "OK" text
    }

    func testSanitizer_preservesValidatedImageOutsideModelVisibleText() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let base64 = png.base64EncodedString()
        let result: [String: Any] = ["content": [
            ["type": "text", "text": "fresh frame"],
            ["type": "image", "mimeType": "image/png", "data": base64],
        ]]

        let extracted = MCPOutputSanitizer.extractContent(from: result)

        XCTAssertEqual(extracted.attachments.count, 1)
        XCTAssertEqual(extracted.attachments.first?.inlineData, png)
        XCTAssertEqual(extracted.attachments.first?.mimeType, "image/png")
        XCTAssertTrue(extracted.text.contains("fresh frame"))
        XCTAssertTrue(extracted.text.contains("[image attached: image/png, 9 bytes]"))
        XCTAssertFalse(extracted.text.contains(base64), "base64 must never enter model-visible text")
    }

    func testSanitizer_rejectsInvalidUnsupportedAndMismatchedImages() {
        let jpegHeader = Data([0xFF, 0xD8, 0xFF, 0x01]).base64EncodedString()
        let result: [String: Any] = ["content": [
            ["type": "image", "mimeType": "image/png", "data": "not base64!"],
            ["type": "image", "mimeType": "image/svg+xml", "data": "PHN2Zz4="],
            ["type": "image", "mimeType": "image/png", "data": jpegHeader],
        ]]

        let extracted = MCPOutputSanitizer.extractContent(from: result)

        XCTAssertTrue(extracted.attachments.isEmpty)
        XCTAssertTrue(extracted.text.contains("invalid base64 data"))
        XCTAssertTrue(extracted.text.contains("unsupported MIME type"))
        XCTAssertTrue(extracted.text.contains("payload does not match MIME type"))
    }

    func testSanitizer_boundsImageCountAndDecodedBytes() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let smallBlock: [String: Any] = [
            "type": "image", "mimeType": "image/png", "data": png.base64EncodedString(),
        ]
        let countResult = MCPOutputSanitizer.extractContent(from: [
            "content": Array(repeating: smallBlock, count: MCPOutputSanitizer.maxImages + 1),
        ])
        XCTAssertEqual(countResult.attachments.count, MCPOutputSanitizer.maxImages)
        XCTAssertTrue(countResult.text.contains("image-count limit exceeded"))

        var oversized = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        oversized.append(Data(repeating: 0, count: MCPOutputSanitizer.maxImageBytes))
        let byteResult = MCPOutputSanitizer.extractContent(from: ["content": [[
            "type": "image", "mimeType": "image/png", "data": oversized.base64EncodedString(),
        ]]])
        XCTAssertTrue(byteResult.attachments.isEmpty)
        XCTAssertTrue(byteResult.text.contains("decoded-byte limit exceeded"))
    }

    func testManager_carriesSanitizedImageIntoToolResultAttachments() async {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01])
        let config = MCPServerConfig(name: "vision", command: "/bin/echo")
        let connection = ImageResultMCPConnection(config: config, rawResult: ["content": [[
            "type": "image", "mimeType": "image/jpeg", "data": jpeg.base64EncodedString(),
        ]]])
        let manager = MCPClientManager(
            serversForTesting: [config], connectionFactory: { _ in connection })
        _ = await manager.discoverAndWrapTools(projectRoot: dir)

        let result = await manager.call(server: "vision", tool: "snapshot", arguments: [:])
        await manager.shutdownAll()

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.attachments.first?.inlineData, jpeg)
        XCTAssertFalse(result.output.contains(jpeg.base64EncodedString()))
    }

    // MARK: - RemoteMCPTool schema mapping

    func testRemoteTool_schemaToParameters() {
        let schema: [String: Any] = [
            "properties": [
                "query": ["type": "string", "description": "the query"],
                "limit": ["type": "integer", "description": "max"],
            ],
            "required": ["query"],
        ]
        let params = RemoteMCPTool.parameters(from: schema).sorted { $0.name < $1.name }
        XCTAssertEqual(params.map(\.name), ["limit", "query"])
        XCTAssertEqual(params.first { $0.name == "query" }?.required, true)
        XCTAssertEqual(params.first { $0.name == "limit" }?.required, false)
        XCTAssertEqual(params.first { $0.name == "limit" }?.type, "integer")
    }

    func testRemoteTool_namespacing() async {
        let manager = MCPClientManager()
        let spec = RemoteToolSpec(name: "search", description: "find things", inputSchema: [:])
        let tool = RemoteMCPTool(serverName: "github", spec: spec, manager: manager)
        XCTAssertEqual(tool.name, "github__search")
        XCTAssertTrue(tool.description.contains("external MCP server 'github'"))
    }

    func testManager_callUnknownServerIsFailure() async {
        let manager = MCPClientManager()
        let r = await manager.call(server: "nope", tool: "x", arguments: [:])
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("not connected"))
    }

    // MARK: - Codex CRITICAL #1 regression: project-local .mcp.json is NOT auto-loaded

    func testConfig_projectLocalNotLoadedByDefault() throws {
        // A repo-dropped .mcp.json must be IGNORED unless explicitly trusted, else a
        // checked-out repo is an RCE primitive.
        let sh = FileManager.default.fileExists(atPath: "/bin/sh") ? "/bin/sh" : "/bin/bash"
        try writeConfig(#"{"mcpServers":{"evil":{"command":"\#(sh)","args":["-c","echo pwned"]}}}"#)
        XCTAssertFalse(MCPClientConfig.candidatePaths(projectRoot: dir).contains(dir + "/.mcp.json"))
        let (servers, _) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: false, includeUserConfig: false)
        XCTAssertFalse(servers.contains { $0.name == "evil" }, "project-local server must not load by default")
    }

    func testConfig_projectLocalLoadedOnlyWhenTrusted() throws {
        let sh = FileManager.default.fileExists(atPath: "/bin/sh") ? "/bin/sh" : "/bin/bash"
        try writeConfig(#"{"mcpServers":{"trusted":{"command":"\#(sh)","args":["-c","echo ok"]}}}"#)
        XCTAssertTrue(MCPClientConfig.candidatePaths(projectRoot: dir, allowProjectConfig: true).contains(dir + "/.mcp.json"))
        let (servers, _) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertTrue(servers.contains { $0.name == "trusted" })
    }

    // MARK: - toolEffects: the owner's per-tool effect declaration (bio-scientist audit fix, 2026-09-18)

    func testConfig_toolEffectsReadOnlyDeclarationParsed() throws {
        let sh = FileManager.default.fileExists(atPath: "/bin/sh") ? "/bin/sh" : "/bin/bash"
        try writeConfig(#"{"mcpServers":{"bio":{"command":"\#(sh)","toolEffects":{"pubmed_search":"readOnly","uniprot_entry":"readOnly","run_python":"projectMutation"}}}}"#)
        let (servers, issues) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertTrue(issues.isEmpty, "\(issues)")
        let bio = servers.first { $0.name == "bio" }
        XCTAssertEqual(bio?.declaredReadOnlyTools, ["pubmed_search", "uniprot_entry"],
                       "only readOnly declarations grant admission; projectMutation is documentation")
    }

    func testConfig_toolEffectsAbsentMeansNoDeclarations() throws {
        let sh = FileManager.default.fileExists(atPath: "/bin/sh") ? "/bin/sh" : "/bin/bash"
        try writeConfig(#"{"mcpServers":{"bare":{"command":"\#(sh)"}}}"#)
        let (servers, _) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertEqual(servers.first { $0.name == "bare" }?.declaredReadOnlyTools, [],
                       "no toolEffects map -> every tool defaults to effectful (fail-closed)")
    }

    func testConfig_toolEffectsUnknownEffectRejectedLoudly() throws {
        // A typo like "readonly" would fail closed SILENTLY (tool just never exposed) - reject the
        // entry instead so the misconfiguration is visible.
        let sh = FileManager.default.fileExists(atPath: "/bin/sh") ? "/bin/sh" : "/bin/bash"
        try writeConfig(#"{"mcpServers":{"typo":{"command":"\#(sh)","toolEffects":{"pubmed_search":"readonly"}}}}"#)
        let (servers, issues) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertFalse(servers.contains { $0.name == "typo" })
        XCTAssertTrue(issues.contains { $0.server == "typo" && $0.reason.contains("unknown effect") })
    }

    func testConfig_toolEffectsWrongShapeRejected() throws {
        let sh = FileManager.default.fileExists(atPath: "/bin/sh") ? "/bin/sh" : "/bin/bash"
        try writeConfig(#"{"mcpServers":{"bad":{"command":"\#(sh)","toolEffects":["pubmed_search"]}}}"#)
        let (servers, issues) = MCPClientConfig.load(projectRoot: dir, allowProjectConfig: true, includeUserConfig: false)
        XCTAssertFalse(servers.contains { $0.name == "bad" })
        XCTAssertTrue(issues.contains { $0.server == "bad" && $0.reason.contains("toolEffects") })
    }

    // MARK: - Codex MED regression: sanitizer strips \r and bidi-override format chars

    func testSanitizer_stripsCarriageReturnAndBidi() {
        let dirty = "safe\rHIDDEN\u{202E}reversed\u{2066}iso"
        let clean = MCPOutputSanitizer.sanitize(dirty)
        XCTAssertFalse(clean.contains("\r"))
        XCTAssertFalse(clean.unicodeScalars.contains { $0.value == 0x202E })  // RTL override
        XCTAssertFalse(clean.unicodeScalars.contains { $0.value == 0x2066 })  // LTR isolate
        XCTAssertTrue(clean.contains("safe"))
        XCTAssertTrue(clean.contains("reversed"))
    }

    // MARK: - Dogfood regression: server stderr must not flood the REPL by default

    /// A chatty server (e.g. lsp-swift logging "received diagnostics for <file>" per file)
    /// was flooding every kist turn because serverStderr emitted unconditionally. Server
    /// stderr is diagnostic-only (protocol is on stdout; failures surface via warn/error),
    /// so it is gated behind verbose. Non-verbose ⇒ nothing emitted.
    func testServerStderr_suppressedUnlessVerbose() {
        XCTAssertNil(MCPLog.serverStderrLine(server: "lsp-swift",
                                             text: "received diagnostics for file:///x.swift",
                                             verbose: false))
        let line = MCPLog.serverStderrLine(server: "lsp-swift",
                                           text: "received diagnostics for file:///x.swift",
                                           verbose: true)
        XCTAssertEqual(line, "[mcp STDERR] [lsp-swift] received diagnostics for file:///x.swift\n")
    }

    /// Untrusted stderr stays bounded (2 KB) even when shown, so a hostile server
    /// can't blow out the log with one giant line.
    func testServerStderr_boundedWhenVerbose() {
        let huge = String(repeating: "A", count: 5000)
        let line = MCPLog.serverStderrLine(server: "evil", text: huge, verbose: true)
        XCTAssertNotNil(line)
        // "[mcp STDERR] [evil] " prefix + 2 KiB payload + bounded truncation marker + "\n"
        XCTAssertEqual(line?.filter { $0 == "A" }.count, 2 * 1024)
        XCTAssertTrue(line?.contains("…[truncated]") == true)
        XCTAssertLessThan(line?.utf8.count ?? .max, 2 * 1024 + 256)
    }

    func testMCPLogSanitizer_handlesUnicodeC1StringTerminatorsAndByteBoundary() {
        let dirty = "before"
            + "\u{009D}hidden-osc\u{009C}"
            + "middle"
            + "\u{0090}hidden-dcs\u{009C}"
            + "after\u{202E}\u{2066}\u{FEFF}"
        XCTAssertEqual(
            MCPLog.sanitizedDiagnosticForTesting(dirty),
            "beforemiddleafter"
        )

        let splitScalar = String(repeating: "A", count: 7) + "🙂tail"
        let bounded = MCPLog.sanitizedDiagnosticForTesting(splitScalar, byteLimit: 9)
        XCTAssertTrue(bounded.hasPrefix("AAAAAAA\u{FFFD}"))
        XCTAssertTrue(bounded.hasSuffix("…[truncated]"))
        XCTAssertFalse(bounded.contains("tail"))
    }

    /// Codex (a): gating the live stream mustn't erase the failure diagnosis. The connection keeps a
    /// bounded stderr tail that a spawn/handshake/close failure surfaces, so a fatal server message
    /// isn't a silent dark spot. Pin: the buffer keeps the LAST bytes and stays bounded.
    func testStderrTail_keepsBoundedRecentBytes() {
        let tail = MCPStderrTail()
        tail.append("missing API key\n")
        XCTAssertTrue(tail.snapshot().contains("missing API key"))
        tail.append(String(repeating: "Z", count: 5000))
        let snap = tail.snapshot()
        XCTAssertLessThanOrEqual(snap.count, 2000, "tail stays bounded")
        XCTAssertTrue(snap.hasSuffix("Z"), "keeps the most-recent bytes")
        XCTAssertFalse(snap.contains("missing API key"), "old bytes evicted once past the cap")
    }
}

private actor ImageResultMCPConnection: MCPConnection {
    nonisolated let config: MCPServerConfig
    private let rawResult: [String: Any]
    private var alive = false

    init(config: MCPServerConfig, rawResult: [String: Any]) {
        self.config = config
        self.rawResult = rawResult
    }

    var isAlive: Bool { alive }

    func start() { alive = true }
    func listTools() -> [RemoteToolSpec] { [] }
    func callTool(name: String, arguments: [String: Any], correlationID: String?) -> [String: Any] {
        rawResult
    }
    func shutdown() { alive = false }
}
