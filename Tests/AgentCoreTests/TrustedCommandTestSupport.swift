import Foundation
@testable import AgentCore

func makePlanTestTrustedCommandReference(
    arguments: [String: Any], stdout: String, stderr: String = "", exitCode: Int,
    timedOut: Bool = false, wasSignalled: Bool = false
) -> BuilderTrustedCommandReference {
    let nonce = UUID().uuidString.lowercased()
    let argumentsDigest = AuditLog.digest(arguments).1
    return try! BuilderTrustedCommandReference(
        observationID: "test-observation-\(nonce)",
        invocationID: "test-invocation-\(nonce)",
        gateArgumentsDigest: argumentsDigest,
        requestedArgumentsDigest: argumentsDigest,
        effectiveLauncherDigest: BuilderEvidenceDigest.sha256(
            "test-launcher\u{0}\(argumentsDigest)"),
        stdoutDigest: BuilderEvidenceDigest.sha256(stdout),
        stderrDigest: BuilderEvidenceDigest.sha256(stderr),
        stdoutByteCount: stdout.utf8.count,
        stderrByteCount: stderr.utf8.count,
        exitCode: exitCode,
        timedOut: timedOut,
        wasSignalled: wasSignalled,
        wallTimeMilliseconds: 1)
}

func makePlanTestTrustedCommandResult(
    arguments: [String: Any], success: Bool = true, output: String,
    error: String? = nil, metadata: [String: String], exitCode: Int? = nil
) -> ToolResult {
    let stdout = metadata["stdout"] ?? output
    let stderr = metadata["stderr"] ?? ""
    let actualExitCode = exitCode ?? Int(metadata["exit_code"] ?? "") ?? (success ? 0 : 1)
    let timedOut = metadata["timed_out"]?.lowercased() == "true"
    let wasSignalled = metadata["was_signalled"]?.lowercased() == "true"
    let reference = makePlanTestTrustedCommandReference(
        arguments: arguments, stdout: stdout, stderr: stderr, exitCode: actualExitCode,
        timedOut: timedOut, wasSignalled: wasSignalled)
    return ToolResult(
        success: success, output: output, error: error, metadata: metadata,
        trustedCommandReference: reference)
}
