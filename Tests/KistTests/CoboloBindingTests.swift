import XCTest
import AgentCore
@testable import Kist

final class CoboloBindingTests: XCTestCase {
    private let source = "       IDENTIFICATION DIVISION.\n       PROGRAM-ID. HELLO.\n"
    private let endpoint = "http://127.0.0.1:11434"
    private let model = "cobol-jeeves-ft:latest"

    private func generationMetadata() -> [String: String] {
        [
            "provider": "cobol", "model": model, "offline": "true", "endpoint": endpoint,
            "source_sha256": BuilderEvidenceDigest.sha256(source), "compiled": "false",
            "ran": "false", "expect_met": "false"
        ]
    }

    func testCanonicalNumericLoopbackEndpointRejectsHostnames() throws {
        XCTAssertEqual(try KistRunner.coboloLocalOllamaEndpoint(environment: [:]), endpoint)
        XCTAssertEqual(try KistRunner.coboloLocalOllamaEndpoint(
            environment: ["OLLAMA_HOST": "http://[::1]:11434"]), "http://[::1]:11434")
        for value in ["http://localhost:11434", "http://ollama:11434", "http://192.168.1.2:11434"] {
            XCTAssertThrowsError(try KistRunner.coboloLocalOllamaEndpoint(
                environment: ["OLLAMA_HOST": value]))
        }
    }

    func testGenerationMetadataEveryBindingIsExact() throws {
        XCTAssertEqual(try KistRunner.coboloValidatedGeneratedSource(
            success: true, output: source, error: nil, metadata: generationMetadata(),
            expectedModel: model, endpoint: endpoint), Data(source.utf8))
        let invalid: [(String, String)] = [
            ("provider", "ollama"), ("model", "other"), ("offline", "false"),
            ("endpoint", "http://[::1]:11434"), ("source_sha256", String(repeating: "0", count: 64)),
            ("compiled", "true"), ("ran", "true"), ("expect_met", "true")
        ]
        for (key, value) in invalid {
            var metadata = generationMetadata(); metadata[key] = value
            XCTAssertThrowsError(try KistRunner.coboloValidatedGeneratedSource(
                success: true, output: source, error: nil, metadata: metadata,
                expectedModel: model, endpoint: endpoint), "accepted mismatched \(key)")
        }
    }

    func testGenerationSourceCapIsEnforcedBeforeWrite() {
        let oversized = String(repeating: "X", count: KistRunner.coboloMaxAcceptedSourceBytes + 1)
        var metadata = generationMetadata(); metadata["source_sha256"] = BuilderEvidenceDigest.sha256(oversized)
        XCTAssertThrowsError(try KistRunner.coboloValidatedGeneratedSource(
            success: true, output: oversized, error: nil, metadata: metadata,
            expectedModel: model, endpoint: endpoint))
    }

    func testSemanticVerdictEveryBindingIsExact() throws {
        let expected: [String: String] = [
            "contract_id": "contract", "candidate_sha256": "candidate",
            "compile_evidence_digest": "compile", "run_evidence_digest": "run",
            "decision": "APPROVE", "reason": "bound"
        ]
        let valid = String(data: try JSONSerialization.data(withJSONObject: expected,
                                                            options: [.sortedKeys]), encoding: .utf8)!
        XCTAssertTrue(try KistRunner.coboloSemanticReceipt(
            responseText: valid, actualIdentity: "gemini:critic", expectedIdentity: "gemini:critic",
            contractID: "contract", candidateSHA256: "candidate",
            compileEvidenceDigest: "compile", runEvidenceDigest: "run").approved)
        for key in ["contract_id", "candidate_sha256", "compile_evidence_digest", "run_evidence_digest"] {
            var invalid = expected; invalid[key] = "wrong"
            let text = String(data: try JSONSerialization.data(withJSONObject: invalid), encoding: .utf8)!
            XCTAssertThrowsError(try KistRunner.coboloSemanticReceipt(
                responseText: text, actualIdentity: "gemini:critic", expectedIdentity: "gemini:critic",
                contractID: "contract", candidateSHA256: "candidate",
                compileEvidenceDigest: "compile", runEvidenceDigest: "run"), "accepted mismatched \(key)")
        }
        XCTAssertThrowsError(try KistRunner.coboloSemanticReceipt(
            responseText: valid, actualIdentity: "openai:critic", expectedIdentity: "gemini:critic",
            contractID: "contract", candidateSHA256: "candidate",
            compileEvidenceDigest: "compile", runEvidenceDigest: "run"))
    }

    func testPromotionVerdictEveryBindingIsExact() throws {
        let expected: [String: String] = [
            "contract_id": "contract", "candidate_sha256": "candidate",
            "semantic_receipt_digest": "semantic", "verification_digest": "verification",
            "decision": "APPROVE", "reason": "bound"
        ]
        let valid = String(data: try JSONSerialization.data(withJSONObject: expected,
                                                            options: [.sortedKeys]), encoding: .utf8)!
        XCTAssertTrue(try KistRunner.coboloPromotionReceipt(
            responseText: valid, actualIdentity: "openai:reviewer", expectedIdentity: "openai:reviewer",
            contractID: "contract", candidateSHA256: "candidate",
            semanticReceiptDigest: "semantic", verificationDigest: "verification").approved)
        for key in ["contract_id", "candidate_sha256", "semantic_receipt_digest", "verification_digest"] {
            var invalid = expected; invalid[key] = "wrong"
            let text = String(data: try JSONSerialization.data(withJSONObject: invalid), encoding: .utf8)!
            XCTAssertThrowsError(try KistRunner.coboloPromotionReceipt(
                responseText: text, actualIdentity: "openai:reviewer", expectedIdentity: "openai:reviewer",
                contractID: "contract", candidateSHA256: "candidate",
                semanticReceiptDigest: "semantic", verificationDigest: "verification"),
                "accepted mismatched \(key)")
        }
        XCTAssertThrowsError(try KistRunner.coboloPromotionReceipt(
            responseText: valid, actualIdentity: "gemini:reviewer", expectedIdentity: "openai:reviewer",
            contractID: "contract", candidateSHA256: "candidate",
            semanticReceiptDigest: "semantic", verificationDigest: "verification"))
    }

    func testBudgetDenialOccursBeforeModelWork() async {
        let budget = BudgetLedger(maxTokens: 1)
        do {
            _ = try await KistRunner.coboloReserveBudget(
                budget, providerID: "gemini", prompt: "nonempty prompt",
                maximumCompletionTokens: 800)
            XCTFail("budget reservation unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("budget denied"))
        }
        let spent = await budget.spentTokens()
        XCTAssertEqual(spent, 0)
    }
}
