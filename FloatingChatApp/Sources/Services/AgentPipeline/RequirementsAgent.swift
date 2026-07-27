import Foundation

/// Part 2: Converts understanding to code requirements
final class RequirementsAgent {

    private let systemPrompt = """
    You are a senior software architect specializing in Swift and SwiftUI development.
    Convert the user's request into detailed, actionable code requirements.

    Given the analysis of what the user wants, produce:
    1. A summary of what needs to be built
    2. Files to create (with full paths and purpose)
    3. Files to modify (with specific changes needed)
    4. Any new dependencies (frameworks, packages)
    5. Test cases to verify the implementation

    Be VERY specific about:
    - Swift syntax and patterns
    - SwiftUI views and modifiers
    - File paths relative to project root
    - Function and class signatures
    - Where code should be placed in existing files

    IMPORTANT: Output ONLY valid JSON in this exact format:
    {
      "summary": "Brief description of what will be built",
      "filesToCreate": [
        {
          "path": "Sources/Services/MyService.swift",
          "purpose": "Handles X functionality",
          "content": "// Skeleton code or key structure"
        }
      ],
      "filesToModify": [
        {
          "path": "Sources/Views/ChatView.swift",
          "changes": [
            {
              "id": "uuid-here",
              "location": "ChatView.body",
              "action": "add",
              "oldCode": null,
              "newCode": "// Code to add"
            }
          ]
        }
      ],
      "dependencies": ["PDFKit"],
      "testCases": ["Test that X works when Y"]
    }

    Use action values: "add", "modify", or "delete"
    """

    func generateRequirements(
        analysis: ConversationAnalysis,
        projectStructure: String,
        existingFiles: [String]
    ) async throws -> CodeRequirements {
        let provider = await getRequirementsProvider()

        let prompt = """
        User wants: \(analysis.userIntent)

        Project context: \(analysis.projectContext)

        Complexity: \(analysis.complexity.rawValue)

        Current project structure:
        \(projectStructure)

        Existing Swift files:
        \(existingFiles.joined(separator: "\n"))

        Generate detailed code requirements as JSON.
        """

        let messages = [ChatMessage(role: .user, content: prompt)]

        let settings = ModelSettings(
            temperature: 0.4,
            topP: 0.9,
            maxTokens: 4096,
            systemPrompt: systemPrompt
        )

        var response = ""
        let stream = try await provider.sendMessage(
            messages: messages,
            settings: settings,
            stream: false
        )

        for try await chunk in stream {
            response += chunk
        }

        return try parseRequirements(from: response)
    }

    @MainActor
    private func getRequirementsProvider() -> any AIProvider {
        let settings = AgentSettingsManager.shared.settings

        switch settings.conversationModel {
        case "gpt":
            return OpenAIProvider()
        default:
            return AnthropicProvider()
        }
    }

    private func parseRequirements(from response: String) throws -> CodeRequirements {
        // Extract JSON from response
        var jsonString = response

        if let jsonStart = response.range(of: "{"),
           let jsonEnd = response.range(of: "}", options: .backwards) {
            jsonString = String(response[jsonStart.lowerBound...jsonEnd.upperBound])
        }

        guard let data = jsonString.data(using: .utf8) else {
            throw AgentError.invalidResponse("Could not parse requirements response")
        }

        // Try to decode directly
        do {
            let requirements = try JSONDecoder().decode(CodeRequirements.self, from: data)
            return requirements
        } catch {
            // Manual parsing fallback
            return try parseManually(from: jsonString)
        }
    }

    private func parseManually(from json: String) throws -> CodeRequirements {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.invalidResponse("Could not parse requirements JSON")
        }

        let summary = dict["summary"] as? String ?? "No summary"
        let dependencies = dict["dependencies"] as? [String] ?? []
        let testCases = dict["testCases"] as? [String] ?? []

        var filesToCreate: [FileSpec] = []
        if let createArray = dict["filesToCreate"] as? [[String: Any]] {
            for item in createArray {
                if let path = item["path"] as? String,
                   let purpose = item["purpose"] as? String {
                    let content = item["content"] as? String ?? ""
                    filesToCreate.append(FileSpec(path: path, purpose: purpose, content: content))
                }
            }
        }

        var filesToModify: [FileModification] = []
        if let modifyArray = dict["filesToModify"] as? [[String: Any]] {
            for item in modifyArray {
                if let path = item["path"] as? String,
                   let changesArray = item["changes"] as? [[String: Any]] {
                    var changes: [CodeChange] = []
                    for change in changesArray {
                        let location = change["location"] as? String ?? ""
                        let actionStr = change["action"] as? String ?? "add"
                        let action: ChangeAction
                        switch actionStr {
                        case "modify": action = .modify
                        case "delete": action = .delete
                        default: action = .add
                        }
                        let oldCode = change["oldCode"] as? String
                        let newCode = change["newCode"] as? String ?? ""

                        changes.append(CodeChange(
                            location: location,
                            action: action,
                            oldCode: oldCode,
                            newCode: newCode
                        ))
                    }
                    filesToModify.append(FileModification(path: path, changes: changes))
                }
            }
        }

        return CodeRequirements(
            summary: summary,
            filesToCreate: filesToCreate,
            filesToModify: filesToModify,
            dependencies: dependencies,
            testCases: testCases
        )
    }
}
