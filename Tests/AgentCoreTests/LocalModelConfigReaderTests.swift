import XCTest
@testable import AgentCore

/// Pins safety-net #3: chat-template/stop detection for local models. The loop's clean-stop on local
/// weights depends entirely on picking the right turn-end token, so detection + the GGUF/JSON readers
/// are unit-pinned (incl. a hand-built GGUF fixture — no network, no model download).
final class LocalModelConfigReaderTests: XCTestCase {

    // MARK: family detection from the template string (strongest signal)

    func testDetectLlama3FromTemplate() {
        XCTAssertEqual(ChatTemplateFamily.detect(
            chatTemplate: "{{ '<|start_header_id|>' }}...{{ '<|eot_id|>' }}", eosToken: nil, modelName: nil), .llama3)
    }
    func testDetectChatMLFromTemplate() {
        XCTAssertEqual(ChatTemplateFamily.detect(
            chatTemplate: "<|im_start|>system\n...<|im_end|>", eosToken: nil, modelName: nil), .chatml)
    }
    func testDetectGemmaFromTemplate() {
        XCTAssertEqual(ChatTemplateFamily.detect(
            chatTemplate: "<start_of_turn>user\n...<end_of_turn>", eosToken: nil, modelName: nil), .gemma)
    }
    func testDetectMistralFromTemplate() {
        XCTAssertEqual(ChatTemplateFamily.detect(
            chatTemplate: "{{ '[INST]' + message + '[/INST]' }}", eosToken: nil, modelName: nil), .mistral)
    }
    func testDetectDeepSeekFromTemplate() {
        XCTAssertEqual(ChatTemplateFamily.detect(
            chatTemplate: "<｜begin▁of▁sentence｜>...<｜end▁of▁sentence｜>", eosToken: nil, modelName: nil), .deepseek)
    }

    func testFallBackToEosThenName() {
        XCTAssertEqual(ChatTemplateFamily.detect(chatTemplate: nil, eosToken: "<|im_end|>", modelName: nil), .chatml)
        XCTAssertEqual(ChatTemplateFamily.detect(chatTemplate: nil, eosToken: nil, modelName: "Qwen2.5-7B-Instruct"), .chatml)
        XCTAssertEqual(ChatTemplateFamily.detect(chatTemplate: nil, eosToken: nil, modelName: "Meta-Llama-3-8B"), .llama3)
        XCTAssertEqual(ChatTemplateFamily.detect(chatTemplate: nil, eosToken: nil, modelName: "mystery-model"), .unknown)
    }

    // MARK: stop sequences — every known family stops on its turn-end token, never its start token

    func testEveryKnownFamilyHasTurnEndStops() {
        for fam in ChatTemplateFamily.allCases where fam != .unknown {
            XCTAssertFalse(fam.stopSequences.isEmpty, "\(fam) must declare stop sequences")
        }
        XCTAssertTrue(ChatTemplateFamily.llama3.stopSequences.contains("<|eot_id|>"))
        XCTAssertTrue(ChatTemplateFamily.chatml.stopSequences.contains("<|im_end|>"))
        XCTAssertFalse(ChatTemplateFamily.chatml.stopSequences.contains("<|im_start|>"), "never stop on the START token")
        XCTAssertTrue(ChatTemplateFamily.unknown.stopSequences.isEmpty)
    }

    // DeepSeek HIGH: a stop list must NEVER contain a turn-START token (own OR next-turn) — that token
    // could appear in output and truncate it. Pins the invariant on every family, not just chatml.
    func testNoFamilyStopsOnAStartToken() {
        let startTokens = ["<|im_start|>", "<start_of_turn>", "[INST]", "<|user|>", "<|assistant|>", "<|start_header_id|>"]
        for fam in ChatTemplateFamily.allCases {
            for stop in fam.stopSequences {
                XCTAssertFalse(startTokens.contains(stop), "\(fam) must not stop on the start token \(stop)")
            }
        }
        XCTAssertEqual(ChatTemplateFamily.mistral.stopSequences, ["</s>"])           // no [INST]
        XCTAssertFalse(ChatTemplateFamily.phi.stopSequences.contains("<|user|>"))    // no <|user|>
    }

    // GPT LOW: a bare generic EOS must not, by itself, force a family classification.
    func testGenericEosTokenIsNotDecisive() {
        XCTAssertEqual(ChatTemplateFamily.detect(chatTemplate: nil, eosToken: "<|end_of_text|>", modelName: nil), .unknown)
        // but the llama3-specific EOS still classifies
        XCTAssertEqual(ChatTemplateFamily.detect(chatTemplate: nil, eosToken: "<|eot_id|>", modelName: nil), .llama3)
    }

    func testProfileAppendsDeclaredEosToStops() {
        let p = LocalModelTemplate.from(chatTemplate: "<|im_end|>", eosToken: "<|special_eos|>", modelName: nil, source: "t")
        XCTAssertEqual(p.family, .chatml)
        XCTAssertTrue(p.stopSequences.contains("<|im_end|>"))
        XCTAssertTrue(p.stopSequences.contains("<|special_eos|>"), "a declared EOS we don't already cover is added")
    }

    // MARK: tokenizer_config.json reader

