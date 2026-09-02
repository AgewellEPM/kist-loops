import Foundation

/// ACT-vs-ASK reversibility gate — the #1 conversational mechanism (Claude-Code's blast-radius rule):
/// *local + reversible → just do it; irreversible / high-blast-radius → stop and ask.* It lets the agent
/// move freely on safe work while a genuinely catastrophic action (rm -rf, force-push, curl|sh, a write
/// that escapes the project) BREAKS THROUGH "allow all" and re-asks — the difference between a collaborator
/// and a vending machine that will happily `rm -rf /` because you clicked "allow all" earlier.
///
/// Pure + conservative: only CLEARLY irreversible/catastrophic patterns are `.dangerous`, to avoid
/// crying wolf. Everything mutating-but-recoverable is `.mutating` (honors normal approval); read-only is
/// `.safe` (never prompts).
public enum ActionRisk: String, Sendable, Equatable {
    case safe        // read-only / no side effect → never needs approval
    case mutating    // changes state but is recoverable (in-project edit, local build) → normal approval
    case dangerous   // irreversible / high-blast-radius → ALWAYS ask, even past "allow all"
}

public enum ReversibilityClassifier {

    /// Tools with no durable side effect → never need approval. (`ask_user` is `.safe` too — asking IS
    /// the interaction, it needs no separate gate — but it's handled as its own case, not lumped here, so
    /// "read-only" keeps its literal meaning.)
    static let readOnlyTools: Set<String> = [
        // NOTE: fetch_url / web_search are deliberately NOT here — they route through the exfil gate
        // (see the `case "fetch_url", "web_search"` below). Adding them back makes the gate dead code.
        // analyze_media / media_clip are also NOT here — they UPLOAD to the Gemini Files API (remote side
        // effect + cost), so they're `.mutating` (default) and pinned active by ReversibilityClassifierTests.
        "read_file", "list_files", "glob_files", "search_code",
        "context_brain", "read_spreadsheet", "query_data",
    ]

    /// FIRST-token verbs that mark a namespaced MCP tool leaf as READ-ONLY. Strict ALLOWLIST —
    /// a foreign MCP tool is trusted-ungated ONLY when its leaf clearly reads; everything else is
    /// gated (fail-safe / default-deny). (Codex: a mutating-verb blocklist is inherently leaky.)
    static let mcpReadOnlyVerbs: Set<String> = [
        "get","list","read","find","search","show","describe","definition","declaration","implementation",
        "reference","references","hover","diagnostic","diagnostics","completion","complete","symbol","symbols",
        "signature","resolve","query","lookup","fetch","status","info","count","exists","has","inspect","view",
        "peek","outline","tree","help","document","documentation","capabilities","ping","health","screenshot",
        "snapshot","capture","log","logs","history","detail","details","summary",
    ]

    /// Generic read verbs that, STANDING ALONE as the whole leaf (`srv__get`), are too vague to
    /// prove read-only — the server fully controls what a bare `get` does. A real read tool names
    /// its object (`get_user`, `getStatus`) or is a specific read noun (`definition`). So a bare
    /// generic verb is gated (Codex HIGH #3); specific read nouns stay trusted even alone.
    static let mcpGenericReadVerbs: Set<String> = ["get","list","read","fetch","query","search","find","show","view","lookup"]

    /// ANY of these tokens anywhere in the leaf disqualifies it from read-only (a compound like
    /// `get_and_replace` / `getAndReplace` / `listAndArchive` mutates). Superset — err toward gating.
    static let mcpMutatingTokens: Set<String> = [
        "edit","write","apply","create","update","delete","remove","rename","move","drop","format","patch",
        "insert","replace","fix","commit","push","merge","overwrite","truncate","save","set","put","post",
        "upsert","mkdir","touch","exec","execute","run","install","deploy","publish","send","sync","add",
        "clear","reset","kill","stop","start","restart","modify","import","export","upload","download","mutate",
        // composite / side-effecting verbs Codex flagged as missing (HIGH #2, r1+r2):
        "archive","unarchive","append","store","restore","enable","disable","assign","unassign","close","open",
        "copy","link","unlink","subscribe","unsubscribe","grant","revoke","lock","unlock","schedule","cancel",
        "approve","reject","trigger","invoke","call","emit","dispatch","register","unregister","provision","destroy",
        "flush","purge","wipe","rollback","bulk","batch","process","submit","confirm","finalize","rotate","scale",
        "migrate","notify","toggle","attach","detach","bind","unbind","promote","demote","tag","untag","seed","drain",
    ]

