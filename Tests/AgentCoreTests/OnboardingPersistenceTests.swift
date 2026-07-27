import XCTest
@testable import AgentCore

/// Persistence + secret-hygiene contracts for model onboarding.
final class OnboardingPersistenceTests: XCTestCase {
    private func tmp(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("kist-onboard-\(UUID().uuidString)-\(name)").path
    }

    // MARK: CustomProviderStore

    func testUpsertRoundTripsAndMakesProvider() throws {
        let path = tmp("providers.json")
        let rec = CustomProviderRecord(id: "together", name: "Together", keyAccount: "custom_together_api_key",
                                       endpoint: "https://api.together.xyz/v1/chat/completions",
                                       defaultModel: "llama-3-70b",
                                       availableModels: [AIModel(id: "llama-3-70b")])
        try CustomProviderStore.upsert(rec, path: path)
        let loaded = CustomProviderStore.load(path: path)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "together")
        XCTAssertEqual(loaded.first?.endpoint, "https://api.together.xyz/v1/chat/completions")
        XCTAssertEqual(loaded.first?.defaultModel, "llama-3-70b")
    }

    func testUpsertRejectsReservedBuiltinId() {
        let path = tmp("providers.json")
        let rec = CustomProviderRecord(id: "openai", name: "Imposter", keyAccount: "x",
                                       endpoint: "https://e/v1/chat/completions", defaultModel: "m",
                                       availableModels: [])
        XCTAssertThrowsError(try CustomProviderStore.upsert(rec, path: path)) { err in
            XCTAssertEqual(err as? CustomProviderStore.StoreError, .reservedId("openai"))
        }
        XCTAssertFalse(CustomProviderStore.isIdAvailable("openai"))
        XCTAssertFalse(CustomProviderStore.isIdAvailable("deepseek"))
    }

    func testReservedIdRejectionIsCaseInsensitive() {
        let path = tmp("providers.json")
        // 'OpenAI' must not slip past the reserved check and shadow built-in 'openai'.
        XCTAssertFalse(CustomProviderStore.isIdAvailable("OpenAI"))
        XCTAssertFalse(CustomProviderStore.isIdAvailable("DeepSeek"))
        let rec = CustomProviderRecord(id: "OpenAI", name: "x", keyAccount: "k",
                                       endpoint: "https://e/v1/chat/completions", defaultModel: "m", availableModels: [])
        XCTAssertThrowsError(try CustomProviderStore.upsert(rec, path: path)) { err in
            XCTAssertEqual(err as? CustomProviderStore.StoreError, .reservedId("openai"))
        }
    }

    func testUpsertReplacesByIdAndRemoveWorks() throws {
        let path = tmp("providers.json")
        let v1 = CustomProviderRecord(id: "fw", name: "FW1", keyAccount: "k", endpoint: "https://e/v1/chat/completions",
                                      defaultModel: "a", availableModels: [])
        let v2 = CustomProviderRecord(id: "fw", name: "FW2", keyAccount: "k", endpoint: "https://e/v1/chat/completions",
                                      defaultModel: "b", availableModels: [])
        try CustomProviderStore.upsert(v1, path: path)
        try CustomProviderStore.upsert(v2, path: path)
        XCTAssertEqual(CustomProviderStore.loadRecords(path: path).count, 1, "same id replaces, not duplicates")
        XCTAssertEqual(CustomProviderStore.loadRecords(path: path).first?.defaultModel, "b")
        XCTAssertTrue(CustomProviderStore.remove(id: "fw", path: path))
        XCTAssertEqual(CustomProviderStore.loadRecords(path: path).count, 0)
        XCTAssertFalse(CustomProviderStore.remove(id: "fw", path: path), "removing absent id is a no-op false")
    }

    func testCorruptFileIsFailSoftEmpty() throws {
        let path = tmp("providers.json")
        try "{ not valid json".data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(CustomProviderStore.load(path: path).count, 0)
    }

    // MARK: SecretWriter

    func testWriteEnforces0600AndReadsBack() throws {
        let path = tmp("keys.json")
        let account = "custom_probe_\(UInt32.random(in: 1...9_999_999))_api_key"
        try SecretWriter.write(account: account, key: "sk-secret-123", path: path)

        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "key file MUST be owner-only or FileKeyStore silently ignores it")
        // The very store kist reads keys from must see it back.
        XCTAssertEqual(FileKeyStore(path: path).key(forAccount: account), "sk-secret-123")
    }

    func testWriteMergesAndEmptyKeyRejected() throws {
        let path = tmp("keys.json")
        try SecretWriter.write(account: "acct_a", key: "AAA", path: path)
        try SecretWriter.write(account: "acct_b", key: "BBB", path: path)
        let store = FileKeyStore(path: path)
        XCTAssertEqual(store.key(forAccount: "acct_a"), "AAA")
        XCTAssertEqual(store.key(forAccount: "acct_b"), "BBB")
        XCTAssertThrowsError(try SecretWriter.write(account: "acct_c", key: "   ", path: path)) { err in
            XCTAssertEqual(err as? SecretWriter.SecretError, .emptyKey)
        }
    }

    func testKeyAccountConvention() {
        XCTAssertEqual(SecretWriter.keyAccount(forCustomId: "foo"), "custom_foo_api_key")
    }
}
