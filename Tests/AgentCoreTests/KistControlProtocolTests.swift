import XCTest
@testable import AgentCore

/// The IPC contract between `kist` and the `kist-control` broker must round-trip exactly and frame safely.
final class KistControlProtocolTests: XCTestCase {

    func testRequestResponseRoundTripThroughFraming() throws {
        let req = DesktopActionRequest(id: "r1", kind: .click, display: 1, x: 100, y: 200, clicks: 2)
        let frame = try KistControlFraming.encode(req)
        let decoded = try KistControlFraming.decode(DesktopActionRequest.self, from: frame)
        XCTAssertEqual(decoded?.value, req)
        XCTAssertEqual(decoded?.consumed, frame.count)

        let resp = DesktopActionResponse(id: "r1", ok: true, message: "done", width: 10, height: 20)
        let rframe = try KistControlFraming.encode(resp)
        XCTAssertEqual(try KistControlFraming.decode(DesktopActionResponse.self, from: rframe)?.value, resp)
    }

    func testPartialFrameReturnsNilUntilComplete() throws {
        let req = DesktopActionRequest(id: "r2", kind: .type, text: "hello")
        let frame = try KistControlFraming.encode(req)
        // Fewer than 4 length bytes, and length-present-but-body-incomplete, both yield nil (wait for more).
        XCTAssertNil(try KistControlFraming.decode(DesktopActionRequest.self, from: frame.prefix(2)))
        XCTAssertNil(try KistControlFraming.decode(DesktopActionRequest.self, from: frame.prefix(frame.count - 1)))
        XCTAssertNotNil(try KistControlFraming.decode(DesktopActionRequest.self, from: frame))
    }

    func testOversizedFrameFailsClosed() {
        var evil = Data([0xFF, 0xFF, 0xFF, 0xFF])   // ~4GB claimed length
        evil.append(Data([0x7b, 0x7d]))
        XCTAssertThrowsError(try KistControlFraming.decode(DesktopActionResponse.self, from: evil, maxBytes: 1024)) {
            XCTAssertEqual($0 as? KistControlFramingError, .frameTooLarge(0xFFFFFFFF))
        }
    }

    func testTwoBackToBackFramesConsumeIndependently() throws {
        let a = try KistControlFraming.encode(DesktopActionRequest(id: "a", kind: .move, x: 1, y: 2))
        let b = try KistControlFraming.encode(DesktopActionRequest(id: "b", kind: .key, keys: ["cmd", "c"]))
        var buf = a; buf.append(b)
        let first = try KistControlFraming.decode(DesktopActionRequest.self, from: buf)
        XCTAssertEqual(first?.value.id, "a")
        let rest = buf.suffix(from: buf.startIndex + first!.consumed)
        XCTAssertEqual(try KistControlFraming.decode(DesktopActionRequest.self, from: Data(rest))?.value.id, "b")
    }

    func testTCCNeedsAreCorrectPerKind() {
        XCTAssertTrue(DesktopActionKind.click.needsAccessibility)
        XCTAssertTrue(DesktopActionKind.type.needsAccessibility)
        XCTAssertFalse(DesktopActionKind.screenshot.needsAccessibility)
        XCTAssertTrue(DesktopActionKind.screenshot.needsScreenRecording)
        XCTAssertFalse(DesktopActionKind.mousePosition.needsAccessibility)   // pure read
        XCTAssertFalse(DesktopActionKind.mousePosition.needsScreenRecording)
    }
}
