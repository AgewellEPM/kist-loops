import XCTest
@testable import AgentCore
#if canImport(Glibc)
import Glibc
#endif

/// Real-fd transport round-trip via socketpair (no bind/accept needed): a framed request written to one end
/// decodes exactly at the other, the tested BrokerCore produces the response, and it round-trips back. Proves
/// writeFrame/readFrame over a real Unix socket + the broker path end-to-end, with a mock actuator (no TCC).
final class UnixSocketTransportTests: XCTestCase {

    private func pair() -> (Int32, Int32)? {
        var fds: [Int32] = [0, 0]
        #if os(Linux)
        let type = Int32(SOCK_STREAM.rawValue)
        #else
        let type = SOCK_STREAM
        #endif
        guard socketpair(AF_UNIX, type, 0, &fds) == 0 else { return nil }
        return (fds[0], fds[1])
    }

    func testFramedRequestResponseRoundTripOverRealSocket() throws {
        guard let (a, b) = pair() else { return XCTFail("socketpair failed") }
        defer { close(a); close(b) }

        let req = DesktopActionRequest(id: "rt1", kind: .click, x: 42, y: 99, clicks: 2)
        try UnixSocketTransport.writeFrame(req, to: a)
        let received = try UnixSocketTransport.readFrame(DesktopActionRequest.self, from: b)
        XCTAssertEqual(received, req, "the request must decode byte-identical at the peer")

        // The tested broker produces the response; a mock actuator stands in for the real CGEvent hands.
        let mock = MockDesktopActuator { .init(id: $0.id, ok: true, message: "clicked @\($0.x ?? -1),\($0.y ?? -1)") }
        let broker = BrokerCore(actuator: mock, expectedUID: getuid())
        let peer = DesktopPeer(uid: getuid(), authenticated: true, describedBy: "test")
        let resp = broker.handle(received, from: peer)
        try UnixSocketTransport.writeFrame(resp, to: b)

        let back = try UnixSocketTransport.readFrame(DesktopActionResponse.self, from: a)
        XCTAssertTrue(back.ok)
        XCTAssertEqual(back.message, "clicked @42,99")
        XCTAssertEqual(mock.performed.count, 1, "the authorized request reached the actuator exactly once")
    }

    func testUnauthorizedPeerRoundTripsAFailureWithoutActuating() throws {
        guard let (a, b) = pair() else { return XCTFail("socketpair failed") }
        defer { close(a); close(b) }
        try UnixSocketTransport.writeFrame(DesktopActionRequest(id: "x", kind: .type, text: "hi"), to: a)
        let received = try UnixSocketTransport.readFrame(DesktopActionRequest.self, from: b)

        let mock = MockDesktopActuator()
        let broker = BrokerCore(actuator: mock, expectedUID: getuid())
        let rogue = DesktopPeer(uid: getuid(), authenticated: false, describedBy: "rogue")   // failed signature check
        try UnixSocketTransport.writeFrame(broker.handle(received, from: rogue), to: b)

        let back = try UnixSocketTransport.readFrame(DesktopActionResponse.self, from: a)
        XCTAssertFalse(back.ok)
        XCTAssertEqual(back.code, .unauthorizedPeer)
        XCTAssertTrue(mock.performed.isEmpty, "an unauthorized peer never actuates, even over a real socket")
    }
}
