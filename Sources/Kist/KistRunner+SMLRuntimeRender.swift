import Foundation
import AgentCore

extension KistRunner {
    static func renderSMLRuntimeHostExport(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let export = try await makeSMLRuntimeHostExport(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(export), as: UTF8.self)
    }

    static func renderSMLRuntimeHostLaunchDescriptor(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let launch = try await makeSMLRuntimeHostLaunchDescriptor(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(launch), as: UTF8.self)
    }

    static func renderSMLRuntimeHostOpenAPI(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let openAPI = try await makeSMLRuntimeHostOpenAPI(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(openAPI), as: UTF8.self)
    }

    static func renderSMLRuntimeHostModelRouter(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let modelRouter = try await makeSMLRuntimeHostModelRouter(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(modelRouter), as: UTF8.self)
    }

    static func renderSMLRuntimeHostOnyxDrivers(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let onyxDrivers = try await makeSMLRuntimeHostOnyxDrivers(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(onyxDrivers), as: UTF8.self)
    }

    static func renderSMLRuntimeHostPlanning(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let planning = try await makeSMLRuntimeHostPlanning(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(planning), as: UTF8.self)
    }

    static func renderSMLRuntimeHostCatalog(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let catalog = try await makeSMLRuntimeHostCatalog(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(catalog), as: UTF8.self)
    }

    static func renderSMLRuntimeHostMount(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let mount = try await makeSMLRuntimeHostMount(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(mount), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAgentGuide(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let guide = try await makeSMLRuntimeHostAgentGuide(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(guide), as: UTF8.self)
    }

    static func renderSMLRuntimeHostGuide(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let guide = try await makeSMLRuntimeHostGuide(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(guide), as: UTF8.self)
    }

    static func renderSMLRuntimeHostWiring(
        sourcePath: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let wiring = try await makeSMLRuntimeHostWiring(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(wiring), as: UTF8.self)
    }

    static func renderSMLRuntimeHostRunbook(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let runbook = try await makeSMLRuntimeHostRunbook(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(runbook), as: UTF8.self)
    }

    static func renderSMLRuntimeHostScaffold(
        sourcePath: String?,
        outputDirectory: String?,
        projectRoot: String,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let scaffold = try await writeSMLRuntimeHostScaffold(
            sourcePath: sourcePath,
            outputDirectory: outputDirectory,
            projectRoot: projectRoot,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(scaffold), as: UTF8.self)
    }

    static func renderSMLRuntimeHostREPLCommand(
        sourcePath: String?,
        projectRoot: String,
        mode: SMLRuntimeHostMode = .ephemeralExport,
        workflowID: String? = nil,
        line: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let command = try await makeSMLRuntimeHostREPLCommand(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            mode: mode,
            workflowID: workflowID,
            line: line,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(command), as: UTF8.self)
    }

    static func renderSMLRuntimeHostREPLTranscript(
        sourcePath: String?,
        projectRoot: String,
        mode: SMLRuntimeHostMode = .ephemeralExport,
        workflowID: String? = nil,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let transcript = try await makeSMLRuntimeHostREPLTranscript(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            mode: mode,
            workflowID: workflowID,
            scriptPath: scriptPath,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(transcript), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAttachments(
        sourcePath: String?,
        projectRoot: String,
        workflowID: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let attachments = try await makeSMLRuntimeHostAttachments(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            workflowID: workflowID,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(attachments), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAPIExchange(
        sourcePath: String?,
        projectRoot: String,
        mode: SMLRuntimeHostMode = .ephemeralExport,
        method: SMLWorkflowAPIMethod = .get,
        path: String?,
        bodyJSON: String? = nil,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let exchange = try await makeSMLRuntimeHostAPIExchange(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            mode: mode,
            method: method,
            path: path,
            bodyJSON: bodyJSON,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(exchange), as: UTF8.self)
    }

    static func renderSMLRuntimeHostAPITranscript(
        sourcePath: String?,
        projectRoot: String,
        mode: SMLRuntimeHostMode = .ephemeralExport,
        scriptPath: String?,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let transcript = try await makeSMLRuntimeHostAPITranscript(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            mode: mode,
            scriptPath: scriptPath,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(transcript), as: UTF8.self)
    }

    static func renderSMLRuntimeHostModelTurn(
        sourcePath: String?,
        projectRoot: String,
        prompt: String?,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let turn = try await makeSMLRuntimeHostModelTurn(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            prompt: prompt,
            binding: binding,
            providers: providers,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(turn), as: UTF8.self)
    }

    static func renderSMLRuntimeHostModelTranscript(
        sourcePath: String?,
        projectRoot: String,
        scriptPath: String?,
        binding: ProviderBinding,
        providers: ProviderRegistry,
        roleOverride: String? = nil,
        actor: String? = nil,
        apiBasePathOverride: String? = nil,
        apiWorkflowPathOverrides: [String: String] = [:],
        title: String? = nil,
        version: String? = nil,
        modelMaximumCommandRoundsOverride: Int? = nil
    ) async throws -> String {
        let transcript = try await makeSMLRuntimeHostModelTranscript(
            sourcePath: sourcePath,
            projectRoot: projectRoot,
            scriptPath: scriptPath,
            binding: binding,
            providers: providers,
            roleOverride: roleOverride,
            actor: actor,
            apiBasePathOverride: apiBasePathOverride,
            apiWorkflowPathOverrides: apiWorkflowPathOverrides,
            title: title,
            version: version,
            modelMaximumCommandRoundsOverride: modelMaximumCommandRoundsOverride
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(transcript), as: UTF8.self)
    }

}
