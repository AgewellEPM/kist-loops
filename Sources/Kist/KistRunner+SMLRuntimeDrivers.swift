import Foundation
import AgentCore

extension KistRunner {
    /// Builds the production capability driver set for a durable/serve host from the human-owned
    /// catalog plus the optional driver config files. Missing config is a missing CAPABILITY, not
    /// an error: no models.json simply means no model driver, so CALL_MODEL steps park honestly
    /// at waiting_capability instead of failing launch. What IS a launch error: two drivers
    /// claiming one admitted reference (ambiguity must never resolve by luck), probed here for
    /// every catalog entry before any task can run.
    static func buildSMLCapabilityDrivers(
        projectRoot: String,
        catalog: SMLExecutionAdmissionCatalog,
        embedder: (@Sendable (String) async throws -> [Float])? = nil
    ) throws -> [any SMLInstructionDriver] {
        var drivers: [any SMLInstructionDriver] = []

        // CALL_TOOL + OBSERVE ride the headless tool registry under a shell-denied context:
        // least privilege by default — a tool that needs shell fails closed as a visible FAILED
        // outcome, and widening is a deliberate future knob, never an accident of serve mode.
        // The project audit is owner-only and records argument digests, never raw values.
        let registry = ToolRegistry.headless()
        let context = ToolContext(
            projectRoot: projectRoot,
            auditLog: AuditLog.forProject(root: projectRoot),
            allowMediaDropInbox: false
        )

        if !catalog.toolCapabilities.isEmpty {
            drivers.append(SMLToolCapabilityDriver(
                allowedCapabilities: catalog.toolCapabilities,
                registry: registry,
                context: context
            ))
        }
        if !catalog.observationSources.isEmpty {
            drivers.append(SMLObservationCapabilityDriver(
                allowedSources: catalog.observationSources,
                registry: registry,
                context: context
            ))
        }
        if !catalog.modelPurposes.isEmpty,
           let bindings = try loadOptionalModelBindings(projectRoot: projectRoot) {
            drivers.append(SMLModelCapabilityDriver(
                bindings: bindings,
                providers: ProviderRegistry()
            ))
        }
        if !catalog.retrievalSources.isEmpty,
           let bindings = try loadOptionalRetrievalBindings(projectRoot: projectRoot),
           let embedder {
            drivers.append(SMLRetrievalCapabilityDriver(
                bindings: bindings,
                embed: embedder
            ))
        }
        return drivers
    }

    /// Launch-time disjointness probe: every admitted reference must resolve to AT MOST one
    /// driver. Zero drivers is honest parking; two is a routing ambiguity that aborts launch.
    static func requireDisjointSMLDrivers(
        router: SMLCapabilityRouter,
        catalog: SMLExecutionAdmissionCatalog
    ) throws {
        let probes: [(SMLInstructionOperation, Set<String>)] = [
            (.callTool, catalog.toolCapabilities),
            (.observe, catalog.observationSources),
            (.callModel, catalog.modelPurposes),
            (.retrieve, catalog.retrievalSources),
        ]
        for (operation, references) in probes {
            for reference in references.sorted() {
                let probe = SMLCapabilityRouter.probeRequest(
                    operation: operation, reference: reference
                )
                do {
                    _ = try router.driverID(for: probe)
                } catch let error as SMLCapabilityRouterError {
                    if case .noDriver = error {
                        continue  // honest parking — approval + pending view surface it
                    }
                    throw error   // ambiguity (or worse) aborts launch
                }
            }
        }
    }

    private static func loadOptionalModelBindings(
        projectRoot: String
    ) throws -> SMLModelPurposeBindings? {
        do {
            return try SMLModelPurposeBindings.load(projectRoot: projectRoot)
        } catch SMLModelPurposeBindings.LoadError.missing {
            return nil
        }
    }

    private static func loadOptionalRetrievalBindings(
        projectRoot: String
    ) throws -> SMLRetrievalSourceBindings? {
        do {
            return try SMLRetrievalSourceBindings.load(projectRoot: projectRoot)
        } catch SMLRetrievalSourceBindings.LoadError.missing {
            return nil
        }
    }
}
