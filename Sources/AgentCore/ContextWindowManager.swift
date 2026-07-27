import Foundation

/// Bounds the outbound model context for long REPL/checkpoint transcripts.
///
/// The full transcript remains in the local checkpoint. This manager only trims the message list
/// sent to a provider call, preserving the opening context and the freshest turns with an explicit
/// notice that middle history was omitted.
public struct ContextWindowManager: Sendable {
    public var maxCharacters: Int
    public var keepFirst: Int
    public var keepLast: Int

    public init(maxCharacters: Int = 80_000, keepFirst: Int = 1, keepLast: Int = 48) {
        self.maxCharacters = max(1_000, maxCharacters)
        self.keepFirst = max(0, keepFirst)
        self.keepLast = max(1, keepLast)
    }

    public static let `default` = ContextWindowManager()

    /// Build an outbound prompt window from provider/model metadata. Large-window models such as
    /// MiMo get to carry far more repo/conversation context; unknown models keep the conservative
    /// default so small windows do not get overrun.
    public static func forModel(capabilities: ModelCapabilities) -> ContextWindowManager {
        guard let tokens = capabilities.contextWindowTokens, tokens > 0 else { return .default }
        let usableCharacters = max(80_000, Int(Double(tokens) * 4.0 * 0.80))
        let tail = tokens >= 200_000 ? 256 : 48
        return ContextWindowManager(maxCharacters: usableCharacters, keepFirst: 1, keepLast: tail)
    }

    /// True when the transcript exceeds the outbound budget — the trigger for compaction.
    public func overBudget(_ messages: [ChatMessage]) -> Bool { totalCost(messages) > maxCharacters }

    /// Split an over-budget transcript into (keep-front, summarize-these, keep-back). The middle is what
    /// gets compacted into ONE summary; prefix+suffix stay verbatim. nil if there's nothing worth
    /// compacting (not over budget, or too few messages to have a middle).
    public func compactionSplit(_ messages: [ChatMessage]) -> (prefix: [ChatMessage], middle: [ChatMessage], suffix: [ChatMessage])? {
        guard overBudget(messages), messages.count > keepFirst + keepLast + 1 else { return nil }
        let prefix = Array(messages.prefix(keepFirst))
        let suffix = Array(messages.suffix(keepLast))
        let middle = Array(messages.dropFirst(keepFirst).dropLast(keepLast))
        guard !middle.isEmpty else { return nil }
        return (prefix, middle, suffix)
    }

    /// Assemble the compacted transcript: prefix + a single summary message + suffix. Unlike `trim`
    /// (which DROPS the middle with a count notice), this REPLACES it with a model-written summary so
    /// decisions/facts/state survive — Claude-Code-style auto-compaction.
    public func compacted(prefix: [ChatMessage], summary: String, suffix: [ChatMessage]) -> [ChatMessage] {
        let summaryMsg = ChatMessage(role: .user,
            content: "[Earlier conversation was compacted to fit the context window. Summary of what happened, decisions made, and current state:]\n\(summary)")
        return prefix + [summaryMsg] + suffix
    }

    public func trim(_ messages: [ChatMessage]) -> [ChatMessage] {
        guard totalCost(messages) > maxCharacters, messages.count > 1 else { return messages }

        let prefixCount = min(keepFirst, messages.count)
        let prefix = Array(messages.prefix(prefixCount))
        let notice = ChatMessage(role: .user, content: "[Context window notice: earlier middle conversation was omitted from this provider call to stay within the model context window. Use current files/tools as source of truth.]")

        var used = totalCost(prefix) + cost(notice)
        var suffix: [ChatMessage] = []
        let candidates = Array(messages.dropFirst(prefixCount)).reversed()

        for message in candidates {
            let messageCost = cost(message)
            if suffix.count < keepLast, used + messageCost <= maxCharacters {
                suffix.insert(message, at: 0)
                used += messageCost
            } else if suffix.isEmpty, used < maxCharacters {
                suffix.insert(truncated(message, maxContentCharacters: max(80, maxCharacters - used - 200)), at: 0)
                used = maxCharacters
            }
        }

        let omitted = max(0, messages.count - prefix.count - suffix.count)
        guard omitted > 0 else { return messages }
        let countedNotice = ChatMessage(role: .user, content: "[Context window notice: \(omitted) earlier middle message(s) were omitted from this provider call to stay within the model context window. Use current files/tools as source of truth.]")
        return prefix + [countedNotice] + suffix
    }

    private func totalCost(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + cost($1) }
    }

    private func cost(_ message: ChatMessage) -> Int {
        var n = message.content.count
        n += message.toolCalls?.reduce(0) { $0 + $1.name.count + $1.argumentsJSON.count + $1.id.count } ?? 0
        n += message.toolCallId?.count ?? 0
        if message.imageData != nil { n += 2_000 }
        return n + 32
    }

    private func truncated(_ message: ChatMessage, maxContentCharacters: Int) -> ChatMessage {
        guard message.content.count > maxContentCharacters else { return message }
        let head = message.content.prefix(max(0, maxContentCharacters))
        return ChatMessage(role: message.role,
                           content: "\(head)\n[...truncated by context window...]",
                           imageData: message.imageData,
                           imageMimeType: message.imageMimeType,
                           toolCalls: message.toolCalls,
                           toolCallId: message.toolCallId)
    }
}
