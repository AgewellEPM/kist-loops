import Foundation

/// The outer loop — the "24/7 founder". Scan → rank → pick → run the inner
/// pipeline → repeat. It orchestrates real work only; every claim of progress is
/// backed by the inner loop's gated, committed artifacts.
public struct OuterLoop: Sendable {
    private let scanner: SignalScanner
    private let ranker: SignalRanker
    private let pipeline: Pipeline
    private let llm: LLMClient
    private let outputRoot: URL
    private let inner: InnerPipeline
    private let budget: LLMBudget?
    private let runToken: String
    private let log: Log

    public init(
        scanner: SignalScanner,
        ranker: SignalRanker = SignalRanker(),
        pipeline: Pipeline = .full,
        llm: LLMClient,
        outputRoot: URL,
        inner: InnerPipeline = InnerPipeline(),
        budget: LLMBudget? = nil,
        runToken: String = String(UUID().uuidString.prefix(6)).lowercased(),
        log: Log = Log("loop")
    ) {
        self.scanner = scanner
        self.ranker = ranker
        self.pipeline = pipeline
        self.llm = llm
        self.outputRoot = outputRoot
        self.inner = inner
        self.budget = budget
        self.runToken = runToken
        self.log = log
    }

    /// One full cycle. Returns the inner result, or nil if nothing worth building
    /// was found (an honest "no-op", not a fabricated project).
    @discardableResult
    public func runOnce(cycle: Int = 0) async throws -> InnerPipeline.Result? {
        log.info("scanning for signals…")
        let signals = try await scanner.scan()
        log.info("found \(signals.count) signals")
        guard let top = ranker.top(signals) else {
            log.warn("no signals to act on")
            return nil
        }
        log.success("selected (score \(String(format: "%.1f", top.score))): \(top.signal.title)")

        let agents = AgentFactory.agents(for: pipeline, llm: llm)
        // Per-run token in the dir name (Codex MED-6): two loops sharing an output root
        // and cycle number never collide on the same workspace/ledger.
        let dir = outputRoot.appendingPathComponent(
            Self.slug(top.signal.title, cycle: cycle) + "-" + runToken, isDirectory: true)
        let workspace = GitWorkspace(root: dir)

        let result = await inner.run(brief: top.signal.brief, agents: agents, workspace: workspace)
        if result.completed {
            log.success("pipeline complete → \(result.workspace.path) (\(result.artifacts.count) artifacts)")
        } else {
            log.warn("pipeline blocked at \(result.blockedStage?.displayName ?? "?"): \(result.blockReason ?? "")")
        }
        return result
    }

    /// Run until cancelled, `maxCycles` is reached, or the LLM budget is exhausted,
    /// sleeping `intervalSeconds` between cycles. Bounded by construction so an
    /// autonomous daemon can never spin unbounded (or unbounded-spend).
    /// Returns the number of cycles actually run.
    @discardableResult
    public func run(intervalSeconds: UInt64, maxCycles: Int? = nil) async -> Int {
        var cycle = 0
        while !Task.isCancelled {
            if let max = maxCycles, cycle >= max {
                log.info("reached max cycles (\(max)) — stopping"); break
            }
            if let budget, await budget.remaining() <= 0 {
                let spent = await budget.spent()
                log.warn("LLM budget exhausted (\(spent) calls) — stopping"); break
            }
            do {
                _ = try await runOnce(cycle: cycle)
            } catch {
                log.error("cycle \(cycle) failed: \(error)")
            }
            cycle += 1
            if maxCycles.map({ cycle >= $0 }) ?? false { continue }  // skip the sleep on the last cycle
            log.info("sleeping \(intervalSeconds)s until next cycle")
            try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
        }
        log.info("loop stopped after \(cycle) cycle(s)")
        return cycle
    }

    /// Filesystem-safe, deterministic workspace name.
    static func slug(_ title: String, cycle: Int) -> String {
        let allowed = CharacterSet.alphanumerics
        let base = title.lowercased().unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" }
            .prefix(48)
        let collapsed = String(base).replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(format: "c%03d-%@", cycle, collapsed.isEmpty ? "project" : collapsed)
    }
}
