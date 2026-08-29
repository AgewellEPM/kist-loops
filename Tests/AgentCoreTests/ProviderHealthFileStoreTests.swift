import XCTest
@testable import AgentCore

/// The read-side of the daemon's provider-health snapshot. The whole point of the store is the
/// routing audit 2026-08-25 failure: the file said ollama was "down" and routing selected it
/// anyway — so these tests pin exactly when a provider is benched and when the store fails open.
final class ProviderHealthFileStoreTests: XCTestCase {
    private var dir: URL!
    private let t0 = Date(timeIntervalSince1970: 1_787_674_536)

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kist_health_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeHealth(_ rows: [String: (status: String, checkedAt: Double)]) throws {
        let providers = rows.map { id, row in
            "\"\(id)\": {\"status\": \"\(row.status)\", \"checkedAt\": \(row.checkedAt)}"
        }.joined(separator: ",")
        try Data("{\"providers\": {\(providers)}}".utf8)
            .write(to: dir.appendingPathComponent("provider-health.json"))
    }

    private func store(maxAge: TimeInterval = ProviderHealthFileStore.defaultMaxAge) -> ProviderHealthFileStore {
        ProviderHealthFileStore(directory: dir, maxAge: maxAge, now: { [t0] in t0 })
    }

    func testFreshDownVerdictBenchesProviderCaseInsensitively() throws {
        try writeHealth(["Ollama": ("down", t0.timeIntervalSince1970 - 60)])
        XCTAssertTrue(store().down("ollama"))
        XCTAssertTrue(store().down("OLLAMA"))
        XCTAssertEqual(store().downProviders(), ["ollama"])
    }

    func testDegradedAndUnknownAreNotDown() throws {
        // "degraded" = missing key (the registry's key checks own that), "unknown" = not evidence.
        try writeHealth(["anthropic": ("degraded", t0.timeIntervalSince1970 - 60),
                         "openai": ("unknown", t0.timeIntervalSince1970 - 60)])
        XCTAssertFalse(store().down("anthropic"))
        XCTAssertFalse(store().down("openai"))
    }

    func testStaleDownVerdictIsIgnored() throws {
        // The user may have restarted the provider since a dead daemon's last verdict.
        try writeHealth(["ollama": ("down", t0.timeIntervalSince1970 - 7_200)])
        XCTAssertFalse(store().down("ollama"), "a stale verdict must not bench a recovered provider")
    }

    func testMissingFileFailsOpen() {
        XCTAssertFalse(store().down("ollama"))
        XCTAssertTrue(store().downProviders().isEmpty)
    }

    func testMalformedFileFailsOpen() throws {
        try Data("not json{{{".utf8).write(to: dir.appendingPathComponent("provider-health.json"))
        XCTAssertFalse(store().down("ollama"))
    }

    func testRowWithoutStatusNeverBenches() throws {
        try Data("{\"providers\": {\"ollama\": {\"checkedAt\": \(t0.timeIntervalSince1970)}}}".utf8)
            .write(to: dir.appendingPathComponent("provider-health.json"))
        XCTAssertFalse(store().down("ollama"))
    }

    func testOllamaVerdictIgnoredWhenEndpointOverridden() throws {
        // Codex P2 (2026-08-25): the daemon probed ITS endpoint; with OLLAMA_HOST pointing this
        // process elsewhere, a localhost "down" verdict must not bench a healthy remote Ollama.
        try writeHealth(["ollama": ("down", t0.timeIntervalSince1970 - 60)])
        XCTAssertFalse(ProviderHealthFileStore.verdictAppliesToThisProcess(
            providerId: "ollama", environment: ["OLLAMA_HOST": "http://192.168.1.5:11434"]),
            "an overridden endpoint makes the daemon's verdict unverifiable — fail open")
        XCTAssertTrue(ProviderHealthFileStore.verdictAppliesToThisProcess(
            providerId: "ollama", environment: [:]),
            "no override ⇒ default endpoint on both sides ⇒ the verdict applies")
        XCTAssertTrue(ProviderHealthFileStore.verdictAppliesToThisProcess(
            providerId: "openai", environment: ["OLLAMA_HOST": "http://192.168.1.5:11434"]),
            "the override is ollama-specific; other providers' verdicts are unaffected")
        setenv("OLLAMA_HOST", "http://192.168.1.5:11434", 1)
        defer { unsetenv("OLLAMA_HOST") }
        XCTAssertFalse(store().down("ollama"),
                       "end-to-end: the fresh down verdict is skipped while the override is set")
    }

    func testHonorsKistHomeOverrideLikeTheProducingDaemon() throws {
        // Codex P2 (2026-08-25): the daemon writes $KIST_HOME/runtime/provider-health.json; a reader
        // pinned to ~/.kist would fail open and known-down providers would stay selectable.
        let home = dir.appendingPathComponent("alt-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("runtime"),
                                                withIntermediateDirectories: true)
        try Data("{\"providers\": {\"ollama\": {\"status\": \"down\", \"checkedAt\": \(t0.timeIntervalSince1970 - 60)}}}".utf8)
            .write(to: home.appendingPathComponent("runtime/provider-health.json"))
        setenv("KIST_HOME", home.path, 1)
        defer { unsetenv("KIST_HOME") }
        let envStore = ProviderHealthFileStore(now: { [t0] in t0 })
        XCTAssertTrue(envStore.down("ollama"),
                      "the reader must resolve the same $KIST_HOME root as the producing daemon")
    }
}
