import XCTest
import AgentCore
@testable import Kist

final class RoleProfileStoreTests: XCTestCase {

    func testSaveLoadListAndDeleteProfiles() throws {
        let store = RoleProfileStore(path: tempPath())
        let profile = RoleProfileStore.Profile(
            planner: "openai:gpt-4.1",
            worker: "perplexity",
            coder: "deepseek:deepseek-coder",
            critic: "gemini:gemini-2.5-flash"
        )

        try store.save(profile, named: "dream_team")

        XCTAssertEqual(try store.names(), ["dream_team"])
        XCTAssertEqual(try store.profile(named: "dream_team"), profile)
        XCTAssertTrue(try store.delete(named: "dream_team"))
        XCTAssertFalse(try store.delete(named: "dream_team"))
        XCTAssertEqual(try store.names(), [])
    }

    func testProfileRoundTripsRoleBindings() throws {
        let bindings = RoleBindings(default: ProviderBinding(providerId: "openai", model: "gpt-4.1"))
            .binding(.worker, to: ProviderBinding(providerId: "perplexity"))
            .binding(.coder, to: ProviderBinding(providerId: "deepseek"))
            .binding(.critic, to: ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))

        let profile = RoleProfileStore.Profile(bindings: bindings)

        XCTAssertEqual(profile.binding(for: .planner), ProviderBinding(providerId: "openai", model: "gpt-4.1"))
        XCTAssertEqual(profile.binding(for: .worker), ProviderBinding(providerId: "perplexity"))
        XCTAssertEqual(profile.binding(for: .coder), ProviderBinding(providerId: "deepseek"))
        XCTAssertEqual(profile.binding(for: .critic), ProviderBinding(providerId: "gemini", model: "gemini-2.5-flash"))
    }

    func testInvalidNamesAreRejectedWithoutWritingAmbiguousKeys() throws {
        let store = RoleProfileStore(path: tempPath())
        let profile = RoleProfileStore.Profile(planner: "openai", worker: "openai", coder: "openai", critic: "openai")

        XCTAssertThrowsError(try store.save(profile, named: " dream ")) { error in
            XCTAssertEqual(error as? RoleProfileStore.StoreError, .invalidName(" dream "))
        }
        XCTAssertThrowsError(try store.save(profile, named: "dream/team"))
        XCTAssertThrowsError(try store.profile(named: ""))
        XCTAssertEqual(try store.names(), [])
    }

    func testCorruptProfileFileDoesNotGetSilentlyClobbered() throws {
        let path = tempPath()
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)

        let store = RoleProfileStore(path: path)
        let profile = RoleProfileStore.Profile(planner: "openai", worker: "openai", coder: "openai", critic: "openai")

        XCTAssertThrowsError(try store.names())
        XCTAssertThrowsError(try store.profile(named: "dream"))
        XCTAssertThrowsError(try store.save(profile, named: "dream"))
        XCTAssertEqual(String(data: try Data(contentsOf: url), encoding: .utf8), "{not json")
    }

    private func tempPath() -> String {
        NSTemporaryDirectory() + "kist-role-profiles-\(UUID().uuidString)/roles.json"
    }
}
