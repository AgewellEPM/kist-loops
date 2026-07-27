import XCTest
import Foundation
@testable import AgentCore

/// LIVE proof that the Streamable-HTTP MCP transport actually works: spins a real local JSON-RPC HTTP
/// server (python3), then drives MCPHTTPConnection through initialize + tools/list + tools/call over the
/// wire. Skips cleanly if python3 isn't available.
final class MCPHTTPLiveTests: XCTestCase {

    func testHTTPConnectionHandshakeListAndCall() async throws {
        guard let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("python3 not available")
        }
        let script = """
        import http.server, json, sys
        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                n = int(self.headers.get('Content-Length', 0))
                body = json.loads(self.rfile.read(n)) if n else {}
                method, mid = body.get('method'), body.get('id')
                if method == 'initialize':
                    r = {"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"mock"}}}
                    self.send_response(200); self.send_header('Content-Type','application/json'); self.send_header('Mcp-Session-Id','sess123'); self.end_headers()
                    self.wfile.write(json.dumps(r).encode())
                elif method == 'tools/list':
                    assert self.headers.get('Authorization') == 'Bearer tok', 'missing auth header'
                    assert self.headers.get('Mcp-Session-Id') == 'sess123', 'missing session id'
                    r = {"jsonrpc":"2.0","id":mid,"result":{"tools":[{"name":"echo","description":"echoes","inputSchema":{}}]}}
                    self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
                    self.wfile.write(json.dumps(r).encode())
                elif method == 'tools/call':
                    r = {"jsonrpc":"2.0","id":mid,"result":{"content":[{"type":"text","text":"hi"}]}}
                    self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
                    self.wfile.write(json.dumps(r).encode())
                else:
                    self.send_response(202); self.end_headers()
            def log_message(self, *a): pass
        srv = http.server.HTTPServer(('127.0.0.1', 0), H)
        print(srv.server_address[1], flush=True)
        srv.serve_forever()
        """
        let scriptPath = NSTemporaryDirectory() + "mcp_mock_\(UUID().uuidString).py"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: scriptPath) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [scriptPath]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        try proc.run()
        defer { proc.terminate() }

        // Read the port the server bound to (first line of stdout).
        var port = ""
        let handle = outPipe.fileHandleForReading
        let deadline = Date().addingTimeInterval(5)
        while port.isEmpty && Date() < deadline {
            let d = handle.availableData
            if !d.isEmpty { port = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard let p = Int(port), p > 0 else { throw XCTSkip("mock server did not report a port") }

        let cfg = MCPServerConfig(name: "mock", url: "http://127.0.0.1:\(p)/mcp", headers: ["Authorization": "Bearer tok"])
        let conn = MCPHTTPConnection(config: cfg, timeout: 5)
        try await conn.start()                              // initialize + captures session id
        let tools = try await conn.listTools()             // sends auth + session headers (asserted server-side)
        XCTAssertEqual(tools.map { $0.name }, ["echo"])
        let result = try await conn.callTool(name: "echo", arguments: ["x": 1])
        XCTAssertNotNil(result["content"])
        await conn.shutdown()
    }
}
