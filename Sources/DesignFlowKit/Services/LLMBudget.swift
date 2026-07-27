import Foundation

/// A hard cap on how many model calls a run may make. An autonomous loop that
/// makes paid API calls with no bound is a foot-gun; this is the safety valve.
/// Fail-closed: once the cap is hit, further calls are refused (the pipeline
/// blocks), never silently allowed.
public actor LLMBudget {
    public let maxCalls: Int
    private var used = 0

    public init(maxCalls: Int) {
        self.maxCalls = max(0, maxCalls)
    }

    /// Reserve one call. Returns false if the cap is already reached (caller must
    /// treat that as a hard stop, not a retry).
    public func tryConsume() -> Bool {
        guard used < maxCalls else { return false }
        used += 1
        return true
    }

    public func spent() -> Int { used }
    public func remaining() -> Int { max(0, maxCalls - used) }
}

/// Decorator that enforces an `LLMBudget` around any `LLMClient`. Composes with the
/// real OpenAI client or the dry stub identically.
public struct BudgetedLLMClient: LLMClient {
    private let inner: LLMClient
    private let budget: LLMBudget

    public init(_ inner: LLMClient, budget: LLMBudget) {
        self.inner = inner
        self.budget = budget
    }

    public func complete(system: String, user: String) async throws -> String {
        guard await budget.tryConsume() else {
            throw LLMError.budgetExceeded(limit: budget.maxCalls)
        }
        return try await inner.complete(system: system, user: user)
    }
}
