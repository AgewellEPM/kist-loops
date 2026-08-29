import Foundation
import XCTest
@testable import AgentCore

final class EvolutionCapabilityFitnessTests: XCTestCase {
    private typealias Fixture = (
        plan: EvolutionCapabilityEvaluationPlan,
        parent: EvolutionCapabilitySubjectIdentity,
        child: EvolutionCapabilitySubjectIdentity,
        frozen: EvolutionCapabilityFrozenInputs
    )

    private func hex(_ character: Character, count: Int) -> String {
        String(repeating: String(character), count: count)
    }

    private func identity(
        commit: Character,
        tree: Character,
        control: Character
    ) throws -> EvolutionCapabilitySubjectIdentity {
        try EvolutionCapabilitySubjectIdentity(
            commitSHA: hex(commit, count: 40),
            treeSHA: hex(tree, count: 40),
            gitControlDigest: hex(control, count: 64))
    }

    private func frozen(provider: Character = "d") throws -> EvolutionCapabilityFrozenInputs {
        try EvolutionCapabilityFrozenInputs(
            corpusDigest: hex("a", count: 64),
            harnessDigest: hex("b", count: 64),
            evaluatorDigest: hex("c", count: 64),
            providerDigest: hex(provider, count: 64),
            modelDigest: hex("e", count: 64),
            toolsetDigest: hex("f", count: 64))
    }

    private func fixture() throws -> Fixture {
        let parent = try identity(commit: "1", tree: "2", control: "3")
        let child = try identity(commit: "4", tree: "5", control: "6")
        let frozen = try frozen()
        return (
            try EvolutionCapabilityEvaluationPlan(
                parentIdentity: parent,
                childBaseIdentity: parent,
                childIdentity: child,
                frozenInputs: frozen),
            parent,
            child,
            frozen
        )
    }

    private func result(
        _ caseID: String,
        _ passed: Bool,
        evidence: Character
    ) throws -> EvolutionCapabilityCaseResult {
        try EvolutionCapabilityCaseResult(
            caseID: caseID,
            passed: passed,
            evidenceDigest: hex(evidence, count: 64))
    }

    private func arm(
        _ arm: EvolutionCapabilityArm,
        identity: EvolutionCapabilitySubjectIdentity,
        frozen: EvolutionCapabilityFrozenInputs,
        infrastructureSucceeded: Bool = true,
        infrastructureEvidence: Character,
        cases: [(String, Bool, Character)]
    ) throws -> EvolutionCapabilityArmResult {
        try EvolutionCapabilityArmResult(
            arm: arm,
            identity: identity,
            frozenInputs: frozen,
            infrastructureSucceeded: infrastructureSucceeded,
            infrastructureEvidenceDigest: hex(infrastructureEvidence, count: 64),
            cases: try cases.map { try result($0.0, $0.1, evidence: $0.2) })
    }

    private func validArms(
        _ fixture: Fixture
    ) throws -> (EvolutionCapabilityArmResult, EvolutionCapabilityArmResult) {
        let parent = try arm(
            .parent,
            identity: fixture.parent,
            frozen: fixture.frozen,
            infrastructureEvidence: "7",
            cases: [
                ("z-still-unsolved", false, "8"),
                ("a-stable", true, "9"),
                ("m-newly-solved", false, "a"),
            ])
        let child = try arm(
            .child,
            identity: fixture.child,
            frozen: fixture.frozen,
            infrastructureEvidence: "b",
            cases: [
                ("m-newly-solved", true, "c"),
                ("z-still-unsolved", false, "d"),
                ("a-stable", true, "e"),
            ])
        return (parent, child)
    }

