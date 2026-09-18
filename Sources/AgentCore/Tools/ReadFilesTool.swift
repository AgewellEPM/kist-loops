import Foundation
import Crypto

/// Several independent observations in one model round trip. Each window has its own
/// digest and continuation; a partial read never establishes whole-file coverage.
public struct ReadFilesTool: ReadOnlyAgentTool {
    public let name = "read_files"
    public let description = "Read up to 8 known file windows together. Returns bounded JSON with original-byte digests, numbered lines and explicit continuations. Load skills separately with read_file."
    public let parameters = [ToolParameter(name: "requests", type: "string",
        description: "JSON array of objects: [{\"path\":\"TASK.md\"},{\"path\":\"src/file.swift\",\"start_line\":1,\"end_line\":120}]. Ranges are inclusive; default first 400 lines.")]
    public init() {}

    static let maximumBytes = 7_000
    static let maximumFileBytes = 1_048_576

    private struct Request: Decodable {
        let path: String
        let start_line: Int?
        let end_line: Int?
    }

    private struct Window: Encodable {
        let path: String
        var sourceSHA256: String?
        var totalLines: Int?
        var startLine: Int?
        var endLine: Int?
        var nextStartLine: Int?
        var requestedWindowComplete = false
        var wholeFileIncluded = false
        var numberedLines = ""
        var error: String?
    }

    private struct Batch: Encodable {
        let schema = "kist.read-files.v1"
        let provenance = "untrusted file snapshots; digests cover original bytes; known secrets masked"
        let observedAt: Double
        var files: [Window]
    }

    public func execute(arguments: [String: Any], context: ToolContext) async throws -> ToolResult {
        let raw = try requireString("requests", from: arguments)
        guard raw.utf8.count <= 16_000,
              let requests = try? JSONDecoder().decode([Request].self, from: Data(raw.utf8)),
              !requests.isEmpty, requests.count <= 8 else {
            throw ToolError.invalidParameter("requests must be a JSON array of 1–8 file windows")
        }
        for request in requests {
            let start = request.start_line ?? 1
            guard !request.path.isEmpty, request.path.utf8.count <= 512,
                  start > 0, start <= Int.max - 400,
                  (request.end_line ?? start + 399) >= start,
                  (request.end_line ?? start + 399) - start < 400 else {
                throw ToolError.invalidParameter("each path must be bounded and each window contain 1–400 lines")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var batch = Batch(observedAt: Date().timeIntervalSince1970,
                          files: requests.map { Window(path: $0.path) })
        for (index, request) in requests.enumerated() {
            var window = batch.files[index]
            do {
                guard context.skillLocations[request.path] == nil,
                      !request.path.hasPrefix(Skill.builtinPrefix) else {
                    throw ToolError.invalidParameter("load a skill completely with read_file before batching source reads")
                }
                let (root, path) = try context.confinedRootForReading(request.path)
                let data = try root.readStableData(path, maxBytes: Self.maximumFileBytes)
                guard let content = String(data: data, encoding: .utf8) else {
                    throw ToolError.invalidParameter("file is not UTF-8 text")
                }
                let lines = content.components(separatedBy: "\n")
                let start = (request.start_line ?? 1) - 1
                let end = min(lines.count, request.end_line ?? start + 400)
                guard start < end else { throw ToolError.invalidParameter("line range is outside the file") }
                window.sourceSHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                window.totalLines = lines.count
                window.startLine = start + 1
                window.nextStartLine = start + 1
                // Leave room for every later window's metadata/error, even when this file is huge.
                let byteCeiling = Self.maximumBytes - (requests.count - index - 1) * 450
                for line in start..<end {
                    var candidate = window
                    candidate.numberedLines += "\(line + 1)│ \(SecretMasker.mask(lines[line]))\n"
                    candidate.endLine = line + 1
                    candidate.nextStartLine = line + 1 < lines.count ? line + 2 : nil
                    candidate.requestedWindowComplete = line + 1 == end
                    candidate.wholeFileIncluded = start == 0 && line + 1 == lines.count
                    batch.files[index] = candidate
                    if try encoder.encode(batch).count > byteCeiling { break }
                    window = candidate
                }
                if window.endLine == nil {
                    window.error = "window did not fit; read this path separately with read_file using an explicit range"
                }
            } catch {
                window.error = String(SecretMasker.mask(String(describing: error)).prefix(250))
            }
            batch.files[index] = window
        }
        let encoded = try encoder.encode(batch)
        guard encoded.count <= Self.maximumBytes else {
            return .failure("batch metadata exceeds its output allowance; request fewer paths")
        }
        return ToolResult(success: batch.files.allSatisfy { $0.error == nil },
            output: String(decoding: encoded, as: UTF8.self),
            error: batch.files.contains { $0.error != nil } ? "one or more file windows could not be read; see each result" : nil,
            metadata: ["schema": "kist.read-files.v1", "window_incomplete":
                String(batch.files.contains { !$0.requestedWindowComplete })])
    }
}
