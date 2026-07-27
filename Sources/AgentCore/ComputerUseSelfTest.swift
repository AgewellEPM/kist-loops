import Foundation

/// End-to-end SMOKE TEST for computer use — proves the stack actually WORKS on this machine, not just
/// that permissions are granted (that's `computer_use_check`). It catches the failures readiness can't:
/// Screen Recording granted but capture returns black, a wrong Moondream key, an app with no AX tree,
/// and — the one thing no unit test can — whether input injection REALLY moves the cursor (all CGEvent
/// side effects are otherwise only "verified manually"). Run it before betting a live agent run on the
/// hands working.
///
/// The orchestration (run steps, aggregate, report) is pure and unit-tested with injected step results;
/// the production steps that touch the real screen/mouse/model are the integration boundary.
public enum ComputerUseSelfTest {

    public struct StepResult: Sendable, Equatable {
        public let name: String
        public let passed: Bool
        public let detail: String
        public init(name: String, passed: Bool, detail: String) {
            self.name = name; self.passed = passed; self.detail = detail
        }
    }

    public typealias Step = @Sendable () async -> StepResult

    /// Run the named steps in order; returns the results and whether every step passed.
    public static func run(_ steps: [Step]) async -> (results: [StepResult], allPassed: Bool) {
        var results: [StepResult] = []
        for step in steps { results.append(await step()) }
        return (results, results.allSatisfy(\.passed))
    }

    public static func report(_ results: [StepResult], allPassed: Bool) -> String {
        let lines = results.map { "  \($0.passed ? "✓" : "✗") \($0.name): \($0.detail)" }.joined(separator: "\n")
        let header = allPassed
            ? "✓ Computer-use self-test PASSED — the stack works on this machine."
            : "✗ Computer-use self-test FAILED — fix the ✗ steps before a live run."
        return header + "\n" + lines
    }
}
