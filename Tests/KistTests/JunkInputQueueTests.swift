import XCTest
@testable import Kist

/// The "$" garbage-turn bug (2026-07-29): a stray punctuation char typed at an approval prompt (or as
/// type-ahead) was queued as the NEXT turn's instruction, so kist ran a garbage turn (`ask_user: "You
/// sent '$'"`) INSTEAD of the user's real question — "it ignored what I just asked." Fix: input with no
/// alphanumeric content is never queued. Pinned at BOTH queue sites (multi-site rule):
/// TerminalInteractor.deferredPrompt (approval path) and TurnInputQueue (type-ahead path).
final class JunkInputQueueTests: XCTestCase {

    // MARK: the shared gate

    func testIsQueueableInstructionRejectsPunctuationOnly() {
        XCTAssertFalse(TurnInputQueue.isQueueableInstruction("$"))
        XCTAssertFalse(TurnInputQueue.isQueueableInstruction(";;"))
        XCTAssertFalse(TurnInputQueue.isQueueableInstruction("  !  "))
        XCTAssertTrue(TurnInputQueue.isQueueableInstruction("how close is Perslis?"))
        XCTAssertTrue(TurnInputQueue.isQueueableInstruction("1"))   // alphanumeric intent is kept
    }

    // MARK: approval path — TerminalInteractor.deferredPrompt

    func testPunctuationOnlyApprovalInputIsNotQueued() {
        XCTAssertNil(TerminalInteractor.deferredPrompt(fromRejectedApproval: "$"),
                     "a bare '$' at an approval must NOT become the next turn's prompt (the reported garbage-turn bug)")
        XCTAssertNil(TerminalInteractor.deferredPrompt(fromRejectedApproval: "  ;  "))
    }

    func testRealRedirectAtApprovalStillQueues() {
        XCTAssertEqual(TerminalInteractor.deferredPrompt(fromRejectedApproval: "actually do X instead"),
                       "actually do X instead", "a real typed redirect must still be queued")
        XCTAssertEqual(TerminalInteractor.deferredPrompt(fromRejectedApproval: "no wait, use COBOL"),
                       "wait, use COBOL", "the 'no <redirect>' form keeps the redirect")
    }

    // MARK: type-ahead path — TurnInputQueue (feed bytes like the watcher does)

    func testTypeAheadDropsPunctuationLineButKeepsRealQuestion() {
        let q = TurnInputQueue.shared
        q.clearAll()
        q.begin()
        feed(q, "$\n")                                              // stray key + Enter while kist works
        feed(q, "how close is Perslis to running any machine?\n")  // the real question
        q.end()
        XCTAssertEqual(q.popQueued(), "how close is Perslis to running any machine?",
                       "only the real question should be queued")
        XCTAssertNil(q.popQueued(), "the '$' line must have been dropped, not queued")
    }

    private func feed(_ q: TurnInputQueue, _ s: String) {
        for b in Array(s.utf8) { q.feed(b) }
    }
}
