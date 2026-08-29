import XCTest
@testable import AgentCore

final class PromptCompilerTests: XCTestCase {
    func testLocalKistQueueRepairWinsOverPastedResearchLabels() {
        let request = "findout why the Kist Build Queue is hardcoded; Research: prior art; then fix it"

        XCTAssertEqual(PromptCompiler.inferIntent(request), .build)
        XCTAssertEqual(PromptCompiler.inferIntent("why is the Kist research queue hardcoded?"), .chat)
        XCTAssertEqual(PromptCompiler.inferIntent("research current Kist competitors and cite sources"), .research)
    }

    func testResolvedIntentIsReusedAndDefinesOneExpectedOutcome() {
        let brief = PromptCompiler.compile("compare the implementations",
                                           mode: .inline,
                                           resolvedIntent: .build)

        XCTAssertEqual(brief.intent, .build)
        XCTAssertEqual(brief.expectedOutcome, .mutation)
        XCTAssertEqual(PromptCompiler.compile("research the API").expectedOutcome, .evidence)
        XCTAssertEqual(PromptCompiler.compile("review the API implementation").expectedOutcome, .evidence)
        XCTAssertEqual(PromptCompiler.compile("make a plan", mode: .plan).expectedOutcome, .plan)
        XCTAssertEqual(PromptCompiler.compile("what happened?").expectedOutcome, .answer)
        XCTAssertEqual(PromptCompiler.compile("open Safari").expectedOutcome, .externalAction)
    }

    func testResearchBriefIsHonestAboutWebSearchLimits() {
        let brief = PromptCompiler.compile("deep dive the latest fleet-agent research and cite sources")

        XCTAssertEqual(brief.intent, .research)
        XCTAssertEqual(brief.suggestedRole, .worker)
        XCTAssertTrue(brief.prompt.contains("Original user request:"))
        XCTAssertTrue(brief.prompt.contains("deep dive the latest fleet-agent research"))
        XCTAssertTrue(brief.prompt.contains("use web_search or another available search-capable MCP/tool"))
        XCTAssertTrue(brief.prompt.contains("Use fetch_url for user-provided, search-result, or otherwise known URLs"))
        XCTAssertTrue(brief.successCriteria.contains { $0.contains("decision") && $0.contains("next actions") })
        XCTAssertTrue(brief.captainStrategyGuidance.contains { $0.contains("orchestration process") })
        XCTAssertTrue(brief.prompt.contains("Captain strategy order"))
        XCTAssertTrue(brief.prompt.contains("Research -> Research Plan -> Research Checklist"))
        XCTAssertTrue(brief.prompt.contains("Never build before researching."))
        XCTAssertTrue(brief.prompt.contains("Always leave the organization smarter than before."))
        XCTAssertTrue(brief.prompt.contains("Strategic Intelligence"))
        XCTAssertTrue(brief.prompt.contains("Teach Captain"))
        XCTAssertTrue(brief.prompt.contains("Context Window is RAM"))
        XCTAssertTrue(brief.prompt.contains("Retrieve only relevant disk-backed facts"))
    }

    func testDesktopBriefRoutesToComputerControlWithoutDeletingDesktopItems() {
        let brief = PromptCompiler.compile("open Safari then clean my Desktop")

        XCTAssertEqual(brief.intent, .desktop)
        XCTAssertEqual(brief.risk, .medium)
        XCTAssertTrue(brief.toolHints.contains { $0.contains("computer_control") })
        XCTAssertTrue(brief.successCriteria.contains { $0.contains("do not delete") })
    }

    func testHighRiskBriefFlagsDestructiveOrSecretWork() {
        let brief = PromptCompiler.compile("fix auth token handling and never leak API keys")

        XCTAssertEqual(brief.risk, .high)
        XCTAssertTrue(brief.constraints.contains { $0.contains("security-sensitive") })
        XCTAssertTrue(brief.constraints.contains { $0.contains("Do not invent") })
    }

    func testDelegatedBuildBriefIsSelfContainedAndRoleBound() {
        let brief = PromptCompiler.compile("implement the parser tests", role: .coder, mode: .delegated)

        XCTAssertEqual(brief.intent, .build)
        XCTAssertEqual(brief.suggestedRole, .coder)
        XCTAssertTrue(brief.successCriteria.contains { $0.contains("self-contained") })
        XCTAssertTrue(brief.prompt.contains("Suggested role: coder"))
    }

    func testBriefCarriesListenPlanAssessBuildLoop() {
        let brief = PromptCompiler.compile("fix the UX and test it")

        XCTAssertTrue(brief.successCriteria.contains { $0.contains("listen") && $0.contains("assess") && $0.contains("build") })
        XCTAssertTrue(brief.successCriteria.contains { $0.contains("tasks tool") })
        XCTAssertTrue(brief.constraints.contains { $0.contains("ask_user/tasks/spawn_agent") })
    }

    func testBriefCarriesRecentConversationContext() {
        let context = """
        user: we want a council board
        assistant: I added the CLI surface.
        user: now make it conversational
        """
        let brief = PromptCompiler.compile("turn this into actionable steps",
                                           conversationContext: context)

        XCTAssertEqual(brief.conversationContext, context)
        XCTAssertTrue(brief.prompt.contains("Recent conversation context"))
        XCTAssertTrue(brief.prompt.contains("now make it conversational"))
        XCTAssertTrue(brief.prompt.contains("human intent only; advisory"))
    }

