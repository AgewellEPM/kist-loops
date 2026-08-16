import XCTest
import Foundation
@testable import AgentCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Regression for Codex finding P2-H: the aggregate stdout+stderr truncation in
/// `ProcessGroupRunner.run` used `String.prefix(capPerStream)`, which counts Characters
/// (grapheme clusters), NOT bytes. With emoji-heavy multibyte output, `capPerStream`
/// graphemes can be 4×+ that many bytes — so the emitted combined text blew past the
/// aggregate byte boundary while STILL reporting `outputTruncated == true`. The fix
/// truncates the UTF-8 BYTE view at a valid Unicode scalar boundary and reserves the
/// marker's bytes, so emitted bytes <= cap and the result stays well-formed UTF-8.
///
/// These tests would PASS trivially under the buggy code for the boolean flags but FAIL
/// on the byte-count assertion — that assertion is the discriminator.
final class ProcessGroupRunnerByteTruncationTests: XCTestCase {

    private var cwd: String!
    private let env = ["PATH": "/usr/bin:/bin"]

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "pgr-bytetrunc-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        cwd = ToolContext.canonicalize(base)
    }
    override func tearDownWithError() throws {
        if let cwd { try? FileManager.default.removeItem(atPath: cwd) }
    }

    /// A Swift `String` is UTF-8 by construction; this re-encode round-trip makes the
    /// "valid UTF-8, no scalar split by truncation" claim explicit and load-bearing.
    private func isWellFormedUTF8(_ s: String) -> Bool {
        return String(bytes: Array(s.utf8), encoding: .utf8) == s
    }

    // MARK: - The end-to-end invariant, driven through the real run() aggregate site

    // SITE: ProcessGroupRunner.run aggregate-truncation (`combined.utf8.count > capPerStream`, formerly
    // truncated via `combined.prefix(cap)`).
    //
    // The aggregate branch only fires when the COMBINED stdout+stderr exceeds the cap. If a single
    // stream hits `capPerStream` first, the per-stream cap kills the group (SIGTERM) BEFORE the other
    // stream writes — so a sequential "flood one then the other" script can never make `combined`
    // exceed the cap through the real run() path. To drive the aggregate site deterministically, each
    // stream stays UNDER the per-stream cap (no SIGTERM), but TOGETHER they exceed it. Emoji (4-byte
    // scalars) make it a genuine byte-vs-Character discriminator: under the OLD `combined.prefix(cap)`
    // (grapheme count) the ~640 combined bytes — only ~160 graphemes — would survive whole.
    func testAggregateEmojiTruncationHonorsByteBudget() throws {
        let cap = 400
        // 80 × 💥 = 320 bytes per stream — under the 400-byte per-stream cap (no SIGTERM) — but
        // 640 bytes combined, well over the aggregate budget, so the aggregate branch must fire.
        let script = "printf '💥%.0s' $(seq 1 80); printf '💥%.0s' $(seq 1 80) 1>&2"
        let o = ProcessGroupRunner.run(
            launchPath: "/bin/sh", launchArgs: ["-c", script],
            cwd: cwd, env: env, timeoutSeconds: 10, capPerStream: cap)

        XCTAssertFalse(o.timedOut, "run should complete, not time out")
        XCTAssertFalse(o.stdoutTruncated, "each stream is under its own cap — no per-stream truncation")
        XCTAssertFalse(o.stderrTruncated, "each stream is under its own cap — no per-stream truncation")
        XCTAssertTrue(o.outputTruncated,
                      "combined output exceeded the aggregate cap → outputTruncated must be true")
        // THE DISCRIMINATOR: byte count, not Character count. The marker is reserved WITHIN the
        // budget, so the whole emitted string (content + marker) must fit under the cap.
        XCTAssertLessThanOrEqual(o.combined.utf8.count, cap,
            "aggregate combined output (\(o.combined.utf8.count) B) must not exceed the byte cap (\(cap) B) — the old Character-prefix let emoji blow past it")
        XCTAssertTrue(isWellFormedUTF8(o.combined),
                      "truncation must cut on a scalar boundary → well-formed UTF-8, never a split emoji")
        XCTAssertTrue(o.combined.hasSuffix("[output truncated]"),
                      "truncated output must carry the marker: \(o.combined)")
    }

    // PER-STREAM byte cap (a DIFFERENT mechanism from the aggregate branch): a single emoji flood far
    // over the cap must be byte-capped, not Character-capped. Under a grapheme-based cap, 300 emoji =
    // 1200 bytes would survive a "300" cap — so `combined.utf8.count <= cap` is the byte-vs-grapheme
    // discriminator, and the result must stay well-formed UTF-8 (never a split scalar).
    func testStdoutOnlyEmojiPerStreamCapIsByteBounded() throws {
        let cap = 300
        let script = "printf '🔥%.0s' $(seq 1 1000)"   // 1000 × 4 B = 4000 B >> 300 B
        let o = ProcessGroupRunner.run(
            launchPath: "/bin/sh", launchArgs: ["-c", script],
            cwd: cwd, env: env, timeoutSeconds: 10, capPerStream: cap)

        XCTAssertFalse(o.timedOut)
        XCTAssertTrue(o.outputTruncated, "a stream over its cap must report truncated")
        XCTAssertTrue(o.stdoutTruncated, "stdout exceeded its per-stream cap")
        XCTAssertLessThanOrEqual(o.combined.utf8.count, cap,
            "stdout-only emoji output (\(o.combined.utf8.count) B) must not exceed the per-stream byte cap (\(cap) B)")
        XCTAssertTrue(isWellFormedUTF8(o.combined),
                      "per-stream truncation must cut on a scalar boundary → well-formed UTF-8")
    }

    // MARK: - The pure helper, over boundary edge cases (unit-level, no subprocess)

    // Multibyte content that does NOT divide evenly into the budget: back-off to a scalar
    // boundary must keep the result under budget AND well-formed (never a half emoji).
    func testTruncateUTF8BacksOffToScalarBoundary() {
        let marker = "\n…[output truncated]"
        // 100 × 4-byte emoji = 400 content bytes. Budget 63 is NOT a multiple of 4 and doesn't
        // align with the marker size — the cut lands mid-scalar and must back off.
        let text = String(repeating: "😀", count: 100)
        let budget = 63
        let out = ProcessGroupRunner.truncateUTF8(text, toByteBudget: budget, marker: marker)

        XCTAssertLessThanOrEqual(out.utf8.count, budget,
            "helper output (\(out.utf8.count) B) must fit the byte budget (\(budget) B)")
        XCTAssertEqual(String(bytes: Array(out.utf8), encoding: .utf8), out,
                       "helper output must be well-formed UTF-8 (no scalar split)")
        XCTAssertTrue(out.hasSuffix(marker), "helper must append the marker")
        // No mangled/replacement scalar from a mid-emoji cut.
        XCTAssertFalse(out.unicodeScalars.contains("\u{FFFD}"),
                       "truncation must not introduce a U+FFFD replacement char")
    }

    // Degenerate budget smaller than the marker: never exceed the budget (fail-safe edge).
    func testTruncateUTF8BudgetSmallerThanMarker() {
        let marker = "\n…[output truncated]"   // > 1 byte
        let text = String(repeating: "🙂", count: 50)
        for budget in [0, 1, 3, marker.utf8.count - 1] {
            let out = ProcessGroupRunner.truncateUTF8(text, toByteBudget: budget, marker: marker)
            XCTAssertLessThanOrEqual(out.utf8.count, max(0, budget),
                "with budget \(budget) the helper must still not exceed it (got \(out.utf8.count) B)")
            XCTAssertEqual(String(bytes: Array(out.utf8), encoding: .utf8), out,
                           "budget \(budget): result must stay well-formed UTF-8")
        }
    }

    // ASCII sanity: budget larger than the marker leaves exactly (budget - marker) content bytes.
    func testTruncateUTF8ASCIIFillsBudget() {
        let marker = "\n…[output truncated]"
        let text = String(repeating: "a", count: 10_000)
        let budget = 500
        let out = ProcessGroupRunner.truncateUTF8(text, toByteBudget: budget, marker: marker)
        XCTAssertLessThanOrEqual(out.utf8.count, budget)
        // ASCII divides evenly → exactly budget bytes emitted (no back-off needed).
        XCTAssertEqual(out.utf8.count, budget,
                       "ASCII content should fill the budget exactly: \(out.utf8.count) vs \(budget)")
        XCTAssertTrue(out.hasSuffix(marker))
    }
}
