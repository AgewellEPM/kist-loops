import Foundation

/// Part 3: Generates actual code using DeepSeek
final class CodeAgent {

    private let deepseek = DeepSeekProvider()

    private let systemPrompt = """
    You are an expert Swift and SwiftUI developer.
    Generate production-ready, compilable code based on the requirements.

    RULES:
    - Follow Apple's Swift API Design Guidelines
    - Use SwiftUI for UI (not UIKit/AppKit unless necessary)
    - Include proper error handling with do-catch or Result types
    - Add concise comments only for complex logic
    - Use @MainActor for UI-related classes and ObservableObject
    - Use async/await for asynchronous operations
    - Follow existing code patterns in the project
    - Import necessary frameworks at the top

    For each file, output COMPLETE, COMPILABLE Swift code.
    Do not use placeholders like "// TODO" or "..." - write actual implementation.

    When modifying existing files, output the FULL file content with changes applied.
    """

    func generateCode(
        requirements: CodeRequirements,
        projectPath: String
    ) async throws -> [GeneratedFile] {
        var generatedFiles: [GeneratedFile] = []

        // Generate new files
        for fileSpec in requirements.filesToCreate {
            let code = try await generateNewFile(fileSpec: fileSpec, requirements: requirements)
            generatedFiles.append(GeneratedFile(
                path: fileSpec.path,
                content: code,
                isNew: true
            ))
        }

        // Generate modifications
        for modification in requirements.filesToModify {
            let fullPath = projectPath + "/" + modification.path

            // Read existing file
            let existingContent: String
            if FileManager.default.fileExists(atPath: fullPath) {
                existingContent = (try? String(contentsOfFile: fullPath, encoding: .utf8)) ?? ""
            } else {
                existingContent = ""
            }

            let modifiedCode = try await modifyExistingFile(
                existingContent: existingContent,
                modification: modification,
                requirements: requirements
            )

            generatedFiles.append(GeneratedFile(
                path: modification.path,
                content: modifiedCode,
                isNew: existingContent.isEmpty
            ))
        }

        return generatedFiles
    }

    private func generateNewFile(
        fileSpec: FileSpec,
        requirements: CodeRequirements
    ) async throws -> String {
        let prompt = """
        Generate a complete Swift file for:

        File: \(fileSpec.path)
        Purpose: \(fileSpec.purpose)

        Context: \(requirements.summary)

        Skeleton/hints provided:
        \(fileSpec.content)

        Generate the COMPLETE, COMPILABLE Swift code for this file.
        Include all necessary imports and implementations.
        """

        let messages = [ChatMessage(role: .user, content: prompt)]

        let settings = ModelSettings(
            temperature: 0.3,
            topP: 0.95,
            maxTokens: 8192,
            systemPrompt: systemPrompt
        )

        var response = ""
        let stream = try await deepseek.sendMessage(
            messages: messages,
            settings: settings,
            stream: false
        )

        for try await chunk in stream {
            response += chunk
        }

        return extractCode(from: response)
    }

    private func modifyExistingFile(
        existingContent: String,
        modification: FileModification,
        requirements: CodeRequirements
    ) async throws -> String {
        // Build modification instructions
        var changeDescriptions: [String] = []
        for change in modification.changes {
            let desc = """
            - \(change.action.rawValue.uppercased()) at \(change.location):
              \(change.newCode)
            """
            changeDescriptions.append(desc)
        }

        let prompt = """
        Modify this Swift file according to the changes below.

        EXISTING FILE CONTENT:
        ```swift
        \(existingContent)
        ```

        CHANGES TO MAKE:
        \(changeDescriptions.joined(separator: "\n"))

        CONTEXT: \(requirements.summary)

        Output the COMPLETE modified file with all changes applied.
        The code must be compilable.
        """

        let messages = [ChatMessage(role: .user, content: prompt)]

        let settings = ModelSettings(
            temperature: 0.2,
            topP: 0.95,
            maxTokens: 8192,
            systemPrompt: systemPrompt
        )

        var response = ""
        let stream = try await deepseek.sendMessage(
            messages: messages,
            settings: settings,
            stream: false
        )

        for try await chunk in stream {
            response += chunk
        }

        return extractCode(from: response)
    }

    func fixBuildError(
        error: AgentBuildError,
        fileContent: String
    ) async throws -> String {
        let prompt = """
        Fix this build error in the Swift file.

        ERROR:
        File: \(error.file)
        Line: \(error.line)
        Message: \(error.message)

        CURRENT FILE CONTENT:
        ```swift
        \(fileContent)
        ```

        Output the COMPLETE fixed file. The code must compile without errors.
        """

        let messages = [ChatMessage(role: .user, content: prompt)]

        // Use DeepSeek R1 for reasoning about errors
        let originalModel = deepseek.selectedModel
        deepseek.selectedModel = deepseek.availableModels.first { $0.id == "deepseek-reasoner" }

        let settings = ModelSettings(
            temperature: 0.1,
            topP: 0.95,
            maxTokens: 8192,
            systemPrompt: "You are an expert Swift developer. Fix the build error and output the complete corrected file."
        )

        var response = ""
        let stream = try await deepseek.sendMessage(
            messages: messages,
            settings: settings,
            stream: false
        )

        for try await chunk in stream {
            response += chunk
        }

        // Restore original model
        deepseek.selectedModel = originalModel

        return extractCode(from: response)
    }

    // MARK: - Helpers

    private func extractCode(from response: String) -> String {
        // Remove markdown code blocks if present
        var code = response

        // Remove ```swift and ``` markers
        if let codeStart = code.range(of: "```swift") {
            code = String(code[codeStart.upperBound...])
        } else if let codeStart = code.range(of: "```") {
            code = String(code[codeStart.upperBound...])
        }

        if let codeEnd = code.range(of: "```", options: .backwards) {
            code = String(code[..<codeEnd.lowerBound])
        }

        return code.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
