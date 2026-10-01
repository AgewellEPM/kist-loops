import Foundation

/// An explicit request to open a registered guest is a runtime action, including
/// when the next clause says “let's build”. This only classifies intent; the
/// live GhostBridge catalog still resolves the target and grants no authority
/// to substitute a different Windows release or invent a disk path.
enum LegacySessionIntent {
    static func isLaunch(_ request: String) -> Bool {
        let text = request.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let introduction = #"(?:(?:hey\s+)?kist[,\s]+)?(?:(?:please|can you|could you|would you)\s+)?"#
        let verb = #"(?:open(?:\s*up)?|launch|boot(?:\s+up)?|start(?:\s+up)?|bring\s+up|fire\s+up)"#
        let possessive = #"\s*(?:(?:our|my|the)\s*)?"#
        let guest = #"(?:windows\s*(?:3\.1|nt\s*4(?:\.0)?|2000|95|98(?:\s*se)?|xp|7|8(?:\.1)?|10|11)|win\s*(?:3\.1|31|nt\s*4|2000|95|98|xp|7|8|10|11)|nt\s*4(?:\.0)?)"#
        let pattern = "^" + introduction + verb + possessive + "(" + guest + ")" + #"(?=$|[\s,;.!?])"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return false }
        let suffix = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        // Opening an artifact named for a platform is not booting that platform.
        let artifact = #"^(?:\.\w|(?:driver|source|code|file|folder|directory|project|repo|repository|documentation|docs|readme|manual|image|iso)\b)"#
        return suffix.range(of: artifact, options: .regularExpression) == nil
    }

    static let toolHints = [
        "For a registered Windows guest, first call ghostbridge-legacy__legacy_system_catalog and follow that target's launchDirection. Use the exact registered generation; never invent a disk, QMP path, target ID or replacement guest.",
        "Use ghostbridge-legacy__legacy_session_open, then poll its same sessionId with legacy_session_status until HOT or an authoritative terminal failure. A timeout is not proof that launch failed; do not start another guest. Keep one guest at a time.",
        "Launching and navigation are separate checks. For semantic V-Card actions, call ghostbridge-vcards__vcard_status and require its enrolled provider, witness, cleanup and approved workflow. legacy_click, legacy_key and observation-only cards do not grant executable action authority.",
        "Use the configured IsolatedTester/TinkyVision observation route for fresh guest evidence. Preserve the lifecycle owner for close and prove the guest and helpers stopped. Report concrete launch or navigation blockers without claiming the desktop is ready.",
    ]
}
