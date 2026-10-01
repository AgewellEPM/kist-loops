import XCTest
@testable import AgentCore

final class LegacySessionIntentTests: XCTestCase {
    func testOrdinaryGuestLaunchPhrasesRetainRuntimeOutcome() {
        for request in [
            "Kist open up our Win98 and let's build",
            "kist open upour win98 and lets build",
            "openup our windows 98",
            "Please boot Windows NT 4.0",
            "can you open Windows 3.1?",
            "bring up my win2000",
            "launch win95", "start winxp", "open Windows 7", "open Windows 8",
            "open Windows 10", "open Windows 11",
        ] {
            let brief = PromptCompiler.compile(request)
            XCTAssertEqual(brief.intent, .desktop, request)
            XCTAssertEqual(brief.expectedOutcome, .externalAction, request)
            XCTAssertEqual(brief.outcomeContract.authority, .explicitRequest, request)
            XCTAssertFalse(brief.outcomeContract.allowsMutation, "A guest launch does not grant host source-edit authority: \(request)")
            XCTAssertTrue(brief.toolHints.contains { $0.contains("legacy_system_catalog") }, request)
            XCTAssertTrue(brief.toolHints.contains { $0.contains("vcard_status") }, request)
            XCTAssertFalse(brief.toolHints.contains { $0.contains("open_app") }, request)
        }
    }

    func testQuestionsReadOnlyAndCodeWorkDoNotAuthorizeGuestLaunch() {
        for request in [
            "Explain how to open Windows 98", "Can Kist open Windows 98?",
            "Make sure I can say Kist open Windows 98", "fix the win98 driver code",
            "open windows 98 source code", "open win98.py", "open win98 README",
            "open Windows 11 ISO", "open win98 documentation", "Do not open Windows 98",
        ] {
            XCTAssertFalse(LegacySessionIntent.isLaunch(request), request)
            XCTAssertNotEqual(PromptCompiler.compile(request).intent, .desktop, request)
        }
        let plan = PromptCompiler.compile("open Windows 98", mode: .plan)
        XCTAssertEqual(plan.intent, .plan)
        XCTAssertFalse(plan.outcomeContract.allowsMutation)
        let inspect = PromptCompiler.compile("open Windows 98, but only explain; do not execute")
        XCTAssertFalse(inspect.outcomeContract.allowsMutation)
    }

    func testRuntimeRouteDoesNotTurnAHostBuildIntoGuestWork() {
        XCTAssertEqual(PromptCompiler.compile("build a Windows 98 application").intent, .build)
        XCTAssertEqual(PromptCompiler.compile("fix Windows 11 startup code").intent, .build)
        XCTAssertFalse(LegacySessionIntent.isLaunch("open win980"))
        XCTAssertFalse(LegacySessionIntent.isLaunch("open windows 12"))
        XCTAssertEqual(PromptCompiler.compile("open Windows 98 then build a calculator").intent, .desktop)
    }
}
