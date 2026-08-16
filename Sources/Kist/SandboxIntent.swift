import Foundation

/// NATURAL-LANGUAGE SANDBOX CONTROL — "run it headless" / "run it in a small window at the top of my
/// screen" drive the isolated macOS-guest sandbox (`~/bin/vmsandbox`) directly, the same way
/// ControlIntentParser makes "switch to gemini" mutate the runtime: deterministic, no LLM, no task turn.
///
/// Conservative by design (a mention is not a command):
///   • Only short, directive-shaped messages fire (questions and long prose never do).
///   • "headless"/"window" alone is not enough when the sentence is about OTHER work ("run the tests
///     headless") — a sandbox/vm noun wins ties, a work noun blocks.
/// The executor shells to `vmsandbox`, which owns clone/persist/boot/login policy; kist adds no policy
/// of its own. Path: $KIST_VMSANDBOX override, else ~/bin/vmsandbox (no user-path literal).
enum SandboxIntent: Equatable {
    case run(mode: String, pos: String?)     // mode: headless|window|full; pos: top|topleft|center
    case stop
    case status

    // Nouns that name OUR sandbox/guest. "vm"/"guest" alone also appear in perslis/win98 asks — the
    // desktop/legacy router (PromptCompiler .desktop) claims those via richer phrases; these stay narrow.
    private static let sandboxNouns = ["sandbox", "isolated mac", "mac guest", "guest mac", "mybox",
                                       "the vm", "a vm", "virtual mac"]
    // Work nouns that mean the message is about something ELSE running headless (don't hijack).
    private static let workNouns = ["test", "build", "script", "pipeline", "dogfood", "agent", "loop",
                                    "server", "deploy", "browser", "chrome", "safari"]
    private static let questionLeads = ["what", "why", "how", "explain", "tell me", "is it", "does",
                                        "should", "could", "can the", "can it"]

    static func parse(_ message: String) -> SandboxIntent? {
        let t = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, t.count <= 140 else { return nil }                 // directives are short
        if questionLeads.contains(where: { t.hasPrefix($0) }) { return nil } // questions never fire
        let hasSandboxNoun = sandboxNouns.contains { t.contains($0) }
        let hasWorkNoun = workNouns.contains { t.contains($0) }
        // A named work noun blocks UNLESS the sandbox is also named explicitly ("sandbox" outranks).
        if hasWorkNoun && !hasSandboxNoun { return nil }

        // stop / status first (most specific)
        if hasSandboxNoun || t.contains("headless") || t.contains("window") {
            // stop requires the sandbox NAMED — a bare "close the window" is any window, not ours.
            if ["stop", "close", "shut down", "shutdown", "kill"].contains(where: { t.contains($0) }),
               hasSandboxNoun {
                return .stop
            }
            if t.contains("status") || t.hasSuffix("running") || t.contains("still up") {
                return hasSandboxNoun ? .status : nil
            }
        }

        let runVerb = ["run", "start", "boot", "launch", "open", "spin", "bring", "show", "go"]
            .contains { t.contains($0) }

        // WINDOW mode: wants to SEE it — "in a (small) window", "at the top of my screen", "show me".
        if t.contains("window") || t.contains("on my screen") || t.contains("let me see") {
            guard runVerb || hasSandboxNoun else { return nil }
            // "in a window"-shaped or sandbox-named — both are explicit enough.
            guard hasSandboxNoun || t.contains("in a window") || t.contains("in a small window")
                  || t.contains("small window") || t.contains("in the window") else { return nil }
            if t.contains("full") || t.contains("big window") || t.contains("large window") {
                return .run(mode: "full", pos: pos(in: t))
            }
            return .run(mode: "window", pos: pos(in: t))
        }

        // HEADLESS mode: "run it headless", "run headless", "start the sandbox headless".
        if t.contains("headless") {
            guard runVerb || hasSandboxNoun else { return nil }
            return .run(mode: "headless", pos: nil)
        }

        // Bare sandbox run with no presentation named → headless (the never-surprise default).
        if hasSandboxNoun, runVerb,
           ["run", "start", "boot", "launch", "spin up", "bring up"].contains(where: { t.contains($0) }) {
            return .run(mode: "headless", pos: nil)
        }
        return nil
    }

    private static func pos(in t: String) -> String? {
        if t.contains("top left") || t.contains("top-left") || t.contains("corner") { return "topleft" }
        if t.contains("center") || t.contains("centre") || t.contains("middle") { return "center" }
        if t.contains("top") { return "top" }
        return nil
    }

    /// Resolve the wrapper: $KIST_VMSANDBOX override, else ~/bin/vmsandbox. Nil (with a message) when
    /// absent — fail-fast, never a silent no-op.
    static func wrapperPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["KIST_VMSANDBOX"], !env.isEmpty { return env }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidate = home + "/bin/vmsandbox"
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// Run vmsandbox with live output in the terminal. Blocking is CORRECT here: boot+login is the
    /// user's foreground intent ("run it…"), and the wrapper's own waits are bounded (fail-fast inside).
    static func execute(_ intent: SandboxIntent) {
        guard let bin = wrapperPath() else {
            print("\u{001B}[31msandbox · vmsandbox not found (~/bin/vmsandbox or $KIST_VMSANDBOX)\u{001B}[0m")
            return
        }
        var args: [String]
        switch intent {
        case .run(let mode, let pos):
            args = [mode]
            if let pos { args += ["--pos", pos] }
        case .stop:   args = ["stop"]
        case .status: args = ["status"]
        }
        print("\u{001B}[37msandbox · vmsandbox \(args.joined(separator: " "))\u{001B}[0m")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        // Inherit stdio so boot/login progress streams live to the user.
        p.standardOutput = FileHandle.standardOutput
        p.standardError = FileHandle.standardError
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                print("\u{001B}[31msandbox · vmsandbox exited \(p.terminationStatus)\u{001B}[0m")
            }
        } catch {
            print("\u{001B}[31msandbox · failed to run vmsandbox: \(error.localizedDescription)\u{001B}[0m")
        }
    }
}