    /// A conjunction anywhere means the leaf names TWO actions (`getAndReplace`, `list_and_archive`).
    /// A genuine read tool never does — so a conjunction ⇒ NOT read-only, regardless of the second
    /// verb. This closes the "read-first + <novel mutating verb>" class without an exhaustive blocklist.
    static let mcpConjunctions: Set<String> = ["and", "or", "then", "plus", "with"]

    /// R6 (2026-07-29): read-only tools of the LOCAL SYMBOLIC BRAIN (jeeves-floor) whose READ intent
    /// lives in the SECOND leaf token — `symbolic_QUERY`, `proof_SCORE`, `check_CONTRADICTION`,
    /// `ibm_cobol_ORACLE`, `engineering_RULES`, `explain`. The first-token verb gate (`isReadOnlyMCPTool`)
    /// only trusts the FIRST token, so it mis-classified all of these `.dangerous` — which SILENTLY
    /// DENIED the symbolic brain in autonomous `--loop` (NonDestructiveInteractor rejects dangerous),
    /// the exact mode that needs it. This is a tight PER-SERVER allowlist of proven-read leaves, NOT a
    /// loosening of the general verb sets. `teach_relation` MUTATES the floor and is deliberately
    /// ABSENT (stays gated). Keyed by the trusted local server id from `~/.mcp.json`.
    static let trustedReadOnlyServerLeaves: [String: Set<String>] = [
        "jeeves-floor": ["symbolic_query", "proof_score", "check_contradiction",
                         "explain", "ibm_cobol_oracle", "engineering_rules"],
        // Perslis gateway READ leaves (2026-08-19): lets an autonomous loop
        // poll a build/qualification cycle — build_STATUS, artifact_READ of a
        // receipt, gateway_CAPABILITIES — without a prompt. Every one is a
        // pure observation of gateway state; the gateway's own registry pins
        // their operation family as read. Mutating verbs (build_submit,
        // artifact_begin/chunk/commit, vm_*, *_execute) are deliberately
        // ABSENT: submitting a build compiles inside a VM and writes
        // artifacts — a real state change that keeps requiring approval.
        "perslis": ["build_status", "artifact_status", "artifact_read",
                    "gateway_capabilities", "gateway_identity",
                    "qualification_report", "perslis_info", "perslis_identity"],
        // TinkyVision observations return pixels/state only. Actuation and remote-control leaves
        // stay absent, so those remain dangerous even on this trusted local server.
        "tinky-vision-control": ["portal_state", "portal_snapshot", "portal_remote_status",
                                 "os_ax_check", "os_find_window", "os_focused_window",
                                 "os_list_apps", "os_screenshot", "vision_find_text"],
    ]

    /// True iff `name` is a known read-only tool of a trusted local server (see above). Matches the
    /// server prefix (before the FIRST `__`) AND the leaf (after the LAST `__`) — so a foreign server
    /// can't borrow the trust by reusing a leaf name, and `teach_relation` is never trusted.
    static func isTrustedReadOnlyMCPTool(_ name: String) -> Bool {
        guard let sep = name.range(of: MCPClientManager.namespaceSeparator) else { return false }
        let server = String(name[..<sep.lowerBound]).lowercased()
        guard let leaves = trustedReadOnlyServerLeaves[server],
              let leaf = mcpLeaf(name)?.lowercased() else { return false }
        return leaves.contains(leaf)
    }

    /// A namespaced external MCP tool (`server__leaf` — separator is `__`).
    public static func isMCPTool(_ name: String) -> Bool { name.contains(MCPClientManager.namespaceSeparator) }

    /// Leaf after the LAST `__` (so a server name containing `__` can't shift the leaf). Original case.
    static func mcpLeaf(_ name: String) -> String? {
        guard let r = name.range(of: MCPClientManager.namespaceSeparator, options: .backwards) else { return nil }
        return String(name[r.upperBound...])
    }

