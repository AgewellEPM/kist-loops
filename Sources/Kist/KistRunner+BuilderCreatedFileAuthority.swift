import Foundation
import AgentCore

/// Narrow repair authority within one worker's sealed create contract. It is never serialized or
/// accepted from a provider. Editing a created path requires the same root and exact contents last
/// observed after a successful host file tool; another worker/root or preimage drift cannot reuse it.
actor BuilderCreatedFileAuthority {
    private var digests: [String: String] = [:]

    func record(path: String, context: ToolContext) {
        guard let key = key(path: path, context: context) else { return }
        digests[key] = digest(path: path, context: context)
    }

    func matches(path: String, context: ToolContext) -> Bool {
        guard let key = key(path: path, context: context), let expected = digests[key],
              let actual = digest(path: path, context: context) else { return false }
        return expected == actual
    }

    private func key(path: String, context: ToolContext) -> String? {
        guard let root = ToolContext.canonicalize(context.projectRoot) else { return nil }
        return root + "\u{0}" + path
    }

    private func digest(path: String, context: ToolContext) -> String? {
        guard let data = try? context.confinedRoot().readStableData(path, maxBytes: 16 * 1_024 * 1_024)
        else { return nil }
        return BuilderEvidenceDigest.sha256(data.base64EncodedString())
    }
}
