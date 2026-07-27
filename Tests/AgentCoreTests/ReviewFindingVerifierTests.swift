import XCTest
import Foundation
@testable import AgentCore

/// The "ground a review finding against real source before trusting it" discipline — the mechanical
/// version of reading the cited code to catch a high-recall model's confident false positives.
final class ReviewFindingVerifierTests: XCTestCase {

    private var root: String!
    override func setUpWithError() throws {
        let dir = NSTemporaryDirectory() + "rfv-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/Sources", withIntermediateDirectories: true)
        // A real source file the findings will cite.
        let src = """
        import Foundation
        public struct ResearchRunTool {
            public init(allowedHosts: [String] = []) {}
            func run() -> Int {
                let x = 1
                return x
            }
        }
        """
        try src.write(toFile: dir + "/Sources/ResearchRunTool.swift", atomically: true, encoding: .utf8)
        root = dir
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(atPath: root) } }

    // A finding that quotes REAL code at the cited line grounds true.
    func testGroundsWhenQuotedCodeIsReal() {
        let f = GroundedReviewFinding(severity: "HIGH", file: "Sources/ResearchRunTool.swift", line: 3,
                              codeQuote: "public init(allowedHosts: [String] = []) {}", claim: "init is public")
        let g = ReviewFindingVerifier.ground(f, projectRoot: root)
        XCTAssertTrue(g.grounded, g.reason)
    }

    // The DeepSeek case: a finding that QUOTES CODE THAT ISN'T THERE is dropped as fabricated — even
    // though the file and line are real. A filename-only check (the old GroundedReviewValidator) misses this.
    func testFabricatedQuoteIsRefutedEvenWhenFileExists() {
        let f = GroundedReviewFinding(severity: "CRITICAL", file: "Sources/ResearchRunTool.swift", line: 3,
                              codeQuote: "subclass overrides execute() to bypass the gate", claim: "subclass bypass")
        let g = ReviewFindingVerifier.ground(f, projectRoot: root)
        XCTAssertFalse(g.grounded, "code that isn't in the file must not ground")
        XCTAssertTrue(g.reason.contains("not found") || g.reason.contains("fabricated"), g.reason)
    }

    // A finding citing a file that doesn't exist is fabricated.
    func testMissingFileIsNotGrounded() {
        let f = GroundedReviewFinding(severity: "HIGH", file: "Sources/DoesNotExist.swift", line: 1,
                              codeQuote: "let x = 1", claim: "x")
        XCTAssertFalse(ReviewFindingVerifier.ground(f, projectRoot: root).grounded)
    }

    // Path traversal / absolute paths can't be grounded (no escaping the project).
    func testTraversalRefused() {
        let f = GroundedReviewFinding(severity: "HIGH", file: "../../etc/passwd", line: 1, codeQuote: "root:x:0:0", claim: "x")
        XCTAssertFalse(ReviewFindingVerifier.ground(f, projectRoot: root).grounded)
    }

    // Grounding is robust to indentation/whitespace differences between the quote and the source.
    func testWhitespaceInsensitiveGrounding() {
        let f = GroundedReviewFinding(severity: "LOW", file: "Sources/ResearchRunTool.swift", line: 4,
                              codeQuote: "func   run()  ->  Int {\n      let x = 1", claim: "run")
        XCTAssertTrue(ReviewFindingVerifier.ground(f, projectRoot: root).grounded)
    }

    // An empty/trivial quote can't be grounded — a finding must show its work.
    func testEmptyQuoteIsNotGrounded() {
        let f = GroundedReviewFinding(severity: "HIGH", file: "Sources/ResearchRunTool.swift", line: 3, codeQuote: "  ", claim: "vague")
        XCTAssertFalse(ReviewFindingVerifier.ground(f, projectRoot: root).grounded)
    }

    // A real quote with a wrong-by-a-lot line still grounds (the line is clamped into range; the quote is
    // found). The reported reason cites the ORIGINAL line the model gave, not the clamped value.
    func testRealQuoteWrongLineStillGrounds() {
        let f = GroundedReviewFinding(severity: "MED", file: "Sources/ResearchRunTool.swift", line: 999,
                              codeQuote: "public struct ResearchRunTool", claim: "struct")
        let g = ReviewFindingVerifier.ground(f, projectRoot: root)
        XCTAssertTrue(g.grounded)
        XCTAssertTrue(g.reason.contains("999"), "reason cites the original line: \(g.reason)")
    }

    // verify(): a fabricated finding is refutedFabricated WITHOUT a panel; a grounded one with an
    // all-refute panel is refutedPanel; with a no-refute panel is confirmed; with no panel is unverified.
    func testVerifyClassifiesAcrossTheBoard() async {
        let real = GroundedReviewFinding(severity: "HIGH", file: "Sources/ResearchRunTool.swift", line: 3,
                                 codeQuote: "public init(allowedHosts: [String] = []) {}", claim: "public init")
        let fake = GroundedReviewFinding(severity: "CRITICAL", file: "Sources/ResearchRunTool.swift", line: 3,
                                 codeQuote: "os.system('rm -rf /')", claim: "shell injection")

        // No panel: real → unverified, fake → refutedFabricated.
        let held = await ReviewFindingVerifier.verify(findings: [real, fake], projectRoot: root)
        XCTAssertEqual(held[0].verdict, .unverified)
        XCTAssertEqual(held[1].verdict, .refutedFabricated)

        // All-refute panel: real grounded finding gets refutedPanel; fake is STILL refutedFabricated
        // (a fabrication never reaches the panel — grounding is dispositive).
        let allRefute = await ReviewFindingVerifier.verify(findings: [real, fake], projectRoot: root,
                                                           panel: [StubRefuter(refuted: true), StubRefuter(refuted: true), StubRefuter(refuted: true)])
        XCTAssertEqual(allRefute[0].verdict, .refutedPanel)
        XCTAssertEqual(allRefute[1].verdict, .refutedFabricated)

        // No-refute panel: the real grounded finding is confirmed.
        let noRefute = await ReviewFindingVerifier.verify(findings: [real], projectRoot: root,
                                                         panel: [StubRefuter(refuted: false), StubRefuter(refuted: false)])
        XCTAssertEqual(noRefute[0].verdict, .confirmed)
        XCTAssertTrue(noRefute[0].isTrustworthy)
    }

    // The refute panel cannot rescue a fabrication, and confirmation needs a STRICT minority to refute.
    func testTieDoesNotConfirm() async {
        let real = GroundedReviewFinding(severity: "HIGH", file: "Sources/ResearchRunTool.swift", line: 5,
                                 codeQuote: "let x = 1\n        return x", claim: "x")
        // 1 refute of 2 = a tie → NOT a strict minority → not confirmed.
        let tied = await ReviewFindingVerifier.verify(findings: [real], projectRoot: root,
                                                     panel: [StubRefuter(refuted: true), StubRefuter(refuted: false)])
        XCTAssertEqual(tied[0].verdict, .refutedPanel, "a tie does not confirm — skeptics win ties")
    }

    // parse(): pulls structured findings out of mixed prose + FINDING blocks.
    func testParseExtractsStructuredFindings() {
        let text = """
        Here is my review. Some prose the parser ignores.

        <<<FINDING
        severity: HIGH
        file: Sources/ResearchRunTool.swift
        line: 3
        claim: the initializer is public
        code: public init(allowedHosts: [String] = []) {}
        FINDING>>>

        More prose.

        <<<FINDING
        severity: LOW
        file: Sources/ResearchRunTool.swift
        claim: multi-line code quote
        code: func run() -> Int {
            let x = 1
            return x
        }
        FINDING>>>
        """
        let findings = ReviewFindingVerifier.parse(text)
        XCTAssertEqual(findings.count, 2)
        XCTAssertEqual(findings[0].severity, "HIGH")
        XCTAssertEqual(findings[0].line, 3)
        XCTAssertEqual(findings[0].file, "Sources/ResearchRunTool.swift")
        XCTAssertTrue(findings[1].codeQuote.contains("return x"), "multi-line code captured: \(findings[1].codeQuote)")
        // And the parsed findings ground correctly against the real file.
        XCTAssertTrue(ReviewFindingVerifier.ground(findings[0], projectRoot: root).grounded)
        XCTAssertTrue(ReviewFindingVerifier.ground(findings[1], projectRoot: root).grounded)
    }

    // The COUNCIL wiring: a critic's output with one real + one fabricated finding produces a grounding
    // section that flags the fabricated one — so the council can't surface a false positive unchallenged.
    func testCouncilGroundingSectionFlagsFabricatedCriticFinding() async {
        let criticOutput = """
        The design is mostly fine, but two concerns:

        <<<FINDING
        severity: HIGH
        file: Sources/ResearchRunTool.swift
        line: 3
        claim: the initializer is public and unguarded
        code: public init(allowedHosts: [String] = []) {}
        FINDING>>>

        <<<FINDING
        severity: CRITICAL
        file: Sources/ResearchRunTool.swift
        line: 3
        claim: there is a hidden shell exec backdoor
        code: Process.launchedProcess(launchPath: "/bin/sh", arguments: ["-c", payload])
        FINDING>>>
        """
        let section = await AICouncil.groundingSection(criticOutput, projectRoot: root)
        XCTAssertTrue(section.contains("Finding Grounding"))
        XCTAssertTrue(section.contains("✓ grounded"), "the real finding is grounded")
        XCTAssertTrue(section.contains("LIKELY FABRICATED"), "the invented shell-exec finding is flagged")
        XCTAssertTrue(section.contains("1 grounded, 1 likely fabricated"), section)
    }

    // No structured findings (purely strategic critique) ⇒ no grounding section (no noise).
    func testCouncilGroundingSectionEmptyWhenNoStructuredFindings() async {
        let section = await AICouncil.groundingSection("Just prose, no findings here.", projectRoot: root)
        XCTAssertTrue(section.isEmpty)
    }

    // Codex MED4: a too-short quote (a ubiquitous token) can't ground — it would give false confidence.
    func testShortUbiquitousQuoteRejected() {
        let f = GroundedReviewFinding(severity: "HIGH", file: "Sources/ResearchRunTool.swift", line: 6,
                              codeQuote: "return x", claim: "trivial token")   // 8 chars < minQuoteChars
        let g = ReviewFindingVerifier.ground(f, projectRoot: root)
        XCTAssertFalse(g.grounded, "a sub-threshold quote must not ground")
        XCTAssertTrue(g.reason.contains("too short"), g.reason)
    }

    // Codex HIGH2: a malformed huge line number must fail SOFT (clamp), not overflow-trap.
    func testHugeLineNumberDoesNotCrash() {
        let f = GroundedReviewFinding(severity: "HIGH", file: "Sources/ResearchRunTool.swift", line: Int.max,
                              codeQuote: "public struct ResearchRunTool", claim: "struct")
        let g = ReviewFindingVerifier.ground(f, projectRoot: root)   // must not trap
        XCTAssertTrue(g.grounded, "real code still grounds via whole-file fallback despite an absurd line")
    }

    // Codex: a malformed lineWindow (Int.max) must not overflow either — clamp before the window math.
    func testHugeLineWindowDoesNotCrash() {
        let f = GroundedReviewFinding(severity: "HIGH", file: "Sources/ResearchRunTool.swift", line: 3,
                              codeQuote: "public init(allowedHosts: [String] = []) {}", claim: "init")
        let g = ReviewFindingVerifier.ground(f, projectRoot: root, lineWindow: Int.max)   // must not trap
        XCTAssertTrue(g.grounded, "lineWindow Int.max is clamped; real code still grounds")
    }

    // Codex MED3: a symlink that escapes the project root must NOT be readable/groundable.
    func testSymlinkEscapeRefused() throws {
        let link = root + "/Sources/escape.swift"
        try? FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/etc/hosts")
        let f = GroundedReviewFinding(severity: "CRITICAL", file: "Sources/escape.swift", line: 1,
                              codeQuote: "localhost loopback entry that is plausibly long enough", claim: "leak via symlink")
        XCTAssertFalse(ReviewFindingVerifier.ground(f, projectRoot: root).grounded,
                       "a symlink escaping the project root must not be grounded/read")
    }

    // Codex HIGH1: the planner-sanitized output strips raw finding blocks, KEEPS grounded findings, and
    // REMOVES fabricated ones — so a fabricated finding can never reach the final synthesis.
    func testSanitizedForPlannerDropsFabricatedKeepsGrounded() async {
        let critic = """
        Strategic note: the plan is broadly fine.

        <<<FINDING
        severity: HIGH
        file: Sources/ResearchRunTool.swift
        line: 3
        claim: the initializer is public
        code: public init(allowedHosts: [String] = []) {}
        FINDING>>>
        <<<FINDING
        severity: CRITICAL
        file: Sources/ResearchRunTool.swift
        line: 3
        claim: hidden shell backdoor
        code: Process.launchedProcess(launchPath: "/bin/sh", arguments: ["-c", payload])
        FINDING>>>
        """
        let findings = ReviewFindingVerifier.parse(critic)
        let verified = await ReviewFindingVerifier.verify(findings: findings, projectRoot: root)
        let sanitized = ReviewFindingVerifier.sanitizedForPlanner(critic, verified: verified)
        XCTAssertFalse(sanitized.contains("<<<FINDING"), "raw finding blocks removed for the planner")
        XCTAssertFalse(sanitized.contains("launchedProcess"), "the FABRICATED finding's code is gone")
        XCTAssertTrue(sanitized.contains("Strategic note"), "prose critique preserved")
        XCTAssertTrue(sanitized.contains("CODE-GROUNDED FINDINGS"), "grounded findings summarized")
        XCTAssertTrue(sanitized.contains("existence is confirmed, but the bug itself is NOT yet validated"),
                      "the existence-only / no-refute-panel qualifier must be present (honest framing)")
        XCTAssertFalse(sanitized.contains("safe to act on"), "must NOT tell the planner an unvalidated finding is safe")
        XCTAssertTrue(sanitized.contains("GROUNDING ACTIVE"), "the prose caveat frames un-grounded code claims for the planner")
        XCTAssertTrue(sanitized.contains("the initializer is public"), "the GROUNDED claim is kept")
        XCTAssertTrue(sanitized.contains("1 finding(s)") && sanitized.contains("REMOVED"), "dropped count noted")
    }

    // Codex: an UNTERMINATED finding block (which parse drops → empty findings) must STILL have its raw
    // markers stripped before the planner sees them — sanitizing with empty verified strips stray markers.
    func testSanitizedStripsUnterminatedBlockEvenWithNoFindings() {
        let critic = "Strategic critique here.\n\n<<<FINDING\nseverity: HIGH\nfile: x\nclaim: dangling (no close marker)"
        let sanitized = ReviewFindingVerifier.sanitizedForPlanner(critic, verified: [])
        XCTAssertFalse(sanitized.contains("<<<FINDING"), "the dangling marker is stripped for the planner")
        XCTAssertFalse(sanitized.contains("dangling"), "the unterminated block's content does not leak")
        XCTAssertTrue(sanitized.contains("Strategic critique"), "prose preserved")
    }

    // Codex round-3 BLOCK: the exact adversarial path — a code-specific claim written PURELY as prose
    // (no <<<FINDING>>> block, so verified is empty) must STILL get the planner caveat. The earlier
    // heuristic suppressed it here (the bypass); the caveat now fires unconditionally.
    func testProseOnlyCodeClaimStillGetsCaveat() {
        let critic = "Serious bug: Sources/Foo.swift line 42 deletes the user's account without auth. Fix it."
        let sanitized = ReviewFindingVerifier.sanitizedForPlanner(critic, verified: [])
        XCTAssertTrue(sanitized.contains("GROUNDING ACTIVE"),
                      "a prose-only code claim with no finding block must still be caveated to the planner")
        XCTAssertTrue(sanitized.contains("NOT verified"))
    }

    // stripFindingBlocks fails soft on an unterminated block (no crash, drops the dangling tail).
    func testStripFindingBlocksUnterminated() {
        let s = ReviewFindingVerifier.stripFindingBlocks("keep this <<<FINDING\nseverity: HIGH\n(no close)")
        XCTAssertEqual(s, "keep this")
    }

    private struct StubRefuter: ReviewFindingRefuter {
        let refuted: Bool
        func refute(_ finding: GroundedReviewFinding) async -> ReviewRefuteVote { ReviewRefuteVote(refuted: refuted, reason: "stub") }
    }
}
