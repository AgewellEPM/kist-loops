import Foundation

extension ToolResult {
    /// The same result with `prefix` prepended to its output. Keeps the trusted command reference
    /// and builder verification receipt (their fields are module-internal), so a wrapper that
    /// annotates a sealed command's output cannot strip the evidence that seals it (0.17.63).
    public func prefixingOutput(_ prefix: String) -> ToolResult {
        ToolResult(success: success, output: prefix + output, error: error,
                   metadata: metadata, attachments: attachments,
                   trustedCommandReference: trustedCommandReference,
                   trustedBuilderVerification: trustedBuilderVerification)
    }
}
