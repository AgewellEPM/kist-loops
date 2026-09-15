import Foundation

/// Local accounting for concrete provider attempts, including failures, retries, compaction,
/// and review. This is advisory telemetry and grants no execution or completion authority.
public struct ProviderAttemptObservation: Sendable {
    public let id: String
    public let provider: String
    public let model: String
    public let mechanism: String
    public let usage: TokenUsage
    public let usageReported: Bool
    public let startedAt: Date
    public let endedAt: Date
    public let success: Bool

    @TaskLocal public static var observer: (@Sendable (ProviderAttemptObservation) -> Void)?

    static func record(provider: String, model: String, mechanism: String, usage: TokenUsage,
                       usageReported: Bool, elapsedNanoseconds: UInt64, success: Bool) {
        guard let observer else { return }
        let ended = Date()
        observer(Self(id: UUID().uuidString, provider: provider, model: model,
                      mechanism: mechanism, usage: usage, usageReported: usageReported,
                      startedAt: ended.addingTimeInterval(-Double(elapsedNanoseconds) / 1_000_000_000),
                      endedAt: ended, success: success))
    }
}
