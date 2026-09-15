import Foundation
import AgentCore

extension KistRunner {
    /// A bounded observation-only command for explicit sync and an operator-installed timer. It
    /// resolves no provider, starts only LIST, and always awaits MCP shutdown before returning.
    static func runListLearning(_ opts: KistOptions) async -> Int32 {
        guard !(opts.listLearningSync && opts.listLearningStatus) else {
            err("choose --list-learning-sync or --list-learning-status")
            return 2
        }
        guard !opts.noMemory else {
            print("LIST learning disabled by --no-memory; no observations read or written")
            return 0
        }
        guard let root = ToolContext.canonicalize(opts.project) else {
            err("LIST learning requires an existing project directory")
            return 2
        }
        let store = OrganizationalLearningStore(projectRoot: root)
        if opts.listLearningStatus {
            print(store.listLearningStatus())
            return 0
        }
        let manager = MCPClientManager()
        let discovered = await manager.discoverAndWrapTools(
            projectRoot: root, admittedServerNames: ["list"])
        let context = ToolContext(projectRoot: root)
        let learning = makeListLearning(root: root, opts: opts,
                                        tools: ToolRegistry(discovered), context: context)
        let succeeded: Bool
        if let learning {
            succeeded = await learning.refresh()
        } else {
            err("LIST MCP missing: configure server 'list' exposing 'recent_observations'")
            succeeded = false
        }
        await manager.shutdownAll()
        if succeeded {
            print("LIST sync completed · source observations remain unsigned advisory data")
            print(store.listLearningStatus())
        }
        return succeeded ? 0 : 1
    }
}
