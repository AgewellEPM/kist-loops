import Foundation
import AgentCore

// `/audit` — the SECURITY AUDIT surface (roadmap #2). The whole scanner suite already existed
// (SecurityAuditor orchestrating SecretScanner + StaticAnalyzer/SAST + DependencyAuditor, plus the
// OWASP-Top-10-Agentic ComplianceMapper) but had no user-facing command. This exposes it: run the audit
// over the project and print a severity-ranked report; `/audit owasp` prints the governance posture.
extension KistREPL {

    func runSecurityAudit(args: String) async {
        let a = args.trimmingCharacters(in: .whitespaces).lowercased()
        if ["owasp", "compliance", "governance", "posture"].contains(a) {
            print("\u{001B}[36;1m🛡  governance posture\u{001B}[0m")
            print(ComplianceMapper.report())
            return
        }
        let root = projectRoot
        print("\u{001B}[36;1m🛡  security audit\u{001B}[0m\u{001B}[2m · scanning for committed secrets, injection surfaces, weak crypto, insecure config, risky deps…\u{001B}[0m")
        // Off the async runtime — a full tree walk is CPU/IO bound (bounded to 5000 files internally).
        let report = await Task.detached(priority: .userInitiated) {
            SecurityAuditor.audit(root: root)
        }.value
        print(report.render())
        if !report.findings.isEmpty {
            print("\u{001B}[2m  · static-analysis LEADS — verify each before acting · `/audit owasp` for the OWASP-Top-10-Agentic posture\u{001B}[0m")
        }
    }
}
