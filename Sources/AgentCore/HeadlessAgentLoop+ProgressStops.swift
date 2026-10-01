import Foundation

extension HeadlessAgentLoop {
    static func projectScopeStop(_ result: ToolResult) -> String? {
        guard !result.success, result.hostPathScopeDenied else { return nil }
        return "blocked by project scope — start in the requested repository with `kist --project <project-directory>`, "
            + "or explicitly add the needed read-only directory with `--allow-read <directory>`. "
            + "The current turn has stopped. Refusal: \(result.error ?? "filesystem access refused")"
    }

    static let gatheringStop = "stopped early — repeated searches or reads produced no new evidence "
        + "after recovery guidance. Narrow the target or provide the missing project path before retrying."
}