    func testReadsTokenizerConfigJSON() throws {
        let dir = NSTemporaryDirectory() + "tok-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let json = """
        { "chat_template": "<|im_start|>user<|im_end|>", "eos_token": { "content": "<|im_end|>" }, "model_type": "qwen2" }
        """
        let path = dir + "/tokenizer_config.json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)

        let p = LocalModelConfigReader.read(path: path)
        XCTAssertEqual(p?.family, .chatml)
        XCTAssertEqual(p?.eosToken, "<|im_end|>")
        XCTAssertEqual(p?.source, "tokenizer_config.json")
        // also resolves when handed the directory
        XCTAssertEqual(LocalModelConfigReader.read(path: dir)?.family, .chatml)
    }

    func testTokenizerConfigArrayTemplateForm() throws {
        let dir = NSTemporaryDirectory() + "tok2-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let json = """
        { "chat_template": [ {"name":"default","template":"<|eot_id|>"}, {"name":"tool_use","template":"x"} ],
          "eos_token": "<|eot_id|>" }
        """
        let path = dir + "/tokenizer_config.json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(LocalModelConfigReader.read(path: path)?.family, .llama3)
    }

    // MARK: GGUF binary metadata reader — hand-built minimal fixture

    func testParsesHandBuiltGGUF() throws {
        let dir = NSTemporaryDirectory() + "gguf-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/tiny.gguf"
        let data = Self.makeGGUF(kv: [
            ("general.architecture", .string("llama")),
            ("general.name", .string("Meta-Llama-3-8B-Instruct")),
            ("some.count", .uint32(42)),                                  // non-string KV must be skipped cleanly
            ("tokenizer.ggml.tokens", .stringArray(["a", "b", "c"])),     // array must be skipped cleanly
            ("tokenizer.chat_template", .string("{{ '<|eot_id|>' }}")),   // the key we care about, AFTER an array
        ])
        try data.write(to: URL(fileURLWithPath: path))

        let p = LocalModelConfigReader.read(path: path)
        XCTAssertEqual(p?.family, .llama3, "must skip past the non-string KV + token array to read chat_template")
        XCTAssertEqual(p?.source, "GGUF metadata")
        XCTAssertTrue(p?.stopSequences.contains("<|eot_id|>") ?? false)
    }

    func testRejectsNonGGUFFile() throws {
        let dir = NSTemporaryDirectory() + "bad-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/not.gguf"
        try Data("this is not a gguf file at all, just text".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(LocalModelConfigReader.read(path: path), "bad magic → nil, no crash")
    }

    func testMissingPathReturnsNil() {
        XCTAssertNil(LocalModelConfigReader.read(path: "/no/such/path/model.gguf"))
    }

    // GPT MED: a crafted GGUF with deeply-nested arrays must fail CLOSED (nil), not blow the stack.
    func testDeeplyNestedGGUFArrayFailsClosed() throws {
        let dir = NSTemporaryDirectory() + "gguf-deep-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/deep.gguf"

        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func gstr(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); d.append(contentsOf: b) }
        d.append(contentsOf: [0x47, 0x47, 0x55, 0x46]); u32(3); u64(0); u64(1)   // 1 KV
        gstr("evil.nested"); u32(9)                                              // value type = ARRAY
        // 64 levels of array-of-array (each: elemType=9 array, count=1) — exceeds the depth guard (16).
        for _ in 0..<64 { u32(9); u64(1) }
        u32(0); u64(0)                                                           // innermost: empty uint8 array
        try d.write(to: URL(fileURLWithPath: path))

        XCTAssertNil(LocalModelConfigReader.read(path: path), "pathological nesting must fail closed, not crash")
    }

    // GPT HIGH: an oversized (untrusted) tokenizer_config.json must be rejected before slurping into memory.
    func testOversizedTokenizerConfigRejected() throws {
        let dir = NSTemporaryDirectory() + "tok-big-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/tokenizer_config.json"
        // 17 MB of valid-prefix JSON padding → over the 16 MB cap → rejected (nil), not OOM'd.
        var json = "{ \"chat_template\": \"<|im_end|>\", \"_pad\": \""
        json += String(repeating: "x", count: 17 * 1024 * 1024)
        json += "\" }"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertNil(LocalModelConfigReader.read(path: path), "a >16MB tokenizer_config must be rejected")
    }

    // MARK: - minimal GGUF writer (test fixture only)

    private enum GGVal { case string(String); case uint32(UInt32); case stringArray([String]) }

    private static func makeGGUF(kv: [(String, GGVal)]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u64(_ v: UInt64) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func gstr(_ s: String) { let b = Array(s.utf8); u64(UInt64(b.count)); d.append(contentsOf: b) }

        d.append(contentsOf: [0x47, 0x47, 0x55, 0x46])   // "GGUF"
        u32(3)                                            // version
        u64(0)                                            // tensor_count
        u64(UInt64(kv.count))                             // kv_count
        for (key, val) in kv {
            gstr(key)
            switch val {
            case .string(let s): u32(8); gstr(s)
            case .uint32(let n): u32(4); u32(n)
            case .stringArray(let arr): u32(9); u32(8); u64(UInt64(arr.count)); arr.forEach { gstr($0) }
            }
        }
        return d
    }
}
