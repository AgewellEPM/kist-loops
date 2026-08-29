import Foundation

/// Lifecycle is evaluated before pinning or ranking. A pin can keep an eligible memory salient, but it
/// can never resurrect a retired, superseded, or application-time-ineligible claim.
public enum MemoryLifecycleStatus: String, Codable, Sendable, Equatable {
    case active
    case retired
    case superseded
}

/// Decay rates intentionally match the Python Cortex memory schema.
public enum MemoryDecayRate: String, Codable, Sendable, Equatable, CaseIterable {
    case none
    case verySlow = "very_slow"
    case slow
    case medium
    case fast
    case veryFast = "very_fast"
    case session

    public var halfLifeDays: Double {
        switch self {
        case .none: return 36_500
        case .verySlow: return 365
        case .slow: return 180
        case .medium: return 90
        case .fast: return 30
        case .veryFast: return 7
        case .session: return 1
        }
    }
}

public enum TemporalMemoryError: Error, Sendable, Equatable, LocalizedError {
    case invalidField(String)
    case duplicateAliases([String])
    case unknownFields([String])
    case unverifiedReinforcement
    case inactiveReinforcement
    case futureConfirmation
    case counterOverflow(String)

    public var errorDescription: String? {
        switch self {
        case .invalidField(let field): return "invalid temporal-memory field: \(field)"
        case .duplicateAliases(let fields):
            return "duplicate temporal-memory aliases: \(fields.joined(separator: ", "))"
        case .unknownFields(let fields):
            return "unknown temporal-memory fields: \(fields.joined(separator: ", "))"
        case .unverifiedReinforcement: return "reinforcement requires verified evidence"
        case .inactiveReinforcement: return "retired or superseded memory cannot be reinforced"
        case .futureConfirmation: return "confirmation time is too far in the future"
        case .counterOverflow(let field): return "temporal-memory counter overflow: \(field)"
        }
    }
}

private struct TemporalAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// Explicit recurrence used only as a bounded ranking multiplier. Absence means no seasonal behavior;
/// callers must never infer a season from prose, tags, or one historical observation.
public struct SeasonalMemoryWindow: Codable, Sendable, Equatable {
    public static let maximumTimeZoneBytes = 128
    public static let maximumInSeasonBoost = 2.0

    public let months: [Int]
    /// Monday = 0 ... Sunday = 6, matching Python `datetime.weekday()`.
    public let weekdays: [Int]
    public let startHour: Int?
    public let endHour: Int?
    public let timeZoneIdentifier: String
    public let inSeasonBoost: Double
    public let offSeasonFactor: Double

    public init(months: [Int] = [], weekdays: [Int] = [],
                startHour: Int? = nil, endHour: Int? = nil,
                timeZoneIdentifier: String = "UTC",
                inSeasonBoost: Double = 1.15, offSeasonFactor: Double = 0.35) throws {
        guard months.count <= 12,
              months.allSatisfy({ (1...12).contains($0) }),
              Set(months).count == months.count else {
            throw TemporalMemoryError.invalidField("seasonal_window.months")
        }
        guard weekdays.count <= 7,
              weekdays.allSatisfy({ (0...6).contains($0) }),
              Set(weekdays).count == weekdays.count else {
            throw TemporalMemoryError.invalidField("seasonal_window.weekdays")
        }
        guard (startHour == nil) == (endHour == nil) else {
            throw TemporalMemoryError.invalidField("seasonal_window.daily_hours")
        }
        if let startHour, let endHour {
            guard (0...23).contains(startHour), (0...24).contains(endHour),
                  startHour != endHour,
                  !(startHour == 0 && endHour == 0) else {
                throw TemporalMemoryError.invalidField("seasonal_window.daily_hours")
            }
        }
        guard !months.isEmpty || !weekdays.isEmpty || startHour != nil else {
            throw TemporalMemoryError.invalidField("seasonal_window.selectors")
        }

        let zone = timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !zone.isEmpty, !zone.contains("\0"),
              zone.utf8.count <= Self.maximumTimeZoneBytes,
              (zone == "UTC" || TimeZone.knownTimeZoneIdentifiers.contains(zone)),
              TimeZone(identifier: zone) != nil else {
            throw TemporalMemoryError.invalidField("seasonal_window.timezone")
        }
        guard inSeasonBoost.isFinite, (1...Self.maximumInSeasonBoost).contains(inSeasonBoost) else {
            throw TemporalMemoryError.invalidField("seasonal_window.in_season_boost")
        }
        guard offSeasonFactor.isFinite, (0...1).contains(offSeasonFactor) else {
            throw TemporalMemoryError.invalidField("seasonal_window.off_season_factor")
        }

        self.months = months.sorted()
        self.weekdays = weekdays.sorted()
        self.startHour = startHour
        self.endHour = endHour
        self.timeZoneIdentifier = zone
        self.inSeasonBoost = inSeasonBoost
        self.offSeasonFactor = offSeasonFactor
    }

