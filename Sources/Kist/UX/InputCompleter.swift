import Foundation

/// Tab-completion for the conversational REPL. It completes slash commands, provider/model/role
/// names, common subcommands, file paths, and a small best-effort project symbol index.
enum InputCompleter {
    struct Edit: Equatable {
        let range: Range<Int>
        let replacement: String
        let suggestions: [String]
        let completed: Bool
    }

    static let builtInCommands = [
        "/help", "/model", "/m", "/paste", "/v", "/media", "/preview", "/imgcat", "/reasoning", "/plan", "/goals", "/goal", "/goalmap", "/goal-map",
        "/tasks", "/todo", "/action", "/test", "/plan-execute", "/pe", "/research", "/council", "/consult",
        "/fleet-status", "/cockpit", "/fleet", "/team", "/roles", "/agent", "/agents",
        "/persona", "/personality", "/specialist", "/specialists", "/providers", "/health",
        "/probe", "/usage", "/autonomy", "/activity", "/pulse", "/summary", "/confidence", "/why", "/version", "/ver", "/changelog", "/whatsnew", "/failures", "/failure", "/logs", "/details", "/proof", "/bench", "/eval",
        "/replay", "/protocols", "/commands", "/save-chat", "/clear", "/exit", "/quit", "/q",
        "/chain", "/pipeline", "/copilot", "/cp", "/reflect", "/reflection", "/learn",
        "/knowledge", "/knowledge-debt", "/debt", "/teach", "/rules", "/organizational-rules",
        "/learning", "/model-learning", "/captain-learning",
        "/industry", "/intelligence", "/strategic-intelligence", "/strategic-intel",
        "/retrieve", "/recall",
        "/legal", "/legal-research", "/law", "/case-research",
        "/captain", "/strategy", "/organize", "/domain", "/domain-learning", "/research-first", "/sme",
        "/local-model", "/local-models", "/model-scout", "/model-acquire", "/acquire-model",
        "/model-run", "/run-model-acquire", "/hf", "/huggingface",
        "/self-heal", "/heal", "/fix-self", "/self-test", "/selftest",
        "/immune", "/immune-system", "/immune-check", "/evolve",
        "/simulate", "/simulation", "/sim", "/sandbox", "/risk",
        "/symbolic", "/workflow", "/workflows", "/compile-workflow",
        // full built-in coverage so the live glow is accurate (a real command must be listed to glow):
        "/wu-tang", "/wutang", "/wu", "/odb", "/bug-bounty", "/bounty", "/bb",
        "/mode", "/cortex", "/memory", "/remember", "/watch", "/play", "/auto", "/autopilot",
        "/doctor", "/providers-doctor", "/probe-providers", "/tools", "/capabilities", "/contract",
        "/think", "/thinking", "/role", "/team-roles", "/mcp-status", "/a2a", "/status",
        "/export-chat", "/transcript", "/review", "/dag", "/help",
        "/dashboard", "/kanban", "/kist-dashboard", "/fallout-dashboard", "/pipboy", "/pip-boy",
        "/fix", "/repair", "/build", "/dig", "/effort", "/ultra",
        "/ballbusting", "/ballbust", "/ball-busting", "/roast",
        "/scorecard", "/models", "/model-scorecard", "/trackrecord",
        "/eval", "/eval-suite", "/regression-suite", "/bench",
        "/audit", "/security", "/security-audit", "/vuln", "/sast"
    ]

    static let roleWords = [
        "planner", "architect", "worker", "researcher", "analyst", "coder", "builder",
        "developer", "critic", "reviewer", "verifier", "tester"
    ]

    static let subcommands = [
        "map", "add", "start", "done", "complete", "block", "clear", "save", "load", "delete",
        "profiles", "reset", "on", "off", "execute", "build", "new", "forge", "create", "show", "scout",
        "vet", "verify", "metadata", "allow", "gate"
    ]

