import Foundation
import AgentCore

/// LLM-backed agent: builds a prompt from accumulated context, calls the model,
/// and writes the result to its designated artifact path.
public struct PromptAgent: Agent {
    public let kind: AgentKind
    private let llm: LLMClient
    private let system: String
    private let makeUser: @Sendable (PipelineContext) -> String

    public init(kind: AgentKind, llm: LLMClient, system: String,
                makeUser: @escaping @Sendable (PipelineContext) -> String) {
        self.kind = kind
        self.llm = llm
        self.system = system
        self.makeUser = makeUser
    }

    public func produce(context: PipelineContext, workspace: GitWorkspace) async throws -> String {
        let text = try await llm.complete(system: system, user: makeUser(context))
        try workspace.write(text, to: kind.artifactPath)
        return text
    }
}

/// The Build Architect does NOT ask a model whether the build passed — it runs a
/// real Swift type check on the Developer's generated code and reports the result.
public struct BuildArchitectAgent: Agent {
    public let kind: AgentKind = .buildArchitect
    public init() {}

    public func produce(context: PipelineContext, workspace: GitWorkspace) async throws -> String {
        let generatedRel = AgentKind.developer.artifactPath
        let generatedURL = workspace.root.appendingPathComponent(generatedRel)
        let (status, detail) = await Self.compileCheck(generatedURL)

        let report = """
        # Build Report

        Seed: \(context.seedBrief)

        - Generated source: `\(generatedRel)`
        - swiftc type check: **\(status)**

        ## Detail
        ```
        \(detail.isEmpty ? "(no diagnostics)" : detail)
        ```

        _This report reflects `swiftc -typecheck`; application linking and runtime behavior require separate verification._
        """
        try workspace.write(report, to: kind.artifactPath)
        // FAIL-CLOSED (Codex BLOCKER-1): a non-PASS build is a stage FAILURE. Write the
        // honest report (for diagnosis), then throw so the pipeline BLOCKS — a run whose
        // generated code doesn't compile can never be reported COMPLETE.
        guard status == "PASS" else {
            throw BuildError.notCompilable(status: status, detail: String(detail.prefix(500)))
        }
        return report
    }

    public enum BuildError: Error, CustomStringConvertible {
        case notCompilable(status: String, detail: String)
        public var description: String {
            switch self {
            case let .notCompilable(status, detail):
                return "generated code did not build (swiftc: \(status)) — \(detail)"
            }
        }
    }

    /// Returns (statusLabel, diagnostics). Never throws — a missing toolchain or a
    /// syntax error is a truthful result, not a loop-fatal error.
    static func compileCheck(_ file: URL) async -> (String, String) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return ("NO SOURCE", "Developer produced no source at \(file.lastPathComponent)")
        }
        let result = await BoundedProcessRunner.run(
            executable: "/usr/bin/env", arguments: ["swiftc", "-typecheck", file.path],
            cwd: file.deletingLastPathComponent().path,
            environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: 60, maximumOutputBytes: 1_048_576
        )
        var detail = result.stdout + result.stderr
        if result.timedOut { detail += "\nSwift type check timed out." }
        if result.cancelled { detail += "\nSwift type check cancelled." }
        if result.outputTruncated { detail += "\nSwift diagnostics exceeded the output limit." }
        return (result.succeeded ? "PASS" : "FAIL", detail)
    }
}

/// Builds the concrete agent instances for a pipeline. This is the seam where
/// DesignFlow's pipeline *recipes* map onto real, running specialists.
public enum AgentFactory {
    public static func agents(for pipeline: Pipeline, llm: LLMClient) -> [Agent] {
        pipeline.agents.map { make($0, llm: llm) }
    }

    private static func make(_ kind: AgentKind, llm: LLMClient) -> Agent {
        switch kind {
        case .uiDesigner:
            return PromptAgent(
                kind: .uiDesigner, llm: llm,
                system: "You are an expert UI/UX designer. Produce a concise, structured Markdown design analysis: layout, component hierarchy, color/typography direction, key user flows, and accessibility considerations.",
                makeUser: { ctx in "Design brief:\n\(ctx.seedBrief)\n\nProduce the design analysis as Markdown." }
            )
        case .designAnalyst:
            return PromptAgent(
                kind: .designAnalyst, llm: llm,
                system: "You are a senior software architect. From the design, extract a structured feature list, data models, user interactions, and component tree as Markdown. Be specific and implementation-ready.",
                makeUser: { ctx in "Prior work:\n\(ctx.accumulatedContext)\n\nExtract features and technical requirements as Markdown." }
            )
        case .developer:
            return PromptAgent(
                kind: .developer, llm: llm,
                system: "You are an expert Swift/SwiftUI developer. Output ONLY valid Swift source code — no prose, no Markdown fences. Include necessary imports and compile-ready SwiftUI views and models.",
                makeUser: { ctx in "Specification:\n\(ctx.accumulatedContext)\n\nGenerate the Swift implementation. Respond with Swift source only." }
            )
        case .buildArchitect:
            return BuildArchitectAgent()
        }
    }
}