    public func isInSeason(at instant: Date) -> Bool {
        guard instant.timeIntervalSince1970.isFinite,
              let zone = TimeZone(identifier: timeZoneIdentifier) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = zone

        var selectorInstant = instant
        if let startHour, let endHour {
            let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: instant)
            guard let hour = components.hour, let minute = components.minute,
                  let second = components.second else { return false }
            let localHour = Double(hour) + Double(minute) / 60
                + Double(second) / 3_600 + Double(components.nanosecond ?? 0) / 3_600_000_000_000
            if startHour < endHour {
                guard Double(startHour) <= localHour, localHour < Double(endHour) else { return false }
            } else {
                guard localHour >= Double(startHour) || localHour < Double(endHour) else { return false }
                if localHour < Double(endHour) {
                    guard let previousLocalDay = calendar.date(byAdding: .day, value: -1, to: instant) else {
                        return false
                    }
                    selectorInstant = previousLocalDay
                }
            }
        }

        let selectors = calendar.dateComponents([.month, .weekday], from: selectorInstant)
        if !months.isEmpty {
            guard let month = selectors.month, months.contains(month) else { return false }
        }
        if !weekdays.isEmpty {
            guard let foundationWeekday = selectors.weekday else { return false }
            let mondayZeroWeekday = (foundationWeekday + 5) % 7
            guard weekdays.contains(mondayZeroWeekday) else { return false }
        }
        return true
    }

    public func multiplier(at instant: Date) -> Double {
        isInSeason(at: instant) ? inSeasonBoost : offSeasonFactor
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case months, weekdays
        case startHour = "start_hour"
        case startHourCamel = "startHour"
        case localStartHour = "local_start_hour"
        case localStartHourCamel = "localStartHour"
        case endHour = "end_hour"
        case endHourCamel = "endHour"
        case localEndHour = "local_end_hour"
        case localEndHourCamel = "localEndHour"
        case timezone
        case timeZone = "timeZone"
        case inSeasonBoost = "in_season_boost"
        case inSeasonBoostCamel = "inSeasonBoost"
        case offSeasonFactor = "off_season_factor"
        case offSeasonFactorCamel = "offSeasonFactor"
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: TemporalAnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = raw.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else { throw TemporalMemoryError.unknownFields(unknown) }

        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedMonths = try values.decodeIfPresent([Int].self, forKey: .months) ?? []
        let decodedWeekdays = try values.decodeIfPresent([Int].self, forKey: .weekdays) ?? []
        let decodedStart = try Self.decodeAlias(
            Int.self, from: values,
            keys: [.startHour, .startHourCamel, .localStartHour, .localStartHourCamel])
        let decodedEnd = try Self.decodeAlias(
            Int.self, from: values,
            keys: [.endHour, .endHourCamel, .localEndHour, .localEndHourCamel])
        let decodedZone = try Self.decodeAlias(
            String.self, from: values, keys: [.timezone, .timeZone]) ?? "UTC"
        let decodedBoost = try Self.decodeAlias(
            Double.self, from: values, keys: [.inSeasonBoost, .inSeasonBoostCamel]) ?? 1.15
        let decodedOffFactor = try Self.decodeAlias(
            Double.self, from: values, keys: [.offSeasonFactor, .offSeasonFactorCamel]) ?? 0.35
        try self.init(months: decodedMonths, weekdays: decodedWeekdays,
                      startHour: decodedStart, endHour: decodedEnd,
                      timeZoneIdentifier: decodedZone,
                      inSeasonBoost: decodedBoost, offSeasonFactor: decodedOffFactor)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(months, forKey: .months)
        try values.encode(weekdays, forKey: .weekdays)
        try values.encodeIfPresent(startHour, forKey: .startHour)
        try values.encodeIfPresent(endHour, forKey: .endHour)
        try values.encode(timeZoneIdentifier, forKey: .timezone)
        try values.encode(inSeasonBoost, forKey: .inSeasonBoost)
        try values.encode(offSeasonFactor, forKey: .offSeasonFactor)
    }

    private static func decodeAlias<T: Decodable>(
        _ type: T.Type,
        from values: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> T? {
        let present = keys.filter { values.contains($0) }
        guard present.count <= 1 else {
            throw TemporalMemoryError.duplicateAliases(present.map(\.rawValue))
        }
        guard let key = present.first else { return nil }
        return try values.decodeIfPresent(type, forKey: key)
    }
}

