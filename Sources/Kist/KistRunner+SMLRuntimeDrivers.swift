import Foundation
import AgentCore

extension KistRunner {
    struct SMLRuntimeCapabilityStack {
        let gateway: SMLCommandGateway
        let pump: SMLRuntimeCapabilityPump
    }

    /// One assembly seam for every durable operator surface. Serve and the interactive REPL must
    /// never drift into different catalogs, driver sets, claim compilers, or authority resolvers.
    static func makeSMLRuntimeCapabilityStack(
        host: SMLRuntimeHostLaunch,
        projectRoot: String,
        actor: String
    ) throws -> SMLRuntimeCapabilityStack {
        guard let environment = host.durableEnvironment,
              let runtime = host.durableRuntime else {
            throw SMLRuntimeCapabilityStackError.durableHostRequired
        }
        let catalog = try SMLRuntimeHostCatalogFile.load(projectRoot: projectRoot)
        let drivers = try buildSMLCapabilityDrivers(projectRoot: projectRoot, catalog: catalog)
        let router = SMLCapabilityRouter(drivers: drivers)
        try requireDisjointSMLDrivers(router: router, catalog: catalog)
        let gateway = SMLCommandGateway(runtime: runtime, replayGuard: environment.store)
        let coordinator = SMLCapabilityCoordinator(
            runtime: runtime,
            router: router,
            claimCompiler: SMLCapabilityClaimCompiler(
                actor: actor,
                commandID: { "sml-claim-\(UUID().uuidString.lowercased())" },
                dispatchID: { "sml-dispatch-\(UUID().uuidString.lowercased())" }
            ),
            completionCompiler: SMLCapabilityCompletionCompiler(
                actor: actor,
                commandID: { "sml-complete-\(UUID().uuidString.lowercased())" }
            ),
            gateway: gateway,
            authorityResolver: environment.authorityResolver,
            clock: environment.clock
        )
        return SMLRuntimeCapabilityStack(
            gateway: gateway,
            pump: SMLRuntimeCapabilityPump(
                store: environment.store,
                coordinator: SMLApprovalGatedCoordinator(
                    coordinator: coordinator,
                    store: environment.store
                )
            )
        )
    }

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

enum SMLRuntimeCapabilityStackError: Error, CustomStringConvertible {
    case durableHostRequired

    var description: String {
        "SML capability execution requires a durable host"
    }
}
