import Foundation

/// Mid-run steering measures stalled information gathering. Reading a new file/window or
/// receiving changed output is progress; the provider request budget still bounds the run.
struct HeadlessGatheringProgress {
    private var seen: Set<String> = []
    private(set) var stalledCalls = 0

    mutating func observe(tool: String, args: [String: Any], result: ToolResult,
                          visibleBody: String, readOnly: Bool) {
        guard readOnly else { stalledCalls = 0; return }
        let encodedArgs = (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? TrajectoryAnalyzer.fingerprint(args)
        let identity = BuilderEvidenceDigest.sha256(
            tool + "\n" + encodedArgs + "\n" + visibleBody)
        if result.success, seen.insert(identity).inserted {
            stalledCalls = 0
        } else {
            stalledCalls += 1
        }
    }

    mutating func didNudge() { stalledCalls = 0 }
}
