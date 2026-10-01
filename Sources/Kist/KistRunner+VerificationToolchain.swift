import Foundation
import AgentCore

/// Host-side toolchain reality check for sealed verification commands (0.17.63).
///
/// The sealed planning pass names a verification executable from the closed allowlist, and the
/// builder later runs it through the confined `run_command` chokepoint with the launcher's PATH.
/// `pytest` is on that allowlist, but on a stock macOS install the runner exists only as a module
/// of the system `python3` — there is no `pytest` binary on PATH (live 2026-09-27: a correct
/// hello-world plan wrote both files and then failed its final verification with "executable not
/// found or not executable: pytest"). Rewriting `pytest …` to `python3 -m pytest …` when, and
/// only when, the bare binary is absent and `python3` is present keeps the SAME runner and the
/// same arguments; both executables are on the allowlist, so no authority changes hands.
extension KistRunner {
    /// Directories consulted after the process PATH, mirroring RunCommandTool's fallback so the
    /// preflight sees the toolchain the confined runner will see.
    static let verificationToolchainFallbackDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// True when `executable` (a bare name or absolute path) resolves to an executable file on the
    /// process PATH or the well-known toolchain dirs. Bare names only: the allowlist has no paths.
    static func hostVerificationExecutableResolvable(
        _ executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let fm = FileManager.default
        if executable.hasPrefix("/") { return fm.isExecutableFile(atPath: executable) }
        guard !executable.contains("/") else { return false }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let dirs = path.split(separator: ":").map(String.init)
            + verificationToolchainFallbackDirs.filter { !path.split(separator: ":").contains(Substring($0)) }
        return dirs.contains { fm.isExecutableFile(atPath: $0 + "/" + executable) }
    }

    /// Module-form rewrites for allowlisted runners that commonly ship without a binary on PATH.
    /// Keyed by the bare executable; the value is the interpreter and the argument prefix.
    static let verificationModuleForms: [String: (interpreter: String, prefix: [String])] = [
        "pytest": (interpreter: "python3", prefix: ["-m", "pytest"]),
    ]

    /// `pytest args` → `python3 -m pytest args` when `pytest` is not resolvable but `python3` is.
    /// Every other command, and a resolvable `pytest`, comes back unchanged.
    static func normalizeVerificationCommand(
        executable: String,
        arguments: [String],
        executableResolvable: (String) -> Bool
    ) -> (executable: String, arguments: [String]) {
        guard let form = verificationModuleForms[executable],
              !executableResolvable(executable),
              executableResolvable(form.interpreter) else {
            return (executable, arguments)
        }
        return (form.interpreter, form.prefix + arguments)
    }

    /// Tokens the sealed planning pass reserves ON TOP of prompt bytes + max output, because the
    /// provider's measured usage will exceed Kist's prompt bytes:
    /// - subscription CLIs prepend a fixed product system context (measured, never in our bytes);
    /// - reasoning models report thinking tokens in `completion_tokens` even when thinking is
    ///   disabled (live 2026-09-27: deepseek-v4-pro answered the planning JSON fine, then
    ///   "provider usage exceeded the reserved sealed planning pass upper bound" refused the build —
    ///   the only warm planner left on the machine could never plan).
    /// The reservation is transient; the ledger commits the measured usage afterwards.
    static let builderPreflightReasoningAllowance = 32_768
    static let builderPreflightReasoningProviderIDs: Set<String> = ["deepseek"]

    static func builderPreflightFramingAllowance(
        providerID: String, model: String?, registry: ProviderRegistry
    ) -> Int {
        // This pass always requests disableThinking. Ollama honors think:false for Qwen3.5;
        // it has no hidden subscription prompt or unbounded reasoning outside num_predict.
        // Reserving the cloud reasoning allowance made even a one-file local plan unaffordable.
        if providerID.lowercased() == "ollama" { return 0 }
        if ["claude-cli", "codex-cli"].contains(providerID) { return builderPreflightReasoningAllowance }
        if builderPreflightReasoningProviderIDs.contains(providerID.lowercased()) {
            return builderPreflightReasoningAllowance
        }
        return registry.capabilities(providerId: providerID, model: model).reasoning
            ? builderPreflightReasoningAllowance : 0
    }
}
