import Foundation
import AgentCore

// `/scorecard` — make the Captain's per-model track record LEGIBLE. Shows, per model, how often it
// succeeded / failed / looped, its top failure reasons, and the rank nudge (or auto-avoid) the Captain
// applies when picking — so "don't burn shit" is visible, not a black box.
extension KistREPL {

    func showScorecard() {
        let verdicts = CaptainLearningStore(projectRoot: projectRoot).modelVerdicts()
        guard !verdicts.isEmpty else {
            print("\u{001B}[36;1m📊 model scorecard\u{001B}[0m \u{001B}[2m· no data yet — it fills as you run builds/turns, then the Captain routes around models that fail or loop\u{001B}[0m")
            return
        }
        print("\u{001B}[36;1m📊 model scorecard\u{001B}[0m \u{001B}[2m· the Captain's per-model track record (why it prefers/avoids a model)\u{001B}[0m")
        // Best track record first (preferred at top, avoided at bottom).
        let rows = verdicts.values.sorted {
            if $0.exclude != $1.exclude { return !$0.exclude && $1.exclude }
            if $0.rankDelta != $1.rankDelta { return $0.rankDelta > $1.rankDelta }
            return $0.successRate > $1.successRate
        }
        for v in rows {
            let name = TeamLanguage.displayName(v.providerId).padding(toLength: 14, withPad: " ", startingAt: 0)
            let ok = Int((v.successRate * 100).rounded())
            let loop = Int((v.loopRate * 100).rounded())
            let flag: String
            if v.exclude {
                flag = "\u{001B}[31m⛔ avoided\u{001B}[0m"
            } else if v.rankDelta > 0 {
                flag = "\u{001B}[32m▲ +\(v.rankDelta)\u{001B}[0m"
            } else if v.rankDelta < 0 {
                flag = "\u{001B}[33m▼ \(v.rankDelta)\u{001B}[0m"
            } else {
                flag = "\u{001B}[2m· neutral\u{001B}[0m"
            }
            let reasons = v.byReason.sorted { $0.value > $1.value }.prefix(2)
                .map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
            let tail = reasons.isEmpty ? "" : "  \u{001B}[2m[\(reasons)]\u{001B}[0m"
            print("  \(name) \(v.samples) runs · \(ok)% ok · \(loop)% looped   \(flag)\(tail)")
        }
        print("\u{001B}[2m  ▲ preferred · ▼ down-ranked · ⛔ routed around (chronic). Cold-start neutral; stale offenders get re-probed.\u{001B}[0m")
    }
}