    /// Unicode-AWARE tokenizer: splits on `_ . / -` (and any non-alphanumeric), letter↔digit, and
    /// camelCase — including acronym runs (`getDELETE`→[get,delete], `HTTPServer`→[http,server]) and
    /// digits (`getDelete2Rows`→[get,delete,2,rows]). Unlike an ASCII regex, a non-ASCII letter is a
    /// LETTER here, so a homoglyph name (`getüpdate…`) glues into a non-read-verb first token and
    /// FAILS CLOSED (gated) instead of yielding a clean `get`. (Codex HIGH #1.)
    static func mcpLeafTokens(_ leaf: String) -> [String] {
        func cls(_ c: Character) -> Int { c.isNumber ? 3 : (c.isLetter ? (c.isUppercase ? 1 : 2) : 0) }
        let chars = Array(leaf)
        var tokens: [String] = []
        var cur = ""
        func flush() { if !cur.isEmpty { tokens.append(cur.lowercased()); cur = "" } }
        for i in chars.indices {
            let c = chars[i], k = cls(c)
            if k == 0 { flush(); continue }                                   // separator / punctuation
            if let last = cur.last {
                let p = cls(last)
                if (k == 3) != (p == 3) { flush() }                           // letter↔digit
                else if p == 2 && k == 1 { flush() }                          // lower→Upper
                else if p == 1 && k == 1, i + 1 < chars.count, cls(chars[i + 1]) == 2 { flush() } // acronym end
            }
            cur.append(c)
        }
        flush()
        return tokens
    }

    /// Read-only iff: FIRST token is a read verb, NO conjunction (two-action name), NO mutating
    /// token, and it isn't a bare generic verb. Fail-safe: anything ambiguous stays gated.
    public static func isReadOnlyMCPTool(_ name: String) -> Bool {
        if isTrustedReadOnlyMCPTool(name) { return true }   // R6: symbolic-brain read tools (2nd-token read verb)
        guard let leaf = mcpLeaf(name) else { return false }
        // A legit read-tool name is ASCII. ANY non-ASCII letter is a homoglyph-disguise vector
        // (a mutating verb after a separator can't be exact-matched against the ASCII verb sets),
        // so reject the whole leaf → gated. Closes the entire homoglyph class. (Codex r3 HIGH.)
        if leaf.contains(where: { $0.isLetter && !$0.isASCII }) { return false }
        let tokens = mcpLeafTokens(leaf)
        guard let first = tokens.first, mcpReadOnlyVerbs.contains(first) else { return false }
        if tokens.contains(where: { mcpConjunctions.contains($0) }) { return false }   // "getAndX" etc.
        if tokens.contains(where: { mcpMutatingTokens.contains($0) }) { return false }
        if tokens.count == 1 && mcpGenericReadVerbs.contains(first) { return false }    // bare `get`/`list`…
        return true
    }

    /// Host-control MCP verbs — mouse/keyboard/screen actuation a desktop MCP server exposes. Used to gate
    /// such MCP tools behind --enable-computer-use (council 2026-07-03). Targeted (not "all non-read MCP")
    /// so legit non-desktop MCP servers — github, databases, filesystem — keep working unarmed; the leaf is
    /// namespaced, so `clickhouse`-style false positives are unlikely, and arming is the escape hatch.
    static let hostControlMCPVerbs: Set<String> = [
        "click", "doubleclick", "rightclick", "press", "keypress", "key", "keystroke", "hotkey",
        "type", "tap", "hover", "move", "drag", "drop", "scroll", "swipe", "mouse", "keyboard",
        "cursor", "activate", "focus", "screenshot", "screencapture", "capture", "snapshot", "record",
    ]

    /// True iff `name` is an MCP tool whose leaf names a host-control (desktop actuation / screen capture) verb.
    public static func isHostControlMCPTool(_ name: String) -> Bool {
        guard isMCPTool(name), let leaf = mcpLeaf(name) else { return false }
        return Set(mcpLeafTokens(leaf)).contains { hostControlMCPVerbs.contains($0) }
    }

    /// Name-only read-only check (no args). CONSERVATIVE by design: a tool that is read-only for
    /// SOME arguments (e.g. `tasks list` vs `tasks add`, `custom_tool list` vs run) is reported
    /// NOT read-only here, because with only the name we can't prove the safe path. Callers that
    /// need a per-invocation verdict must use `assess(tool:args:projectRoot:)`.
    ///
    /// Intended for cosmetic/failure-framing decisions (e.g. "can this tool's failure have left
    /// uncommitted work?"), NOT for the approval gate. Erring toward "not read-only" keeps such
    /// framing on the safe side (never calls a mutating failure benign).
    public static func isDefinitelyReadOnly(_ tool: String) -> Bool {
        if readOnlyTools.contains(tool) { return true }
        if isMCPTool(tool) { return isReadOnlyMCPTool(tool) }
        return false
    }

