import XCTest
@testable import DockerControl

final class ProjectProberTests: XCTestCase {
    private func dir(with files: [String]) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for f in files { try? "x".write(to: d.appendingPathComponent(f), atomically: true, encoding: .utf8) }
        return d
    }

    func testDetectsEachKind() {
        let p = ProjectProber()
        XCTAssertEqual(p.probe(dir(with: ["Package.swift"])), .swift)
        XCTAssertEqual(p.probe(dir(with: ["package.json"])), .node)
        XCTAssertEqual(p.probe(dir(with: ["requirements.txt"])), .python)
        XCTAssertEqual(p.probe(dir(with: ["index.html"])), .staticSite)
        XCTAssertEqual(p.probe(dir(with: ["README.md"])), .unknown)
    }
}

final class DockerfileGeneratorTests: XCTestCase {
    func testGeneratesPinnedNonRootDockerfiles() {
        let g = DockerfileGenerator()
        for kind in [ProjectKind.swift, .node, .python, .staticSite] {
            let df = g.dockerfile(for: kind)
            XCTAssertNotNil(df, "\(kind) should generate a Dockerfile")
            XCTAssertTrue(df!.contains("FROM "), "\(kind): must pin a base image")
        }
        XCTAssertNil(g.dockerfile(for: .unknown), "no Dockerfile invented for unknown")
        // Non-root user where the base supports it.
        XCTAssertTrue(g.dockerfile(for: .node)!.contains("USER node"))
        XCTAssertTrue(g.dockerfile(for: .swift)!.contains("USER runner"))
    }
}

/// THE safety floor — verified purely, no daemon.
final class DockerCommandSafetyTests: XCTestCase {
    func testRunAlwaysBakesInTheSafetyFloorAndNeverPrivileged() {
        let spec = ContainerSpec(image: "kist-df-x", name: "kist-df-x",
                                 env: ["A": "1"], ports: [PortMap(host: 8080, container: 80)],
                                 memory: "256m", cpus: "0.5", network: "none")
        let argv = DockerCommand.run(spec)
        let joined = argv.joined(separator: " ")
        XCTAssertTrue(argv.contains("--rm"))
        XCTAssertTrue(joined.contains("--security-opt no-new-privileges"))
        XCTAssertTrue(joined.contains("--cap-drop ALL"))
        XCTAssertTrue(joined.contains("--memory 256m"))
        XCTAssertTrue(joined.contains("--cpus 0.5"))
        XCTAssertTrue(joined.contains("--network none"))
        XCTAssertFalse(joined.contains("--privileged"), "must NEVER be privileged")
    }

    func testPsIsScopedToManagedPrefix() {
        XCTAssertTrue(DockerCommand.ps(managedPrefix: "kist-df-").joined(separator: " ").contains("name=kist-df-"))
    }
}

final class DockerControlNameScopeTests: XCTestCase {
    /// A fake runner so we test control flow without a daemon.
    private func control(_ record: @escaping @Sendable ([String]) -> Void = { _ in }) -> DockerControl {
        DockerControl(managedPrefix: "kist-df-") { argv in
            record(argv)
            // Pretend `version` succeeds (daemon "available") and everything exits 0.
            return (0, argv.first == "version" ? "27.0.0" : "ok")
        }
    }

    func testRefusesUnmanagedNames() {
        let c = control()
        XCTAssertThrowsError(try c.stop("my-precious-db")) { e in
            guard case DockerControl.ControlError.refusedUnmanaged = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try c.remove("prod-postgres")) { e in
            guard case DockerControl.ControlError.refusedUnmanaged = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try c.buildImage(tag: "someones-image", contextDir: ".")) { e in
            guard case DockerControl.ControlError.refusedUnmanaged = e else { return XCTFail("\(e)") }
        }
    }

    func testAllowsManagedNamesAndIssuesTheCommand() throws {
        var seen: [[String]] = []
        let c = control { seen.append($0) }
        _ = try c.stop("kist-df-abc")
        XCTAssertTrue(seen.contains(["stop", "kist-df-abc"]))
    }

    func testUnavailableDaemonFailsClosed() {
        let c = DockerControl(managedPrefix: "kist-df-") { _ in (1, "") }  // version exits 1
        XCTAssertThrowsError(try c.stop("kist-df-abc")) { e in
            guard case DockerControl.ControlError.unavailable = e else { return XCTFail("\(e)") }
        }
    }
}

final class AutoConfiguratorTests: XCTestCase {
    private func dir(with file: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ac-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? "x".write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return d
    }

    func testProducesManagedScopedPlan() {
        let plan = AutoConfigurator(managedPrefix: "kist-df-").configure(projectDir: dir(with: "package.json"), name: "My App!")
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.kind, .node)
        XCTAssertTrue(plan!.imageTag.hasPrefix("kist-df-"), "image must be in our namespace")
        XCTAssertTrue(plan!.spec.name.hasPrefix("kist-df-"))
        XCTAssertEqual(plan?.spec.ephemeral, true)
        XCTAssertEqual(plan?.spec.network, "none")
    }

    func testUnknownKindHasNoPlan() {
        XCTAssertNil(AutoConfigurator().configure(projectDir: dir(with: "README.md"), name: "x"))
    }
}
