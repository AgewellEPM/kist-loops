import Foundation
import Combine

/// Main orchestrator for the coding agent pipeline
@MainActor
final class AgentPipelineManager: ObservableObject {
    static let shared = AgentPipelineManager()

    // Agents
    private lazy var conversationAgent = ConversationAgent()
    private lazy var requirementsAgent = RequirementsAgent()
    private lazy var codeAgent = CodeAgent()
    private lazy var buildAgent = BuildAgent()

    // Pipeline state
    @Published var currentStage: AgentStage = .idle
    @Published var pipelineOutput: [AgentStageOutput] = []
    @Published var isRunning = false
    @Published var lastAnalysis: ConversationAnalysis?
    @Published var lastRequirements: CodeRequirements?
    @Published var lastBuildResult: AgentBuildResult?

    enum AgentStage: Int, Equatable {
        case idle = 0
        case understanding = 1
        case requirements = 2
        case generating = 3
        case building = 4
        case complete = 5
        case error = -1
    }

    private var currentTask: Task<Void, Never>?

    private init() {}

    // MARK: - Main Pipeline Entry Point

    func runPipeline(
        userMessage: String,
        projectPath: String,
        conversationHistory: [ChatMessage]
    ) -> AsyncThrowingStream<AgentStageOutput, Error> {
        return AsyncThrowingStream { continuation in
            self.currentTask = Task {
                await self.executePipeline(
                    userMessage: userMessage,
                    projectPath: projectPath,
                    conversationHistory: conversationHistory,
                    continuation: continuation
                )
            }
        }
    }

    private func executePipeline(
        userMessage: String,
        projectPath: String,
        conversationHistory: [ChatMessage],
        continuation: AsyncThrowingStream<AgentStageOutput, Error>.Continuation
    ) async {
        isRunning = true
        pipelineOutput = []

        do {
            // Stage 1: Understanding
            currentStage = .understanding
            let output1 = AgentStageOutput.understanding(analysis: "Analyzing your request...")
            pipelineOutput.append(output1)
            continuation.yield(output1)

            let analysis = try await conversationAgent.analyze(
                message: userMessage,
                history: conversationHistory,
                projectPath: projectPath
            )
            lastAnalysis = analysis

            let analysisOutput = AgentStageOutput.understanding(
                analysis: "Intent: \(analysis.userIntent)\nComplexity: \(analysis.complexity.rawValue)"
            )
            pipelineOutput.append(analysisOutput)
            continuation.yield(analysisOutput)

            // Check if clarifications needed
            if !analysis.clarifications.isEmpty && !analysis.isReadyForDevelopment {
                let clarifyOutput = AgentStageOutput.understanding(
                    analysis: "Questions: \(analysis.clarifications.joined(separator: "\n"))"
                )
                continuation.yield(clarifyOutput)
                continuation.finish()
                isRunning = false
                return
            }

            // Stage 2: Requirements
            currentStage = .requirements
            let output2 = AgentStageOutput.requirements(spec: "Generating code requirements...")
            pipelineOutput.append(output2)
            continuation.yield(output2)

            let projectContext = try await ProjectContextService.shared.loadProject(at: projectPath)
            let requirements = try await requirementsAgent.generateRequirements(
                analysis: analysis,
                projectStructure: projectContext.structure,
                existingFiles: projectContext.swiftFiles
            )
            lastRequirements = requirements

            let reqOutput = AgentStageOutput.requirements(
                spec: "Files to create: \(requirements.filesToCreate.count)\nFiles to modify: \(requirements.filesToModify.count)"
            )
            pipelineOutput.append(reqOutput)
            continuation.yield(reqOutput)

            // Stage 3: Code Generation
            currentStage = .generating
            let output3 = AgentStageOutput.codeGeneration(chunk: "Generating code with DeepSeek...")
            pipelineOutput.append(output3)
            continuation.yield(output3)

            let generatedFiles = try await codeAgent.generateCode(
                requirements: requirements,
                projectPath: projectPath
            )

            for file in generatedFiles {
                let fileOutput = AgentStageOutput.codeGeneration(chunk: "Generated: \(file.path)")
                pipelineOutput.append(fileOutput)
                continuation.yield(fileOutput)
            }

            // Stage 4: Building
            currentStage = .building
            continuation.yield(.buildStarted)

            let settings = AgentSettingsManager.shared.settings
            let buildResult = try await buildAgent.executeAndBuild(
                generatedFiles: generatedFiles,
                projectPath: projectPath,
                scheme: settings.scheme.isEmpty ? "FloatingChatApp" : settings.scheme
            )
            lastBuildResult = buildResult

            if buildResult.success {
                currentStage = .complete
                let completeOutput = AgentStageOutput.complete(
                    summary: "Build succeeded! \(generatedFiles.count) files created/modified."
                )
                pipelineOutput.append(completeOutput)
                continuation.yield(completeOutput)
            } else {
                // Try to fix errors
                if settings.autoFixErrors && !buildResult.errors.isEmpty {
                    let fixOutput = AgentStageOutput.buildOutput(line: "Build failed. Attempting to fix...")
                    continuation.yield(fixOutput)

                    for attempt in 1...settings.maxFixAttempts {
                        let fixed = try await attemptFix(
                            errors: buildResult.errors,
                            projectPath: projectPath,
                            scheme: settings.scheme
                        )

                        if fixed {
                            currentStage = .complete
                            continuation.yield(.complete(summary: "Build succeeded after \(attempt) fix attempt(s)!"))
                            break
                        }

                        if attempt == settings.maxFixAttempts {
                            currentStage = .error
                            continuation.yield(.error(message: "Could not fix build errors after \(attempt) attempts"))
                        }
                    }
                } else {
                    currentStage = .error
                    let errorMsg = buildResult.errors.map { "\($0.file):\($0.line): \($0.message)" }.joined(separator: "\n")
                    continuation.yield(.error(message: "Build failed:\n\(errorMsg)"))
                }
            }

            continuation.finish()

        } catch {
            currentStage = .error
            continuation.yield(.error(message: error.localizedDescription))
            continuation.finish()
        }

        isRunning = false
    }

    private func attemptFix(errors: [AgentBuildError], projectPath: String, scheme: String) async throws -> Bool {
        for error in errors {
            let filePath = projectPath + "/" + error.file
            guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { continue }

            let fixedContent = try await codeAgent.fixBuildError(
                error: error,
                fileContent: content
            )

            try fixedContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        // Rebuild
        let result = try await buildAgent.runXcodebuild(
            projectPath: projectPath,
            scheme: scheme,
            configuration: "Debug"
        )

        return result.success
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        isRunning = false
        currentStage = .idle
    }

    func reset() {
        stop()
        pipelineOutput = []
        lastAnalysis = nil
        lastRequirements = nil
        lastBuildResult = nil
    }
}
