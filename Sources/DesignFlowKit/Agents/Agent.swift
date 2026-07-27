import Foundation

/// A specialist stage. `produce` writes the stage's artifact into the workspace
/// and returns the text it generated (which becomes context for the next stage).
///
/// Writing is the agent's job; *verifying* the write is the gate's job. The two
/// are deliberately separated so an agent can never mark its own homework.
public protocol Agent: Sendable {
    var kind: AgentKind { get }
    func produce(context: PipelineContext, workspace: GitWorkspace) async throws -> String
}
