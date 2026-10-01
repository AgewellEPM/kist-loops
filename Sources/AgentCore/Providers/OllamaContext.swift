import Foundation

extension OllamaProvider {
    /// Prevent obvious context overflow on non-loop callers as well (planner, capsule, router).
    /// This is an estimate, not a tokenizer. Reject before sending instead of letting the server
    /// silently drop the original objective. Images have a separate, conservative token reserve.
    func validateContextEstimate(_ body: [String: Any]) throws {
        guard let options = body["options"] as? [String: Any],
              let context = options["num_ctx"] as? Int else { return }
        var promptBytes = 0
        var images = 0
        for message in body["messages"] as? [[String: Any]] ?? [] {
            var textual = message
            images += (textual.removeValue(forKey: "images") as? [String])?.count ?? 0
            promptBytes += (try? JSONSerialization.data(withJSONObject: textual).count) ?? 0
        }
        for key in ["tools", "format"] {
            if let value = body[key], JSONSerialization.isValidJSONObject(value) {
                promptBytes += (try? JSONSerialization.data(withJSONObject: value).count) ?? 0
            }
        }
        let estimate = (promptBytes + 3) / 4 + images * 4_096 + 256
            + max(0, options["num_predict"] as? Int ?? 0)
        guard estimate <= context else {
            throw AIProviderError.configuration(
                "local context capacity estimate exceeded: \(estimate) tokens for a \(context)-token runtime; reduce the request or use cloud fallback")
        }
    }
}
