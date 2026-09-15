import Foundation
import AgentCore

extension KistRunner {
    struct SMLRuntimeCapabilityStack {
        let gateway: SMLCommandGateway
        let pump: SMLRuntimeCapabilityPump
        let mcpManager: MCPClientManager?

        func shutdown() async {
            await mcpManager?.shutdownAll()
        }
    }

    /// One assembly seam for every durable operator surface. Serve and the interactive REPL must
    /// never drift into different catalogs, driver sets, claim compilers, or authority resolvers.
    static func makeSMLRuntimeCapabilityStack(
        host: SMLRuntimeHostLaunch,
        projectRoot: String,
        actor: String,
        enableComputerUse: Bool = false,
        mcpManagerForTesting: MCPClientManager? = nil
    ) async throws -> SMLRuntimeCapabilityStack {
        guard let environment = host.durableEnvironment,
              let runtime = host.durableRuntime else {
            throw SMLRuntimeCapabilityStackError.durableHostRequired
        }
        let catalog = try SMLRuntimeHostCatalogFile.load(projectRoot: projectRoot)
        let configuredMCP = try loadOptionalMCPBindings(projectRoot: projectRoot)
        let admittedMCP = configuredMCP?.selecting(catalog.toolCapabilities)
        var mcpManager: MCPClientManager?
        var discoveredMCPTools: [RemoteMCPTool] = []
        if let admittedMCP, !admittedMCP.tools.isEmpty {
            let manager = mcpManagerForTesting ?? MCPClientManager()
            mcpManager = manager
            let discovered = await manager.discoverAndWrapTools(
                projectRoot: projectRoot,
                allowProjectConfig: admittedMCP.allowProjectConfig,
                admittedServerNames: admittedMCP.serverNames
            )
            discoveredMCPTools = discovered.filter {
                admitsMCPTool(
                    name: $0.name,
                    explicitComputerUseRequirement: $0.explicitComputerUseRequirement,
                    enableComputerUse: enableComputerUse
                )
            }
        }

        do {
            let providers = makeRegistry(config: KistConfig.load())
            let drivers = try buildSMLCapabilityDrivers(
                projectRoot: projectRoot,
                catalog: catalog,
                embeddingProvider: makeEmbedder(registry: providers),
                providers: providers,
                mcpBindings: admittedMCP,
                discoveredMCPTools: discoveredMCPTools
            )
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
                        store: environment.store,
                        policy: try SMLApprovalPolicy.load(projectRoot: projectRoot)
                    ),
                    reportDrain: { reportSMLRuntimeDrain($0) }
                ),
                mcpManager: mcpManager
            )
        } catch {
            await mcpManager?.shutdownAll()
            throw error
        }
    }

    /// Scope a long-lived capability stack to one operator surface and await teardown before that
    /// surface returns or throws. This is the MCP no-zombie guarantee for both serve and REPL mode.
    static func withSMLRuntimeCapabilityStack<Result>(
        host: SMLRuntimeHostLaunch,
        projectRoot: String,
        actor: String,
        enableComputerUse: Bool = false,
        _ body: (SMLRuntimeCapabilityStack) async throws -> Result
    ) async throws -> Result {
        let stack = try await makeSMLRuntimeCapabilityStack(
            host: host,
            projectRoot: projectRoot,
            actor: actor,
            enableComputerUse: enableComputerUse
        )
        do {
            let result = try await body(stack)
            await stack.shutdown()
            return result
        } catch {
            await stack.shutdown()
            throw error
        }
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
        embedder: (@Sendable (String) async throws -> [Float])? = nil,
        embeddingProvider: (any EmbeddingProviding)? = nil,
        providers: ProviderRegistry = ProviderRegistry(),
        mcpBindings: SMLMCPToolBindings? = nil,
        discoveredMCPTools: [RemoteMCPTool] = []
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

        // Endpoint files are inert until their exact capability also appears in the human-owned
        // catalog. Partition those reviewed names from built-in tools so CALL_TOOL has one owner.
        let endpointRegistry = try SMLHTTPEndpointRegistry.load(projectRoot: projectRoot)
        let admittedHTTPRegistry = endpointRegistry.selecting(catalog.toolCapabilities)
        let httpCapabilities = Set(admittedHTTPRegistry.endpoints.keys)
        let admittedMCPBindings = mcpBindings?.selecting(catalog.toolCapabilities)
        let mcpCapabilities = Set(admittedMCPBindings?.tools.keys.map { $0 } ?? [])
        for capability in httpCapabilities.sorted() where registry.tool(named: capability) != nil {
            throw SMLRuntimeCapabilityStackError.httpToolCollision(capability)
        }
        for capability in mcpCapabilities.sorted() {
            if registry.tool(named: capability) != nil {
                throw SMLRuntimeCapabilityStackError.mcpToolCollision(
                    capability: capability, other: "built-in tool registry")
            }
            if httpCapabilities.contains(capability) {
                throw SMLRuntimeCapabilityStackError.mcpToolCollision(
                    capability: capability, other: "HTTP endpoint registry")
            }
        }
        let builtInToolCapabilities = catalog.toolCapabilities
            .subtracting(httpCapabilities)
            .subtracting(mcpCapabilities)

        if !builtInToolCapabilities.isEmpty {
            drivers.append(SMLToolCapabilityDriver(
                allowedCapabilities: builtInToolCapabilities,
                registry: registry,
                context: context
            ))
        }
        if !httpCapabilities.isEmpty {
            let authentication = try SMLHTTPAuthenticationStore.load(projectRoot: projectRoot)
            drivers.append(try SMLHTTPCapabilityDriver(
                registry: admittedHTTPRegistry,
                authentication: authentication
            ))
        }
        if let admittedMCPBindings, !admittedMCPBindings.tools.isEmpty {
            drivers.append(try SMLMCPToolCapabilityDriver(
                bindings: admittedMCPBindings,
                discoveredTools: discoveredMCPTools,
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
            for schema in catalog.modelOutputSchemas.sorted() where bindings.outputSchemas[schema] == nil {
                throw SMLModelOutputError.unknownSchema(schema)
            }
            drivers.append(SMLModelCapabilityDriver(
                bindings: bindings,
                providers: providers
            ))
        }
        if !catalog.retrievalSources.isEmpty,
           let configured = try loadOptionalRetrievalBindings(projectRoot: projectRoot) {
            let bindings = SMLRetrievalSourceBindings(sources: configured.sources.filter {
                catalog.retrievalSources.contains($0.key)
            })
            if !bindings.sources.isEmpty {
                if let embeddingProvider {
                    drivers.append(SMLRetrievalCapabilityDriver(bindings: bindings, provider: embeddingProvider))
                } else if let embedder {
                    drivers.append(SMLRetrievalCapabilityDriver(bindings: bindings, embed: embedder))
                } else {
                    throw SMLRuntimeCapabilityStackError.retrievalEmbedderUnavailable
                }
            }
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

    private static func loadOptionalMCPBindings(
        projectRoot: String
    ) throws -> SMLMCPToolBindings? {
        do {
            return try SMLMCPToolBindings.load(projectRoot: projectRoot)
        } catch SMLMCPToolBindings.LoadError.missing {
            return nil
        }
    }
}

enum SMLRuntimeCapabilityStackError: Error, CustomStringConvertible {
    case durableHostRequired
    case httpToolCollision(String)
    case mcpToolCollision(capability: String, other: String)
    case retrievalEmbedderUnavailable

    var description: String {
        switch self {
        case .durableHostRequired:
            return "SML capability execution requires a durable host"
        case .httpToolCollision(let capability):
            return "SML capability '\(capability)' is defined by both the HTTP endpoint registry "
                + "and the built-in tool registry"
        case .mcpToolCollision(let capability, let other):
            return "SML MCP capability '\(capability)' collides with the \(other)"
        case .retrievalEmbedderUnavailable:
            return "SML retrieval bindings need a configured embedding provider permitted by Kist's provider policy. "
                + "Configure that provider (for example KIST_EMBEDDER=ollama with an admitted Ollama provider), "
                + "or remove the unused retrieval binding; no retrieval was started."
        }
    }
}