    public static func assess(tool: String, args: [String: Any], projectRoot: String) -> ActionRisk {
        if readOnlyTools.contains(tool) { return .safe }
        // DEFAULT-DENY for external MCP tools: they bypass ConfinedRoot, so anything not PROVABLY
        // read-only is high-blast-radius → .dangerous (ALWAYS prompt, even past "allow all"), like
        // run_command. A leaf that clearly reads (definition/references/hover/get/list…) stays ungated.
        if isMCPTool(tool) { return isReadOnlyMCPTool(tool) ? .safe : .dangerous }
        switch tool {
        case "desktop_control", "ax_press", "tap", "point_click":
            // THE HANDS: real mouse/keyboard injection drives the live desktop — irreversible and
            // high-blast-radius, so .dangerous → ALWAYS prompt (even past "allow all"), never auto-run on a
            // .mutating pass. Defense-in-depth atop --enable-computer-use arming + the OS Accessibility gate.
            // (Council-mandated 2026-07-03: these fell through to .mutating and auto-ran in one-shot.)
            return .dangerous
        case "ask_user":
            return .safe   // a clarifying question needs no approval gate
        case "fetch_url", "web_search", "jeeves_research":
            // Research is normally safe — BUT an outbound request that EXFILTRATES (a URL embedding a
            // secret, or a long opaque data blob that looks like stolen file contents) is the lethal-
            // trifecta exfil channel and must be gated. Low false-positive: real research URLs/queries
            // don't carry your API keys or 80+ chars of base64.
            // Gate EVERY outbound-data field, not just url/query — `site` (web_search) is an exfil channel too.
            // jeeves_research (R6) sends its `query` to the Tavily-backed symbolic wheel — same exfil
            // surface, same gate, so it's freely reachable by autonomous loops unless the query looks stolen.
            let target = [args["url"] as? String, args["query"] as? String, args["site"] as? String]
                .compactMap { $0 }.joined(separator: " ")
            return urlLooksLikeExfil(target) ? .dangerous : .safe
        case "make_dir":
            return .mutating
        case "apply_patch":
            if let patch = args["patch"] as? String, ApplyPatch.touchesEscapingPath(patch, projectRoot: projectRoot) {
                return .dangerous   // a hunk targets a path outside the project root
            }
            return .mutating
        case "write_file", "edit_file":
            // A write that lands OUTSIDE the project is irreversible from the user's view (no git, no undo).
            if let path = (args["path"] as? String ?? args["file"] as? String),
               pathEscapesProject(path, projectRoot) { return .dangerous }
            return .mutating
        case "move_file":
            // Dangerous only if EITHER endpoint escapes the project (could clobber an external file).
            let from = args["from"] as? String, to = args["to"] as? String
            if let from, pathEscapesProject(from, projectRoot) { return .dangerous }
            if let to, pathEscapesProject(to, projectRoot) { return .dangerous }
            return .mutating
        case "run_command":
            // RunCommandTool accepts EITHER a shell string ("command"/"cmd") OR executable + args[] — fold
            // both into one string so a structured `{"executable":"git","args":["push","--force"]}` can't
            // evade the dangerous patterns (Codex HIGH: argv bypass).
            let shellCmd = (args["command"] as? String ?? args["cmd"] as? String ?? "")
            var combined = shellCmd
            if let exe = args["executable"] as? String {
                let argv = (args["args"] as? [Any])?.compactMap { $0 as? String } ?? []
                combined = ([exe] + argv).joined(separator: " ") + " " + shellCmd
            }
            return commandRisk(combined)
        case "custom_tool":
            // Listing generated tools is read-only. Creating/running a generated helper changes state or
            // runs code, so it stays in the normal approval/sandbox lane.
            if (args["action"] as? String)?.lowercased() == "list" { return .safe }
            return .mutating
        case "research_run":
            // Status inspection is read-only; every other action writes the research ledger and may
            // invoke web/browser/context gatherers.
            if (args["action"] as? String)?.lowercased() == "status" { return .safe }
            return .mutating
        case "tasks":
            // Listing/checking the shared board is read-only. Adding, starting, completing, blocking,
            // clearing, or attaching evidence mutates `.kist/plan.json`.
            let action = (args["action"] as? String ?? "list").lowercased()
            if action == "list" || action == "validate" || action == "check" { return .safe }
            return .mutating
        case "visual_verify":
            // Writes screenshots/reports under .kist/visual-runs and may launch a browser capture.
            return .mutating
        default:
            return .mutating   // browse / computer_control / any unknown mutating tool
        }
    }

