import XCTest
@testable import AgentCore

/// The engine meets reality: real external processes as the oracle. These are INTEGRATION tests — they
/// spawn actual macOS binaries — and skip gracefully where a binary is absent.
final class ProcessOracleTests: XCTestCase {

    private func requireExecutable(_ path: String) throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: path), "\(path) not available")
    }

    /// tr 'a-z' 'A-Z' — ASCII-only uppercasing (deliberately NOT Unicode-aware; that distinction matters below).
    private func asciiUpper(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map {
            (97...122).contains($0.value) ? Unicode.Scalar($0.value - 32)! : $0
        }))
    }

    // Oracles comparing against a stdout-only closure candidate use the .stdout surface (the closure models
    // stdout, not the process's exit code).
    private func tr() -> ProcessOracle {
        ProcessOracle(executable: "/usr/bin/tr", arguments: ["a-z", "A-Z"], outputs: [.stdout])
    }

    // MARK: - the backend itself

    func testCatRoundTripsStdin() throws {
        try requireExecutable("/bin/cat")
        XCTAssertEqual(try ProcessOracle(executable: "/bin/cat", outputs: [.stdout]).run("round trip 123"), "round trip 123")
    }

    func testRealTrUppercases() throws {
        try requireExecutable("/usr/bin/tr")
        XCTAssertEqual(try tr().run("hello world"), "HELLO WORLD")
    }

    func testTimeoutThrows() throws {
        try requireExecutable("/bin/sleep")
        let slow = ProcessOracle(executable: "/bin/sleep", arguments: ["5"], timeout: 0.4)
        XCTAssertThrowsError(try slow.run("")) { err in
            guard case ProcessOracle.OracleError.timedOut = err else { return XCTFail("expected timeout, got \(err)") }
        }
    }

    // MARK: - council fixes

    func testLosslessEncodingDistinctBinaryOutputsNeverCollapse() throws {
        try requireExecutable("/bin/sh")
        // printf raw bytes 0xFF 0xFE vs 0xFE 0xFF — both invalid UTF-8. Pre-fix, String(data:utf8)??"" made
        // both "" → false equivalent. Now they must differ.
        let a = ProcessOracle(executable: "/bin/sh", arguments: ["-c", "printf '\\377\\376'"], outputs: [.stdout])
        let b = ProcessOracle(executable: "/bin/sh", arguments: ["-c", "printf '\\376\\377'"], outputs: [.stdout])
        let oa = try a.run(""), ob = try b.run("")
        XCTAssertNotEqual(oa, ob, "distinct binary outputs must not collapse to the same string")
        XCTAssertFalse(oa.isEmpty)
        let report = EquivalenceRun.run([.init(id: "bin", input: "")], oracle: a.run, candidate: { inp in try b.run(inp) })
        XCTAssertEqual(report.overall, .regressed)   // was falsely .equivalent before the fix
    }

    func testExitCodeDifferenceIsCaught() throws {
        try requireExecutable("/bin/sh")
        // Identical stdout, different exit code. Default surface includes exit code → NOT equivalent.
        let ok = ProcessOracle(executable: "/bin/sh", arguments: ["-c", "echo hi"])          // exit 0
        let fail = ProcessOracle(executable: "/bin/sh", arguments: ["-c", "echo hi; exit 3"]) // exit 3, same stdout
        let report = EquivalenceRun.run([.init(id: "x", input: "")], oracle: ok.run, candidate: { inp in try fail.run(inp) })
        XCTAssertEqual(report.overall, .regressed, "a crash with identical stdout must not read equivalent")
    }

    func testLargeStdinDoesNotDeadlockOrTruncate() throws {
        try requireExecutable("/bin/cat")
        let big = String(repeating: "x", count: 300_000)   // well past the 64KB pipe buffer
        let out = try ProcessOracle(executable: "/bin/cat", outputs: [.stdout], timeout: 20).run(big)
        XCTAssertEqual(out.count, 300_000, "large stdin must round-trip with no deadlock and no truncation")
    }

    func testLargeStdoutNotTruncated() throws {
        try requireExecutable("/bin/cat")
        let big = String(repeating: "abcdefgh", count: 40_000)   // 320KB out
        XCTAssertEqual(try ProcessOracle(executable: "/bin/cat", outputs: [.stdout], timeout: 20).run(big).count, big.count)
    }

    // MARK: - the ENGINE, pointed at a real binary

    func testEngineJudgesCandidateAgainstRealTr() throws {
        try requireExecutable("/usr/bin/tr")
        let corpus: [EquivalenceRun.Case] = ["hello", "World", "abc123", "MiXeD", ""].enumerated()
            .map { .init(id: "\($0.offset)", input: $0.element) }
        let good = EquivalenceRun.run(corpus, oracle: tr().run, candidate: asciiUpper)
        XCTAssertEqual(good.overall, .evidenceBoundedEquivalent)
        let bad = EquivalenceRun.run(corpus, oracle: tr().run, candidate: { $0.lowercased() })
        XCTAssertEqual(bad.overall, .regressed)
    }

    func testEngineCatchesUnicodeDifferenceBetweenTrAndSwiftUppercased() throws {
        try requireExecutable("/usr/bin/tr")
        // Swift `.uppercased()` is Unicode-aware (café→CAFÉ) but tr 'a-z' 'A-Z' is ASCII-only (café→CAFé).
        // The engine surfaces this genuine portability bug as a regression.
        let report = EquivalenceRun.run([.init(id: "accent", input: "café")], oracle: tr().run, candidate: { $0.uppercased() })
        XCTAssertEqual(report.overall, .regressed)
    }

    // THE "capture breaks first" WALL on a real process: a nondeterministic oracle is caught by Gate 0 and
    // the engine REFUSES to certify — it never trusts a leaky capture.
    func testNondeterministicRealOracleIsRefusedByGate0() throws {
        try requireExecutable("/bin/sh")
        let rng = ProcessOracle(executable: "/bin/sh", arguments: ["-c", "od -An -N8 -tx1 /dev/urandom"], outputs: [.stdout])
        let report = EquivalenceRun.run([.init(id: "x", input: "")], oracle: rng.run, candidate: { _ in "anything" })
        XCTAssertEqual(report.overall, .captureFailed)
    }

    // MARK: - golden capture from a real binary + the whole cathedral end to end

    func testGoldenCaptureAndReplayFromRealTr() throws {
        try requireExecutable("/usr/bin/tr")
        let (golden, unsealed) = GoldenCorpus.capture([.init(id: "a", input: "hello")], oracle: tr().run)
        XCTAssertEqual(golden.map { $0.reference }, ["HELLO"])
        XCTAssertTrue(unsealed.isEmpty)
        XCTAssertEqual(GoldenCorpus.replay(golden, candidate: asciiUpper).overall, .evidenceBoundedEquivalent)
    }

    func testCathedralCertifiesACorrectPortOfARealBinary() throws {
        try requireExecutable("/usr/bin/tr")
        let seed: [EquivalenceRun.Case] = ["hello", "WORLD", "MixedCase99", "a-b-c", "x"].enumerated()
            .map { .init(id: "seed\($0.offset)", input: $0.element) }
        let mutants: [MutationMeter.Mutant] = [
            .init(name: "identity") { $0 },
            .init(name: "lower") { $0.lowercased() },
            .init(name: "reverse") { String($0.reversed()) },
            .init(name: "empty") { _ in "" },
            .init(name: "prefixed") { "X" + self.asciiUpper($0) },
        ]
        let result = PortVerifier.verify(record: [], seedInputs: seed, mutants: mutants,
                                         oracle: tr().run, candidate: asciiUpper)
        XCTAssertEqual(result.evidence.trust, .evidenceBoundedEquivalent)
        XCTAssertTrue(result.evidence.isCutoverEligible)
        XCTAssertEqual(result.evidence.mutationScore, 1.0)
    }
}
