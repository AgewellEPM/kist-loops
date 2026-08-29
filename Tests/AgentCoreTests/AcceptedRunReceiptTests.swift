import Dispatch
import Foundation
import XCTest
@testable import AgentCore

final class AcceptedRunReceiptTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let contractID = "kist-builder-deadbeef"
    private let exactGoal = "Build the exact requested artifact"
    private let objective = "9a1faec2d43ac8f7fdac944b05bc75a4d370678a4f12c1be6199bc451aef0c92"
    private let verificationDigest = String(repeating: "c", count: 64)
    private let projectIdentity = String(repeating: "b", count: 64)
    private let ledgerRecordDigest = String(repeating: "e", count: 64)
    private let subject = "/tmp/governed-project"

    override func setUp() {
        super.setUp()
        ForgeSeal.forceEphemeralKeyForTesting()
    }

    override func tearDown() {
        ForgeSeal.resetCacheForTesting()
        super.tearDown()
    }

    private func runID(_ value: Int) -> String {
        let suffix = String(value, radix: 16)
        return String(repeating: "0", count: 64 - suffix.count) + suffix
    }

    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("accepted-run-receipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func receipt(runID: String = String(repeating: "a", count: 64),
                         issuedAt: Date? = nil,
                         freshness: TimeInterval = 3_600) throws -> AcceptedRunReceipt {
        try AcceptedRunReceipt.mintAccepted(
            runID: runID, projectIdentity: projectIdentity,
            contractID: contractID, exactGoal: exactGoal,
            objectiveFingerprint: objective,
            verificationSubject: subject, verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest,
            issuedAt: issuedAt ?? now, freshness: freshness)
    }

    private func tamper(_ receipt: AcceptedRunReceipt, key: String, value: Any) throws
        -> AcceptedRunReceipt {
        let encoded = try JSONEncoder().encode(receipt)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object[key] = value
        let changed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(AcceptedRunReceipt.self, from: changed)
    }

    func testMintBindsEveryTrustFieldInForgeSealCanonical() throws {
        let value = try receipt()
        XCTAssertEqual(value.schema, AcceptedRunReceipt.currentSchema)
        XCTAssertEqual(value.issuer, AcceptedRunReceipt.trustedIssuer)
        XCTAssertEqual(value.decision, .accepted)
        XCTAssertTrue(value.accepted)
        XCTAssertEqual(value.seal.count, 64)
        XCTAssertTrue(ForgeSeal.verify(value.canonicalSigningString, seal: value.seal))
        XCTAssertEqual(value.canonicalSigningString, """
        schema=kist.accepted-run-receipt.v2
        issuer=kist.host.builder-final-verifier
        runID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        projectIdentity=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        contractIDBase64=a2lzdC1idWlsZGVyLWRlYWRiZWVm
        objectiveFingerprint=9a1faec2d43ac8f7fdac944b05bc75a4d370678a4f12c1be6199bc451aef0c92
        verificationSubjectBase64=L3RtcC9nb3Zlcm5lZC1wcm9qZWN0
        verificationDigest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        ledgerRecordDigest=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
        decision=accepted
        accepted=true
        reviewGrade=independent-provider
        independentReview=true
        issuedAtMillis=2000000000000
        validUntilMillis=2000003600000
        """)
        try value.validate(now: now)
    }

    func testPythonDashboardInteropVector() throws {
        let keyDirectory = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: keyDirectory) }
        let keyURL = keyDirectory.appendingPathComponent("forgeseal-v1.key")
        try Data((0..<32).map(UInt8.init)).write(to: keyURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        ForgeSeal.resetCacheForTesting()
        ForgeSeal.keyDirectoryOverrideForTesting = keyDirectory.path

        let contract = "build.verify.v1"
        let goal = "build and verify"
        let fingerprint = try AcceptedRunReceipt.computeObjectiveFingerprint(
            contractID: contract, exactGoal: goal)
        XCTAssertEqual(
            fingerprint,
            "b1376d9447c132a2c0921d45e65c45fe30bc667a07d2d85444e1c6b16e047276")
        let value = try AcceptedRunReceipt.mintAccepted(
            runID: String(repeating: "a", count: 64),
            projectIdentity: String(repeating: "b", count: 64),
            contractID: contract, exactGoal: goal,
            objectiveFingerprint: fingerprint,
            verificationSubject: "builder-final-verifier: tests passed ✓",
            verificationDigest: String(repeating: "c", count: 64),
            ledgerRecordDigest: String(repeating: "e", count: 64),
            issuedAt: Date(timeIntervalSince1970: 1_000), freshness: 60)
        XCTAssertEqual(
            value.seal,
            "6ff4529338f1b35d26a5c9a525b00799e1c3c26e1d8f8a36509a59a60fa4ea3b")
    }

    func testProjectIdentityCrossLanguageVectorAndFilesystemDrift() throws {
        func identity(_ label: String, _ root: URL) -> String {
            do { return try AcceptedRunReceipt.computeProjectIdentity(projectRoot: root.path) }
            catch {
                XCTFail("\(label) project identity failed: \(error)")
                return ""
            }
        }
        XCTAssertEqual(try AcceptedRunReceipt.computeProjectIdentity(
            canonicalResolvedProjectPath: "/srv/kist/project",
            deviceDecimal: "16777234", inodeDecimal: "123456789"),
            "3ddc6507263e907b0fd6091ed25d92ccedff2c2f676168d7b279c32d06374403")

        let parent = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let physical = parent.appendingPathComponent("physical", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let original = identity("physical", physical)
        XCTAssertEqual(identity("symlink alias", alias),
                       original, "a symlink alias must resolve to the same active root")

        let renamed = parent.appendingPathComponent("renamed", isDirectory: true)
        try FileManager.default.moveItem(at: physical, to: renamed)
        let renamedIdentity = identity("renamed", renamed)
        XCTAssertNotEqual(renamedIdentity, original,
                          "canonical path drift must invalidate the old identity")

        try FileManager.default.removeItem(at: renamed)
        try FileManager.default.createDirectory(at: renamed, withIntermediateDirectories: true)
        XCTAssertNotEqual(identity("same-path inode replacement", renamed),
                          renamedIdentity,
                          "same-path root inode replacement must invalidate copied evidence")
    }

    func testV1ReceiptDecodesForMigrationButCanNeverValidateGreen() throws {
        let canonical = """
        schema=kist.accepted-run-receipt.v1
        issuer=kist.host.builder-final-verifier
        runID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        contractIDBase64=a2lzdC1idWlsZGVyLWRlYWRiZWVm
        objectiveFingerprint=9a1faec2d43ac8f7fdac944b05bc75a4d370678a4f12c1be6199bc451aef0c92
        verificationSubjectBase64=L3RtcC9nb3Zlcm5lZC1wcm9qZWN0
        verificationDigest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
        decision=accepted
        accepted=true
        reviewGrade=independent-provider
        independentReview=true
        issuedAtMillis=2000000000000
        validUntilMillis=2000003600000
        """
        let seal = ForgeSeal.sign(canonical)
        let object: [String: Any] = [
            "schema": AcceptedRunReceipt.legacySchema,
            "issuer": AcceptedRunReceipt.trustedIssuer,
            "runID": String(repeating: "a", count: 64), "contractID": contractID,
            "objectiveFingerprint": objective, "verificationSubject": subject,
            "verificationDigest": verificationDigest, "decision": "accepted",
            "accepted": true, "reviewGrade": "independent-provider",
            "independentReview": true, "issuedAtMillis": 2_000_000_000_000 as Int64,
            "validUntilMillis": 2_000_003_600_000 as Int64, "seal": seal,
        ]
        let legacy = try JSONDecoder().decode(
            AcceptedRunReceipt.self,
            from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        XCTAssertEqual(legacy.schema, AcceptedRunReceipt.legacySchema)
        XCTAssertNil(legacy.projectIdentity)
        XCTAssertNil(legacy.ledgerRecordDigest)
        XCTAssertThrowsError(try legacy.validate(now: now))
    }

    func testTamperingSignedEvidenceInvalidatesReceipt() throws {
        let original = try receipt()
        let changed = try tamper(
            original, key: "verificationDigest", value: String(repeating: "d", count: 64))
        XCTAssertThrowsError(try changed.validate(now: now)) { error in
            XCTAssertEqual(error as? AcceptedRunReceiptError, .invalidSeal)
        }
    }

    func testEvenResealedSameModelReviewCannotMasqueradeAsIndependent() throws {
        let original = try receipt()
        let changedGrade = try tamper(
            original, key: "reviewGrade", value: "same-model")
        let resealedGrade = try tamper(
            changedGrade, key: "seal",
            value: ForgeSeal.sign(changedGrade.canonicalSigningString))
        XCTAssertThrowsError(try resealedGrade.validate(now: now)) { error in
            XCTAssertEqual(error as? AcceptedRunReceiptError, .invalidField("reviewGrade"))
        }

        let changedFlag = try tamper(
            original, key: "independentReview", value: false)
        let resealedFlag = try tamper(
            changedFlag, key: "seal",
            value: ForgeSeal.sign(changedFlag.canonicalSigningString))
        XCTAssertThrowsError(try resealedFlag.validate(now: now)) { error in
            XCTAssertEqual(error as? AcceptedRunReceiptError, .invalidField("reviewGrade"))
        }
    }

    func testMintRecomputesObjectiveFromSignedContractAndExactGoal() throws {
        XCTAssertEqual(try AcceptedRunReceipt.computeObjectiveFingerprint(
            contractID: contractID, exactGoal: exactGoal), objective)
        XCTAssertThrowsError(try AcceptedRunReceipt.mintAccepted(
            runID: String(repeating: "a", count: 64),
            projectIdentity: projectIdentity,
            contractID: contractID, exactGoal: exactGoal + " relabeled",
            objectiveFingerprint: objective,
            verificationSubject: subject, verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest,
            issuedAt: now)) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError,
                               .bindingMismatch("objectiveFingerprint"))
            }
    }

    func testStrictSchemaRejectsUnsignedExtensionField() throws {
        let encoded = try JSONEncoder().encode(receipt())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["verified"] = true
        let extended = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(AcceptedRunReceipt.self, from: extended))
    }

    func testBindingRejectsRunObjectiveSubjectAndDigestMismatch() throws {
        let value = try receipt()
        let cases: [(AcceptedRunReceipt.Binding, String)] = [
            (try .init(runID: String(repeating: "d", count: 64),
                       contractID: contractID, exactGoal: exactGoal,
                       projectIdentity: projectIdentity,
                       verificationSubject: subject,
                       verificationDigest: verificationDigest,
                       ledgerRecordDigest: ledgerRecordDigest), "runID"),
            (try .init(runID: value.runID,
                       contractID: "kist-builder-different", exactGoal: exactGoal,
                       projectIdentity: projectIdentity,
                       verificationSubject: subject,
                       verificationDigest: verificationDigest,
                       ledgerRecordDigest: ledgerRecordDigest), "contractID"),
            (try .init(runID: value.runID, contractID: contractID,
                       exactGoal: exactGoal + " relabeled",
                       projectIdentity: projectIdentity,
                       verificationSubject: subject,
                       verificationDigest: verificationDigest,
                       ledgerRecordDigest: ledgerRecordDigest), "objectiveFingerprint"),
            (try .init(runID: value.runID, contractID: contractID, exactGoal: exactGoal,
                       projectIdentity: projectIdentity,
                       verificationSubject: "/tmp/another-project",
                       verificationDigest: verificationDigest,
                       ledgerRecordDigest: ledgerRecordDigest), "verificationSubject"),
            (try .init(runID: value.runID, contractID: contractID, exactGoal: exactGoal,
                       projectIdentity: projectIdentity,
                       verificationSubject: subject,
                       verificationDigest: String(repeating: "d", count: 64),
                       ledgerRecordDigest: ledgerRecordDigest),
             "verificationDigest"),
            (try .init(runID: value.runID, contractID: contractID, exactGoal: exactGoal,
                       projectIdentity: String(repeating: "d", count: 64),
                       verificationSubject: subject, verificationDigest: verificationDigest,
                       ledgerRecordDigest: ledgerRecordDigest), "projectIdentity"),
            (try .init(runID: value.runID, contractID: contractID, exactGoal: exactGoal,
                       projectIdentity: projectIdentity,
                       verificationSubject: subject, verificationDigest: verificationDigest,
                       ledgerRecordDigest: String(repeating: "d", count: 64)),
             "ledgerRecordDigest"),
        ]
        for (binding, field) in cases {
            XCTAssertThrowsError(try value.validate(matching: binding, now: now)) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError, .bindingMismatch(field))
            }
        }
    }

    func testExactLowercase64HexRunIDIsRequired() {
        for invalid in ["legacy-123", String(repeating: "a", count: 63),
                        String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            XCTAssertThrowsError(try AcceptedRunReceipt.mintAccepted(
                runID: invalid, projectIdentity: projectIdentity,
                contractID: contractID, exactGoal: exactGoal,
                objectiveFingerprint: objective,
                verificationSubject: subject, verificationDigest: verificationDigest,
                ledgerRecordDigest: ledgerRecordDigest,
                issuedAt: now)) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError, .invalidField("runID"))
            }
        }
    }

    func testFreshnessRejectsExpiredFutureAndOverlongReceipts() throws {
        let short = try receipt(freshness: 60)
        XCTAssertThrowsError(try short.validate(
            now: now.addingTimeInterval(61))) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError, .expired)
            }
        let future = try receipt(issuedAt: now.addingTimeInterval(301))
        XCTAssertThrowsError(try future.validate(now: now)) { error in
            XCTAssertEqual(error as? AcceptedRunReceiptError, .notYetValid)
        }
        XCTAssertThrowsError(try receipt(
            freshness: AcceptedRunReceipt.defaultFreshness + 1)) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError, .invalidField("freshness"))
            }
    }

    func testStoreRejectsReplayThroughAPIAndOnValidation() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AcceptedRunReceiptStore(projectRoot: root.path)
        let value = try receipt()
        try store.append(value, now: now)
        XCTAssertThrowsError(try store.append(value, now: now)) { error in
            XCTAssertEqual(error as? AcceptedRunReceiptError, .replayDetected)
        }

        // Simulate a copied signed line which bypassed the writer. One valid receipt appearing twice
        // must not become two independent host decisions.
        let once = try Data(contentsOf: store.fileURL)
        let replayWriter = try FileHandle(forWritingTo: store.fileURL)
        try replayWriter.seekToEnd()
        try replayWriter.write(contentsOf: once)
        try replayWriter.close()
        let binding = try AcceptedRunReceipt.Binding(
            runID: value.runID, contractID: contractID, exactGoal: exactGoal,
            projectIdentity: projectIdentity,
            verificationSubject: subject, verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest)
        XCTAssertThrowsError(try store.validatedReceipt(matching: binding, now: now)) { error in
            XCTAssertEqual(error as? AcceptedRunReceiptError, .replayDetected)
        }
    }

    func testStoreRejectsTornFinalLineInsteadOfAppendingAcrossIt() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AcceptedRunReceiptStore(projectRoot: root.path)
        try store.append(try receipt(), now: now)
        let handle = try FileHandle(forWritingTo: store.fileURL)
        let endOffset = try handle.seekToEnd()
        XCTAssertGreaterThan(endOffset, 0)
        try handle.truncate(atOffset: endOffset - 1)
        try handle.close()

        XCTAssertThrowsError(try store.allReceipts()) { error in
            XCTAssertEqual(error as? AcceptedRunReceiptError, .malformedStore)
        }
        XCTAssertThrowsError(try store.append(
            receipt(runID: runID(2)), now: now)) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError, .malformedStore)
            }
    }

    func testStoreRejectsDuplicateJSONKeysAndNoncanonicalRows() throws {
        for duplicateKey in ["accepted", "runID"] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = AcceptedRunReceiptStore(projectRoot: root.path)
            try store.append(try receipt(), now: now)
            let canonical = try String(contentsOf: store.fileURL, encoding: .utf8)
            let needle = "\"\(duplicateKey)\":"
            let value = duplicateKey == "accepted"
                ? "true" : "\"\(String(repeating: "a", count: 64))\""
            let duplicate = canonical.replacingOccurrences(
                of: needle, with: "\"\(duplicateKey)\":\(value),\(needle)",
                options: [], range: canonical.range(of: needle))
            try Data(duplicate.utf8).write(to: store.fileURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
            XCTAssertThrowsError(try store.allReceipts()) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError, .malformedStore)
            }
        }
    }

    func testAnyCanonicalSameRunDuplicateInvalidatesBeforeSealOrFreshness() throws {
        for second in [
            try tamper(try receipt(), key: "seal", value: String(repeating: "0", count: 64)),
            try receipt(issuedAt: now.addingTimeInterval(-7_200), freshness: 60),
        ] {
            let root = try temporaryRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = AcceptedRunReceiptStore(projectRoot: root.path)
            try store.append(try receipt(), now: now)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var line = try encoder.encode(second)
            line.append(0x0A)
            let handle = try FileHandle(forWritingTo: store.fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()

            XCTAssertThrowsError(try store.allReceipts()) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError, .replayDetected)
            }
        }
    }

    func testLockedAtomicAppendPreservesEveryConcurrentReceiptAsCompleteJSONL() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AcceptedRunReceiptStore(projectRoot: root.path)
        let receipts = try (1...24).map { try receipt(runID: runID($0)) }
        let errorsLock = NSLock()
        var errors: [Error] = []

        DispatchQueue.concurrentPerform(iterations: receipts.count) { index in
            do {
                try store.append(receipts[index], now: now)
            } catch {
                errorsLock.lock()
                errors.append(error)
                errorsLock.unlock()
            }
        }

        XCTAssertTrue(errors.isEmpty, "atomic append errors: \(errors)")
        let loaded = try store.allReceipts()
        XCTAssertEqual(loaded.count, receipts.count)
        XCTAssertEqual(Set(loaded.map(\.runID)), Set(receipts.map(\.runID)))
        let raw = try Data(contentsOf: store.fileURL)
        XCTAssertEqual(raw.last, 0x0A)
        let lines = raw.split(separator: 0x0A)
        XCTAssertEqual(lines.count, receipts.count)
        for line in lines {
            XCTAssertNoThrow(try JSONDecoder().decode(
                AcceptedRunReceipt.self, from: Data(line)))
        }
    }

    func testMintAndAppendAcceptedIsNarrowBuilderIntegrationHook() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AcceptedRunReceiptStore(projectRoot: root.path)
        let value = try store.mintAndAppendAccepted(
            runID: runID(1), projectIdentity: projectIdentity,
            contractID: contractID, exactGoal: exactGoal,
            objectiveFingerprint: objective,
            verificationSubject: subject, verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest,
            now: now, freshness: 3_600)
        XCTAssertEqual(try store.allReceipts(), [value])
        XCTAssertEqual(store.fileURL.path,
                       root.appendingPathComponent(".kist/accepted-run-receipts.jsonl").path)
    }

    func testMintOrValidateIsIdempotentForExactAcceptedMission() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AcceptedRunReceiptStore(projectRoot: root.path)
        let first = try store.mintOrValidateAccepted(
            runID: runID(1), projectIdentity: projectIdentity,
            contractID: contractID, exactGoal: exactGoal,
            objectiveFingerprint: objective, verificationSubject: subject,
            verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest,
            now: now, freshness: 3_600)

        let resumed = try store.mintOrValidateAccepted(
            runID: runID(1), projectIdentity: projectIdentity,
            contractID: contractID, exactGoal: exactGoal,
            objectiveFingerprint: objective, verificationSubject: subject,
            verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest,
            now: now.addingTimeInterval(30), freshness: 30)

        XCTAssertEqual(resumed, first, "resume must reuse the one host decision")
        XCTAssertEqual(try store.allReceipts(), [first])
    }

    func testMintOrValidateRejectsResumeBindingMismatchAndCopiedReplay() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AcceptedRunReceiptStore(projectRoot: root.path)
        let first = try store.mintOrValidateAccepted(
            runID: runID(1), projectIdentity: projectIdentity,
            contractID: contractID, exactGoal: exactGoal,
            objectiveFingerprint: objective, verificationSubject: subject,
            verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest,
            now: now, freshness: 3_600)

        XCTAssertThrowsError(try store.mintOrValidateAccepted(
            runID: first.runID, projectIdentity: projectIdentity,
            contractID: contractID, exactGoal: exactGoal,
            objectiveFingerprint: objective, verificationSubject: "another subject",
            verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest, now: now)) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError,
                               .bindingMismatch("verificationSubject"))
            }

        let once = try Data(contentsOf: store.fileURL)
        let writer = try FileHandle(forWritingTo: store.fileURL)
        try writer.seekToEnd()
        try writer.write(contentsOf: once)
        try writer.close()
        XCTAssertThrowsError(try store.mintOrValidateAccepted(
            runID: first.runID, projectIdentity: projectIdentity,
            contractID: contractID, exactGoal: exactGoal,
            objectiveFingerprint: objective, verificationSubject: subject,
            verificationDigest: verificationDigest,
            ledgerRecordDigest: ledgerRecordDigest, now: now)) { error in
                XCTAssertEqual(error as? AcceptedRunReceiptError, .replayDetected)
            }
    }
}
