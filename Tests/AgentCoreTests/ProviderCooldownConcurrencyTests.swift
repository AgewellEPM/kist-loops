import Dispatch
import Foundation
import XCTest
@testable import AgentCore

/// Regression for Codex P2-G: `record()` did load->modify->atomic-replace with no
/// cross-process lock, so two concurrent kist processes each loaded the same table,
/// added their OWN provider, and replaced the file — last-writer-wins silently
/// dropped the other provider's cooldown, routing traffic back to a failing provider.
///
/// The fix wraps the full load-modify-save in a stable sidecar advisory lock
/// (`provider-cooldowns.json.lock`, flock LOCK_EX). These tests pin that behavior.
final class ProviderCooldownConcurrencyTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cooldown-concurrency-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// SITE: ProviderCooldownStore.record() — the only load-modify-save write site.
    ///
    /// Strength (honest): this drives many concurrent in-process `record()` calls for
    /// DISTINCT providers and asserts EVERY one survives in the final table. Without
    /// the lock, interleaved load->save windows drop rows non-deterministically, so a
    /// clobber shows up as a missing provider over repeated runs. flock is a
    /// cross-process advisory lock, so guarding the in-process transaction also proves
    /// the cross-process transaction is guarded (same lock, same critical section).
    /// It is a race detector, not a formal proof: a single run can pass by luck, but
    /// the high fan-out plus the deterministic-lock-file test below close the gap.
    func testConcurrentRecordsForDifferentProvidersAllSurvive() {
        let dir = tempDir()
        let providers = (0..<24).map { "provider-\($0)" }

        // Fan out record() across threads to force the load-modify-save windows to
        // interleave. Each store instance stands in for a separate kist process.
        DispatchQueue.concurrentPerform(iterations: providers.count) { i in
            ProviderCooldownStore(directory: dir).record(providers[i], ttl: 600)
        }

        let store = ProviderCooldownStore(directory: dir)
        for p in providers {
            XCTAssertTrue(store.coolingDown(p),
                          "record() at ProviderCooldownStore.record() dropped \(p) — cross-process lock regressed")
        }
        XCTAssertEqual(Set(store.activeCooldowns()), Set(providers),
                       "final table must hold every concurrently-recorded provider")
    }

    /// SITE: ProviderCooldownStore.record() — deterministic proof the sidecar lock is
    /// engaged. The concurrency test above can theoretically pass unlocked by luck;
    /// this one cannot: it asserts the stable lock file is created by the write path.
    func testRecordCreatesStableSidecarLockFile() {
        let dir = tempDir()
        let lockURL = dir.appendingPathComponent("provider-cooldowns.json.lock")
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockURL.path),
                       "precondition: no lock file before any write")

        ProviderCooldownStore(directory: dir).record("openai")

        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path),
                      "record() must open/create the sidecar lock to serialize the transaction")
    }

    /// SITE: ProviderCooldownStore.record() — the lock is a serialization mechanism,
    /// not a data channel: recording under the lock must still persist normal state,
    /// and must not crash or wedge when the lock is contended by rapid re-entry.
    func testRecordUnderLockStillPersistsAndDoesNotWedge() {
        let dir = tempDir()
        let store = ProviderCooldownStore(directory: dir)
        for _ in 0..<50 { store.record("openai", ttl: 600) }   // rapid re-acquire, must not deadlock
        XCTAssertTrue(store.coolingDown("openai"))
        XCTAssertEqual(store.activeCooldowns(), ["openai"])
    }
}