public enum TemporalMemoryState: String, Sendable, Equatable {
    case eligible
    case superseded
    case retired
    case futureCreated = "future-created"
    case futureTransaction = "future-transaction"
    case futureAccess = "future-access"
    case futureConfirmation = "future-confirmation"
    case notYetValid = "not-yet-valid"
    case validityExpired = "validity-expired"
    case invalid
}

public struct TemporalMemoryEvaluation: Sendable, Equatable {
    public let state: TemporalMemoryState
    public let salience: Double
    public let decayAnchor: Date?
    /// Nil means no explicit seasonal recurrence was attached.
    public let inSeason: Bool?

    public var isRetrievalEligible: Bool { state == .eligible }

    public init(state: TemporalMemoryState, salience: Double,
                decayAnchor: Date?, inSeason: Bool?) {
        self.state = state
        self.salience = salience
        self.decayAnchor = decayAnchor
        self.inSeason = inSeason
    }
}

/// Shared transaction-time, valid-time, evidence-time, lifecycle, and decay metadata. Codable uses
/// explicit ISO-8601 strings (and accepts Unix seconds) so it never inherits Foundation's reference-date
/// `Date` encoding. Encoding emits the Python schema's snake_case names; decoding accepts snake/camel.
public struct MemoryTemporalEnvelope: Codable, Sendable, Equatable {
    public static let maximumFutureEvidenceSkew: TimeInterval = 5 * 60
    /// Scalar event clocks kept beside an encoded envelope may lose sub-millisecond precision at the
    /// JSON/ISO-8601 boundary. Anything beyond this allowance is a different history and must not be
    /// admitted for storage or operational recall.
    public static let storedClockAgreementTolerance: TimeInterval = 0.001
    public static let maximumCounter = Int64.max
    public static let confidenceFloor = 0.05
    public static let maximumLifecycleTextBytes = 512
    // Python's datetime/ISO-8601 wire domain is years 0001...9999. Keeping every
    // temporal field inside that shared domain makes later encoding/calendar use total.
    public static let minimumWireEpoch: TimeInterval = -62_135_596_800
    public static let maximumWireEpoch: TimeInterval = 253_402_300_799.999

    /// Validate the legacy scalar event clock beside a temporal envelope. Keeping this check in the
    /// shared kernel prevents shelves from presenting one event time to audit/order code and another
    /// to decay and eligibility evaluation.
    public static func storedClockAgrees(_ scalarEpoch: TimeInterval,
                                         with nested: Date) -> Bool {
        let nestedEpoch = nested.timeIntervalSince1970
        guard scalarEpoch.isFinite, nestedEpoch.isFinite,
              (minimumWireEpoch...maximumWireEpoch).contains(scalarEpoch),
              (minimumWireEpoch...maximumWireEpoch).contains(nestedEpoch) else {
            return false
        }
        return abs(scalarEpoch - nestedEpoch) <= storedClockAgreementTolerance
    }

    public private(set) var createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var accessedAt: Date
    public private(set) var validFrom: Date?
    public private(set) var validUntil: Date?
    public private(set) var lastConfirmedAt: Date?
    public private(set) var seasonalWindow: SeasonalMemoryWindow?
    public private(set) var accessCount: Int64
    public private(set) var reinforcementCount: Int64
    public private(set) var decayRate: MemoryDecayRate
    public private(set) var baseSalience: Double
    public private(set) var pinned: Bool
    public private(set) var status: MemoryLifecycleStatus
    public private(set) var retiredAt: Date?
    public private(set) var retiredReason: String?
    public private(set) var supersededBy: String?
    public private(set) var supersedes: String?

