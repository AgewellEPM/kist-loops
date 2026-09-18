import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import AgentCore

final class OperatorActionResultTests: XCTestCase {
    func testDelayedDuplicateCannotBecomeAStaleBaselineDenialAfterLeaseAcquisition() async throws {
        let fixture = try OperatorResultFixture()
        let request = try fixture.replacement()
        try fixture.permit(request)
        let marker = try fixture.markerURL(request)
        let target = fixture.workspace.appendingPathComponent("note.txt")
        let response = await fixture.run(request) { point in
            guard point == .workspaceLeaseAcquired else { return }
            // Model the completed competing holder after this invocation passed
            // the early unused check. No real process or concurrent service runs.
            try Data((OperatorActionHost.sha256(request) + "\n").utf8).write(to: marker)
            try Data("earlier publication".utf8).write(to: target)
        }
        XCTAssertEqual(response.disposition, .unknown)
        XCTAssertEqual(response.code, "already_consumed")
        XCTAssertEqual(try String(contentsOf: target), "earlier publication")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.resultURL(request).path))
    }

    func testObservedReplacementPublishesExactCanonicalResultAcrossScopes() async throws {
        for scope in ["workspace", "source", "packet"] {
            let fixture = try OperatorResultFixture()
            let request = try fixture.request("replace_file", ["path": "HANDOFF.md",
                "expected_sha256": "missing", "content": "Actual fixture result\n"], scope: scope)
            try fixture.permit(request)
            let response = await fixture.run(request)
            XCTAssertEqual(response.disposition, .observed)
            XCTAssertFalse(response.accepted)
            XCTAssertEqual(response.policy_sha256, OperatorActionHost.policySHA256)
            XCTAssertEqual(response.observed_at, fixture.date(0))
            XCTAssertEqual(response.request_sha256, OperatorActionHost.sha256(request))
            XCTAssertEqual(try Data(contentsOf: fixture.resultURL(request)), try fixture.wire(response))
            XCTAssertEqual(try Data(contentsOf: fixture.markerURL(request)),
                Data((OperatorActionHost.sha256(request) + "\n").utf8))
            XCTAssertEqual(try String(contentsOf: fixture.target(scope).appendingPathComponent("HANDOFF.md")),
                           "Actual fixture result\n")
            var info = stat()
            XCTAssertEqual(lstat(try fixture.resultURL(request).path, &info), 0)
            XCTAssertEqual(info.st_mode & mode_t(0o7777), mode_t(0o600))
            XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
            XCTAssertEqual(info.st_uid, geteuid())
            XCTAssertEqual(info.st_nlink, 1)
        }
    }

    func testExactExistingBaselineAndReplayKeepImmutableResult() async throws {
        let fixture = try OperatorResultFixture()
        let file = fixture.workspace.appendingPathComponent("note.txt")
        try Data("before".utf8).write(to: file)
        let request = try fixture.request("replace_file", ["path": "note.txt",
            "expected_sha256": OperatorActionHost.sha256(Data("before".utf8)), "content": "after"])
        try fixture.permit(request)
        let response = await fixture.run(request)
        XCTAssertEqual(response.disposition, .observed)
        let bytes = try Data(contentsOf: fixture.resultURL(request))
        var before = stat(), after = stat()
        XCTAssertEqual(lstat(try fixture.resultURL(request).path, &before), 0)
        let replay = await fixture.run(request)
        XCTAssertEqual(replay.disposition, .unknown)
        XCTAssertEqual(replay.code, "already_consumed")
        XCTAssertEqual(try Data(contentsOf: fixture.resultURL(request)), bytes)
        XCTAssertEqual(lstat(try fixture.resultURL(request).path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_dev, after.st_dev)
        XCTAssertEqual(try String(contentsOf: file), "after")
    }

    func testOccupiedResultSlotsRefuseBeforePermitConsumptionOrEffect() async throws {
        for kind in ["regular", "empty", "symlink", "dangling", "hardlink", "directory", "fifo"] {
            let fixture = try OperatorResultFixture()
            let request = try fixture.replacement()
            try fixture.permit(request)
            let slot = try fixture.resultURL(request)
            let outside = fixture.base.appendingPathComponent("outside.txt")
            try Data("outside sentinel".utf8).write(to: outside)
            switch kind {
            case "regular": try Data("occupied sentinel".utf8).write(to: slot)
            case "empty": try Data().write(to: slot)
            case "symlink": try FileManager.default.createSymbolicLink(at: slot, withDestinationURL: outside)
            case "dangling": try FileManager.default.createSymbolicLink(at: slot,
                withDestinationURL: fixture.base.appendingPathComponent("missing.txt"))
            case "hardlink": try FileManager.default.linkItem(at: outside, to: slot)
            case "directory": try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: false)
            default: XCTAssertEqual(mkfifo(slot.path, 0o600), 0)
            }
            let response = await fixture.run(request)
            XCTAssertEqual(response.disposition, .denied, kind)
            XCTAssertFalse(response.accepted, kind)
            XCTAssertFalse(fixture.consumed(request), kind)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent("note.txt").path), kind)
            XCTAssertEqual(try String(contentsOf: outside), "outside sentinel", kind)
            var info = stat()
            XCTAssertEqual(lstat(slot.path, &info), 0, "Occupied result slot must remain intact")
        }
    }

    func testObservedEffectWithoutResultRemainsUnknownDespiteMatchingDestination() async throws {
        let fixture = try OperatorResultFixture()
        let request = try fixture.replacement()
        try fixture.permit(request)
        let response = await fixture.run(request) { point in
            if point == .effectObserved { throw OperatorResultFixture.Injected.failure }
        }
        XCTAssertEqual(response.disposition, .unknown)
        XCTAssertEqual(response.code, "outcome_unknown")
        XCTAssertTrue(fixture.consumed(request))
        XCTAssertEqual(try String(contentsOf: fixture.workspace.appendingPathComponent("note.txt")), "after")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.resultURL(request).path))
    }

    func testEveryPersistenceInterruptionKeepsConsumedChargeAndReturnsUnknown() async throws {
        for checkpoint in [OperatorActionResultCheckpoint.resultCreated, .resultWritten,
                           .resultFileSynced, .resultDirectorySynced] {
            let fixture = try OperatorResultFixture()
            let request = try fixture.replacement()
            try fixture.permit(request)
            let response = await fixture.run(request) { point in
                if point == checkpoint { throw OperatorResultFixture.Injected.failure }
            }
            XCTAssertEqual(response.disposition, .unknown)
            XCTAssertFalse(response.accepted)
            XCTAssertTrue(fixture.consumed(request))
            XCTAssertEqual(try String(contentsOf: fixture.workspace.appendingPathComponent("note.txt")), "after")
            let retained = try Data(contentsOf: fixture.resultURL(request))
            XCTAssertEqual(retained.isEmpty, checkpoint == .resultCreated)
            if checkpoint == .resultDirectorySynced {
                // A later failure can contradict a complete saved observation. A consumer
                // must keep valid unknown stdout unknown instead of preferring this sidecar.
                let saved = try JSONDecoder().decode(OperatorActionResponse.self, from: retained)
                XCTAssertEqual(saved.disposition, .observed)
                XCTAssertEqual(retained, try fixture.wire(saved))
            }
            let replay = await fixture.run(request)
            XCTAssertEqual(replay.code, "already_consumed")
            XCTAssertEqual(try Data(contentsOf: fixture.resultURL(request)), retained)
        }
    }

    func testResultSlotCreatedAfterPreflightIsNeverOverwritten() async throws {
        let fixture = try OperatorResultFixture()
        let request = try fixture.replacement()
        try fixture.permit(request)
        let slot = try fixture.resultURL(request)
        let response = await fixture.run(request) { point in
            if point == .effectObserved { try Data("racing sentinel".utf8).write(to: slot) }
        }
        XCTAssertEqual(response.disposition, .unknown)
        XCTAssertTrue(fixture.consumed(request))
        XCTAssertEqual(try String(contentsOf: slot), "racing sentinel")
        XCTAssertEqual(try String(contentsOf: fixture.workspace.appendingPathComponent("note.txt")), "after")
    }

    func testChangedConsumedMarkerCannotQualifyAResultAfterTheEffect() async throws {
        let fixture = try OperatorResultFixture()
        let request = try fixture.replacement()
        try fixture.permit(request)
        let marker = try fixture.markerURL(request)
        let response = await fixture.run(request) { point in
            if point == .effectObserved { try Data("wrong request marker\n".utf8).write(to: marker) }
        }
        XCTAssertEqual(response.disposition, .unknown)
        XCTAssertEqual(try String(contentsOf: fixture.workspace.appendingPathComponent("note.txt")), "after")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.resultURL(request).path))
    }

    func testResultPublicationRejectsModeHardlinkAndNameReplacementRaces() async throws {
        for kind in ["mode", "hardlink", "replacement", "bytes"] {
            let fixture = try OperatorResultFixture()
            let request = try fixture.replacement()
            try fixture.permit(request)
            let slot = try fixture.resultURL(request)
            let response = await fixture.run(request) { point in
                guard point == .resultWritten else { return }
                switch kind {
                case "mode": try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: slot.path)
                case "hardlink": try FileManager.default.linkItem(at: slot, to: fixture.base.appendingPathComponent("extra-link"))
                case "replacement":
                    try FileManager.default.moveItem(at: slot, to: fixture.base.appendingPathComponent("original-result"))
                    try Data("replacement sentinel".utf8).write(to: slot)
                default:
                    let size = try Data(contentsOf: slot).count
                    try Data(repeating: 32, count: size).write(to: slot)
                }
            }
            XCTAssertEqual(response.disposition, .unknown, kind)
            XCTAssertTrue(fixture.consumed(request), kind)
        }
    }

    func testAuthorityIdentityAndPrivacyCannotDriftDuringResultPublication() async throws {
        for phase in [OperatorActionResultCheckpoint.effectObserved, .resultFileSynced] {
            for kind in ["mode", "replacement"] {
                let fixture = try OperatorResultFixture()
                let request = try fixture.replacement()
                try fixture.permit(request)
                let response = await fixture.run(request) { point in
                    guard point == phase else { return }
                    if kind == "mode" {
                        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.authorities.path)
                    } else {
                        try FileManager.default.moveItem(at: fixture.authorities,
                            to: fixture.base.appendingPathComponent("old-authorities"))
                        try FileManager.default.createDirectory(at: fixture.authorities, withIntermediateDirectories: false,
                            attributes: [.posixPermissions: 0o700])
                    }
                }
                XCTAssertEqual(response.disposition, .unknown)
                XCTAssertEqual(try String(contentsOf: fixture.workspace.appendingPathComponent("note.txt")), "after")
                if kind == "replacement" {
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.authorities.path), [])
                }
            }
        }
    }

    func testResultIORejectsInvalidNamesBoundsAndNonPrivateAuthority() throws {
        let fixture = try OperatorResultFixture()
        let directory = try OperatorActionDirectory(path: fixture.authorities.path, ownerPrivate: true)
        for id in ["", "../escape", "not-a-uuid", UUID().uuidString + "/extra"] {
            XCTAssertThrowsError(try directory.requireResultAbsent(actionID: id))
            XCTAssertThrowsError(try directory.publishResult(actionID: id, data: Data("{}\n".utf8)))
        }
        let id = UUID().uuidString
        XCTAssertEqual(try OperatorActionDirectory.resultName(actionID: id), ".result-v1-" + id.lowercased() + ".json")
        XCTAssertThrowsError(try directory.publishResult(actionID: id, data: Data()))
        XCTAssertThrowsError(try directory.publishResult(actionID: id,
            data: Data(repeating: 32, count: OperatorActionHost.maximumResultBytes + 1)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.authorities.path), [])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.authorities.path)
        XCTAssertThrowsError(try directory.requireResultAbsent(actionID: id))
        XCTAssertThrowsError(try directory.publishResult(actionID: id, data: Data("{}\n".utf8)))
    }

    func testOtherObservedOperationsAndStaleReplacementsProduceNoResult() async throws {
        let fixture = try OperatorResultFixture()
        try Data("original".utf8).write(to: fixture.workspace.appendingPathComponent("note.txt"))
        for (operation, arguments) in [("read_file", ["path": "note.txt"]),
            ("list_directory", ["path": "."]), ("make_directory", ["path": "new-directory"])] {
            let request = try fixture.request(operation, arguments)
            try fixture.permit(request)
            let response = await fixture.run(request)
            XCTAssertEqual(response.disposition, .observed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.resultURL(request).path))
        }
        let request = try fixture.replacement()
        try fixture.permit(request)
        let denied = await fixture.run(request)
        XCTAssertEqual(denied.disposition, .denied)
        XCTAssertFalse(fixture.consumed(request))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.resultURL(request).path))
    }
}

