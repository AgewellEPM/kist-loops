import XCTest
@testable import AgentCore

final class TaskPersonaMatcherTests: XCTestCase {
    func testConnectorWordsDoNotSelectSpecialists() {
        XCTAssertTrue(TaskPersonaMatcher(registry: nil).matches(for: "and the for with this that").isEmpty)
        let matches = TaskPersonaMatcher(registry: nil).matches(for: "Read evidence.txt and report its contents")
        XCTAssertFalse(matches.contains { $0.specialist.name == "bug-bounty-pentester" })
        XCTAssertFalse(matches.contains { $0.specialist.name == "medical-researcher" })
    }

    func testProgrammingValidityDoesNotSelectLegalResearch() {
        for request in ["Review the rule card: false is not legal for enemy_in_view",
                        "Explain which API calls are legal in this test case"] {
            XCTAssertFalse(TaskPersonaMatcher(registry: nil).matches(for: request)
                .contains { $0.specialist.name == "legal-research-analyst" })
        }
        XCTAssertTrue(TaskPersonaMatcher(registry: nil).matches(for: "Help with a legal question")
            .contains { $0.specialist.name == "legal-research-analyst" })
    }

    private var root: String!
    private var userDir: String!

    override func setUpWithError() throws {
        root = NSTemporaryDirectory() + "persona_\(UUID().uuidString)"
        userDir = NSTemporaryDirectory() + "persona_user_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: userDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(atPath: userDir)
    }

    func testMortgageClauseSelectsLegalAndFinancePersonas() {
        let matches = TaskPersonaMatcher(registry: nil)
            .matches(for: "review this mortgage clause and tell me the financial risks", limit: 3)
            .map(\.specialist.name)

        XCTAssertEqual(matches.first, "real-estate-law-advisor")
        XCTAssertTrue(matches.contains("financial-advisor"))
    }

    func testPatentPriorArtSelectsIPResearcher() {
        let matches = TaskPersonaMatcher(registry: nil)
            .matches(for: "research prior art for this patent filing", limit: 2)

        XCTAssertEqual(matches.first?.specialist.name, "ip-prior-art-researcher")
    }

    func testGenericLegalResearchSelectsLegalAnalyst() {
        let matches = TaskPersonaMatcher(registry: nil)
            .matches(for: "I need a legal research memo on Connecticut court deadlines for this case", limit: 2)

        XCTAssertEqual(matches.first?.specialist.name, "legal-research-analyst")
    }

    func testSwiftCompilerCrashSelectsSwiftEngineer() {
        let matches = TaskPersonaMatcher(registry: nil)
            .matches(for: "fix this Swift compiler crash in the SwiftPM tests", limit: 2)

        XCTAssertEqual(matches.first?.specialist.name, "swift-engineer")
    }

    func testBugBountyScopeSelectsPentesterAndSecurityAuditor() {
        let matches = TaskPersonaMatcher(registry: nil)
            .matches(for: "build an authorized bug bounty pentest plan and check OWASP vulnerabilities", limit: 3)
            .map(\.specialist.name)

        XCTAssertEqual(matches.first, "bug-bounty-pentester")
        XCTAssertTrue(matches.contains("security-auditor"))
    }

    func testSavedSpecialistsParticipateAndWinTieOverBuiltin() throws {
        let reg = SpecialistRegistry(projectRoot: root, userDir: userDir)
        try reg.save(SpecialistDefinition(name: "real-estate-law-advisor",
                                          description: "PROJECT real estate specialist for local closing workflow",
                                          systemPrompt: "Project-specific real estate instructions."))

        let match = TaskPersonaMatcher(registry: reg)
            .matches(for: "review this real estate closing document", limit: 1)
            .first

        XCTAssertEqual(match?.specialist.source, root + "/.kist/agents/real-estate-law-advisor.md")
        XCTAssertEqual(match?.specialist.systemPrompt, "Project-specific real estate instructions.")
    }

    func testPromptContextCarriesInstructionsAndToolCeilingLanguage() {
        let matches = TaskPersonaMatcher(registry: nil)
            .matches(for: "deep research the future of agentic coding with citations", limit: 1)
        let context = TaskPersonaMatcher.promptContext(matches: matches)!

        XCTAssertTrue(context.contains("ACTIVE SPECIALIST MATCHES"))
        XCTAssertTrue(context.contains("research-synthesizer"))
        XCTAssertTrue(context.contains("tool permissions still enforce the ceiling"))
        XCTAssertTrue(context.contains("Decision, Next 5 Tasks, and Test Plan"))
    }

    func testDisplayShowsPrimaryAndConsultingPersonas() {
        let matches = TaskPersonaMatcher(registry: nil)
            .matches(for: "security audit this Swift app UX and vulnerabilities", limit: 3)
        let display = TaskPersonaMatcher.display(matches: matches)!

        XCTAssertTrue(display.contains("acting as:"))
        XCTAssertTrue(display.contains("consulting:"))
    }

    // MARK: dynamic-advisor A1 — new creative/generative personas + regulated-domain disclaimer discipline

    func testJokeAskSelectsComedian() {
        let matches = TaskPersonaMatcher(registry: nil)
            .matches(for: "write me a joke about debugging at 3am", limit: 2)
        XCTAssertEqual(matches.first?.specialist.name, "comedian")
    }

    func testMarketingCopyAskSelectsCopywriter() {
        let matches = TaskPersonaMatcher(registry: nil)
            .matches(for: "write marketing copy and a headline for our landing page", limit: 2)
        XCTAssertEqual(matches.first?.specialist.name, "copywriter")
    }

    func testMusicLicensingAskSelectsAdvisorAndDisclaims() {
        let matches = TaskPersonaMatcher(registry: nil)
            .matches(for: "I want to clear a sample and get a sync license for this song", limit: 2)
        XCTAssertEqual(matches.first?.specialist.name, "music-licensing-advisor")
        let ctx = TaskPersonaMatcher.promptContext(matches: matches)!.lowercased()
        XCTAssertTrue(ctx.contains("not legal advice"),
                      "the music-licensing advisor is regulated — its advisory context must disclaim")
    }

    /// SAFETY MULTI-SITE INVARIANT: every REGULATED-domain persona MUST carry an explicit
    /// "not professional advice / consult a licensed professional" disclaimer in its systemPrompt. Named per
    /// persona so a bare one fails with the site. (Luke's vulnerable-user domain — non-negotiable.)
    func testAllRegulatedPersonasCarryADisclaimer() {
        let byName = Dictionary(uniqueKeysWithValues: BuiltinSpecialists.all.map { ($0.name, $0) })
        let regulated: [(String, [String])] = [
            ("legal-research-analyst",   ["not legal advice", "licensed attorney"]),
            ("real-estate-law-advisor",  ["licensed attorney"]),
            ("financial-advisor",        ["avoid guarantees", "qualified review", "educational"]),
            ("medical-researcher",       ["never present research as a diagnosis", "clinician"]),
            ("music-licensing-advisor",  ["not legal advice", "licensed music attorney"]),
        ]
        for (name, phrases) in regulated {
            guard let def = byName[name] else { XCTFail("regulated persona missing from catalog: \(name)"); continue }
            let prompt = def.systemPrompt.lowercased()
            XCTAssertTrue(phrases.contains { prompt.contains($0) },
                          "\(name) must carry a not-professional-advice disclaimer (looked for one of: \(phrases))")
        }
    }
}