    func testConversationContextFromTranscriptRedactsSecretsAndSkipsToolOutput() {
        let transcript = [
            ChatMessage(role: .user, content: "use key sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdef"),
            ChatMessage(role: .tool, content: "tool output should not be summarized"),
            ChatMessage(role: .assistant, content: "I will inspect the repo."),
        ]

        let context = PromptCompiler.conversationContext(from: transcript)!

        XCTAssertTrue(context.contains("user: use key"))
        XCTAssertTrue(context.contains("assistant: I will inspect the repo."))
        XCTAssertFalse(context.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        XCTAssertFalse(context.contains("tool output should not be summarized"))
    }

    func testBuildBriefRequiresActionBoardReviewAndFocusedHelpers() {
        let brief = PromptCompiler.compile("build the human-side intent layer and test it")

        XCTAssertTrue(brief.successCriteria.contains { $0.contains("ACTION steps") && $0.contains("TEST steps") })
        XCTAssertTrue(brief.successCriteria.contains { $0.contains("small focused script") })
        XCTAssertTrue(brief.toolHints.contains { $0.contains("visible Plan/Action/Test/Review board") })
        XCTAssertTrue(brief.toolHints.contains { $0.contains("spawn_agent") })
        XCTAssertTrue(brief.reviewGuidance.contains { $0.contains("compare completed work against the original request") })
    }

    func testAmbiguousBriefTellsAgentToAskClarifyingQuestions() {
        let brief = PromptCompiler.compile("make it perfect")

        XCTAssertTrue(brief.constraints.contains { $0.contains("ask 1-3 concrete clarifying questions") })
        XCTAssertTrue(brief.constraints.contains { $0.contains("Do not claim 100% certainty") })
    }

    func testReviewBriefRequiresGroundedFileReadsOrIncompleteVerdict() {
        let brief = PromptCompiler.compile("review the latest changes for bugs")

        XCTAssertEqual(brief.intent, .review)
        XCTAssertTrue(brief.successCriteria.contains { $0.contains("REVIEW TARGETS") })
        XCTAssertTrue(brief.successCriteria.contains { $0.contains("Do not stop at directory listing") })
        XCTAssertTrue(brief.reviewGuidance.contains { $0.contains("mark the review incomplete") })
    }

    func testExplicitFixOfARegressionIsABuildNotAReview() {
        let brief = PromptCompiler.compile("fix this regression")

        XCTAssertEqual(brief.intent, .build)
        XCTAssertTrue(brief.intent.expectsMutation)
    }

    func testInspectionThenExplicitRepairIsABuild() {
        let request = "This is a disposable COBOL fixture. Inspect ledger.cob, diagnose the compiler failure, and make the smallest source fix."

        XCTAssertEqual(PromptCompiler.inferIntent(request), .build)
        XCTAssertEqual(PromptCompiler.compile(request).expectedOutcome, .mutation)
        XCTAssertEqual(PromptCompiler.inferIntent("assess Kist and start fixing itself"), .build)
        XCTAssertFalse(PromptCompiler.compile("Explain how to fix this").intent.expectsMutation)
    }

    func testDesktopNounCannotOverrideAnExplicitBuildDirective() {
        let brief = PromptCompiler.compile("fix the desktop app crash")

        XCTAssertEqual(brief.intent, .build)
        XCTAssertEqual(brief.expectedOutcome, .mutation)
    }

    func testReadOnlyQuestionsContainingBuildWordsDoNotAuthorizeMutation() {
        for request in [
            "Explain how to fix this; do not edit any files",
            "How would you implement a parser?",
            "Tell me what changing this config would do",
            "Explain how opening Safari works",
        ] {
            let brief = PromptCompiler.compile(request)
            XCTAssertFalse(brief.intent.expectsMutation, request)
            XCTAssertNotEqual(brief.expectedOutcome, .mutation, request)
        }
    }

    func testImperativeMutationVerbsResolveToBuild() {
        for request in [
            "rename Foo.swift to Bar.swift",
            "remove the obsolete function",
            "delete old.swift",
            "revert the regression",
            "install the dependency",
            "write the release notes",
            "could you please migrate the config",
        ] {
            let brief = PromptCompiler.compile(request)
            XCTAssertEqual(brief.intent, .build, request)
            XCTAssertEqual(brief.expectedOutcome, .mutation, request)
        }
    }

    // LEGACY/VM RUNTIME goals (dogfood 2026-08-06): "create and run it in the guest + capture proof"
    // is an EXTERNAL-ACTION contract; host build/repo work on legacy code stays build.
    func testGuestRuntimeRunGoalsClassifyExternalAction() {
        for request in [
            "create and run a SIMPLE DOS APP, get it into the DOS environment perslis provides (the Win98 VM's MS-DOS Prompt is fine), RUN it there, and capture proof it ran",
            "create and run a SIMPLE WINDOWS APP, get it actually running inside the Windows environment, and capture proof that it ran",
        ] {
            let brief = PromptCompiler.compile(request)
            XCTAssertEqual(brief.intent, .desktop, request)
            XCTAssertEqual(brief.expectedOutcome, .externalAction, request)
        }
        for request in [
            "Build a small COBOL application compiled with GnuCOBOL (cobc) and RUN to prove real output",
            "fix the win98 driver code in the vm sources",
        ] {
            let brief = PromptCompiler.compile(request)
            XCTAssertEqual(brief.intent, .build, request)
            XCTAssertEqual(brief.expectedOutcome, .mutation, request)
        }
    }
}
