import Foundation
import AgentCore

extension KistRunner {
    static func runSMLRuntimeExport(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostExport(
                sourcePath: opts.smlRuntimeExport,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeLaunch(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostLaunchDescriptor(
                sourcePath: opts.smlRuntimeLaunch,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeOpenAPI(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostOpenAPI(
                sourcePath: opts.smlRuntimeOpenAPI,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeModelRouter(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostModelRouter(
                sourcePath: opts.smlRuntimeModelRouter,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeOnyx(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostOnyxDrivers(
                sourcePath: opts.smlRuntimeOnyx,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimePlanning(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostPlanning(
                sourcePath: opts.smlRuntimePlanning,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeCatalog(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostCatalog(
                sourcePath: opts.smlRuntimeCatalog,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeMount(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostMount(
                sourcePath: opts.smlRuntimeMount,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeAgentGuide(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAgentGuide(
                sourcePath: opts.smlRuntimeAgentGuide,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeHostGuide(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostGuide(
                sourcePath: opts.smlRuntimeHostGuide,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeHostWiring(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostWiring(
                sourcePath: opts.smlRuntimeHostWiring,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeRunbook(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostRunbook(
                sourcePath: opts.smlRuntimeRunbook,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeScaffold(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostScaffold(
                sourcePath: opts.smlRuntimeScaffold,
                outputDirectory: opts.smlRuntimeOutputDirectory,
                projectRoot: opts.project,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeAttachments(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAttachments(
                sourcePath: opts.smlRuntimeAttachments,
                projectRoot: opts.project,
                workflowID: opts.smlRuntimeWorkflowID,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeREPL(_ opts: KistOptions) async -> Int32 {
        // No --sml-line: the interactive loop owns the session (reads stdin until exit/EOF).
        if opts.smlRuntimeREPLLine == nil {
            return await runSMLRuntimeREPLInteractive(opts)
        }
        do {
            let json = try await renderSMLRuntimeHostREPLCommand(
                sourcePath: opts.smlRuntimeREPL,
                projectRoot: opts.project,
                mode: opts.smlRuntimeDurable ? .durable : .ephemeralExport,
                workflowID: opts.smlRuntimeWorkflowID,
                line: opts.smlRuntimeREPLLine,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeREPLScript(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostREPLTranscript(
                sourcePath: opts.smlRuntimeREPLScript,
                projectRoot: opts.project,
                mode: opts.smlRuntimeDurable ? .durable : .ephemeralExport,
                workflowID: opts.smlRuntimeWorkflowID,
                scriptPath: opts.smlRuntimeREPLScriptPath,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeAPI(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAPIExchange(
                sourcePath: opts.smlRuntimeAPI,
                projectRoot: opts.project,
                mode: opts.smlRuntimeDurable ? .durable : .ephemeralExport,
                method: opts.smlRuntimeAPIMethod,
                path: opts.smlRuntimeAPIPath,
                bodyJSON: opts.smlRuntimeAPIBody,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeAPIScript(_ opts: KistOptions) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostAPITranscript(
                sourcePath: opts.smlRuntimeAPIScript,
                projectRoot: opts.project,
                mode: opts.smlRuntimeDurable ? .durable : .ephemeralExport,
                scriptPath: opts.smlRuntimeAPIScriptPath,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeModel(
        _ opts: KistOptions,
        registry: ProviderRegistry,
        providerId: String,
        model: String?,
        projectRoot: String
    ) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostModelTurn(
                sourcePath: opts.smlRuntimeModel,
                projectRoot: projectRoot,
                prompt: opts.smlRuntimeModelPrompt ?? opts.goal,
                binding: ProviderBinding(providerId: providerId, model: model),
                providers: registry,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

    static func runSMLRuntimeModelScript(
        _ opts: KistOptions,
        registry: ProviderRegistry,
        providerId: String,
        model: String?,
        projectRoot: String
    ) async -> Int32 {
        do {
            let json = try await renderSMLRuntimeHostModelTranscript(
                sourcePath: opts.smlRuntimeModelScript,
                projectRoot: projectRoot,
                scriptPath: opts.smlRuntimeModelScriptPath,
                binding: ProviderBinding(providerId: providerId, model: model),
                providers: registry,
                roleOverride: opts.smlRuntimeRole,
                actor: opts.smlRuntimeActor,
                apiBasePathOverride: opts.smlRuntimeAPIBasePath,
                apiWorkflowPathOverrides: opts.smlRuntimeAPIWorkflowPathOverrides,
                title: opts.smlRuntimeTitle,
                version: opts.smlRuntimeVersion,
                modelMaximumCommandRoundsOverride: opts.smlRuntimeModelRounds
            )
            print(json)
            return 0
        } catch {
            err("error: \(error)")
            return 2
        }
    }

}
