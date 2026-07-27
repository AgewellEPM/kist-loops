import XCTest
@testable import Kist

final class SelfProjectResolverTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("self-project-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testSelfProjectRequestRecognizesYourCodebaseLanguage() {
        XCTAssertTrue(SelfProjectResolver.isSelfProjectRequest("go through your code base and check for errors"))
        XCTAssertTrue(SelfProjectResolver.isSelfProjectRequest("audit Kist source"))
        XCTAssertTrue(SelfProjectResolver.isSelfProjectRequest("review yourself"))
        XCTAssertFalse(SelfProjectResolver.isSelfProjectRequest("check this website for broken links"))
    }

    func testPromptContextPointsHomeSessionAtKistSourceRoot() throws {
        let home = tempRoot.appendingPathComponent("home", isDirectory: true)
        let source = home.appendingPathComponent("Downloads/kist-loops", isDirectory: true)
        try makeKistSourceRoot(source)

        let context = SelfProjectResolver.promptContextIfNeeded(
            input: "go through your code base and check for errors",
            currentRoot: home.path,
            environment: ["HOME": home.path],
            fileManager: .default)

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("SELF PROJECT RESOLUTION") == true)
        let canonicalSource = (source.path as NSString).resolvingSymlinksInPath
        XCTAssertTrue(context?.contains(canonicalSource) == true)
        XCTAssertTrue(context?.contains("Relative path from this session root: Downloads/kist-loops") == true)
        XCTAssertTrue(context?.contains("Sources/Kist") == true)
    }

    func testPromptContextIsNilForNormalProjectRequests() throws {
        let home = tempRoot.appendingPathComponent("home", isDirectory: true)
        let source = home.appendingPathComponent("Downloads/kist-loops", isDirectory: true)
        try makeKistSourceRoot(source)

        let context = SelfProjectResolver.promptContextIfNeeded(
            input: "inspect my website routes",
            currentRoot: home.path,
            environment: ["HOME": home.path],
            fileManager: .default)

        XCTAssertNil(context)
    }

    func testEnvironmentSourceRootWinsOverNamedCandidates() throws {
        let home = tempRoot.appendingPathComponent("home", isDirectory: true)
        let custom = tempRoot.appendingPathComponent("custom-kist", isDirectory: true)
        try makeKistSourceRoot(custom)

        let resolved = SelfProjectResolver.resolveKistSourceRoot(
            currentRoot: home.path,
            environment: ["HOME": home.path, "KIST_SOURCE_ROOT": custom.path],
            fileManager: .default)

        XCTAssertEqual(resolved, (custom.path as NSString).resolvingSymlinksInPath)
    }

    private func makeKistSourceRoot(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Kist"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/AgentCore"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests/KistTests"),
                                                withIntermediateDirectories: true)
        try "import PackageDescription\nlet package = Package(name: \"kist\")\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "enum KistRunner {}\n"
            .write(to: root.appendingPathComponent("Sources/Kist/KistRunner.swift"), atomically: true, encoding: .utf8)
        try "final class CaptainOrchestrator {}\n"
            .write(to: root.appendingPathComponent("Sources/AgentCore/CaptainOrchestrator.swift"), atomically: true, encoding: .utf8)
        try "final class KistOptionsTests {}\n"
            .write(to: root.appendingPathComponent("Tests/KistTests/KistOptionsTests.swift"), atomically: true, encoding: .utf8)
    }
}
