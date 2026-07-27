import XCTest
@testable import AgentCore

final class SecretMaskerTests: XCTestCase {

    func testMasksCommonProviderKeysAndAssignments() {
        let raw = """
        openai=sk-proj-abcdefghijklmnopqrstuvwxyz123456
        github ghp_abcdefghijklmnopqrstuvwxyz123456
        x-api-key: abcdefghijklmnopqrstuvwxyz
        google AIzaabcdefghijklmnopqrstuvwxyz123456
        """

        let masked = SecretMasker.mask(raw)

        XCTAssertFalse(masked.contains("sk-proj-abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertFalse(masked.contains("ghp_abcdefghijklmnopqrstuvwxyz123456"))
        XCTAssertFalse(masked.contains("abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(masked.contains(SecretMasker.marker))
        XCTAssertTrue(masked.contains("api-key=\(SecretMasker.marker)"))
    }

    func testDoesNotRedactSwiftAPIKeyParameterSignatures() {
        let source = "func stream(messages: [ChatMessage], apiKey: String?) async throws"
        let masked = SecretMasker.mask(source)
        XCTAssertEqual(masked, source)
        XCTAssertFalse(masked.contains(SecretMasker.marker))
    }

    func testMasksAWSAccessKeys() {
        let raw = "aws AKIAIOSFODNN7EXAMPLE session ASIAIOSFODNN7EXAMPLE"
        let masked = SecretMasker.mask(raw)
        XCTAssertFalse(masked.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertFalse(masked.contains("ASIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(masked.contains(SecretMasker.marker))
    }

    /// Table-driven coverage for the higher-severity shapes added in the pattern audit. Each secret
    /// must be fully redacted (its literal value gone) and the marker present.
    func testMasksHighSeveritySecretShapes() {
        let secrets: [(label: String, value: String)] = [
            ("jwt",           "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"),
            ("slack_bot",     "xoxb-1234567890-abcdefghijklmnop"),
            ("stripe_live",   "sk_live_abcdef1234567890ABCDEF"),
            ("stripe_test_rk","rk_test_abcdef1234567890ABCDEF"),
            ("google_oauth",  "GOCSPX-abcdef1234567890ABCDEF"),
            ("npm",           "npm_abcdefghijklmnopqrstuvwxyz0123456789"),
            ("slack_webhook", "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"),
        ]
        for s in secrets {
            let masked = SecretMasker.mask("value: \(s.value) end")
            XCTAssertFalse(masked.contains(s.value), "\(s.label) leaked: \(masked)")
            XCTAssertTrue(masked.contains(SecretMasker.marker), "\(s.label) not masked")
        }
    }

    /// PEM private-key blocks (multiline) must be redacted whole — key material is catastrophic to leak.
    func testMasksPEMPrivateKeyBlock() {
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAxKQ1abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH
        aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899
        -----END RSA PRIVATE KEY-----
        """
        let masked = SecretMasker.mask("here is a key:\n\(pem)\ndone")
        XCTAssertFalse(masked.contains("MIIEowIBAAKCAQEAxKQ1"), "PEM body leaked")
        XCTAssertFalse(masked.contains("BEGIN RSA PRIVATE KEY"), "PEM header leaked")
        XCTAssertTrue(masked.contains(SecretMasker.marker))
        XCTAssertTrue(masked.contains("here is a key:"), "surrounding text preserved")
        XCTAssertTrue(masked.contains("done"))
    }

    /// Guard against false positives: ordinary base64/hex-ish text and identifiers stay intact.
    func testDoesNotOverRedactBenignText() {
        for benign in ["the quick brown fox jumps over 1234567890",
                       "commit a1b2c3d4e5f6 fixed the bug",
                       "npm install left-pad@1.3.0",
                       // source referencing private_key / client_secret identifiers must NOT be redacted
                       "let privateKey = SecKeyCreateRandomKey(attributes, &error)",
                       "func load(clientSecret: String) -> ClientSecretProvider"] {
            XCTAssertEqual(SecretMasker.mask(benign), benign, "over-redacted: \(benign)")
        }
    }

    func testToolRegistryMasksToolOutputErrorAndMetadata() async {
        let result = await ToolRegistry([SecretEchoTool()]).execute(
            name: "secret_echo",
            arguments: [:],
            context: ToolContext(projectRoot: NSTemporaryDirectory())
        )

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.output.contains("sk-test-abcdefghijklmnopqrstuvwxyz"))
        XCTAssertFalse(result.error?.contains("ghp_abcdefghijklmnopqrstuvwxyz123456") ?? false)
        XCTAssertFalse(result.metadata["token"]?.contains("AIzaabcdefghijklmnopqrstuvwxyz123456") ?? false)
        XCTAssertTrue(result.output.contains(SecretMasker.marker))
        XCTAssertEqual(result.metadata["token"], SecretMasker.marker)
    }
}

private struct SecretEchoTool: AgentTool {
    let name = "secret_echo"
    let description = "Return secrets for redaction tests."
    let parameters: [ToolParameter] = []

    func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        ToolResult(
            success: true,
            output: "token sk-test-abcdefghijklmnopqrstuvwxyz",
            error: "ghp_abcdefghijklmnopqrstuvwxyz123456",
            metadata: ["token": "AIzaabcdefghijklmnopqrstuvwxyz123456"]
        )
    }
}
