import Foundation
import AgentCore

/// Offline dataset evidence inspection. No provider, tool registry, MCP or terminal session is initialized.
enum KistBuilderEvidenceCommand {
    static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 2, arguments[0] == "--inspect-builder-evidence" else {
            return failure("usage: kist --inspect-builder-evidence <sealed-run.json>")
        }
        do {
            let file = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let root = try ConfinedRoot(root: file.deletingLastPathComponent().path, readOnly: true)
            let data = try root.readStableOwnerOnlyData(file.lastPathComponent, maxBytes: 16_777_216)
            let report = try BuilderTrainingEvidence.inspect(data)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return 0
        } catch { return failure(String(describing: error)) }
    }

    private static func failure(_ message: String) -> Int32 {
        let body: [String: Any] = ["schema": "kist.builder-training-evidence.v1",
                                 "historicalAccepted": false, "error": SecretMasker.mask(message)]
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self))
        }
        return 2
    }
}
