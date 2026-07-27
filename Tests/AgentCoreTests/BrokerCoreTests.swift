import XCTest
@testable import AgentCore

/// The broker's security invariant: an action reaches the actuator ONLY after peer-auth + same-uid +
/// version + structural gates all pass. Every failing gate must short-circuit BEFORE the actuator.
final class BrokerCoreTests: XCTestCase {
    private let uid: uid_t = 501
    private func req(_ kind: DesktopActionKind = .click, id: String = "1", version: Int = KistControlProtocol.version,
                     x: Int? = 10, y: Int? = 20) -> DesktopActionRequest {
        DesktopActionRequest(version: version, id: id, kind: kind, x: x, y: y)
    }
    private func authedPeer(uid: uid_t) -> DesktopPeer { DesktopPeer(uid: uid, authenticated: true, describedBy: "kist") }

    func testUnauthenticatedPeerNeverReachesActuator() {
        let mock = MockDesktopActuator()
        let core = BrokerCore(actuator: mock, expectedUID: uid)
        let r = core.handle(req(), from: DesktopPeer(uid: uid, authenticated: false, describedBy: "rogue"))
        XCTAssertFalse(r.ok); XCTAssertEqual(r.code, .unauthorizedPeer)
        XCTAssertTrue(mock.performed.isEmpty, "a failed code-signature check must never actuate")
    }

    func testWrongUidRejectedBeforeActuator() {
        let mock = MockDesktopActuator()
        let core = BrokerCore(actuator: mock, expectedUID: uid)
        let r = core.handle(req(), from: authedPeer(uid: 777))
        XCTAssertEqual(r.code, .unauthorizedPeer)
        XCTAssertTrue(mock.performed.isEmpty)
    }

    func testVersionMismatchRejectedBeforeActuator() {
        let mock = MockDesktopActuator()
        let core = BrokerCore(actuator: mock, expectedUID: uid)
        let r = core.handle(req(version: KistControlProtocol.version + 1), from: authedPeer(uid: uid))
        XCTAssertEqual(r.code, .versionMismatch)
        XCTAssertTrue(mock.performed.isEmpty)
    }

    func testStructurallyInvalidRejectedBeforeActuator() {
        let mock = MockDesktopActuator()
        let core = BrokerCore(actuator: mock, expectedUID: uid)
        let r = core.handle(req(.click, x: nil, y: nil), from: authedPeer(uid: uid))
        XCTAssertEqual(r.code, .invalidRequest)
        XCTAssertTrue(mock.performed.isEmpty)
    }

    func testFullyAuthorizedRequestReachesActuatorOnce() {
        let mock = MockDesktopActuator { .init(id: $0.id, ok: true, message: "clicked") }
        let core = BrokerCore(actuator: mock, expectedUID: uid)
        let r = core.handle(req(), from: authedPeer(uid: uid))
        XCTAssertTrue(r.ok); XCTAssertEqual(r.message, "clicked")
        XCTAssertEqual(mock.performed.count, 1)
        XCTAssertEqual(mock.performed.first?.kind, .click)
    }

    func testStructuralRefusalMatrix() {
        XCTAssertNotNil(BrokerCore.structuralRefusal(DesktopActionRequest(id: "x", kind: .drag, x: 1, y: 1)))   // missing dx/dy
        XCTAssertNotNil(BrokerCore.structuralRefusal(DesktopActionRequest(id: "x", kind: .type, text: "")))
        XCTAssertNotNil(BrokerCore.structuralRefusal(DesktopActionRequest(id: "x", kind: .key, keys: [])))
        XCTAssertNotNil(BrokerCore.structuralRefusal(DesktopActionRequest(id: "x", kind: .move, display: -1, x: 1, y: 1)))
        XCTAssertNil(BrokerCore.structuralRefusal(DesktopActionRequest(id: "x", kind: .screenshot)))            // no coords needed
        XCTAssertNil(BrokerCore.structuralRefusal(DesktopActionRequest(id: "x", kind: .key, keys: ["cmd", "c"])))
    }
}
