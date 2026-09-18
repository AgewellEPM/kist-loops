import XCTest

/// Per-site pins for the 0.17.25 hardcoded-fallback sweep (multi-site fix discipline:
/// one assertion per file/site, so a regressed site names itself instead of re-deriving
/// the audit). Source-text pins, deliberately: the invariant is "this literal does not
/// come back / this override stays wired", which is a property of the source itself.
final class HardcodedFallbackRegressionTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // KistTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    // Site: local-model attestation PATH fallback — was the ONLY /Users/<name> literal in Sources.
    func testAttestationPathFallbackDerivesHomeDynamically() throws {
        let src = try source("Sources/Kist/UX/OrganizationalLearningStore+LocalModelAttestation.swift")
        XCTAssertFalse(src.contains("/Users/lukekist"),
                       "user-specific home literal reintroduced in attestation PATH fallback")
        XCTAssertTrue(src.contains("NSHomeDirectory())/bin"),
                      "PATH fallback must derive the home bin dir dynamically")
    }

    // Site: BYOK Anthropic API path (claude-cli is a separate provider and never uses this endpoint).
    func testAnthropicEndpointHonorsOverride() throws {
        let src = try source("Sources/AgentCore/Providers/AnthropicProvider.swift")
        XCTAssertTrue(src.contains("ANTHROPIC_API_URL"),
                      "AnthropicProvider must honor ANTHROPIC_API_URL")
    }

    // Site: bare /code default coder binding.
    func testCoderDefaultHonorsOverride() throws {
        let src = try source("Sources/Kist/KistREPL+Commands.swift")
        XCTAssertTrue(src.contains("KIST_CODER_DEFAULT"),
                      "bare /code must consult KIST_CODER_DEFAULT before the shipped default")
    }

    // Sites (2): fetchOllama request URL + the sourceURL recorded in the metadata it returns.
    func testOllamaMetadataGateHonorsOllamaHost() throws {
        let src = try source("Sources/Kist/UX/LiveModelMetadataGate.swift")
        XCTAssertTrue(src.contains("OLLAMA_HOST"),
                      "fetchOllama must honor OLLAMA_HOST like the chat provider does")
        XCTAssertFalse(src.contains("\"http://localhost:11434/api/show\""),
                       "fetchOllama must build /api/show from the resolved host, not a literal")
    }

    // Site: FileKeyStore path when HOME is absent from the environment.
    func testKeyStoreSurvivesMissingHome() throws {
        let src = try source("Sources/AgentCore/KeyStore.swift")
        XCTAssertTrue(src.contains("NSHomeDirectory()"),
                      "FileKeyStore must not silently degrade to an empty path when HOME is unset")
    }

    // Sites: sibling API-endpoint literals outside AgentCore — same pattern, per-file pins.
    func testSiblingEndpointsHonorOverrides() throws {
        let surfaces: [(label: String, file: String, envVar: String)] = [
            ("designflow-openai", "Sources/DesignFlowKit/Services/LLMClient.swift", "OPENAI_BASE_URL"),
            ("tagteam-deepseek", "Sources/TagTeamKit/Reviewer.swift", "DEEPSEEK_BASE_URL"),
        ]
        for s in surfaces {
            let src = try source(s.file)
            XCTAssertTrue(src.contains(s.envVar),
                          "\(s.label) (\(s.file)) must honor \(s.envVar)")
        }
    }

    // Site: kist-operator Ollama health probe.
    func testOperatorHealthProbeHonorsOllamaHost() throws {
        let src = try source("scripts/kist-operator")
        XCTAssertTrue(src.contains("${OLLAMA_HOST:-"),
                      "kist-operator ollama_up must honor OLLAMA_HOST")
    }

    // Sites (2): test-harness receipt keys — literal defaults stay, but must be env-overridable.
    func testReceiptKeysAreOverridable() throws {
        let surfaces: [(label: String, file: String)] = [
            ("gauntlet", "scripts/receipt-gauntlet.sh"),
            ("smoke", "scripts/receipt-gate-smoke.sh"),
        ]
        for s in surfaces {
            let src = try source(s.file)
            XCTAssertTrue(src.contains("${KIST_RECEIPT_KEY:-"),
                          "\(s.label) (\(s.file)) must allow env override of the receipt key")
        }
    }

    // Site: shared deployment fixture temp dir. The INSTALL_HOME substitutions in the helper
    // deliberately match the production-identity pin. Follow both callers to the extracted
    // helper, then retain the original $HOME requirement at the actual mktemp site.
    func testDeploymentProtocolTempUsesHome() throws {
        for path in ["scripts/tests/kist-deployment-protocol.sh",
                     "scripts/tests/kist-resource-deployment.sh"] {
            let entry = try source(path)
            XCTAssertTrue(entry.contains("source \"$REPO_ROOT/scripts/tests/lib/deployment-fixture.sh\""),
                          "\(path) must use the shared, repository-bound deployment fixture")
            XCTAssertFalse(entry.contains("mktemp -d /Users/"),
                           "\(path) must not add a user-specific temporary directory")
        }
        let src = try source("scripts/tests/lib/deployment-fixture.sh")
        XCTAssertFalse(src.contains("mktemp -d /Users/"),
                       "deployment-protocol mktemp must use $HOME, not a literal user path")
        XCTAssertTrue(src.contains("mktemp -d \"${HOME}/.kist-release-registry-test"),
                      "deployment-protocol mktemp must template under $HOME")
    }
}
