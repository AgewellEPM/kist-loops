import Foundation
import AgentCore

/// Deterministic review scaffolding for "review/audit/latest changes" prompts.
///
/// This closes the MiMo failure mode: an open-ended review caused the model to list directories and
/// write a plan instead of reading the changed files. Kist RESOLVES the request into the exact target
/// files — via `ReviewTargetResolver` (path / subsystem / symbol targeting over git+ripgrep), falling
/// back to the git-changed set — then hands the model that named file list through the tier-aware
/// `Prompts.review` prompt. So "review the auth changes" reviews the auth files, not a directory dump.
enum ReviewContext {
    typealias GitRunner = (_ projectRoot: String, _ args: [String]) -> String?

    static func renderIfNeeded(request: String, projectRoot: String,
                               providerId: String = "", model: String? = nil,
                               sources: ReviewSources? = nil,
                               runner: GitRunner = defaultGitOutput) -> String? {
        guard isReviewLike(request) else { return nil }
        let src = sources ?? GitRipgrepReviewSources(projectRoot: projectRoot)
        let tier = ModelTier.of(providerId: providerId, model: model)

        // Resolve the request into TARGETED files (path / subsystem / symbol). The resolver's own
        // changed-files strategy is intentionally NOT used here — we prefer our richer changed-files set
        // (git status + last-5-commits) for those, so a generic "review recent changes" still sees commits.
        var plan = ReviewTargetResolver.resolve(target: request, sources: src)
        if plan.isEmpty || plan.strategy == "changed-files" {
            let changed = reviewTargets(projectRoot: projectRoot, runner: runner)   // status + last-5-commits
            plan = changed.isEmpty
                ? ReviewPlan(files: [], strategy: "unresolved",
                             rationale: "no target resolved and nothing changed — name a file, symbol, or subsystem")
                : ReviewPlan(files: Array(changed.prefix(12)), strategy: "changed-files",
                             rationale: "reviewing the git-changed set (status + recent commits)")
        }

        guard !plan.isEmpty else {
            return """
            REVIEW TARGETS: none resolved. Name a file/path, a symbol, a subsystem word, or say "recent
            changes". Do not fabricate a review — say REVIEW INCOMPLETE if you cannot ground it in files.
            """
        }
        // Hand the model the tier-aware review prompt built from the resolved plan (the review subsystem).
        // If the set is large for the tier, note the pass sizing (ReviewBatcher) so a weak model paces itself.
        let perPass = ReviewBatcher.filesPerPass(tier)
        let batchNote = plan.files.count > perPass
            ? "\n\n(That is \(plan.files.count) files — read them in passes of ~\(perPass); do not skip any.)"
            : ""
        return "REVIEW TARGETING · strategy: \(plan.strategy)\n\n" + Prompts.review(plan: plan, tier: tier) + batchNote
    }

    static func reviewTargets(projectRoot: String, runner: GitRunner = defaultGitOutput) -> [String] {
        let status = parseStatus(runner(projectRoot, ["status", "--porcelain"]) ?? "")
        let recent = parseNameLines(runner(projectRoot, ["log", "-n", "5", "--name-only", "--format="]) ?? "")
        return orderedUnique((status + recent).filter(isSafeProjectPath))
    }

    static func isReviewLike(_ request: String) -> Bool {
        let lower = request.lowercased()
        return lower.contains("review") || lower.contains("audit") || lower.contains("assess")
            || lower.contains("vulnerability") || lower.contains("security gap")
            || lower.contains("latest changes") || lower.contains("new work")
            || lower.contains("what is broken") || lower.contains("failure point")
    }

    static func parseStatus(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { raw in
            guard raw.count >= 4 else { return nil }
            let pathPart = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if pathPart.contains(" -> ") {
                return pathPart.components(separatedBy: " -> ").last?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return pathPart
        }
    }

    static func parseNameLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func isSafeProjectPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return !parts.contains("..") && !parts.contains(".git")
    }

    /// Dedup PRESERVING order. `reviewTargets` passes status-files first, then recent-commit files, so the
    /// currently-dirty set (what you're actively working on) stays at the front and survives the prefix cap —
    /// older commit-history paths can't crowd it out (which an alphabetic sort would allow).
    private static func orderedUnique(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for p in paths where seen.insert(p).inserted { out.append(p) }
        return out
    }

    private static func defaultGitOutput(projectRoot: String, args: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: "/usr/bin/git") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", projectRoot] + args
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
