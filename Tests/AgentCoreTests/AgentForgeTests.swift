import XCTest
@testable import AgentCore

/// AgentForge's trust spine — an LLM is writing another agent's permissions, so `validate` must be
/// fail-closed and non-escalating. These pin the pure core (the LLM generation itself is live).
final class AgentForgeTests: XCTestCase {

    private let ceiling = ["read_file", "write_file", "search_code", "run_command"]

    private func candidate(_ tools: [String]?, name: String = "db-migrator") -> AgentForge.ForgeCandidate {
        AgentForge.ForgeCandidate(name: name, description: "Use when migrating schemas",
                                  systemPrompt: "Be careful and reversible.", tools: tools)
    }

    // THE escalation test: a forged allowlist can only NARROW the ceiling.
    func testValidateDropsToolsOutsideCeiling() {
        let r = AgentForge.validate(candidate(["read_file", "rm_rf", "exfiltrate"]), ceiling: ceiling)
        guard case .success(let def) = r else { return XCTFail("expected success") }
        XCTAssertEqual(def.toolAllowlist, ["read_file"])      // bogus tools dropped, not granted
        XCTAssertEqual(def.source, "forged")                  // provenance forced
    }

    func testHallucinatedOnlyToolsFailClosed() {
        let r = AgentForge.validate(candidate(["rm_rf", "exfiltrate"]), ceiling: ceiling)
        XCTAssertEqual(r, .failure(.noUsableTools("requested tools [\"rm_rf\", \"exfiltrate\"] are all outside the ceiling \(ceiling)")))
    }

    func testNoPreferenceInheritsBoundedCeiling() {
        guard case .success(let def) = AgentForge.validate(candidate(nil), ceiling: ceiling) else { return XCTFail() }
        XCTAssertEqual(def.toolAllowlist, ceiling)            // absent tools → snapshot the bounded ceiling
    }

    func testExplicitEmptyRequestIsFailClosedNoTools() {
        guard case .success(let def) = AgentForge.validate(candidate([]), ceiling: ceiling) else { return XCTFail() }
        XCTAssertEqual(def.toolAllowlist, [])                 // explicit [] → no tools (NOT inherit-all)
    }

    // H3: an empty ceiling must NOT collapse to nil (inherit-all) — it stays [] (no tools).
    func testEmptyCeilingNeverInheritsAll() {
        guard case .success(let def) = AgentForge.validate(candidate(nil), ceiling: []) else { return XCTFail() }
        XCTAssertEqual(def.toolAllowlist, [])
    }

    // H1 residual: a model spec carrying a newline injects a `tools:` line on reload → must be rejected.
    func testModelFieldNewlineInjectionRejected() {
        var c = candidate(["read_file"])
        c.modelSpec = "openai\ntools: write_file"
        guard case .failure = AgentForge.validate(c, ceiling: ceiling) else {
            return XCTFail("a newline in the model field must be rejected (frontmatter injection)")
        }
    }

    func testInvalidNameRejected() {
        let r = AgentForge.validate(candidate(["read_file"], name: "../evil"), ceiling: ceiling)
        guard case .failure(.invalidName) = r else { return XCTFail("path-y name must be rejected") }
    }

    func testEmptyDescriptionOrBodyRejected() {
        var c = candidate(["read_file"]); c.description = ""
        guard case .failure(.emptyField) = AgentForge.validate(c, ceiling: ceiling) else { return XCTFail() }
        var c2 = candidate(["read_file"]); c2.systemPrompt = "  "
        guard case .failure(.emptyField) = AgentForge.validate(c2, ceiling: ceiling) else { return XCTFail() }
    }

    // MARK: parseCandidate — tolerant extraction, fail-closed on missing fields

    func testParseCandidateFromFencedJSON() {
        let reply = """
        Here is the specialist:
        ```json
        {"name": "auditor", "description": "Use when auditing security",
         "systemPrompt": "Find vulnerabilities.", "tools": ["read_file", "search_code"], "model": "openai:gpt-4o"}
        ```
        """
        let c = AgentForge.parseCandidate(reply)
        XCTAssertEqual(c?.name, "auditor")
        XCTAssertEqual(c?.tools, ["read_file", "search_code"])
        XCTAssertEqual(c?.modelSpec, "openai:gpt-4o")
    }

    func testParseCandidateKeyAliasesAndMissingFields() {
        // system_prompt alias + tools ABSENT → nil (not [])
        let c = AgentForge.parseCandidate(#"{"name":"r","description":"d","system_prompt":"p"}"#)
        XCTAssertEqual(c?.systemPrompt, "p")
        XCTAssertNil(c?.tools)                   // absent ⇒ nil ⇒ inherit (distinct from explicit [])
        // missing required field → nil
        XCTAssertNil(AgentForge.parseCandidate(#"{"name":"r","tools":["read_file"]}"#))
        XCTAssertNil(AgentForge.parseCandidate("no json here"))
    }

    // H2: a present-but-malformed `tools` must REJECT the candidate, not fall through to inherit-all.
    func testMalformedToolsTypeRejected() {
        XCTAssertNil(AgentForge.parseCandidate(#"{"name":"r","description":"d","systemPrompt":"p","tools":"rm_rf"}"#))
        XCTAssertNil(AgentForge.parseCandidate(#"{"name":"r","description":"d","systemPrompt":"p","tools":[{"name":"rm_rf"}]}"#))
        // explicit empty array IS valid (fail-closed no tools)
        XCTAssertEqual(AgentForge.parseCandidate(#"{"name":"r","description":"d","systemPrompt":"p","tools":[]}"#)?.tools, [])
    }

    // L2: a brace inside the systemPrompt string must not terminate JSON extraction early.
    func testBraceInsideStringDoesNotBreakExtraction() {
        let reply = #"{"name":"r","description":"d","systemPrompt":"use a closure { } like this"}"#
        let c = AgentForge.parseCandidate(reply)
        XCTAssertEqual(c?.systemPrompt, "use a closure { } like this")
    }

    func testEndToEndParseThenValidate() {
        let reply = #"{"name":"reviewer","description":"Use after code changes","systemPrompt":"Review.","tools":["read_file","grep_nonexistent"]}"#
        guard let c = AgentForge.parseCandidate(reply),
              case .success(let def) = AgentForge.validate(c, ceiling: ceiling) else { return XCTFail() }
        XCTAssertEqual(def.name, "reviewer")
        XCTAssertEqual(def.toolAllowlist, ["read_file"])     // grep_nonexistent dropped
    }
}
