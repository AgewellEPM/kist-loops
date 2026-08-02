import XCTest
@testable import AgentCore

final class ArtifactChangeEvidenceTests: XCTestCase {
    private func tempRoot(_ prefix: String = "artifact-evidence") throws -> String {
        let root = NSTemporaryDirectory() + "\(prefix)-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return ToolContext.canonicalize(root)!
    }

    private func assertArtifact(_ result: ToolResult, tool: String, arguments: [String: Any],
                                path: String, changed: Bool,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.success, result.error ?? "", file: file, line: line)
        XCTAssertEqual(result.metadata["path"] ?? result.metadata["out_dir"], path,
                       file: file, line: line)
        XCTAssertEqual(result.metadata["artifact_path"], path, file: file, line: line)
        XCTAssertEqual(result.metadata["artifact_confined"], "true", file: file, line: line)
        XCTAssertEqual(result.metadata["changed"], changed ? "true" : "false", file: file, line: line)
        let effect = ToolEffectCatalog.observe(tool: tool, arguments: arguments,
                                               outcomeMetadata: result.metadata)
        XCTAssertEqual(effect.confirmsMutation, changed, file: file, line: line)
        XCTAssertEqual(effect.mutation, changed ? .nonSource : .none, file: file, line: line)
    }

    func testGeneratedImageDefaultPathReportsActualDeltaAndIdenticalOverwrite() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        let tool = GenerateImageTool { _, _, _ in Data([0x89, 0x50, 0x4e, 0x47]) }
        let args: [String: Any] = ["prompt": "same image"] // exercise omitted/default output

        let first = try await tool.execute(arguments: args, context: ToolContext(projectRoot: root))
        assertArtifact(first, tool: "generate_image", arguments: args,
                       path: "generated-images/same-image.png", changed: true)
        let second = try await tool.execute(arguments: args, context: ToolContext(projectRoot: root))
        assertArtifact(second, tool: "generate_image", arguments: args,
                       path: "generated-images/same-image.png", changed: false)
    }

    func testEditAudioAndVideoOnlyConfirmChangedBytes() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data([0x89, 0x50, 1]).write(to: URL(fileURLWithPath: root + "/input.png"))
        let context = ToolContext(projectRoot: root)

        let editArgs: [String: Any] = ["image": "input.png", "prompt": "same edit",
                                       "out": "art/edit.png"]
        let edit = EditImageTool { _, _, _ in Data([1, 2, 3]) }
        assertArtifact(try await edit.execute(arguments: editArgs, context: context),
                       tool: "edit_image", arguments: editArgs, path: "art/edit.png", changed: true)
        assertArtifact(try await edit.execute(arguments: editArgs, context: context),
                       tool: "edit_image", arguments: editArgs, path: "art/edit.png", changed: false)

        let audioArgs: [String: Any] = ["text": "same speech", "out": "art/speech.wav"]
        let audio = GenerateAudioTool { _, _ in
            .init(data: Data([0, 1, 2, 3]), sampleRate: 24_000)
        }
        assertArtifact(try await audio.execute(arguments: audioArgs, context: context),
                       tool: "generate_audio", arguments: audioArgs, path: "art/speech.wav", changed: true)
        assertArtifact(try await audio.execute(arguments: audioArgs, context: context),
                       tool: "generate_audio", arguments: audioArgs, path: "art/speech.wav", changed: false)

        let videoArgs: [String: Any] = ["prompt": "same video", "out": "art/video.mp4"]
        let video = GenerateVideoTool { _, _ in Data([0, 0, 0, 24]) }
        assertArtifact(try await video.execute(arguments: videoArgs, context: context),
                       tool: "generate_video", arguments: videoArgs, path: "art/video.mp4", changed: true)
        assertArtifact(try await video.execute(arguments: videoArgs, context: context),
                       tool: "generate_video", arguments: videoArgs, path: "art/video.mp4", changed: false)
    }

    func testTranslationDefaultOutputReportsActualDeltaAndIdenticalOverwrite() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try "hello".write(toFile: root + "/notes.txt", atomically: true, encoding: .utf8)
        let tool = TranslateDocumentTool { _, _, _ in
            .init(text: "hola", truncated: false)
        }
        let args: [String: Any] = ["path": "notes.txt", "to": "Spanish"]
        let context = ToolContext(projectRoot: root)

        assertArtifact(try await tool.execute(arguments: args, context: context),
                       tool: "translate_document", arguments: args,
                       path: "notes.spanish.md", changed: true)
        assertArtifact(try await tool.execute(arguments: args, context: context),
                       tool: "translate_document", arguments: args,
                       path: "notes.spanish.md", changed: false)
    }

    func testExtractClipReportsRelativeOutputAndIdenticalOverwrite() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data([1]).write(to: URL(fileURLWithPath: root + "/movie.mp4"))
        let tool = MediaClipTool(
            resolveFFmpeg: { "/usr/bin/true" },
            runFFmpeg: { _, args, _ in
                guard let output = args.last else { return .failure("missing output") }
                do {
                    try Data([0xff, 0xd8, 0xff]).write(to: URL(fileURLWithPath: output))
                    return ToolResult(success: true, output: "ok")
                } catch {
                    return .failure(String(describing: error))
                }
            })
        let args: [String: Any] = ["path": "movie.mp4", "at": "1", "out": "clips/frame.jpg"]
        let context = ToolContext(projectRoot: root,
                                  shell: ShellPolicy(enabled: true, autoApprove: true, deny: []))

        assertArtifact(try await tool.execute(arguments: args, context: context),
                       tool: "extract_clip", arguments: args, path: "clips/frame.jpg", changed: true)
        assertArtifact(try await tool.execute(arguments: args, context: context),
                       tool: "extract_clip", arguments: args, path: "clips/frame.jpg", changed: false)
    }

    func testWatchDirectoriesHashContentsAndDoNotConfirmIdenticalCaptures() async throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(atPath: root) }
        try Data([1]).write(to: URL(fileURLWithPath: root + "/movie.mp4"))
        let context = ToolContext(projectRoot: root)
        let watchArgs: [String: Any] = ["path": "movie.mp4", "out_dir": "art/watch"]
        let watch = WatchVideoTool(
            capture: { _, outDir, _, _, _ in
                let path = outDir + "/frame_0001.jpg"
                try Data([0xff, 0xd8, 1]).write(to: URL(fileURLWithPath: path))
                return [path]
            },
            analyze: { _, _ in "ok" })
        assertArtifact(try await watch.execute(arguments: watchArgs, context: context),
                       tool: "watch_video", arguments: watchArgs, path: "art/watch", changed: true)
        assertArtifact(try await watch.execute(arguments: watchArgs, context: context),
                       tool: "watch_video", arguments: watchArgs, path: "art/watch", changed: false)

        let liveArgs: [String: Any] = ["seconds": 1, "interval": 1, "out_dir": "art/live"]
        let live = LiveScreenWatchTool(
            capture: { outDir, _, _, _ in
                let path = outDir + "/screen_0001.png"
                try Data([0x89, 0x50, 1]).write(to: URL(fileURLWithPath: path))
                return [path]
            },
            analyze: { _, _ in "ok" })
        assertArtifact(try await live.execute(arguments: liveArgs, context: context),
                       tool: "live_screen_watch", arguments: liveArgs, path: "art/live", changed: true)
        assertArtifact(try await live.execute(arguments: liveArgs, context: context),
                       tool: "live_screen_watch", arguments: liveArgs, path: "art/live", changed: false)
    }

    func testForgedOrAmbiguousArtifactMetadataCannotConfirmMutation() {
        let args: [String: Any] = ["out": "Artifacts/result.png"]
        let incomplete: [[String: String]] = [
            ["changed": "true"],
            ["changed": "true", "artifact_path": "Artifacts/result.png",
             "artifact_kind": "file"],
            ["changed": "true", "artifact_path": "/tmp/result.png",
             "artifact_kind": "file", "artifact_confined": "true"],
            ["changed": "true", "artifact_path": "../result.png",
             "artifact_kind": "file", "artifact_confined": "true"],
            ["changed": "true", "artifact_path": "Artifacts/result.png",
             "artifact_kind": "directory", "artifact_confined": "true"],
        ]
        for metadata in incomplete {
            XCTAssertFalse(ToolEffectCatalog.observe(tool: "generate_image", arguments: args,
                                                      outcomeMetadata: metadata).confirmsMutation,
                           "must reject \(metadata)")
        }
    }
}
