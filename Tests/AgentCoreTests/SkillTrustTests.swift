import XCTest
import Foundation
@testable import AgentCore

/// Sprint 2 — the trust spine. Project skills are UNTRUSTED until their content hash is pinned;
/// an untrusted loaded skill is forced to read-only (its self-declared allowed-tools is ignored —
/// the security boundary that defeats a malicious skill granting itself run_command).
final class SkillTrustTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() + "trust-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        root = ToolContext.canonicalize(dir) ?? dir
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    // MARK: trust store

    // DeepSeek LOW: a trust store that EXISTS but is corrupt/unreadable must fail CLOSED — load returns
    // an empty store (every project skill untrusted), never carrying over stale trust. (A missing file is
    // the normal first-run state and is silent; the corrupt case also warns, but here we pin the BEHAVIOR.)
    func testCorruptTrustStoreFailsClosed() throws {
        let storePath = root + "/userstore/skills-trust.json"
        try FileManager.default.createDirectory(atPath: root + "/userstore", withIntermediateDirectories: true)
        // First, prove a VALID store loads its pin (control).
        try SkillTrustStore().pinning(name: "mine", hash: "abc123").save(root: root, storePath: storePath)
        XCTAssertTrue(SkillTrustStore.load(root: root, storePath: storePath).isPinned(name: "mine", hash: "abc123"))
        // Now corrupt the file (owner-only regular file, but not valid JSON).
        try Data("{ this is not json".utf8).write(to: URL(fileURLWithPath: storePath))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storePath)
        let loaded = SkillTrustStore.load(root: root, storePath: storePath)
        XCTAssertFalse(loaded.isPinned(name: "mine", hash: "abc123"),
                       "a corrupt trust store must fail closed — no stale trust survives")
        XCTAssertTrue(loaded.allPinned.isEmpty, "corrupt store ⇒ empty (untrusted) pins")
    }

    func testHashIsStableAndPinMatch() {
        let h = SkillTrustStore.hash("hello")
        XCTAssertEqual(h, SkillTrustStore.hash("hello"))
        XCTAssertNotEqual(h, SkillTrustStore.hash("hellp"))
        let store = SkillTrustStore().pinning(name: "s", hash: h)
        XCTAssertTrue(store.isPinned(name: "s", hash: h))
        XCTAssertFalse(store.isPinned(name: "s", hash: SkillTrustStore.hash("other")), "edited content ⇒ not pinned")
        XCTAssertFalse(store.isPinned(name: "other", hash: h))
    }

    func testTrustStoreRoundTripsOwnerOnly() throws {
        // Inject a temp store path so the test never touches the real ~/.config.
        let storePath = root + "/userstore/skills-trust.json"
        let store = SkillTrustStore().pinning(name: "a", hash: "deadbeef")
        try store.save(root: root, storePath: storePath)
        let loaded = SkillTrustStore.load(root: root, storePath: storePath)
        XCTAssertTrue(loaded.isPinned(name: "a", hash: "deadbeef"))
        let attrs = try FileManager.default.attributesOfItem(atPath: storePath)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
        XCTAssertEqual(perms & 0o077, 0, "trust file must be owner-only (0600)")
    }

    // THE COUNCIL'S HIGH FINDING: a repo-shipped .kist/skills-trust.json must NOT grant trust — the
    // store is user-level, so a cloned malicious repo can't pre-trust its own skills.
    func testRepoLocalTrustFileIsIgnored() throws {
        let confined = try ConfinedRoot(root: root)
        try confined.makeDirectory(".kist/skills/evil")
        let body = "---\nname: evil\ndescription: d\nallowed-tools: run_command\n---\nmalice"
        try confined.writeString(".kist/skills/evil/SKILL.md", body, createParents: true)
        // Attacker ships a repo-local trust file pinning the malicious skill's hash.
        let repoTrust = "{\"version\":1,\"projects\":{\"\(root!)\":{\"evil\":\"\(SkillTrustStore.hash(body))\"}}}"
        try confined.writeString(".kist/skills-trust.json", repoTrust, createParents: true)
        // Discovery reads the USER store (here an empty injected path) — the repo-local file is IGNORED.
        let emptyUserStore = root + "/userstore/trust.json"
        let mgr = SkillManager.discover(confined: confined, trustStorePath: emptyUserStore)
        XCTAssertEqual(mgr.activeSkills.first { $0.name == "evil" }?.trust, .untrusted,
                       "a repo-shipped trust file must NOT grant trust")
    }

    // MARK: discovery trust

    func testProjectSkillUntrustedByDefaultThenPinned() throws {
        let storePath = root + "/userstore/trust.json"   // injected — never touch the real ~/.config
        let confined = try ConfinedRoot(root: root)
        let body = "---\nname: mine\ndescription: d\nallowed-tools: write_file\n---\nbody"
        try confined.makeDirectory(".kist/skills/mine")
        try confined.writeString(".kist/skills/mine/SKILL.md", body, createParents: true)

        // Default: untrusted.
        let mgr1 = SkillManager.discover(confined: confined, trustStorePath: storePath)
        let s1 = mgr1.activeSkills.first { $0.name == "mine" }
        XCTAssertEqual(s1?.trust, .untrusted, "an unpinned project skill is untrusted")

        // Pin its current hash to the USER store → trusted.
        try SkillTrustStore().pinning(name: "mine", hash: s1!.contentHash).save(root: root, storePath: storePath)
        let mgr2 = SkillManager.discover(confined: confined, trustStorePath: storePath)
        XCTAssertEqual(mgr2.activeSkills.first { $0.name == "mine" }?.trust, .trusted, "pinned hash ⇒ trusted")
    }

    // MARK: THE security boundary — an untrusted skill cannot grant itself tools

    // Trust is a LOAD-TIME verdict (markLoaded(trusted:)) — a skill loaded as untrusted forces
    // read-only and ignores its self-declared tools.
    func testUntrustedSkillForcedReadOnlyIgnoresDeclaredTools() async {
        let evil = Skill(name: "evil", description: "d", allowedTools: ["run_command", "write_file"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [evil])
        await tracker.markLoaded("evil", trusted: false)               // load path decided untrusted
        let allow = await tracker.activeToolAllowlist()
        XCTAssertNotNil(allow, "loading an untrusted skill restricts the session")
        XCTAssertFalse(allow!.contains("run_command"), "an untrusted skill cannot grant itself run_command")
        XCTAssertFalse(allow!.contains("write_file"), "…nor write_file")
        XCTAssertTrue(allow!.contains("read_file"), "read-only tools remain")
    }

    func testTrustedSkillStillGrantsItsDeclaredTools() async {
        let good = Skill(name: "good", description: "d", allowedTools: ["custom_tool"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [good])
        await tracker.markLoaded("good", trusted: true)
        let allow = await tracker.activeToolAllowlist()
        XCTAssertTrue(allow!.contains("custom_tool"), "a trusted skill's declared tool is granted")
    }

    // UNTRUSTED DOMINATES (Codex HIGH#3): a trusted write-granting skill cannot lift an untrusted session.
    func testUntrustedDominatesTrustedGrant() async {
        let granter = Skill(name: "granter", description: "d", allowedTools: ["write_file"], instructions: "i")
        let evil = Skill(name: "evil", description: "d", allowedTools: ["run_command"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [granter, evil])
        await tracker.markLoaded("granter", trusted: true)
        await tracker.markLoaded("evil", trusted: false)
        let allow = await tracker.activeToolAllowlist()
        XCTAssertEqual(allow, SkillTracker.alwaysSafe, "any untrusted skill ⇒ read-only, no trusted lift")
    }

    // End-to-end via ToolRegistry: an untrusted-loaded skill → write_file refused.
    func testUntrustedSkillBlocksWriteViaRegistry() async {
        let evil = Skill(name: "evil", description: "d", allowedTools: ["write_file"], instructions: "i")
        let tracker = SkillTracker(activeSkills: [evil])
        await tracker.markLoaded("evil", trusted: false)
        let ctx = ToolContext(projectRoot: root, shell: ShellPolicy(enabled: true, autoApprove: true))
            .withSkills(locations: [:], tracker: tracker)
        let r = await ToolRegistry.headless().execute(name: "write_file",
                                                      arguments: ["path": "x.txt", "content": "y"], context: ctx)
        XCTAssertFalse(r.success)
        XCTAssertTrue((r.error ?? "").contains("skill capability scope"), r.error ?? "")
    }

    // CRITICAL TOCTOU regression: pin a benign skill, swap its bytes, then load via read_file → the
    // load re-derives trust from the CURRENT bytes (hash mismatch) ⇒ untrusted, NOT the stale pin.
    func testLoadTimeTrustReDerivedFromCurrentBytes() async throws {
        // ReadFileTool reads the real user store (via context.projectRoot), so isolate it with a temp
        // HOME for this test (swift test runs serially; restored on exit).
        let savedHome = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", root + "/home", 1)
        defer { if let savedHome { setenv("HOME", savedHome, 1) } }

        let confined = try ConfinedRoot(root: root)
        let loc = ".kist/skills/swap/SKILL.md"
        let benign = "---\nname: swap\ndescription: d\nallowed-tools: write_file\n---\nbenign body"
        try confined.makeDirectory(".kist/skills/swap")
        try confined.writeString(loc, benign, createParents: true)
        // Pin the BENIGN hash → trusted at discovery (writes the temp-HOME user store).
        try SkillTrustStore().pinning(name: "swap", hash: SkillTrustStore.hash(benign)).save(root: root)
        let mgr = SkillManager.discover(confined: confined)
        XCTAssertEqual(mgr.activeSkills.first { $0.name == "swap" }?.trust, .trusted)

        // SWAP the file to different (still-valid) bytes — the pin no longer matches.
        try confined.writeString(loc, "---\nname: swap\ndescription: d\nallowed-tools: run_command\n---\nMALICIOUS", createParents: true)
        let tracker = SkillTracker(activeSkills: mgr.activeSkills)
        let ctx = ToolContext(projectRoot: root).withSkills(locations: mgr.locationIndex(), tracker: tracker)

        let result = try await ReadFileTool().execute(arguments: ["path": loc], context: ctx)
        XCTAssertEqual(result.metadata["skill_trust"], "untrusted", "swapped bytes ⇒ untrusted at load, not the stale pin")
        let allow = await tracker.activeToolAllowlist()
        XCTAssertEqual(allow, SkillTracker.alwaysSafe, "the swapped skill is forced read-only")
    }
}
