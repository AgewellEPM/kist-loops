import XCTest
@testable import AgentCore

final class SecurityAuditTests: XCTestCase {

    // MARK: secrets

    func testDetectsCommonSecretsAndRedacts() {
        let aws = "let key = \"AKIAIOSFODNN7EXAMPLE\""
        let f = SecretScanner.scan(text: aws, file: "c.swift")
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].category, .secret)
        XCTAssertEqual(f[0].severity, .critical)
        XCTAssertFalse(f[0].evidence.contains("AKIAIOSFODNN7EXAMPLE"))   // INVARIANT: never leak the raw secret
        XCTAssertTrue(f[0].evidence.contains("•"))
    }

    func testDetectsPrivateKeyAndGithubToken() {
        XCTAssertEqual(SecretScanner.scan(text: "-----BEGIN RSA PRIVATE KEY-----", file: "k.pem").first?.rule, "private-key")
        XCTAssertEqual(SecretScanner.scan(text: "token=ghp_012345678901234567890123456789012345", file: "x").first?.rule, "github-token")
    }

    func testGenericSecretSkipsPlaceholders() {
        XCTAssertTrue(SecretScanner.scan(text: #"api_key = "your_api_key_here_xxxx""#, file: "x").isEmpty)
        XCTAssertEqual(SecretScanner.scan(text: #"api_key = "a8Fj20fkQ91ldkfjs0211""#, file: "x").count, 1)
    }

    // MARK: SAST

    func testStaticAnalyzerCatchesDangerousPatterns() {
        XCTAssertEqual(StaticAnalyzer.scan(text: "subprocess.run(cmd, shell=True)", file: "a.py").first?.rule, "shell-true-py")
        XCTAssertEqual(StaticAnalyzer.scan(text: "requests.get(u, verify=False)", file: "a.py").first?.rule, "tls-verify-disabled-py")
        XCTAssertEqual(StaticAnalyzer.scan(text: "const x = eval(input)", file: "a.js").first?.rule, "eval-use")
        XCTAssertEqual(StaticAnalyzer.scan(text: "hashlib.md5(p)", file: "a.py").first?.category, .crypto)
    }

    func testStaticAnalyzerSkipsComments() {
        XCTAssertTrue(StaticAnalyzer.scan(text: "# subprocess.run(cmd, shell=True)", file: "a.py").isEmpty)
        XCTAssertTrue(StaticAnalyzer.scan(text: "// eval(x)", file: "a.js").isEmpty)
    }

    // MARK: dependencies

    func testDependencyAuditorFlagsFloatingVersions() {
        XCTAssertEqual(DependencyAuditor.scan(text: #"  "react": "^18.0.0""#, file: "package.json").first?.rule, "npm-floating-version")
        XCTAssertEqual(DependencyAuditor.scan(text: "requests>=2.0", file: "requirements.txt").first?.rule, "pip-unpinned")
        XCTAssertTrue(DependencyAuditor.scan(text: "requests==2.31.0", file: "requirements.txt").isEmpty)   // pinned = clean
        XCTAssertEqual(DependencyAuditor.scan(text: #".package(url: "x", from: "1.0.0")"#, file: "Package.swift").first?.rule, "spm-floating-version")
    }

    // MARK: composition + report

    func testScanFileComposesAllScanners() {
        let text = "api_key = \"a8Fj20fkQ91ldkfjs0211\"\nrequests.get(u, verify=False)"
        let f = SecurityAuditor.scanFile(text: text, relativePath: "app.py")
        XCTAssertTrue(f.contains { $0.category == .secret })
        XCTAssertTrue(f.contains { $0.category == .config })
    }

    func testReportSortsBySeverityAndRedactsInRender() {
        let report = AuditReport(findings: SecurityAuditor.scanFile(
            text: "x = \"AKIAIOSFODNN7EXAMPLE\"\nhashlib.md5(p)", relativePath: "a.py"),
            filesScanned: 1, root: "/tmp")
        XCTAssertEqual(report.findings.first?.severity, .critical)   // critical sorts first
        let rendered = report.render()
        XCTAssertFalse(rendered.contains("AKIAIOSFODNN7EXAMPLE"))    // INVARIANT: report never leaks the secret
        XCTAssertTrue(rendered.contains("a.py:1"))
    }

    func testSeverityOrdering() {
        XCTAssertTrue(SecurityFinding.Severity.critical > .high)
        XCTAssertTrue(SecurityFinding.Severity.high > .low)
    }

    // MARK: full walk on a temp tree

    func testAuditWalksTreeAndFindsSecret() throws {
        let dir = NSTemporaryDirectory() + "audit_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/node_modules", withIntermediateDirectories: true)
        try "AKIAIOSFODNN7EXAMPLE".write(toFile: dir + "/leak.swift", atomically: true, encoding: .utf8)
        try "AKIAIOSFODNN7EXAMPLE".write(toFile: dir + "/node_modules/ignored.swift", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let report = SecurityAuditor.audit(root: dir)
        XCTAssertEqual(report.findings.filter { $0.category == .secret }.count, 1)   // node_modules skipped
        XCTAssertEqual(report.findings.first?.file, "leak.swift")
    }
}
