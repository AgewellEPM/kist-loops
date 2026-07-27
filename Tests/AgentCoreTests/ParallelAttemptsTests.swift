import XCTest
@testable import AgentCore

/// Best-of-N orchestration: first verified wins, fail-closed if none verify, single attempt when width<=1.
final class ParallelAttemptsTests: XCTestCase {
    private final class Counter: @unchecked Sendable { let l=NSLock(); var n=0
        func inc()->Int{l.lock();defer{l.unlock()};n+=1;return n}; var v:Int{l.lock();defer{l.unlock()};return n} }

    func testStopsAtFirstVerified() async {
        let c = Counter()
        // attempt 0 fails, attempt 1 verifies → stop at 2, never run attempt 3.
        let sel = await ParallelAttempts.firstVerified(width: 5) { i in
            _ = c.inc()
            return .init(result: "r\(i)", verified: i == 1, quality: 50)
        }
        XCTAssertEqual(sel?.winner, "r1")
        XCTAssertEqual(sel?.attemptsUsed, 2)
        XCTAssertEqual(c.v, 2, "early-stop: didn't run attempts 3-5")
    }

    func testNilWhenNoneVerify() async {
        let sel = await ParallelAttempts.firstVerified(width: 3) { i in
            .init(result: i, verified: false, quality: 99)
        }
        XCTAssertNil(sel, "unverified best-of-N is not done — fail closed")
    }

    func testWidthOneRunsSingleAttempt() async {
        let c = Counter()
        _ = await ParallelAttempts.firstVerified(width: 1) { _ in _ = c.inc(); return .init(result: 0, verified: false, quality: 0) }
        XCTAssertEqual(c.v, 1)
    }
}