    static func edit(line: String, cursor: Int, candidates: [String]) -> Edit? {
        let chars = Array(line)
        let safeCursor = max(0, min(cursor, chars.count))
        let range = tokenRange(in: chars, cursor: safeCursor)
        let prefix = String(chars[range])
        guard !prefix.isEmpty else { return nil }

        let matches = unique(candidates)
            .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !matches.isEmpty else { return nil }

        if matches.count == 1 {
            return Edit(range: range, replacement: matches[0], suggestions: matches, completed: true)
        }

        let common = commonPrefix(matches)
        if common.count > prefix.count {
            return Edit(range: range, replacement: common, suggestions: matches, completed: true)
        }
        return Edit(range: range, replacement: prefix, suggestions: matches, completed: false)
    }

    static func candidates(commands: [String],
                           providers: [String],
                           models: [String],
                           projectRoot: String,
                           symbolCache: () -> [String]) -> [String] {
        var out = builtInCommands
        out.append(contentsOf: commands.map { $0.hasPrefix("/") ? $0 : "/\($0)" })
        out.append(contentsOf: providers)
        out.append(contentsOf: models)
        out.append(contentsOf: roleWords)
        out.append(contentsOf: subcommands)
        out.append(contentsOf: shallowPaths(projectRoot: projectRoot))
        out.append(contentsOf: symbolCache())
        return unique(out)
    }

    static func projectSymbols(projectRoot: String, maxFiles: Int = 300, maxSymbols: Int = 500) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: projectRoot) else { return [] }
        let sourceExts: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "java", "kt", "c", "h", "cpp", "hpp"]
        var symbols: [String] = []
        var files = 0
        while let item = e.nextObject() as? String, files < maxFiles, symbols.count < maxSymbols {
            if item.hasPrefix(".git/") || item.contains("/.build/") || item.contains("/node_modules/") { continue }
            let url = URL(fileURLWithPath: projectRoot).appendingPathComponent(item)
            guard sourceExts.contains(url.pathExtension.lowercased()),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            files += 1
            symbols.append(contentsOf: extractSymbols(from: text))
        }
        return Array(unique(symbols).prefix(maxSymbols))
    }

    static func extractSymbols(from text: String) -> [String] {
        let patterns = [
            #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            #"\b(?:struct|class|enum|protocol|interface|type)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            #"\b(?:let|var|const)\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            #"\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            #"\bdef\s+([A-Za-z_][A-Za-z0-9_]*)"#,
            #"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)"#
        ]
        var out: [String] = []
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            for match in re.matches(in: text, range: range).prefix(200) where match.numberOfRanges > 1 {
                out.append(ns.substring(with: match.range(at: 1)))
            }
        }
        return out
    }

    private static func shallowPaths(projectRoot: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: projectRoot) else { return [] }
        return names
            .filter { !$0.hasPrefix(".git") && !$0.hasPrefix(".build") }
            .prefix(200)
            .flatMap { name -> [String] in
                let path = URL(fileURLWithPath: projectRoot).appendingPathComponent(name).path
                var isDir: ObjCBool = false
                _ = fm.fileExists(atPath: path, isDirectory: &isDir)
                let suffix = isDir.boolValue ? "/" : ""
                return [name + suffix, "./" + name + suffix]
            }
    }

    private static func tokenRange(in chars: [Character], cursor: Int) -> Range<Int> {
        var start = cursor
        var end = cursor
        func boundary(_ c: Character) -> Bool { c == " " || c == "\t" || c == "\n" || c == "\"" || c == "'" }
        while start > 0, !boundary(chars[start - 1]) { start -= 1 }
        while end < chars.count, !boundary(chars[end]) { end += 1 }
        return start..<end
    }

    private static func commonPrefix(_ values: [String]) -> String {
        guard var prefix = values.first else { return "" }
        for value in values.dropFirst() {
            while !value.lowercased().hasPrefix(prefix.lowercased()), !prefix.isEmpty {
                prefix.removeLast()
            }
        }
        return prefix
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where !value.isEmpty {
            let key = value.lowercased()
            if seen.insert(key).inserted { out.append(value) }
        }
        return out
    }
}