    public init(createdAt: Date, updatedAt: Date? = nil, accessedAt: Date? = nil,
                validFrom: Date? = nil, validUntil: Date? = nil,
                lastConfirmedAt: Date? = nil,
                seasonalWindow: SeasonalMemoryWindow? = nil,
                accessCount: Int64 = 0, reinforcementCount: Int64 = 0,
                decayRate: MemoryDecayRate = .medium, baseSalience: Double = 0.8,
                pinned: Bool = false, status: MemoryLifecycleStatus = .active,
                retiredAt: Date? = nil, retiredReason: String? = nil,
                supersededBy: String? = nil, supersedes: String? = nil) throws {
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.accessedAt = accessedAt ?? createdAt
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.lastConfirmedAt = lastConfirmedAt
        self.seasonalWindow = seasonalWindow
        self.accessCount = accessCount
        self.reinforcementCount = reinforcementCount
        self.decayRate = decayRate
        self.baseSalience = baseSalience
        self.pinned = pinned
        self.status = status
        self.retiredAt = retiredAt
        self.retiredReason = retiredReason
        self.supersededBy = supersededBy
        self.supersedes = supersedes
        try validate()
    }

    public mutating func touch(at instant: Date) throws {
        guard Self.isWireRepresentable(instant) else {
            throw TemporalMemoryError.invalidField("accessed_at")
        }
        guard instant >= createdAt, instant >= accessedAt else {
            throw TemporalMemoryError.invalidField("accessed_at")
        }
        guard accessCount < Self.maximumCounter else {
            throw TemporalMemoryError.counterOverflow("access_count")
        }
        accessedAt = instant
        accessCount += 1
    }

    /// Record a storage revision without claiming that the underlying fact became newer or truer.
    /// This is the bitemporal transaction clock: ordinary upserts may advance it, but they must not
    /// move the evidence/decay anchor, access clock, lifecycle, or explicit recurrence.
    public mutating func recordTransaction(at instant: Date) throws {
        guard Self.isWireRepresentable(instant), instant >= updatedAt else {
            throw TemporalMemoryError.invalidField("updated_at")
        }
        updatedAt = instant
    }

    /// Refresh evidence only after an explicit verified confirmation. This is deliberately separate from
    /// `touch`: reading or using a memory must never reinforce its truth.
    public mutating func reinforce(verified: Bool = false,
                                   confirmedAt: Date? = nil,
                                   now: Date) throws {
        guard verified else { throw TemporalMemoryError.unverifiedReinforcement }
        guard status == .active, retiredAt == nil, supersededBy == nil else {
            throw TemporalMemoryError.inactiveReinforcement
        }
        let confirmation = confirmedAt ?? now
        guard Self.isWireRepresentable(now),
              Self.isWireRepresentable(confirmation) else {
            throw TemporalMemoryError.invalidField("confirmation_time")
        }
        guard now >= updatedAt else {
            throw TemporalMemoryError.invalidField("updated_at")
        }
        guard confirmation.timeIntervalSince(now) <= Self.maximumFutureEvidenceSkew else {
            throw TemporalMemoryError.futureConfirmation
        }
        guard reinforcementCount < Self.maximumCounter else {
            throw TemporalMemoryError.counterOverflow("reinforcement_count")
        }
        if let existing = lastConfirmedAt {
            lastConfirmedAt = max(existing, confirmation)
        } else {
            lastConfirmedAt = confirmation
        }
        updatedAt = now
        reinforcementCount += 1
    }

    public mutating func retire(reason: String = "manual", now: Date) throws {
        let cleanReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == .active, retiredAt == nil, supersededBy == nil,
              Self.isValidLifecycleText(cleanReason) else {
            throw TemporalMemoryError.invalidField("retired_reason")
        }
        guard Self.isWireRepresentable(now) else {
            throw TemporalMemoryError.invalidField("retired_at")
        }
        guard now >= updatedAt else {
            throw TemporalMemoryError.invalidField("updated_at")
        }
        status = .retired
        retiredAt = now
        retiredReason = cleanReason
        updatedAt = now
    }

