import Foundation
import XCTest
@testable import AgentCore

/// Fail-closed pins for the private held-out corpus store. Each rejection reason gets its own named
/// assertion so a regression tells you exactly which invariant went soft. The store must load only an
/// owner-private manifest, freeze a digest identical to what the oracle re-derives, and refuse a corpus
/// provisioned anywhere a candidate could read the answers.
final class EvolutionHeldOutCorpusTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("heldout-corpus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func digest(_ text: String) -> String { BuilderEvidenceDigest.sha256(text) }

    private func caseDict(_ id: String, exit: Int = 0, stdout: String = "out",
                          stderr: String = "", argv: [String] = ["/bin/echo", "hi"],
                          stdin: String? = nil, timeout: Int = 30) -> [String: Any] {
        var value: [String: Any] = [
            "caseID": id, "argv": argv, "timeoutSeconds": timeout,
            "expectedExitCode": exit,
            "stdoutDigest": digest(stdout), "stderrDigest": digest(stderr),
        ]
        if let stdin { value["stdin"] = stdin }
        return value
    }

    @discardableResult
    private func writeManifest(_ object: [String: Any], directory: URL? = nil,
                              directoryPermissions: Int = 0o700,
                              manifestPermissions: Int = 0o600) throws -> URL {
        let dir = directory ?? root!
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryPermissions])
        } else {
            try FileManager.default.setAttributes(
                [.posixPermissions: directoryPermissions], ofItemAtPath: dir.path)
        }
        let manifest = dir.appendingPathComponent("corpus.json")
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: manifest)
        try FileManager.default.setAttributes(
            [.posixPermissions: manifestPermissions], ofItemAtPath: manifest.path)
        return manifest
    }

    private func validManifest(_ ids: [String]) -> [String: Any] {
        ["schema": EvolutionHeldOutCorpus.manifestSchema,
         "cases": ids.map { caseDict($0, stdout: "solved-\($0)") }]
    }

    // MARK: Happy path + identity

    func testLoadsAndFreezesAnOwnerPrivateCorpus() throws {
        try writeManifest(validManifest(["beta", "alpha", "gamma"]))
        let frozen = try EvolutionHeldOutCorpus.load(directory: root.path)
        XCTAssertEqual(frozen.caseIDs, ["alpha", "beta", "gamma"], "cases must be sorted by ID")
        XCTAssertEqual(frozen.invocations.map(\.caseID), frozen.caseIDs,
                       "invocations must align with expectations")

        // The frozen digest must equal exactly what the oracle re-derives from the same expectations —
        // this is the agreement that lets a corpus loaded here and a plan built by the backend match.
        let reexpectations = try ["alpha", "beta", "gamma"].map {
            try EvolutionHeldOutOracle.Expectation(
                caseID: $0, stdoutDigest: digest("solved-\($0)"), stderrDigest: digest(""))
        }
        XCTAssertEqual(frozen.corpusDigest, try EvolutionHeldOutOracle.corpusDigest(reexpectations))
    }

    func testFreezeIsOrderIndependent() throws {
        try writeManifest(validManifest(["a", "b", "c"]))
        let forward = try EvolutionHeldOutCorpus.load(directory: root.path).corpusDigest
        try writeManifest(validManifest(["c", "a", "b"]))
        let shuffled = try EvolutionHeldOutCorpus.load(directory: root.path).corpusDigest
        XCTAssertEqual(forward, shuffled, "corpus identity must not depend on manifest ordering")
    }

    func testInvocationDetailIsCarriedForTheBackendButBoundedOnLoad() throws {
        try writeManifest(["schema": EvolutionHeldOutCorpus.manifestSchema,
                           "cases": [caseDict("one", argv: ["/usr/bin/env", "-i", "true"],
                                              stdin: "feed", timeout: 45)]])
        let frozen = try EvolutionHeldOutCorpus.load(directory: root.path)
        let invocation = try XCTUnwrap(frozen.invocations.first)
        XCTAssertEqual(invocation.argv, ["/usr/bin/env", "-i", "true"])
        XCTAssertEqual(invocation.stdin, "feed")
        XCTAssertEqual(invocation.timeoutSeconds, 45)
    }

    // MARK: Owner-private storage (per-site)

    func testGroupOrWorldReadableDirectoryIsRefused() throws {
        try writeManifest(validManifest(["a"]), directoryPermissions: 0o755)
        XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(directory: root.path)) {
            guard case EvolutionHeldOutCorpus.Error.unsafeDirectory = $0 else {
                return XCTFail("expected unsafeDirectory, got \($0)")
            }
        }
    }

    func testGroupOrWorldReadableManifestIsRefused() throws {
        try writeManifest(validManifest(["a"]), manifestPermissions: 0o644)
        XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(directory: root.path)) {
            guard case EvolutionHeldOutCorpus.Error.unsafeManifest = $0 else {
                return XCTFail("expected unsafeManifest, got \($0)")
            }
        }
    }

    func testMissingManifestIsRefused() throws {
        XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(directory: root.path)) {
            guard case EvolutionHeldOutCorpus.Error.unsafeManifest = $0 else {
                return XCTFail("expected unsafeManifest, got \($0)")
            }
        }
    }

    // MARK: Manifest + per-case invariants (per-site)

    func testUnknownSchemaIsRefused() throws {
        try writeManifest(["schema": "kist.evolution.held-out-corpus.v0",
                           "cases": [caseDict("a")]])
        XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(directory: root.path)) {
            guard case EvolutionHeldOutCorpus.Error.malformedManifest = $0 else {
                return XCTFail("expected malformedManifest, got \($0)")
            }
        }
    }

    func testEmptyCorpusIsRefused() throws {
        try writeManifest(["schema": EvolutionHeldOutCorpus.manifestSchema, "cases": []])
        XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(directory: root.path)) {
            XCTAssertEqual($0 as? EvolutionHeldOutCorpus.Error, .emptyCorpus)
        }
    }

    func testDuplicateCaseIsRefused() throws {
        try writeManifest(["schema": EvolutionHeldOutCorpus.manifestSchema,
                           "cases": [caseDict("dup"), caseDict("dup", stdout: "other")]])
        XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(directory: root.path)) {
            XCTAssertEqual($0 as? EvolutionHeldOutCorpus.Error, .duplicateCase("dup"))
        }
    }

    func testInvalidExpectedDigestIsRefused() throws {
        var bad = caseDict("a")
        bad["stdoutDigest"] = "not-a-64-hex-digest"
        try writeManifest(["schema": EvolutionHeldOutCorpus.manifestSchema, "cases": [bad]])
        XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(directory: root.path)) {
            guard case EvolutionHeldOutCorpus.Error.invalidCase(let id, _) = $0 else {
                return XCTFail("expected invalidCase, got \($0)")
            }
            XCTAssertEqual(id, "a")
        }
    }

    func testEmptyArgvIsRefused() throws {
        try writeManifest(["schema": EvolutionHeldOutCorpus.manifestSchema,
                           "cases": [caseDict("a", argv: [])]])
        XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(directory: root.path)) {
            guard case EvolutionHeldOutCorpus.Error.invalidCase = $0 else {
                return XCTFail("expected invalidCase for empty argv, got \($0)")
            }
        }
    }

    func testMultilineArgvElementIsRefused() throws {
        try writeManifest(["schema": EvolutionHeldOutCorpus.manifestSchema,
                           "cases": [caseDict("a", argv: ["/bin/echo", "line1\nline2"])]])
        XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(directory: root.path)) {
            guard case EvolutionHeldOutCorpus.Error.invalidCase = $0 else {
                return XCTFail("expected invalidCase for multiline argv, got \($0)")
            }
        }
    }

    func testOutOfRangeTimeoutIsRefused() throws {
        for timeout in [0, EvolutionHeldOutCorpus.maximumTimeoutSeconds + 1] {
            try writeManifest(["schema": EvolutionHeldOutCorpus.manifestSchema,
                               "cases": [caseDict("a", timeout: timeout)]])
            XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(directory: root.path),
                                 "timeout \(timeout) must be refused") {
                guard case EvolutionHeldOutCorpus.Error.invalidCase = $0 else {
                    return XCTFail("expected invalidCase for timeout \(timeout), got \($0)")
                }
            }
        }
    }

    // MARK: Candidate-visibility defense

    func testCorpusInsideACandidateRootIsRefused() throws {
        let candidateRoot = root.appendingPathComponent("worktree")
        let corpus = candidateRoot.appendingPathComponent("secret-corpus")
        try writeManifest(validManifest(["a"]), directory: corpus)
        XCTAssertThrowsError(try EvolutionHeldOutCorpus.load(
            directory: corpus.path, forbiddenRoots: [candidateRoot.path])) {
            guard case EvolutionHeldOutCorpus.Error.corpusInsideCandidateRoot = $0 else {
                return XCTFail("expected corpusInsideCandidateRoot, got \($0)")
            }
        }
        // The identical corpus OUTSIDE the candidate root loads cleanly — proving the refusal is the
        // location, not the contents.
        XCTAssertNoThrow(try EvolutionHeldOutCorpus.load(
            directory: corpus.path, forbiddenRoots: [root.appendingPathComponent("elsewhere").path]))
    }

    // MARK: Availability probe

    func testAvailabilityNeverThrowsAndReportsBothStates() throws {
        let unavailable = EvolutionHeldOutCorpus.availability(directory: root.path)
        XCTAssertFalse(unavailable.ready)
        XCTAssertFalse(unavailable.detail.isEmpty)

        try writeManifest(validManifest(["a", "b"]))
        let ready = EvolutionHeldOutCorpus.availability(directory: root.path)
        XCTAssertTrue(ready.ready)
        XCTAssertTrue(ready.detail.contains("2 frozen held-out case"))
    }
}
