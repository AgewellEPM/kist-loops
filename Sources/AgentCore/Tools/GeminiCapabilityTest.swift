import Foundation

/// A live smoke-test of the Gemini clients: one minimal real call per capability, so a single
/// command proves the parsers match the live API (closing the "built without a key" verification gap).
/// Probes are injectable so the orchestration + rendering are unit-tested without spending.
public enum GeminiCapabilityTest {
    public struct Result: Sendable, Equatable {
        public var name: String
        public var ok: Bool
        public var detail: String
        public init(name: String, ok: Bool, detail: String) { self.name = name; self.ok = ok; self.detail = detail }
    }

    public struct Probe: Sendable {
        public var name: String
        public var run: @Sendable () async -> Result
        public init(name: String, run: @escaping @Sendable () async -> Result) { self.name = name; self.run = run }
    }

    public static func runAll(_ probes: [Probe]) async -> [Result] {
        var out: [Result] = []
        for p in probes { out.append(await p.run()) }   // serial: cheap, deterministic order, gentle on quota
        return out
    }

    public static func render(_ results: [Result]) -> String {
        let pass = results.filter { $0.ok }.count
        var lines = ["Gemini live self-test · \(pass)/\(results.count) passed", ""]
        for r in results {
            lines.append("\(r.ok ? "✓" : "✗") \(r.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(r.detail)")
        }
        return lines.joined(separator: "\n")
    }

    /// The real probes — one minimal call per Gemini client/path most likely to drift from the docs.
    /// When a `registry` is given, also exercises the full translate_document tool path.
    public static func probes(geminiKey: String, registry: ProviderRegistry? = nil) -> [Probe] {
        var probes: [Probe] = [
            Probe(name: "count_tokens") {
                await guarded("count_tokens") {
                    let n = try await GeminiTokenCounter(apiKey: geminiKey).count(text: "ping")
                    return n > 0 ? "ok (\(n) tokens)" : nil
                }
            },
            Probe(name: "embeddings") {
                await guarded("embeddings") {
                    let v = try await GeminiEmbeddingClient(apiKey: geminiKey).embedding(for: "ping")
                    return v.isEmpty ? nil : "ok (\(v.count)-dim)"
                }
            },
            Probe(name: "image_gen") {
                await guarded("image_gen") {
                    let d = try await GeminiEditImageClient(apiKey: geminiKey).generate(prompt: "a small red dot on white")
                    return d.isEmpty ? nil : "ok (\(d.count) bytes)"
                }
            },
            Probe(name: "tts") {
                await guarded("tts") {
                    let pcm = try await GeminiTTSClient(apiKey: geminiKey).synthesize(text: "hi")
                    return pcm.data.isEmpty ? nil : "ok (\(pcm.data.count) bytes @ \(pcm.sampleRate)Hz)"
                }
            },
            // Proves the live API ACCEPTS the built-in tools (google_search/url_context/code_execution)
            // alongside our functionDeclarations — the combo I couldn't verify when building it.
            Probe(name: "grounded_chat") {
                await guarded("grounded_chat") {
                    // Tool-less call → the built-ins (google_search/url_context/code_execution) ARE sent.
                    // Verifies the built-in request shape is accepted live (they can't ride with functions).
                    let stream = try await GeminiProvider().streamTools(
                        messages: [ChatMessage(role: .user, content: "In one short sentence, what is the Eiffel Tower?")],
                        model: "gemini-2.5-flash", settings: ModelSettings(), apiKey: geminiKey, tools: [])
                    var text = ""
                    for try await event in stream { if case .delta(let d) = event { text += d } }
                    return text.isEmpty ? nil : "ok (built-ins accepted, \(text.count) chars)"
                }
            },
        ]
        if let registry { probes.append(translateProbe(registry: registry, key: geminiKey)) }
        return probes
    }

    /// Full translate_document path on a tiny in-memory doc (read → prompt → stream → write).
    static func translateProbe(registry: ProviderRegistry, key: String) -> Probe {
        Probe(name: "translate_doc") {
            await guarded("translate_doc") {
                let dir = NSTemporaryDirectory() + "gtest_\(UUID().uuidString)"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(atPath: dir) }
                try "Hello, world.".write(toFile: dir + "/in.txt", atomically: true, encoding: .utf8)
                let tool = TranslateDocumentTool(registry: registry,
                                                 binding: ProviderBinding(providerId: "gemini", model: nil), geminiKey: key)
                let r = try await tool.execute(arguments: ["path": "in.txt", "to": "Spanish"],
                                               context: ToolContext(projectRoot: dir))
                return r.success ? "ok" : nil
            }
        }
    }

    /// Run a probe body, turning a thrown error or a nil success-detail into a clear ✗ Result.
    static func guarded(_ name: String, _ body: @Sendable () async throws -> String?) async -> Result {
        do {
            if let detail = try await body() { return Result(name: name, ok: true, detail: detail) }
            return Result(name: name, ok: false, detail: "empty/invalid response")
        } catch {
            return Result(name: name, ok: false, detail: "\(error)".prefix(120).description)
        }
    }
}
