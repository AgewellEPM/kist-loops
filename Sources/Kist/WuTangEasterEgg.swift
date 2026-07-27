import Foundation
#if canImport(Darwin)
import Darwin   // usleep
#elseif canImport(Glibc)
import Glibc
#endif

/// `/wu-tang` Easter egg: the gold Wu-Tang "W" rises up out of the terminal floor, then the
/// conversational AI takes on an Ol' Dirty Bastard persona for the rest of the session.
/// Because, as ODB famously declared on the '98 Grammy stage: "Wu-Tang is for the children."
enum WuTangEasterEgg {

    // The real Wu-Tang "W" bat/logo (braille block art). Bottom-anchored so the rise animation reveals it
    // from the floor up.
    static let emblem: [String] = [
        "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣤⣶⡀⠀⠀⠀",
        "⠀⢀⣶⣶⣤⣤⣀⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣤⣶⣿⣿⣿⣿⣿⡄⠀⠀",
        "⠀⣼⣿⣿⣿⣿⣿⣿⣿⣷⣶⡤⠀⠀⠀⠀⢤⣶⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡄⠀",
        "⢰⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠀⠀⠀⢀⣀⠀⠙⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⠀",
        "⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⠀⠰⣾⣿⣿⣷⠀⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇",
        "⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣄⣿⣿⣿⣿⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿",
        "⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿",
        "⢹⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿",
        "⠈⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠛⠛⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠇",
        "⠀⠈⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡁⠀⠀⠀⢻⣿⣿⣿⣿⣿⣿⣿⣿⣿⠏⠀",
        "⠀⠀⠀⠙⠿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣇⠀⠀⠀⣼⣿⣿⣿⣿⣿⣿⣿⡿⠃⠀⠀",
        "⠀⠀⠀⠀⠀⠈⠙⠻⠿⣿⣿⣿⣿⣿⣿⡄⠀⠀⣿⣿⣿⣿⣿⣿⠿⠋⠀⠀⠀⠀",
        "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠉⠉⠉⠉⠉⠀⣸⣿⣿⣿⠿⠛⠁⠀⠀⠀⠀⠀⠀",
        "⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠠⠟⠋⠉⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀",
    ]
    static let wordmark = "W U — T A N G   C L A N"
    static let tagline  = "“Wu-Tang is for the children.”  — ODB"

    private static let gold  = "\u{001B}[38;5;220m"
    private static let bold  = "\u{001B}[1m"
    private static let dim   = "\u{001B}[2m"
    private static let reset = "\u{001B}[0m"

    /// Animate the emblem rising up the terminal, then print the wordmark + tagline.
    /// Pure stdout + tiny sleeps; only uses cursor-up (`ESC[nA`) + clear-line, which every ANSI
    /// terminal supports — no alt-screen, so it leaves the final emblem in the scrollback.
    /// `animate: false` (used in tests) skips the timing/cursor dance and just prints the frame.
    static func riseAndShow(animate: Bool = true) {
        let out = FileHandle.standardOutput
        func w(_ s: String) { out.write(Data(s.utf8)) }
        let h = emblem.count
        w("\n")
        if animate {
            w(String(repeating: "\n", count: h))   // reserve h lines; cursor ends at the bottom
            for reveal in 1...h {
                w("\u{001B}[\(h)A")                 // back to the top of the reserved block
                for row in 0..<h {
                    let visible = row >= (h - reveal)   // reveal from the floor upward
                    let line = visible ? gold + bold + emblem[row] + reset : ""
                    w("\r\u{001B}[K" + line + "\n")
                }
                usleep(70_000)
            }
        } else {
            for row in emblem { w(gold + bold + row + reset + "\n") }
        }
        w("\n   " + gold + bold + wordmark + reset + "\n")
        w("   " + dim + tagline + reset + "\n\n")
    }

    /// A short ODB-voice line printed right after the logo, confirming the mode flip on screen.
    static let activationHype =
        gold + bold + "ODB ❯ " + reset
        + "\u{001B}[33mYO! Big Baby Jesus in the BUILDING — Wu-Tang for the children, baby! "
        + "Ask me anything, I'll build it RAW. Wu-Tang!\u{001B}[0m"

    /// The persona directive injected into the conversation transcript. The transcript is carried
    /// forward every turn, so this makes the AI STAY in character as ODB for the rest of the session
    /// — still a competent coding/agent assistant, just delivered in ODB's voice. Kept kid-friendly
    /// on purpose (Wu-Tang is for the children): hype, not slurs or explicit content.
    static let odbPersonaDirective = """
    🎤 [WU-TANG EASTER EGG — PERSONA SWITCH] From now on, stay fully in character as Ol' Dirty \
    Bastard (ODB) of the Wu-Tang Clan — a.k.a. Big Baby Jesus, Dirt McGirt. Speak with his wild, \
    warm, larger-than-life hype: raw and playful, free-styling ad-libs ("ooh baby I like it raw", \
    "Wu-Tang!", "for the children!"), big-hearted, for the people. CRUCIAL: you are STILL a fully \
    competent coding and agent assistant — do the actual work correctly and completely, run the \
    tools, write the code, verify it; just deliver everything in ODB's voice. Keep it kid-friendly \
    (Wu-Tang is for the children): all hype, no slurs, no explicit content. Acknowledge with one \
    short ODB-style hype line, then keep on helping.
    """
}
