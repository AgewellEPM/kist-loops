import Foundation
import AgentCore

/// Handlers for the read-only inspector commands (`/skills`, `/mcp`, `/hooks`, `/permissions`) — surfacing
/// the config kist already persists. Extracted from the REPL switch so the dispatcher stays thin and each
/// handler is testable over explicit inputs. Rendering lives in `InspectorPanels`; these just load the
/// on-disk state, resolve the active theme, and hand off.
extension KistREPL {

    private static func inspectorTheme(_ projectRoot: String) -> Theme {
        Theme.resolve(KistSettingsStore(projectRoot: projectRoot).load().theme)
    }

    /// `/skills` — discovered skills (name · estimated token cost · description).
    static func handleSkillsCommand(projectRoot: String) -> String {
        InspectorPanels.skills(SkillManager.discover(projectRoot: projectRoot).allSkills,
                               theme: inspectorTheme(projectRoot))
    }

    /// `/mcp` — configured MCP servers (what agents can reach) + any rejected entries.
    static func handleMcpCommand(projectRoot: String) -> String {
        let (servers, issues) = MCPClientConfig.load(projectRoot: projectRoot,
                                                     allowProjectConfig: true, includeUserConfig: true)
        return InspectorPanels.mcp(servers: servers, issues: issues, theme: inspectorTheme(projectRoot))
    }

    /// `/hooks` — the lifecycle hooks configured in .kist/hooks.json.
    static func handleHooksCommand(projectRoot: String) -> String {
        let hooks = AgentHooks.load(fromFile: projectRoot + "/.kist/hooks.json", projectRoot: projectRoot)
        return InspectorPanels.hooks(hooks?.specs ?? [], theme: inspectorTheme(projectRoot))
    }

    /// `/permissions` — the current tier + which tools still prompt in it. Needs the live bar state.
    static func handlePermissionsCommand(mode: PermissionMode, sensitive: Set<String>, editTools: Set<String>,
                                         projectRoot: String) -> String {
        InspectorPanels.permissions(mode: mode, sensitive: sensitive, editTools: editTools,
                                    theme: inspectorTheme(projectRoot))
    }
}
