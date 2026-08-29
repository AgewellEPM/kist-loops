import XCTest
@testable import AgentCore

final class SMLWorkflowAdmissionTests: XCTestCase {
    func testUnattestedImportedPluginCannotBeAdmittedForExecution() throws {
        let candidate = try SMLWorkflowValidator.requireValidForImport(
            workflow(plugin: .init(id: "invoice_reader"))
        )

        XCTAssertThrowsError(try SMLWorkflowAdmission.admitForExecution(
            candidate, catalog: .init()
        )) { error in
            let admission = error as? SMLWorkflowAdmissionError
            XCTAssertTrue(admission?.diagnostics.contains { $0.code == "unattested_plugin" } == true)
        }
    }

    func testAttestationMustMatchExactImportedContract() throws {
        let imported = SMLPluginContract(
            id: "invoice_reader", reads: ["invoice"], sideEffectLevel: .readOnly
        )
        let attested = SMLPluginContract(
            id: "invoice_reader", reads: ["invoice", "customer"], sideEffectLevel: .readOnly
        )
        let candidate = try SMLWorkflowValidator.requireValidForImport(workflow(plugin: imported))
        let catalog = SMLExecutionAdmissionCatalog(plugins: [
            "invoice_reader": .init(
                contract: attested,
                trustLevel: .verified,
                isolation: .sandboxed,
                attestedBy: "host.registry"
            ),
        ])

        XCTAssertThrowsError(try SMLWorkflowAdmission.admitForExecution(
            candidate, catalog: catalog
        )) { error in
            let admission = error as? SMLWorkflowAdmissionError
            XCTAssertTrue(admission?.diagnostics.contains {
                $0.code == "plugin_attestation_mismatch"
            } == true)
        }
    }

    func testVerifiedExactPluginCanBeAdmittedFromHostCatalog() throws {
        let contract = SMLPluginContract(
            id: "invoice_reader", reads: ["invoice"], sideEffectLevel: .readOnly
        )
        let candidate = try SMLWorkflowValidator.requireValidForImport(workflow(plugin: contract))
        let catalog = SMLExecutionAdmissionCatalog(plugins: [
            "invoice_reader": .init(
                contract: contract,
                trustLevel: .verified,
                isolation: .trustedProcess,
                attestedBy: "host.registry"
            ),
        ])

        let admitted = try SMLWorkflowAdmission.admitForExecution(candidate, catalog: catalog)
        XCTAssertEqual(admitted.id, "invoice.workflow")
    }

    func testContractedPluginCannotEscapeSandbox() throws {
        let contract = SMLPluginContract(
            id: "invoice_reader", reads: ["invoice"], sideEffectLevel: .readOnly
        )
        let candidate = try SMLWorkflowValidator.requireValidForImport(workflow(plugin: contract))
        let catalog = SMLExecutionAdmissionCatalog(plugins: [
            "invoice_reader": .init(
                contract: contract,
                trustLevel: .contracted,
                isolation: .trustedProcess,
                attestedBy: "host.registry"
            ),
        ])

        XCTAssertThrowsError(try SMLWorkflowAdmission.admitForExecution(
            candidate, catalog: catalog
        )) { error in
            let admission = error as? SMLWorkflowAdmissionError
            XCTAssertTrue(admission?.diagnostics.contains {
                $0.code == "plugin_requires_sandbox"
            } == true)
        }
    }

    private func workflow(plugin: SMLPluginContract) -> SMLWorkflow {
        SMLWorkflow(
            id: "invoice.workflow",
            version: "1.0.0",
            name: "Invoice workflow",
            source: .init(kind: .langGraph, reference: "invoice.py#graph"),
            trigger: .init(kind: .manual),
            stateSchema: [],
            entrypoint: "plugin",
            instructions: [
                .init(id: "plugin", op: .runPlugin, plugin: plugin, next: "done"),
                .init(id: "done", op: .complete),
            ]
        )
    }
}