    public mutating func markSuperseded(by recordID: String, now: Date) throws {
        let cleanID = recordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard status == .active, retiredAt == nil, supersededBy == nil,
              Self.isValidLifecycleText(cleanID), Self.isWireRepresentable(now) else {
            throw TemporalMemoryError.invalidField("superseded_by")
        }
        guard now >= updatedAt else {
            throw TemporalMemoryError.invalidField("updated_at")
        }
        status = .superseded
        supersededBy = cleanID
        retiredAt = now
        retiredReason = "superseded by \(cleanID)"
        updatedAt = now
    }

    public func evaluate(at now: Date) -> TemporalMemoryEvaluation {
        guard Self.isWireRepresentable(now), (try? validated()) != nil else {
            return TemporalMemoryEvaluation(state: .invalid, salience: 0,
                                            decayAnchor: nil, inSeason: nil)
        }
        if status == .superseded || supersededBy != nil {
            return ineligible(.superseded, at: now)
        }
        if status == .retired || retiredAt != nil {
            return ineligible(.retired, at: now)
        }
        if createdAt.timeIntervalSince(now) > Self.maximumFutureEvidenceSkew {
            return ineligible(.futureCreated, at: now)
        }
        if updatedAt.timeIntervalSince(now) > Self.maximumFutureEvidenceSkew {
            return ineligible(.futureTransaction, at: now)
        }
        if accessedAt.timeIntervalSince(now) > Self.maximumFutureEvidenceSkew {
            return ineligible(.futureAccess, at: now)
        }
        if let lastConfirmedAt,
           lastConfirmedAt.timeIntervalSince(now) > Self.maximumFutureEvidenceSkew {
            return ineligible(.futureConfirmation, at: now)
        }
        if let validFrom, now < validFrom { return ineligible(.notYetValid, at: now) }
        if let validUntil, now >= validUntil { return ineligible(.validityExpired, at: now) }

        let anchor = lastConfirmedAt ?? createdAt
        var salience: Double
        if pinned {
            salience = 1
        } else {
            let elapsedDays = max(0, now.timeIntervalSince(anchor) / 86_400)
            let decayFactor = pow(0.5, elapsedDays / decayRate.halfLifeDays)
            var adjustedDecay = decayFactor
            if reinforcementCount > 0 {
                let boost = 1 + 0.05 * log(1 + Double(reinforcementCount))
                adjustedDecay = min(1, adjustedDecay * boost)
            }
            salience = baseSalience * adjustedDecay
        }

        let inSeason = seasonalWindow.map { $0.isInSeason(at: now) }
        if let seasonalWindow { salience *= seasonalWindow.multiplier(at: now) }
        return TemporalMemoryEvaluation(state: .eligible,
                                        salience: min(1, max(0, salience)),
                                        decayAnchor: anchor, inSeason: inSeason)
    }

    private func ineligible(_ state: TemporalMemoryState,
                            at now: Date) -> TemporalMemoryEvaluation {
        TemporalMemoryEvaluation(state: state, salience: 0,
                                 decayAnchor: lastConfirmedAt ?? createdAt,
                                 inSeason: seasonalWindow.map { $0.isInSeason(at: now) })
    }

    private func validated() throws -> MemoryTemporalEnvelope {
        try validate()
        return self
    }