/// Disposable fixture shared by all durable-result tests. Only fixed file operations
/// execute; a check invocation fails the test and never launches a process.
final class OperatorResultFixture: @unchecked Sendable {
    enum Injected: Error { case failure }
    let base: URL
    let project: URL
    let packet: URL
    let workspace: URL
    let authorities: URL
    let locks: URL
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        base = URL(fileURLWithPath: try XCTUnwrap(ToolContext.canonicalize(FileManager.default.temporaryDirectory.path)))
            .appendingPathComponent("operator-result-" + UUID().uuidString)
        project = base.appendingPathComponent("project")
        packet = base.appendingPathComponent("packet")
        workspace = packet.appendingPathComponent("Workspace")
        authorities = base.appendingPathComponent("authorities")
        locks = base.appendingPathComponent("locks")
        for directory in [base, project, packet, workspace, authorities] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
    }
    deinit { try? FileManager.default.removeItem(at: base) }
    func target(_ scope: String) -> URL { scope == "source" ? project : scope == "packet" ? packet : workspace }
    func date(_ offset: Double) -> String { ISO8601DateFormatter().string(from: now.addingTimeInterval(offset)) }
    func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func request(_ operation: String, _ arguments: [String: String], scope: String = "workspace") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema_version": 1, "action_id": UUID().uuidString,
            "claim_id": UUID().uuidString, "mission_id": "result-fixture", "project_root": project.path,
            "workspace_root": workspace.path, "policy_sha256": OperatorActionHost.policySHA256,
            "root_scope": scope, "operation": operation, "arguments": arguments], options: [.sortedKeys])
    }
    func replacement() throws -> Data {
        try request("replace_file", ["path": "note.txt", "expected_sha256": "missing", "content": "after"])
    }
    func actionID(_ data: Data) throws -> String { try XCTUnwrap(object(data)["action_id"] as? String) }
    func permitURL(_ data: Data) throws -> URL { authorities.appendingPathComponent(try actionID(data).lowercased() + ".json") }
    func markerURL(_ data: Data) throws -> URL { authorities.appendingPathComponent(".used-" + (try actionID(data).lowercased()) + ".json") }
    func resultURL(_ data: Data) throws -> URL { authorities.appendingPathComponent(try OperatorActionDirectory.resultName(actionID: actionID(data))) }
    func consumed(_ data: Data) -> Bool { (try? markerURL(data)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
    func wire(_ response: OperatorActionResponse) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(response); data.append(10); return data
    }
    func permit(_ data: Data) throws {
        let request = try object(data)
        let projectFD = try OperatorActionDirectory(path: project.path)
        let workspaceFD = try OperatorActionDirectory(path: workspace.path)
        let scope = try XCTUnwrap(request["root_scope"] as? String)
        let targetFD = try OperatorActionDirectory(path: target(scope).path)
        let value: [String: Any] = ["schema_version": 1, "issuer": "buildroulette.operator.v1",
            "operator_request_id": UUID().uuidString, "action_id": request["action_id"]!,
            "claim_id": request["claim_id"]!, "mission_id": request["mission_id"]!,
            "project_root": project.path, "project_device": projectFD.device, "project_inode": projectFD.inode,
            "workspace_root": workspace.path, "workspace_device": workspaceFD.device, "workspace_inode": workspaceFD.inode,
            "root_scope": scope, "allowed_root": targetFD.path, "allowed_root_device": targetFD.device,
            "allowed_root_inode": targetFD.inode, "access": "write", "policy_sha256": OperatorActionHost.policySHA256,
            "request_sha256": OperatorActionHost.sha256(data), "issued_at": date(-1), "expires_at": date(600)]
        let path = try permitURL(data)
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    func run(_ data: Data,
             checkpoint: @Sendable (OperatorActionResultCheckpoint) throws -> Void = { _ in }) async -> OperatorActionResponse {
        await OperatorActionHost.execute(requestData: data, authorityDirectory: authorities,
            now: now, lockDirectory: locks, resultCheckpoint: checkpoint, runCheck: { _ in
                XCTFail("Durable-result fixture must never invoke a check")
                return .init(output: "", exitCode: -1, timedOut: false, cancelled: false,
                    outputTruncated: false, wasSignalled: false, sandboxed: false)
            })
    }
}
