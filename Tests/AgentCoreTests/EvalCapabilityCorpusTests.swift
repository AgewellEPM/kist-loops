import XCTest
@testable import AgentCore

/// P0.5 — the capability-exercising corpus is a SEPARATE held-out set from the golden regression suite, so
/// the ablation oracle can measure compounding on a surface where accumulated state can actually help.
final class EvalCapabilityCorpusTests: XCTestCase {

    private func tmpRootWith(golden: String?, capability: String?) -> String {
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("kist-corpus-\(UUID().uuidString)")
        let evalDir = (root as NSString).appendingPathComponent(".kist/eval")
        try? FileManager.default.createDirectory(atPath: evalDir, withIntermediateDirectories: true)
        if let golden { try? golden.write(toFile: (evalDir as NSString).appendingPathComponent("suite.json"), atomically: true, encoding: .utf8) }
        if let capability { try? capability.write(toFile: (evalDir as NSString).appendingPathComponent("capability-suite.json"), atomically: true, encoding: .utf8) }
        return root
    }

    func testCapabilityCorpusLoadsFromItsOwnFile() {
        let root = tmpRootWith(
            golden: #"[{"name":"golden-custom","prompt":"g","assertions":["healthy"]}]"#,
            capability: #"[{"name":"cap-uses-tool","prompt":"use the tool","assertions":[{"contains":"20"}]}]"#)
        let capNames = Set(EvalGoldenSuite.capabilityCases(projectRoot: root).map { $0.name })
        let goldNames = Set(EvalGoldenSuite.cases(projectRoot: root).map { $0.name })
        // The capability corpus has ONLY its own cases (empty built-in + capability-suite.json), NOT golden's.
        XCTAssertTrue(capNames.contains("cap-uses-tool"))
        XCTAssertFalse(capNames.contains("golden-custom"), "capability corpus must not include the golden suite")
        XCTAssertFalse(capNames.contains("answers-directly"), "capability corpus has an empty built-in")
        // The golden suite is unchanged — its built-ins + its own custom, NOT the capability cases.
        XCTAssertTrue(goldNames.contains("golden-custom"))
        XCTAssertTrue(goldNames.contains("answers-directly"))
        XCTAssertFalse(goldNames.contains("cap-uses-tool"), "golden suite must not include the capability corpus")
    }

    func testEmptyCapabilityCorpusWhenUnseeded() {
        let root = tmpRootWith(golden: nil, capability: nil)
        XCTAssertTrue(EvalGoldenSuite.capabilityCases(projectRoot: root).isEmpty,
                      "unseeded capability corpus is empty (built-in is intentionally empty) — /ablation capability reports so honestly")
    }

    // The oracle's disjointness guard still governs the capability corpus (held-out ∩ warm-training = ∅).
    func testCapabilityCorpusRespectsDisjointnessGuard() {
        let root = tmpRootWith(golden: nil,
            capability: #"[{"name":"shared-id","prompt":"p","assertions":["healthy"]}]"#)
        let ids = EvalGoldenSuite.capabilityCases(projectRoot: root).map { $0.name }
        // If a capability case id also fed the warm state, the ablation must refuse (contamination).
        XCTAssertFalse(AblationHarness.heldOutIsClean(heldOut: Set(ids), accumulatedFrom: ["shared-id"]))
        XCTAssertTrue(AblationHarness.heldOutIsClean(heldOut: Set(ids), accumulatedFrom: ["something-else"]))
    }
}