    private func validate() throws {
        let dates = [createdAt, updatedAt, accessedAt, validFrom, validUntil,
                     lastConfirmedAt, retiredAt].compactMap { $0 }
        guard dates.allSatisfy(Self.isWireRepresentable) else {
            throw TemporalMemoryError.invalidField("timestamp")
        }
        guard updatedAt >= createdAt else {
            throw TemporalMemoryError.invalidField("updated_at")
        }
        guard accessedAt >= createdAt else {
            throw TemporalMemoryError.invalidField("accessed_at")
        }
        if let validFrom, let validUntil, validUntil <= validFrom {
            throw TemporalMemoryError.invalidField("valid_until")
        }
        guard (0...Self.maximumCounter).contains(accessCount) else {
            throw TemporalMemoryError.invalidField("access_count")
        }
        guard (0...Self.maximumCounter).contains(reinforcementCount) else {
            throw TemporalMemoryError.invalidField("reinforcement_count")
        }
        guard baseSalience.isFinite, (0...1).contains(baseSalience) else {
            throw TemporalMemoryError.invalidField("base_salience")
        }
        if let supersedes, !Self.isValidLifecycleText(supersedes) {
            throw TemporalMemoryError.invalidField("supersedes")
        }
        switch status {
        case .active:
            guard retiredAt == nil, retiredReason == nil, supersededBy == nil else {
                throw TemporalMemoryError.invalidField("lifecycle")
            }
        case .retired:
            guard let retiredAt, createdAt <= retiredAt, retiredAt <= updatedAt,
                  let retiredReason, Self.isValidLifecycleText(retiredReason),
                  supersededBy == nil else {
                throw TemporalMemoryError.invalidField("lifecycle")
            }
        case .superseded:
            guard let retiredAt, createdAt <= retiredAt, retiredAt <= updatedAt,
                  let retiredReason, Self.isValidLifecycleText(retiredReason),
                  let supersededBy, Self.isValidLifecycleText(supersededBy) else {
                throw TemporalMemoryError.invalidField("lifecycle")
            }
        }
    }

