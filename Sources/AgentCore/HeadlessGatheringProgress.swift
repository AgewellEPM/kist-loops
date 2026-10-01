import Foundation

/// Mid-run steering measures stalled information gathering. Reading a new file/window or
/// receiving changed output is progress; the provider request budget still bounds the run.
struct HeadlessGatheringProgress {
    private var seen: Set<String> = []
    private(set) var stalledCalls = 0
    private(set) var callsWithoutProgress = 0

    /// Nudging does not erase the evidence that caused the nudge.
    var exhausted: Bool { callsWithoutProgress >= 8 }

    mutating func observe(tool: String, args: [String: Any], result: ToolResult,
                          visibleBody: String, readOnly: Bool) {
        guard readOnly else {
            if result.success {
                stalledCalls = 0; callsWithoutProgress = 0; seen.removeAll()
            }
            return
        }
        let encodedArgs = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? TrajectoryAnalyzer.fingerprint(args)
        // Search/list variants with identical results are the same observation. Preserve file/window
        // identity for reads: two required files may legitimately contain identical text.
        let discovery = ["list_files", "glob_files", "search_code"].contains(tool)
        let searchRoot = ((args["path"] as? String ?? ".") as NSString).standardizingPath
        let identity = BuilderEvidenceDigest.sha256(
            tool + "\n" + (discovery ? searchRoot : encodedArgs) + "\n" + visibleBody)
        if result.success, seen.insert(identity).inserted {
            stalledCalls = 0; callsWithoutProgress = 0
        } else {
            stalledCalls += 1
            callsWithoutProgress += 1
        }
    }

    mutating func didNudge() { stalledCalls = 0 }
}
