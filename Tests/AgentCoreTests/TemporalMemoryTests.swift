import XCTest
@testable import AgentCore

final class TemporalMemoryTests: XCTestCase {
    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    func testSnakeCamelDecodeAndCanonicalEncodingAvoidFoundationDateEpoch() throws {
        let camel = #"""
        {
          "createdAt":0,
          "updatedAt":"1970-01-01T00:00:01Z",
          "validFrom":"2025-02-01T00:00:00Z",
          "validUntil":"2025-03-01T00:00:00Z",
          "seasonalWindow":{
            "months":[1,2,12],"weekdays":[],"startHour":22,"endHour":2,
            "timeZone":"America/New_York","inSeasonBoost":1.5,"offSeasonFactor":0.2
          }
        }
        """#.data(using: .utf8)!
        let value = try JSONDecoder().decode(MemoryTemporalEnvelope.self, from: camel)
        XCTAssertEqual(value.createdAt, Date(timeIntervalSince1970: 0))
        XCTAssertNil(value.lastConfirmedAt, "backward decoding must not invent confirmation")
        XCTAssertEqual(value.seasonalWindow?.months, [1, 2, 12])

        let encoded = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["created_at"])
        XCTAssertNil(object["createdAt"])
        XCTAssertTrue((object["created_at"] as? String)?.hasPrefix("1970-01-01T00:00:00") == true,
                      "wire time is Unix/ISO-8601, never synthesized Date's 2001 reference epoch")
        let season = try XCTUnwrap(object["seasonal_window"] as? [String: Any])
        XCTAssertEqual(season["start_hour"] as? Int, 22)
        XCTAssertNil(season["startHour"])

        let legacy = try JSONDecoder().decode(
            MemoryTemporalEnvelope.self,
            from: #"{"created_at":"2025-01-01T00:00:00Z"}"#.data(using: .utf8)!)
        XCTAssertNil(legacy.validFrom)
        XCTAssertNil(legacy.validUntil)
        XCTAssertNil(legacy.lastConfirmedAt)
        XCTAssertNil(legacy.seasonalWindow)
    }

    func testDuplicateTemporalAndSeasonAliasesAreRejected() {
        let duplicateTime = #"{"created_at":0,"createdAt":0}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(
            MemoryTemporalEnvelope.self, from: duplicateTime))
        let duplicateSeason = #"{"months":[1],"start_hour":1,"startHour":1,"end_hour":2}"#
            .data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(
            SeasonalMemoryWindow.self, from: duplicateSeason))
        let nullCollision = #"{"created_at":null,"createdAt":0}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(
            MemoryTemporalEnvelope.self, from: nullCollision))
        let unknownEnvelope = #"{"created_at":0,"last_confrimed_at":0}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(
            MemoryTemporalEnvelope.self, from: unknownEnvelope))
        let unknownSeason = #"{"months":[1],"moon_phase":"full"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(
            SeasonalMemoryWindow.self, from: unknownSeason))
    }

    func testValidityIsStartInclusiveEndExclusiveAndPinCannotOverrideIt() throws {
        let start = date("2025-01-10T12:00:00Z")
        let end = date("2025-01-11T12:00:00Z")
        let value = try MemoryTemporalEnvelope(
            createdAt: start.addingTimeInterval(-1), validFrom: start,
            validUntil: end, decayRate: .session, baseSalience: 0.2, pinned: true)

        XCTAssertEqual(value.evaluate(at: start.addingTimeInterval(-0.001)).state, .notYetValid)
        XCTAssertEqual(value.evaluate(at: start).state, .eligible)
        XCTAssertEqual(value.evaluate(at: start).salience, 1)
        XCTAssertEqual(value.evaluate(at: end).state, .validityExpired)
        XCTAssertEqual(value.evaluate(at: end).salience, 0,
                       "pinning never resurrects an application-time-ineligible claim")
    }

    func testFutureEvidenceSkewIsSeparateFromFutureValidTime() throws {
        let now = date("2025-01-01T00:00:00Z")
        let atLimit = try MemoryTemporalEnvelope(
            createdAt: now.addingTimeInterval(300), baseSalience: 1)
        XCTAssertEqual(atLimit.evaluate(at: now).state, .eligible)

        let futureCreated = try MemoryTemporalEnvelope(
            createdAt: now.addingTimeInterval(301), pinned: true)
        XCTAssertEqual(futureCreated.evaluate(at: now).state, .futureCreated)

        let futureConfirmation = try MemoryTemporalEnvelope(
            createdAt: now, lastConfirmedAt: now.addingTimeInterval(301), pinned: true)
        XCTAssertEqual(futureConfirmation.evaluate(at: now).state, .futureConfirmation)

        let futureTransaction = try MemoryTemporalEnvelope(
            createdAt: now, updatedAt: now.addingTimeInterval(301), pinned: true)
        XCTAssertEqual(futureTransaction.evaluate(at: now).state, .futureTransaction)

        let futureAccess = try MemoryTemporalEnvelope(
            createdAt: now, accessedAt: now.addingTimeInterval(301), pinned: true)
        XCTAssertEqual(futureAccess.evaluate(at: now).state, .futureAccess)

        let futureClaim = try MemoryTemporalEnvelope(
            createdAt: now, validFrom: now.addingTimeInterval(86_400 * 30), pinned: true)
        XCTAssertEqual(futureClaim.evaluate(at: now).state, .notYetValid,
                       "future valid-time is legitimate, not corrupt evidence time")
    }

    func testLifecycleExclusionPrecedesPin() throws {
        let now = date("2025-01-01T00:00:00Z")
        var retired = try MemoryTemporalEnvelope(createdAt: now, pinned: true)
        try retired.retire(reason: "obsolete", now: now)
        XCTAssertEqual(retired.evaluate(at: now).state, .retired)
        XCTAssertEqual(retired.evaluate(at: now).salience, 0)

        var superseded = try MemoryTemporalEnvelope(createdAt: now, pinned: true)
        try superseded.markSuperseded(by: "replacement", now: now)
        XCTAssertEqual(superseded.evaluate(at: now).state, .superseded)
        XCTAssertEqual(superseded.evaluate(at: now).salience, 0)
        XCTAssertEqual(superseded.retiredAt, now)
        XCTAssertEqual(superseded.retiredReason, "superseded by replacement")

        let futureSeason = try SeasonalMemoryWindow(months: [1], timeZoneIdentifier: "UTC")
        let expiredInSeason = try MemoryTemporalEnvelope(
            createdAt: now, validUntil: now.addingTimeInterval(1),
            seasonalWindow: futureSeason)
        let expiredEvaluation = expiredInSeason.evaluate(at: now.addingTimeInterval(2))
        XCTAssertEqual(expiredEvaluation.state, .validityExpired)
        XCTAssertEqual(expiredEvaluation.inSeason, true,
                       "lifecycle/valid-time exclusion does not falsify recurrence state")
    }

    func testLifecycleTransactionTimeCannotMoveBackward() throws {
        let created = date("2025-01-01T00:00:00Z")
        let updated = created.addingTimeInterval(60)
        var retiring = try MemoryTemporalEnvelope(createdAt: created, updatedAt: updated)
        XCTAssertThrowsError(try retiring.retire(now: created)) { error in
            XCTAssertEqual(error as? TemporalMemoryError, .invalidField("updated_at"))
        }
        XCTAssertEqual(retiring.status, .active)
        XCTAssertEqual(retiring.updatedAt, updated)

        var superseding = try MemoryTemporalEnvelope(createdAt: created, updatedAt: updated)
        XCTAssertThrowsError(try superseding.markSuperseded(by: "new", now: created)) { error in
            XCTAssertEqual(error as? TemporalMemoryError, .invalidField("updated_at"))
        }
        XCTAssertEqual(superseding.status, .active)
        XCTAssertNil(superseding.supersededBy)

        XCTAssertThrowsError(try MemoryTemporalEnvelope(
            createdAt: updated, updatedAt: created)) { error in
                XCTAssertEqual(error as? TemporalMemoryError,
                               .invalidField("updated_at"))
        }
        XCTAssertThrowsError(try MemoryTemporalEnvelope(
            createdAt: updated, accessedAt: created)) { error in
                XCTAssertEqual(error as? TemporalMemoryError,
                               .invalidField("accessed_at"))
        }
    }

    func testLifecycleFieldsAreCoherentAndBounded() throws {
        let created = date("2025-01-01T00:00:00Z")
        let lifecycleAt = created.addingTimeInterval(60)

        XCTAssertThrowsError(try MemoryTemporalEnvelope(
            createdAt: created, status: .active,
            retiredAt: lifecycleAt, retiredReason: "hidden retirement"))
        XCTAssertThrowsError(try MemoryTemporalEnvelope(
            createdAt: created, updatedAt: lifecycleAt, status: .retired,
            retiredAt: lifecycleAt))
        XCTAssertThrowsError(try MemoryTemporalEnvelope(
            createdAt: created, updatedAt: created, status: .retired,
            retiredAt: lifecycleAt, retiredReason: "future retirement"))
        XCTAssertThrowsError(try MemoryTemporalEnvelope(
            createdAt: created, updatedAt: lifecycleAt, status: .superseded,
            retiredAt: lifecycleAt, supersededBy: "replacement"))

        let retired = try MemoryTemporalEnvelope(
            createdAt: created, updatedAt: lifecycleAt, status: .retired,
            retiredAt: lifecycleAt, retiredReason: "obsolete")
        XCTAssertEqual(retired.evaluate(at: lifecycleAt).state, .retired)

        var terminal = retired
        XCTAssertThrowsError(try terminal.retire(
            reason: "second retirement", now: lifecycleAt.addingTimeInterval(1)))
        XCTAssertThrowsError(try terminal.markSuperseded(
            by: "replacement", now: lifecycleAt.addingTimeInterval(1)))
        XCTAssertEqual(terminal.status, .retired)

        var active = try MemoryTemporalEnvelope(createdAt: created)
        XCTAssertThrowsError(try active.retire(
            reason: String(repeating: "x", count: 513), now: lifecycleAt))
        XCTAssertEqual(active.status, .active)
        XCTAssertThrowsError(try active.markSuperseded(
            by: "replacement\nforged", now: lifecycleAt))
        XCTAssertEqual(active.status, .active)
    }

    func testDecayAnchorsOnConfirmationThenFallsBackToCreated() throws {
        let now = date("2025-04-01T00:00:00Z")
        let created = now.addingTimeInterval(-60 * 86_400)
        let confirmed = now.addingTimeInterval(-30 * 86_400)
        let unconfirmed = try MemoryTemporalEnvelope(
            createdAt: created, decayRate: .fast, baseSalience: 1)
        let reinforced = try MemoryTemporalEnvelope(
            createdAt: created, lastConfirmedAt: confirmed,
            decayRate: .fast, baseSalience: 1)

        XCTAssertEqual(unconfirmed.evaluate(at: now).salience, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(reinforced.evaluate(at: now).salience, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(reinforced.evaluate(at: now).decayAnchor, confirmed)
    }

    func testTouchNeverReinforcesTruthButVerifiedReinforcementDoes() throws {
        let created = date("2025-01-01T00:00:00Z")
        let now = date("2025-01-11T00:00:00Z")
        var value = try MemoryTemporalEnvelope(
            createdAt: created, decayRate: .session, baseSalience: 1)
        let originalTransactionTime = value.updatedAt
        let before = value.evaluate(at: now).salience
        try value.touch(at: now)
        XCTAssertEqual(value.accessCount, 1)
        XCTAssertEqual(value.updatedAt, originalTransactionTime,
                       "read telemetry must not make an old claim the latest transaction revision")
        XCTAssertNil(value.lastConfirmedAt)
        XCTAssertEqual(value.reinforcementCount, 0)
        XCTAssertEqual(value.evaluate(at: now).salience, before, accuracy: 0.000_000_1)
        XCTAssertThrowsError(try value.touch(at: created)) { error in
            XCTAssertEqual(error as? TemporalMemoryError,
                           .invalidField("accessed_at"))
        }

        XCTAssertThrowsError(try value.reinforce(confirmedAt: now, now: now)) { error in
            XCTAssertEqual(error as? TemporalMemoryError, .unverifiedReinforcement)
        }
        try value.reinforce(verified: true, confirmedAt: now, now: now)
        XCTAssertEqual(value.lastConfirmedAt, now)
        XCTAssertEqual(value.reinforcementCount, 1)
        XCTAssertEqual(value.evaluate(at: now).salience, 1, accuracy: 0.000_001)
    }

    func testReinforcementRejectsFutureInactiveAndCounterOverflow() throws {
        let now = date("2025-01-01T00:00:00Z")
        var value = try MemoryTemporalEnvelope(createdAt: now)
        XCTAssertThrowsError(try value.reinforce(
            verified: true, confirmedAt: now.addingTimeInterval(301), now: now)) { error in
                XCTAssertEqual(error as? TemporalMemoryError, .futureConfirmation)
        }

        var retired = value
        try retired.retire(now: now)
        XCTAssertThrowsError(try retired.reinforce(verified: true, now: now)) { error in
            XCTAssertEqual(error as? TemporalMemoryError, .inactiveReinforcement)
        }

        var saturated = try MemoryTemporalEnvelope(
            createdAt: now, reinforcementCount: Int64.max)
        XCTAssertThrowsError(try saturated.reinforce(verified: true, now: now)) { error in
            XCTAssertEqual(error as? TemporalMemoryError,
                           .counterOverflow("reinforcement_count"))
        }
        var accessSaturated = try MemoryTemporalEnvelope(
            createdAt: now, accessCount: Int64.max)
        XCTAssertThrowsError(try accessSaturated.touch(at: now)) { error in
            XCTAssertEqual(error as? TemporalMemoryError,
                           .counterOverflow("access_count"))
        }

        let later = now.addingTimeInterval(60)
        var monotonic = try MemoryTemporalEnvelope(
            createdAt: now, lastConfirmedAt: later)
        try monotonic.reinforce(verified: true, confirmedAt: now, now: later)
        XCTAssertEqual(monotonic.lastConfirmedAt, later,
                       "older evidence cannot replace the latest confirmation clock")
    }

    func testMonthYearWrapAndLeapDay() throws {
        let winter = try SeasonalMemoryWindow(
            months: [11, 12, 1, 2], timeZoneIdentifier: "UTC")
        XCTAssertTrue(winter.isInSeason(at: date("2024-02-29T12:00:00Z")))
        XCTAssertTrue(winter.isInSeason(at: date("2025-12-31T23:59:59Z")))
        XCTAssertTrue(winter.isInSeason(at: date("2026-01-01T00:00:00Z")))
        XCTAssertFalse(winter.isInSeason(at: date("2025-03-01T00:00:00Z")))
    }

    func testWeeklyWrapMidnightUsesPreviousLocalCalendarDay() throws {
        let mondayNight = try SeasonalMemoryWindow(
            weekdays: [0], startHour: 22, endHour: 2, timeZoneIdentifier: "UTC")
        XCTAssertTrue(mondayNight.isInSeason(at: date("2025-01-06T22:00:00Z")))
        XCTAssertTrue(mondayNight.isInSeason(at: date("2025-01-07T01:59:59Z")),
                      "Tuesday after midnight belongs to Monday's recurrence")
        XCTAssertFalse(mondayNight.isInSeason(at: date("2025-01-07T02:00:00Z")))
        XCTAssertFalse(mondayNight.isInSeason(at: date("2025-01-07T22:30:00Z")))
    }

    func testNamedTimezoneAndDSTTransitions() throws {
        let oneToThree = try SeasonalMemoryWindow(
            startHour: 1, endHour: 3, timeZoneIdentifier: "America/New_York")
        XCTAssertTrue(oneToThree.isInSeason(at: date("2025-03-09T06:30:00Z"))) // 01:30 EST
        XCTAssertFalse(oneToThree.isInSeason(at: date("2025-03-09T07:00:00Z"))) // 03:00 EDT

        let repeatedOne = try SeasonalMemoryWindow(
            startHour: 1, endHour: 2, timeZoneIdentifier: "America/New_York")
        XCTAssertTrue(repeatedOne.isInSeason(at: date("2025-11-02T05:30:00Z"))) // first 01:30
        XCTAssertTrue(repeatedOne.isInSeason(at: date("2025-11-02T06:30:00Z"))) // second 01:30

        let localDecember = try SeasonalMemoryWindow(
            months: [12], timeZoneIdentifier: "America/New_York")
        XCTAssertTrue(localDecember.isInSeason(at: date("2026-01-01T01:00:00Z")),
                      "calendar selectors are evaluated in the explicit local timezone")
    }

    func testOffSeasonDownrankAndLaterReactivation() throws {
        let created = date("2025-01-01T00:00:00Z")
        let season = try SeasonalMemoryWindow(
            months: [12], timeZoneIdentifier: "UTC",
            inSeasonBoost: 1.5, offSeasonFactor: 0.2)
        let seasonal = try MemoryTemporalEnvelope(
            createdAt: created, seasonalWindow: season,
            decayRate: .none, baseSalience: 0.6)
        let ordinary = try MemoryTemporalEnvelope(
            createdAt: created, decayRate: .none, baseSalience: 0.5)

        let december = date("2025-12-10T00:00:00Z")
        let july = date("2025-07-10T00:00:00Z")
        let nextDecember = date("2026-12-10T00:00:00Z")
        XCTAssertGreaterThan(seasonal.evaluate(at: december).salience,
                             ordinary.evaluate(at: december).salience)
        XCTAssertLessThan(seasonal.evaluate(at: july).salience,
                          ordinary.evaluate(at: july).salience)
        XCTAssertGreaterThan(seasonal.evaluate(at: nextDecember).salience,
                             ordinary.evaluate(at: nextDecember).salience)

        let pinned = try MemoryTemporalEnvelope(
            createdAt: created, seasonalWindow: season,
            decayRate: .session, baseSalience: 0.1, pinned: true)
        XCTAssertEqual(pinned.evaluate(at: july).salience, 0.2, accuracy: 0.000_001,
                       "pin skips age decay but still obeys an explicit off-season factor")
    }

    func testStoredScalarClockAgreementHasOneMillisecondWireBound() {
        let event = Date(timeIntervalSince1970: 1_900_000_000)
        XCTAssertTrue(MemoryTemporalEnvelope.storedClockAgrees(
            event.timeIntervalSince1970 + 0.000_999, with: event))
        XCTAssertFalse(MemoryTemporalEnvelope.storedClockAgrees(
            event.timeIntervalSince1970 + 0.001_001, with: event))
        XCTAssertFalse(MemoryTemporalEnvelope.storedClockAgrees(.nan, with: event))
        XCTAssertFalse(MemoryTemporalEnvelope.storedClockAgrees(
            MemoryTemporalEnvelope.maximumWireEpoch + 1, with: event))
    }

    func testSeasonValidationAndBounds() throws {
        XCTAssertNotNil(TimeZone(identifier: "UTC"))
        XCTAssertNoThrow(try SeasonalMemoryWindow(months: [1], timeZoneIdentifier: "UTC"))
        XCTAssertThrowsError(try SeasonalMemoryWindow())
        XCTAssertThrowsError(try SeasonalMemoryWindow(months: [1, 1]))
        XCTAssertThrowsError(try SeasonalMemoryWindow(weekdays: [7]))
        XCTAssertThrowsError(try SeasonalMemoryWindow(
            startHour: 2, endHour: nil, timeZoneIdentifier: "UTC"))
        XCTAssertThrowsError(try SeasonalMemoryWindow(
            startHour: 2, endHour: 2, timeZoneIdentifier: "UTC"))
        XCTAssertThrowsError(try SeasonalMemoryWindow(
            months: [1], timeZoneIdentifier: "Not/A_Real_Zone"))
        XCTAssertThrowsError(try SeasonalMemoryWindow(
            months: [1], timeZoneIdentifier: "UTC", inSeasonBoost: 2.000_1))
        XCTAssertThrowsError(try SeasonalMemoryWindow(
            months: [1], timeZoneIdentifier: "UTC", offSeasonFactor: -0.001))

        let fullDay = try SeasonalMemoryWindow(
            startHour: 0, endHour: 24, timeZoneIdentifier: "UTC")
        XCTAssertTrue(fullDay.isInSeason(at: date("2025-01-01T23:59:59Z")))

        XCTAssertThrowsError(try MemoryTemporalEnvelope(
            createdAt: Date(timeIntervalSince1970: .greatestFiniteMagnitude)))
        let outOfWireRange = #"{"created_at":253402300800}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(
            MemoryTemporalEnvelope.self, from: outOfWireRange))

        let ordinary = date("2025-01-01T00:00:00Z")
        let unencodable = Date(timeIntervalSince1970: .greatestFiniteMagnitude)
        var touched = try MemoryTemporalEnvelope(createdAt: ordinary)
        XCTAssertThrowsError(try touched.touch(at: unencodable))
        var reinforced = try MemoryTemporalEnvelope(createdAt: ordinary)
        XCTAssertThrowsError(try reinforced.reinforce(
            verified: true, confirmedAt: unencodable, now: ordinary))
        var retired = try MemoryTemporalEnvelope(createdAt: ordinary)
        XCTAssertThrowsError(try retired.retire(now: unencodable))
        var superseded = try MemoryTemporalEnvelope(createdAt: ordinary)
        XCTAssertThrowsError(try superseded.markSuperseded(by: "replacement", now: unencodable))
    }
}