    private func assertFitnessError(
        _ expected: EvolutionCapabilityFitnessError,
        operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? EvolutionCapabilityFitnessError, expected,
                           file: file, line: line)
        }
    }

    func testValidImprovementProducesCanonicalDigestableReceiptInput() throws {
        let fixture = try fixture()
        let (parent, child) = try validArms(fixture)

        let receipt = try EvolutionCapabilityFitnessEvaluator.evaluate(
            plan: fixture.plan, parent: parent, child: child)

        XCTAssertEqual(receipt.schema, EvolutionCapabilityFitnessReceiptInput.currentSchema)
        XCTAssertEqual(receipt.comparisons.map(\.caseID), [
            "a-stable", "m-newly-solved", "z-still-unsolved",
        ])
        XCTAssertEqual(receipt.parentSolvedCount, 1)
        XCTAssertEqual(receipt.childSolvedCount, 2)
        XCTAssertEqual(receipt.solvedCountDelta, 1)
        XCTAssertEqual(receipt.newlySolvedCaseIDs, ["m-newly-solved"])
        XCTAssertEqual(receipt.regressedCaseIDs, [])
        XCTAssertTrue(receipt.parentInfrastructureSucceeded)
        XCTAssertTrue(receipt.childInfrastructureSucceeded)

        let reorderedParent = try arm(
            .parent,
            identity: fixture.parent,
            frozen: fixture.frozen,
            infrastructureEvidence: "7",
            cases: [
                ("a-stable", true, "9"),
                ("m-newly-solved", false, "a"),
                ("z-still-unsolved", false, "8"),
            ])
        let reorderedChild = try arm(
            .child,
            identity: fixture.child,
            frozen: fixture.frozen,
            infrastructureEvidence: "b",
            cases: [
                ("z-still-unsolved", false, "d"),
                ("a-stable", true, "e"),
                ("m-newly-solved", true, "c"),
            ])
        let reorderedReceipt = try EvolutionCapabilityFitnessEvaluator.evaluate(
            plan: fixture.plan, parent: reorderedParent, child: reorderedChild)

        XCTAssertEqual(try receipt.canonicalData(), try reorderedReceipt.canonicalData())
        XCTAssertEqual(try receipt.bindingDigest(), try reorderedReceipt.bindingDigest())
        XCTAssertEqual(try receipt.bindingDigest().count, 64)

        let decoded = try JSONDecoder().decode(
            EvolutionCapabilityFitnessReceiptInput.self,
            from: receipt.canonicalData())
        XCTAssertEqual(decoded, receipt)
        XCTAssertEqual(try decoded.bindingDigest(), try receipt.bindingDigest())

        let encodedArm = try JSONEncoder().encode(parent)
        XCTAssertEqual(
            try JSONDecoder().decode(EvolutionCapabilityArmResult.self, from: encodedArm),
            parent)
    }

    func testPlanRequiresExactParentBaseAndDistinctChildIdentity() throws {
        let parent = try identity(commit: "1", tree: "2", control: "3")
        let wrongBase = try identity(commit: "7", tree: "8", control: "9")
        let child = try identity(commit: "4", tree: "5", control: "6")
        let inputs = try frozen()

        assertFitnessError(.parentBaseIdentityMismatch) {
            _ = try EvolutionCapabilityEvaluationPlan(
                parentIdentity: parent,
                childBaseIdentity: wrongBase,
                childIdentity: child,
                frozenInputs: inputs)
        }

        let unchangedTree = try EvolutionCapabilitySubjectIdentity(
            commitSHA: hex("4", count: 40),
            treeSHA: parent.treeSHA,
            gitControlDigest: hex("6", count: 64))
        assertFitnessError(.childIdentityNotDistinct) {
            _ = try EvolutionCapabilityEvaluationPlan(
                parentIdentity: parent,
                childBaseIdentity: parent,
                childIdentity: unchangedTree,
                frozenInputs: inputs)
        }

        assertFitnessError(.invalidObjectID(field: "subject.commitSHA")) {
            _ = try EvolutionCapabilitySubjectIdentity(
                commitSHA: hex("A", count: 40),
                treeSHA: hex("2", count: 40),
                gitControlDigest: hex("3", count: 64))
        }
    }

    func testCaseIDsMustBeNonemptyUniqueAndBounded() throws {
        let fixture = try fixture()

        assertFitnessError(.invalidCaseID(reason: "empty")) {
            _ = try self.result("", true, evidence: "1")
        }
        assertFitnessError(.invalidCaseID(reason: "longer than 256 UTF-8 bytes")) {
            _ = try self.result(String(repeating: "x", count: 257), true, evidence: "1")
        }

        let duplicate = try result("same", true, evidence: "1")
        assertFitnessError(.duplicateCaseID(arm: .parent, caseID: "same")) {
            _ = try EvolutionCapabilityArmResult(
                arm: .parent,
                identity: fixture.parent,
                frozenInputs: fixture.frozen,
                infrastructureSucceeded: true,
                infrastructureEvidenceDigest: self.hex("2", count: 64),
                cases: [duplicate, duplicate])
        }
        assertFitnessError(.emptyCases(arm: .parent)) {
            _ = try EvolutionCapabilityArmResult(
                arm: .parent,
                identity: fixture.parent,
                frozenInputs: fixture.frozen,
                infrastructureSucceeded: true,
                infrastructureEvidenceDigest: self.hex("2", count: 64),
                cases: [])
        }

        let tooMany = try (0...4_096).map {
            try result("case-\($0)", false, evidence: "3")
        }
        assertFitnessError(.tooManyCases(arm: .parent, limit: 4_096)) {
            _ = try EvolutionCapabilityArmResult(
                arm: .parent,
                identity: fixture.parent,
                frozenInputs: fixture.frozen,
                infrastructureSucceeded: true,
                infrastructureEvidenceDigest: self.hex("2", count: 64),
                cases: tooMany)
        }
    }

    func testBothArmsMustMatchExactIdentityAndFrozenInputs() throws {
        let fixture = try fixture()
        let (parent, child) = try validArms(fixture)
        let wrongParent = try arm(
            .parent,
            identity: fixture.child,
            frozen: fixture.frozen,
            infrastructureEvidence: "7",
            cases: parent.cases.map { ($0.caseID, $0.passed, "8") })
        assertFitnessError(.armIdentityMismatch(arm: .parent)) {
            _ = try EvolutionCapabilityFitnessEvaluator.evaluate(
                plan: fixture.plan, parent: wrongParent, child: child)
        }

        let differentFrozen = try frozen(provider: "0")
        let wrongInputsChild = try arm(
            .child,
            identity: fixture.child,
            frozen: differentFrozen,
            infrastructureEvidence: "b",
            cases: child.cases.map { ($0.caseID, $0.passed, "c") })
        assertFitnessError(.frozenInputsMismatch(arm: .child)) {
            _ = try EvolutionCapabilityFitnessEvaluator.evaluate(
                plan: fixture.plan, parent: parent, child: wrongInputsChild)
        }
    }

    func testBothArmsRequireSuccessfulInfrastructure() throws {
        let fixture = try fixture()
        let (validParent, validChild) = try validArms(fixture)
        let failedParent = try arm(
            .parent,
            identity: fixture.parent,
            frozen: fixture.frozen,
            infrastructureSucceeded: false,
            infrastructureEvidence: "7",
            cases: validParent.cases.map { ($0.caseID, $0.passed, "8") })
        assertFitnessError(.infrastructureFailed(arm: .parent)) {
            _ = try EvolutionCapabilityFitnessEvaluator.evaluate(
                plan: fixture.plan, parent: failedParent, child: validChild)
        }

        let failedChild = try arm(
            .child,
            identity: fixture.child,
            frozen: fixture.frozen,
            infrastructureSucceeded: false,
            infrastructureEvidence: "b",
            cases: validChild.cases.map { ($0.caseID, $0.passed, "c") })
        assertFitnessError(.infrastructureFailed(arm: .child)) {
            _ = try EvolutionCapabilityFitnessEvaluator.evaluate(
                plan: fixture.plan, parent: validParent, child: failedChild)
        }
    }

    func testArmsMustContainTheExactSameHeldOutCaseSet() throws {
        let fixture = try fixture()
        let parent = try arm(
            .parent,
            identity: fixture.parent,
            frozen: fixture.frozen,
            infrastructureEvidence: "7",
            cases: [("parent-only", false, "8"), ("shared", true, "9")])
        let child = try arm(
            .child,
            identity: fixture.child,
            frozen: fixture.frozen,
            infrastructureEvidence: "a",
            cases: [("child-only", true, "b"), ("shared", true, "c")])

        assertFitnessError(.caseSetMismatch(
            parentOnly: ["parent-only"], childOnly: ["child-only"])) {
            _ = try EvolutionCapabilityFitnessEvaluator.evaluate(
                plan: fixture.plan, parent: parent, child: child)
        }
    }

    func testRegressionRejectsChildEvenWhenSolvedCountWouldIncrease() throws {
        let fixture = try fixture()
        let parent = try arm(
            .parent,
            identity: fixture.parent,
            frozen: fixture.frozen,
            infrastructureEvidence: "7",
            cases: [
                ("stable", true, "8"),
                ("regressed", true, "9"),
                ("gain-one", false, "a"),
                ("gain-two", false, "b"),
            ])
        let child = try arm(
            .child,
            identity: fixture.child,
            frozen: fixture.frozen,
            infrastructureEvidence: "c",
            cases: [
                ("stable", true, "d"),
                ("regressed", false, "e"),
                ("gain-one", true, "f"),
                ("gain-two", true, "0"),
            ])

        // Parent solves 2 and child solves 3, but the aggregate gain cannot hide a regression.
        assertFitnessError(.regressedCases(["regressed"])) {
            _ = try EvolutionCapabilityFitnessEvaluator.evaluate(
                plan: fixture.plan, parent: parent, child: child)
        }
    }

    func testAtLeastOneNewlySolvedCaseIsRequired() throws {
        let fixture = try fixture()
        let parent = try arm(
            .parent,
            identity: fixture.parent,
            frozen: fixture.frozen,
            infrastructureEvidence: "7",
            cases: [("stable", true, "8"), ("unsolved", false, "9")])
        let child = try arm(
            .child,
            identity: fixture.child,
            frozen: fixture.frozen,
            infrastructureEvidence: "a",
            cases: [("stable", true, "b"), ("unsolved", false, "c")])

        assertFitnessError(.noNewlySolvedCases) {
            _ = try EvolutionCapabilityFitnessEvaluator.evaluate(
                plan: fixture.plan, parent: parent, child: child)
        }
    }

    func testReceiptDecodeRecomputesDerivedFitnessInsteadOfTrustingIt() throws {
        let fixture = try fixture()
        let (parent, child) = try validArms(fixture)
        let receipt = try EvolutionCapabilityFitnessEvaluator.evaluate(
            plan: fixture.plan, parent: parent, child: child)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: receipt.canonicalData()) as? [String: Any])
        object["solvedCountDelta"] = 99
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        assertFitnessError(.invalidReceipt(reason: "derived fitness fields do not recompute")) {
            _ = try JSONDecoder().decode(
                EvolutionCapabilityFitnessReceiptInput.self, from: tampered)
        }
    }
}