    private static func isValidLifecycleText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumLifecycleTextBytes
            && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
    }

    private static func isWireRepresentable(_ date: Date) -> Bool {
        let epoch = date.timeIntervalSince1970
        return epoch.isFinite && (minimumWireEpoch...maximumWireEpoch).contains(epoch)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case createdAt = "created_at", createdAtCamel = "createdAt"
        case updatedAt = "updated_at", updatedAtCamel = "updatedAt"
        case accessedAt = "accessed_at", accessedAtCamel = "accessedAt"
        case validFrom = "valid_from", validFromCamel = "validFrom"
        case validUntil = "valid_until", validUntilCamel = "validUntil"
        case lastConfirmedAt = "last_confirmed_at", lastConfirmedAtCamel = "lastConfirmedAt"
        case seasonalWindow = "seasonal_window", seasonalWindowCamel = "seasonalWindow"
        case accessCount = "access_count", accessCountCamel = "accessCount"
        case reinforcementCount = "reinforcement_count", reinforcementCountCamel = "reinforcementCount"
        case decayRate = "decay_rate", decayRateCamel = "decayRate"
        case baseSalience = "base_salience", baseSalienceCamel = "baseSalience"
        case pinned, status
        case retiredAt = "retired_at", retiredAtCamel = "retiredAt"
        case retiredReason = "retired_reason", retiredReasonCamel = "retiredReason"
        case supersededBy = "superseded_by", supersededByCamel = "supersededBy"
        case supersedes
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: TemporalAnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = raw.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else { throw TemporalMemoryError.unknownFields(unknown) }

        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let created = try Self.decodeDateAlias(
            from: values, keys: [.createdAt, .createdAtCamel]) else {
            throw TemporalMemoryError.invalidField("created_at")
        }
        let updated = try Self.decodeDateAlias(from: values, keys: [.updatedAt, .updatedAtCamel])
        let accessed = try Self.decodeDateAlias(from: values, keys: [.accessedAt, .accessedAtCamel])
        let validFrom = try Self.decodeDateAlias(from: values, keys: [.validFrom, .validFromCamel])
        let validUntil = try Self.decodeDateAlias(from: values, keys: [.validUntil, .validUntilCamel])
        let confirmed = try Self.decodeDateAlias(
            from: values, keys: [.lastConfirmedAt, .lastConfirmedAtCamel])
        let season = try Self.decodeAlias(
            SeasonalMemoryWindow.self, from: values,
            keys: [.seasonalWindow, .seasonalWindowCamel])
        let accesses = try Self.decodeAlias(
            Int64.self, from: values, keys: [.accessCount, .accessCountCamel]) ?? 0
        let reinforcements = try Self.decodeAlias(
            Int64.self, from: values,
            keys: [.reinforcementCount, .reinforcementCountCamel]) ?? 0
        let decay = try Self.decodeAlias(
            MemoryDecayRate.self, from: values, keys: [.decayRate, .decayRateCamel]) ?? .medium
        let salience = try Self.decodeAlias(
            Double.self, from: values, keys: [.baseSalience, .baseSalienceCamel]) ?? 0.8
        let retiredAt = try Self.decodeDateAlias(from: values, keys: [.retiredAt, .retiredAtCamel])
        let retiredReason = try Self.decodeAlias(
            String.self, from: values, keys: [.retiredReason, .retiredReasonCamel])
        let supersededBy = try Self.decodeAlias(
            String.self, from: values, keys: [.supersededBy, .supersededByCamel])
        try self.init(
            createdAt: created, updatedAt: updated, accessedAt: accessed,
            validFrom: validFrom, validUntil: validUntil,
            lastConfirmedAt: confirmed, seasonalWindow: season,
            accessCount: accesses, reinforcementCount: reinforcements,
            decayRate: decay, baseSalience: salience,
            pinned: try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false,
            status: try values.decodeIfPresent(MemoryLifecycleStatus.self, forKey: .status) ?? .active,
            retiredAt: retiredAt, retiredReason: retiredReason,
            supersededBy: supersededBy,
            supersedes: try values.decodeIfPresent(String.self, forKey: .supersedes))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try Self.encodeDate(createdAt, to: &values, key: .createdAt)
        try Self.encodeDate(updatedAt, to: &values, key: .updatedAt)
        try Self.encodeDate(accessedAt, to: &values, key: .accessedAt)
        try Self.encodeDateIfPresent(validFrom, to: &values, key: .validFrom)
        try Self.encodeDateIfPresent(validUntil, to: &values, key: .validUntil)
        try Self.encodeDateIfPresent(lastConfirmedAt, to: &values, key: .lastConfirmedAt)
        try values.encodeIfPresent(seasonalWindow, forKey: .seasonalWindow)
        try values.encode(accessCount, forKey: .accessCount)
        try values.encode(reinforcementCount, forKey: .reinforcementCount)
        try values.encode(decayRate, forKey: .decayRate)
        try values.encode(baseSalience, forKey: .baseSalience)
        try values.encode(pinned, forKey: .pinned)
        try values.encode(status, forKey: .status)
        try Self.encodeDateIfPresent(retiredAt, to: &values, key: .retiredAt)
        try values.encodeIfPresent(retiredReason, forKey: .retiredReason)
        try values.encodeIfPresent(supersededBy, forKey: .supersededBy)
        try values.encodeIfPresent(supersedes, forKey: .supersedes)
    }

    private static func decodeAlias<T: Decodable>(
        _ type: T.Type,
        from values: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> T? {
        let present = keys.filter { values.contains($0) }
        guard present.count <= 1 else {
            throw TemporalMemoryError.duplicateAliases(present.map(\.rawValue))
        }
        guard let key = present.first else { return nil }
        return try values.decodeIfPresent(type, forKey: key)
    }

    private static func decodeDateAlias(
        from values: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> Date? {
        let present = keys.filter { values.contains($0) }
        guard present.count <= 1 else {
            throw TemporalMemoryError.duplicateAliases(present.map(\.rawValue))
        }
        guard let key = present.first else { return nil }
        guard try !values.decodeNil(forKey: key) else { return nil }
        return try values.decode(TemporalWireDate.self, forKey: key).value
    }

    private static func encodeDate(
        _ date: Date,
        to values: inout KeyedEncodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws {
        try values.encode(TemporalWireDate.string(from: date), forKey: key)
    }

    private static func encodeDateIfPresent(
        _ date: Date?,
        to values: inout KeyedEncodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws {
        if let date { try encodeDate(date, to: &values, key: key) }
    }
}

private struct TemporalWireDate: Decodable {
    let value: Date

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let seconds = try? value.decode(Double.self) {
            guard seconds.isFinite else {
                throw TemporalMemoryError.invalidField("timestamp")
            }
            self.value = Date(timeIntervalSince1970: seconds)
            return
        }
        let raw = try value.decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ordinary = ISO8601DateFormatter()
        ordinary.formatOptions = [.withInternetDateTime]
        guard let parsed = fractional.date(from: raw) ?? ordinary.date(from: raw),
              parsed.timeIntervalSince1970.isFinite else {
            throw TemporalMemoryError.invalidField("timestamp")
        }
        self.value = parsed
    }

    static func string(from date: Date) throws -> String {
        guard date.timeIntervalSince1970.isFinite else {
            throw TemporalMemoryError.invalidField("timestamp")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
