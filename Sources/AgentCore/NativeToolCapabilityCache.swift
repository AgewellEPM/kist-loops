import Foundation

/// Exact capability observation persisted with a loop checkpoint. A provider/model is not
/// globally labeled "no native tools": the observation is bound to the precise advertised
/// tool schema and expires so provider upgrades are probed again.
public struct NativeToolFallbackState: Codable, Sendable, Equatable {
    public let providerId: String
    public let model: String
    public let toolSchemaFingerprint: String
    /// `false` means resume this checkpoint in text mode, but do not quarantine fresh turns.
    /// Optional for backward-compatible decoding of the first cacheable-only schema.
    public let cacheable: Bool?
    public let recordedAt: Date

    public init(providerId: String, model: String, toolSchemaFingerprint: String,
                cacheable: Bool = true, recordedAt: Date = Date()) {
        self.providerId = providerId.lowercased()
        self.model = model.lowercased()
        self.toolSchemaFingerprint = toolSchemaFingerprint
        self.cacheable = cacheable
        self.recordedAt = recordedAt
    }

    var isCacheable: Bool { cacheable ?? true }

    func matches(providerId: String, model: String, toolSchemaFingerprint: String,
                 now: Date, ttl: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(recordedAt)
        return self.providerId == providerId.lowercased()
            && self.model == model.lowercased()
            && self.toolSchemaFingerprint == toolSchemaFingerprint
            && age >= 0 && age <= ttl
    }
}

/// Exact positive observation that the provider accepted a request carrying this tool schema.
/// This is distinct from a completed tool round-trip: a provider proves schema support as soon as
/// it successfully accepts the request (or emits a tool call), even when the assistant calls no tool.
public struct NativeToolPositiveState: Codable, Sendable, Equatable {
    public let providerId: String
    public let model: String
    public let toolSchemaFingerprint: String
    public let recordedAt: Date

    public init(providerId: String, model: String, toolSchemaFingerprint: String,
                recordedAt: Date = Date()) {
        self.providerId = providerId.lowercased()
        self.model = model.lowercased()
        self.toolSchemaFingerprint = toolSchemaFingerprint
        self.recordedAt = recordedAt
    }

    func matches(providerId: String, model: String, toolSchemaFingerprint: String,
                 now: Date, ttl: TimeInterval) -> Bool {
        let age = now.timeIntervalSince(recordedAt)
        return self.providerId == providerId.lowercased()
            && self.model == model.lowercased()
            && self.toolSchemaFingerprint == toolSchemaFingerprint
            && age >= 0 && age <= ttl
    }
}

/// Per-loop capability quarantine shared by all interactive turns on that loop. Checkpoints carry
/// the same exact observation across process restarts; this cache prevents a fresh checkpoint for
/// every REPL turn from probing the same rejected schema again.
actor NativeToolCapabilityCache {
    static let defaultTTL: TimeInterval = 6 * 60 * 60

    private struct Key: Hashable {
        let providerId: String
        let model: String
        let schema: String
    }

    private let ttl: TimeInterval
    private var recordedAt: [Key: Date] = [:]
    private var positiveRecordedAt: [Key: Date] = [:]

    init(ttl: TimeInterval = NativeToolCapabilityCache.defaultTTL) {
        self.ttl = max(1, ttl)
    }

    func observation(providerId: String, model: String, schema: String,
                     now: Date = Date()) -> NativeToolFallbackState? {
        let key = Key(providerId: providerId.lowercased(), model: model.lowercased(), schema: schema)
        if freshPositiveDate(for: key, now: now) != nil {
            recordedAt.removeValue(forKey: key)
            return nil
        }
        guard let date = recordedAt[key] else { return nil }
        let age = now.timeIntervalSince(date)
        if age < 0 || age > ttl {
            recordedAt.removeValue(forKey: key)
            return nil
        }
        return NativeToolFallbackState(
            providerId: key.providerId, model: key.model,
            toolSchemaFingerprint: key.schema, cacheable: true, recordedAt: date)
    }

    func record(_ state: NativeToolFallbackState) {
        guard state.isCacheable else { return }
        let key = Key(providerId: state.providerId, model: state.model,
                      schema: state.toolSchemaFingerprint)
        guard freshPositiveDate(for: key, now: Date()) == nil else { return }
        recordedAt[key] = state.recordedAt
    }

    func recordPositive(_ state: NativeToolPositiveState, now: Date = Date()) {
        let key = Key(providerId: state.providerId, model: state.model,
                      schema: state.toolSchemaFingerprint)
        let age = now.timeIntervalSince(state.recordedAt)
        guard age >= 0, age <= ttl else { return }
        positiveRecordedAt[key] = state.recordedAt
        recordedAt.removeValue(forKey: key)
    }

    func hasPositive(providerId: String, model: String, schema: String,
                     now: Date = Date()) -> Bool {
        let key = Key(providerId: providerId.lowercased(), model: model.lowercased(), schema: schema)
        return freshPositiveDate(for: key, now: now) != nil
    }

    private func freshPositiveDate(for key: Key, now: Date) -> Date? {
        guard let date = positiveRecordedAt[key] else { return nil }
        let age = now.timeIntervalSince(date)
        guard age >= 0, age <= ttl else {
            positiveRecordedAt.removeValue(forKey: key)
            return nil
        }
        return date
    }
}
