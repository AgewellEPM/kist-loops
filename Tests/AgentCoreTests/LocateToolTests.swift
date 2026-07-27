import XCTest
@testable import AgentCore

final class MoondreamClientTests: XCTestCase {

    func testParsePoints() throws {
        let json = #"{"points":[{"x":0.5,"y":0.25},{"x":0.1,"y":0.9}],"request_id":"r"}"#.data(using: .utf8)!
        let pts = try MoondreamClient.parsePoints(json)
        XCTAssertEqual(pts, [.init(x: 0.5, y: 0.25), .init(x: 0.1, y: 0.9)])
    }

    func testParsePointsEmptyIsNotError() throws {
        XCTAssertEqual(try MoondreamClient.parsePoints(#"{"points":[]}"#.data(using: .utf8)!), [])
        XCTAssertEqual(try MoondreamClient.parsePoints(#"{"request_id":"r"}"#.data(using: .utf8)!), [])   // missing key ⇒ empty
    }

    func testParsePointsToleratesStringNumbers() throws {
        let pts = try MoondreamClient.parsePoints(#"{"points":[{"x":"0.5","y":"0.5"}]}"#.data(using: .utf8)!)
        XCTAssertEqual(pts, [.init(x: 0.5, y: 0.5)])
    }

    func testParsePointsRejectsNonObject() {
        XCTAssertThrowsError(try MoondreamClient.parsePoints(#"[1,2,3]"#.data(using: .utf8)!))
    }

    func testParsePointsRejectsNonFiniteCoordinate() {
        // "nan"/"inf" must NOT parse (they'd trap on Int() conversion downstream).
        XCTAssertThrowsError(try MoondreamClient.parsePoints(#"{"points":[{"x":"nan","y":0.5}]}"#.data(using: .utf8)!))
        XCTAssertThrowsError(try MoondreamClient.parsePoints(#"{"points":[{"x":"inf","y":0.5}]}"#.data(using: .utf8)!))
    }

    func testParsePointsPresentButMalformedThrows() {
        // A present-but-wrong `points` is a real error, not silently "not found".
        XCTAssertThrowsError(try MoondreamClient.parsePoints(#"{"points":"nope"}"#.data(using: .utf8)!))
        XCTAssertThrowsError(try MoondreamClient.parsePoints(#"{"points":[{"x":0.5}]}"#.data(using: .utf8)!))   // missing y
    }

    func testParsePointsRejectsBooleanCoordinates() {
        // JSON booleans must NOT bridge to 1.0/0.0 and become an edge/corner click.
        XCTAssertThrowsError(try MoondreamClient.parsePoints(#"{"points":[{"x":true,"y":false}]}"#.data(using: .utf8)!))
    }

    func testPixelsSkipsNonFinitePointsWithoutCrashing() {
        let px = MoondreamClient.pixels(from: [.init(x: .nan, y: 0.5), .init(x: 0.5, y: 0.5)], width: 100, height: 100)
        XCTAssertEqual(px.count, 1)   // the nan point is dropped, not crashed on
        XCTAssertEqual(px[0].x, 50)
    }

    func testPixelsHandlesFiniteButHugeValueWithoutTrapping() {
        // 1e20 is finite (passes isFinite) but would overflow Int() unless clamped to [0,1] first.
        let px = MoondreamClient.pixels(from: [.init(x: 1e20, y: -1e20)], width: 1000, height: 800)
        XCTAssertEqual(px[0].x, 999)   // clamped to the right edge
        XCTAssertEqual(px[0].y, 0)     // clamped to the top
    }

    func testBuildRequestSchemeGuard() throws {
        XCTAssertNoThrow(try MoondreamClient.buildRequest(baseURL: "https://api.moondream.ai/v1", path: "point", apiKey: "k", body: [:]))
        XCTAssertNoThrow(try MoondreamClient.buildRequest(baseURL: "http://localhost:2020/v1", path: "point", apiKey: nil, body: [:]))
        XCTAssertNoThrow(try MoondreamClient.buildRequest(baseURL: "http://127.0.0.1:2020/v1", path: "point", apiKey: nil, body: [:]))
        // plaintext http to a REMOTE host is refused (would leak screenshots/key in the clear).
        XCTAssertThrowsError(try MoondreamClient.buildRequest(baseURL: "http://evil.example.com/v1", path: "point", apiKey: "k", body: [:]))
        XCTAssertThrowsError(try MoondreamClient.buildRequest(baseURL: "ftp://host/v1", path: "point", apiKey: nil, body: [:]))
    }

    func testPixelConversionScalesAndClamps() {
        let px = MoondreamClient.pixels(from: [.init(x: 0.5, y: 0.5), .init(x: 1.2, y: -0.1)], width: 1000, height: 800)
        XCTAssertEqual(px[0].x, 500); XCTAssertEqual(px[0].y, 400)
        // out-of-range normalized values clamp into the image, never off it.
        XCTAssertEqual(px[1].x, 999); XCTAssertEqual(px[1].y, 0)
    }

    func testDataURL() {
        XCTAssertEqual(MoondreamClient.dataURL(Data([0x00, 0x01]), mime: "image/png"), "data:image/png;base64,AAE=")
    }

    func testBuildRequestSetsAuthAndBody() throws {
        let req = try MoondreamClient.buildRequest(baseURL: "https://api.moondream.ai/v1", path: "point",
                                                   apiKey: "secret", body: ["object": "cat"])
        XCTAssertEqual(req.url?.absoluteString, "https://api.moondream.ai/v1/point")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Moondream-Auth"), "secret")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(req.httpBody)
        XCTAssertEqual(String(data: body, encoding: .utf8), #"{"object":"cat"}"#)
    }

    func testBuildRequestOmitsAuthWhenNoKey() throws {
        let req = try MoondreamClient.buildRequest(baseURL: "http://localhost:2020/v1", path: "point", apiKey: nil, body: [:])
        XCTAssertNil(req.value(forHTTPHeaderField: "X-Moondream-Auth"))   // local server needs no key
    }
}

final class LocateToolTests: XCTestCase {

    /// Build a minimal-but-valid PNG header for the given dimensions (only the 24-byte prefix matters).
    private func pngHeader(width: Int, height: Int) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])   // signature
        d.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])                    // IHDR length
        d.append(contentsOf: [0x49, 0x48, 0x44, 0x52])                    // "IHDR"
        func be(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
        d.append(contentsOf: be(width))
        d.append(contentsOf: be(height))
        return d
    }

    func testPngDimensions() {
        XCTAssertEqual(LocateTool.pngDimensions(pngHeader(width: 1440, height: 900))?.width, 1440)
        XCTAssertEqual(LocateTool.pngDimensions(pngHeader(width: 1440, height: 900))?.height, 900)
    }

    func testPngDimensionsRejectsNonPng() {
        XCTAssertNil(LocateTool.pngDimensions(Data("not a png".utf8)))
        XCTAssertNil(LocateTool.pngDimensions(Data([0x89, 0x50])))   // too short
    }

    func testLocateReturnsPixelClickTarget() async throws {
        let dir = NSTemporaryDirectory() + "loc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let shot = dir + "/shot.png"
        try pngHeader(width: 800, height: 600).write(to: URL(fileURLWithPath: shot))
        // Mock perception: "the button" is at the center.
        let tool = LocateTool { _, _ in [.init(x: 0.5, y: 0.5)] }
        let r = try await tool.execute(arguments: ["image": "shot.png", "target": "the button"],
                                       context: ToolContext(projectRoot: dir))
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["x"], "400")
        XCTAssertEqual(r.metadata["y"], "300")
        XCTAssertTrue(r.output.contains("desktop_control"))
    }

    func testLocateNotFoundIsSuccessWithZero() async throws {
        let dir = NSTemporaryDirectory() + "loc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try pngHeader(width: 800, height: 600).write(to: URL(fileURLWithPath: dir + "/shot.png"))
        let tool = LocateTool { _, _ in [] }   // nothing found
        let r = try await tool.execute(arguments: ["image": "shot.png", "target": "unicorn"],
                                       context: ToolContext(projectRoot: dir))
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.metadata["found"], "0")
        XCTAssertTrue(r.output.contains("not found"))
    }

    func testLocateRejectsNonPng() async throws {
        let dir = NSTemporaryDirectory() + "loc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: URL(fileURLWithPath: dir + "/notimage.txt"))
        let tool = LocateTool { _, _ in [.init(x: 0.5, y: 0.5)] }
        let r = try await tool.execute(arguments: ["image": "notimage.txt", "target": "x"],
                                       context: ToolContext(projectRoot: dir))
        XCTAssertFalse(r.success)
        XCTAssertTrue(r.error?.contains("PNG") ?? false)
    }
}