    /// Collapse evasion noise before matching (Codex MED): lowercase, drop quotes, collapse all whitespace
    /// (tabs/newlines/multi-space) to single spaces, and strip leading `KEY=VAL` env-var prefixes. So
    /// `FOO=1 rm\t-rf /`, `rm '-rf' /`, and `git push   --force` all normalize to their canonical form.
    static func normalizeCommand(_ s: String) -> String {
        // Drop quotes and backslashes ENTIRELY (to empty, not space) so shell-lexing evasions reveal their
        // literal form: r''m → rm, rm '-rf' → rm -rf, and a backslash-newline continuation `rm \<nl>-rf`
        // becomes `rm <nl>-rf` (the newline is then collapsed by the whitespace split below) → rm -rf.
        var t = s.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
        var tokens = t.split { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }.map(String.init)
        while let first = tokens.first,
              first.range(of: "^[a-z_][a-z0-9_]*=", options: .regularExpression) != nil,
              !first.contains("/") {
            tokens.removeFirst()   // leading env-var assignment, e.g. FOO=1
        }
        t = tokens.joined(separator: " ")
        return t
    }

    /// Classify a shell command. TIGHT dangerous list — only clear catastrophes — so routine commands
    /// (ls, git commit, npm test, build) stay `.mutating` and don't nag. Over-flagging is SAFE here (an
    /// extra prompt); under-flagging is the catastrophe, so we normalize aggressively before matching.
    static func commandRisk(_ command: String) -> ActionRisk {
        let normalized = normalizeCommand(command)
        let c = " " + normalized + " "
        if c.contains(" git push ") &&
            (c.contains(" --force ") || c.contains(" -f ") || c.contains(" --force-with-lease ")) {
            return .dangerous
        }
        // Irreversible / high-blast-radius patterns.
        let dangerous: [String] = [
            "rm -rf", "rm -fr", "rm -r ", "rm --recursive", "rm -f /", " rmdir /",
            "git push --force", "git push -f", "push --force", "--force-with-lease",
            "git reset --hard", "git clean -",
            "sudo ", "doas ",
            "| sh", "| bash", "|sh", "|bash",   // pipe-to-shell remote exec
            "mkfs", "dd if=", "dd of=", "> /dev/sd", "of=/dev/",
            "shutdown", "reboot", "halt", "poweroff", "killall ",
            "chmod -r ", "chmod -r777", "chmod 777 /", "chown -r ",
            ":(){", "fork bomb",
            "npm publish", "yarn publish", "pod trunk push", "twine upload",
            "drop database", "drop table", "truncate table",
            "kubectl delete", "terraform destroy", "docker system prune",
            // HOST-CONTROL via shell — UI automation / screen capture that ESCAPES the sandbox and drives the
            // desktop on an Accessibility-granted machine. .dangerous so NonDestructive/interactive refuse it
            // (the shell route to the same capability that --enable-computer-use gates for tools). Codex High.
            "osascript", "cliclick", "screencapture", "shortcuts run", "system events",
        ]
        if dangerous.contains(where: { c.contains($0) }) { return .dangerous }
        return .mutating
    }

    /// True if a write path resolves OUTSIDE the project root (absolute-outside, or `..` escape). Symlinks
    /// in the existing prefix are resolved so a path through a symlinked dir is caught.
    static func pathEscapesProject(_ path: String, _ projectRoot: String) -> Bool {
        let target = path.hasPrefix("/")
            ? ToolContext.canonicalizeAllowingMissing(path)
            : ToolContext.canonicalizeAllowingMissing(projectRoot + "/" + path)
        let root = ToolContext.canonicalizeAllowingMissing(projectRoot)
        return !(target == root || target.hasPrefix(root + "/"))
    }

    /// A fetch URL / search query looks like EXFILTRATION if it (1) embeds a detectable secret (a key/token
    /// being shipped out), or (2) carries a long opaque high-entropy blob (≈base64 of file contents). Normal
    /// research URLs and natural-language queries trip neither — so this gates exfil with low false-positives.
    static func urlLooksLikeExfil(_ target: String) -> Bool {
        guard !target.isEmpty else { return false }
        // (1) a secret is present and being carried out.
        if SecretScanner.redactSecrets(in: target) != target { return true }
        // (2) data-shaped tokens (url/base64 charset). Flag if ANY single token is long (one big blob) OR
        // the COMBINED data length is large (the attacker fragmented it across delimiters to dodge a
        // single-token check) OR the whole target is suspiciously long.
        let blobs = target.split { !($0.isLetter || $0.isNumber || "+/=_-".contains($0)) }.map(String.init)
        let longest = blobs.map(\.count).max() ?? 0
        let combined = blobs.reduce(0) { $0 + $1.count }
        if longest >= 80 || combined >= 160 || target.count >= 300 { return true }
        return false
    }
}
