import Foundation
import AgentCore

/// Personality LAYER for the shell — same engine, different voice, switchable at runtime and OFF by default.
/// A persona is injected as a single, MARKED message in the conversation; switching removes the old one and
/// adds the new (so Wu-Tang doesn't persist forever once triggered — the bug Luke hit). "captain" is the
/// professional default (no injection). This keeps the fun optional without baking it into the product.
enum Persona {
    static let marker = "🎭 [PERSONA]"
    static let names = ["captain", "minimal", "hacker", "jarvis", "wutang"]

    /// The directive for a persona, or nil for the professional default (captain/off). Marked so it can be
    /// found + removed on the next switch.
    static func directive(_ name: String) -> String? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "captain", "default", "off", "none", "":
            return nil
        case "minimal", "min":
            return marker + " Respond as tersely as possible: answer, then stop. No pleasantries, no preamble, "
                + "no restating the question, no elaboration unless explicitly asked. Prefer bullets over prose."
        case "hacker", "ops":
            return marker + " Respond in a terse hacker-ops voice — efficient, technical, lightly irreverent, "
                + "but always precise. Assume deep expertise; skip hand-holding and disclaimers. Get to the point."
        case "jarvis":
            return marker + " Respond as JARVIS from Iron Man: polished, composed, subtly witty, always a step "
                + "ahead. Occasionally address the user as 'sir'. Calm competence, dry humor, never flustered — "
                + "while doing the actual work correctly."
        case "wutang", "wu-tang", "wu", "odb":
            return marker + " " + WuTangEasterEgg.odbPersonaDirective
        default:
            return nil
        }
    }

    static func canonical(_ name: String) -> String {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "off", "none", "default": return "captain"
        case "wu-tang", "wu", "odb": return "wutang"
        case "min": return "minimal"
        case "ops": return "hacker"
        default: return name.trimmingCharacters(in: .whitespaces).lowercased()
        }
    }

    static func isPersonaMessage(_ content: String) -> Bool { content.hasPrefix(marker) }

    /// Apply a persona to a transcript: drop any prior persona message, add the new directive (if any).
    /// Returns the canonical persona name now in effect.
    static func apply(_ name: String, to transcript: inout [ChatMessage]) -> String {
        transcript.removeAll { isPersonaMessage($0.content) }
        if let d = directive(name) { transcript.append(ChatMessage(role: .user, content: d)) }
        return canonical(name)
    }
}
