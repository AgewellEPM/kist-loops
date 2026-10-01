import Foundation
import XCTest

extension DeploymentProvenanceTests {
    func testFailedPromotionPreservesEvaluatorReasonAndRollsBack() throws {
        let fixture = repositoryRoot.appendingPathComponent("scripts/tests/kist-deployment-diagnostics.sh")
        let result = try run(URL(fileURLWithPath: "/bin/bash"), arguments: [fixture.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("PASS kist deployment diagnostics"), result.stdout)
    }

    func testInstalledResourceBuildArchiveRollbackAndTrustBoundaries() throws {
        let fixture = repositoryRoot.appendingPathComponent("scripts/tests/kist-resource-deployment.sh")
        let result = try run(fixture)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("PASS kist resource deployment"), result.stdout)
    }

    func testInstalledResourceProtocolEmbeddingsMatchTheirSourceModule() throws {
        let generator = repositoryRoot.appendingPathComponent("scripts/deployment/render_launchers.py")
        let result = try run(URL(fileURLWithPath: "/usr/bin/python3"),
                             arguments: [generator.path, "--check"])
        XCTAssertEqual(result.status, 0, result.stderr)
    }
}
