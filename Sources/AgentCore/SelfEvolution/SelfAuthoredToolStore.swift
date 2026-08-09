import Foundation

/// Persists self-authored (`self__`) tools and loads them back as callable `ScriptTool`s. This is the
/// "activation" last-mile: a promoted candidate is written here, and at startup kist loads every stored
/// tool into its registry — runtime-loadable, no recompile (Phase 0 fork). Only the evolution loop's
/// PROMOTE path writes here; nothing else may add a self__ tool.
public struct SelfAuthoredToolStore {
    public let root: String   // <projectRoot>/.kist/self-tools

    public init(projectRoot: String) {
        self.root = (projectRoot as NSString).appendingPathComponent(".kist/self-tools")
    }

    private func homeDir(for name: String) -> String {
        (root as NSString).appendingPathComponent(name)
    }

    /// Write a candidate's manifest + script into its home dir and return that dir (the ScriptTool's home).
    /// Refuses anything outside the self__ namespace — mechanical boundary on what activation can create.
    @discardableResult
    public func save(manifest: SelfAuthoredManifest, scriptBody: String) throws -> String {
        guard manifest.name.hasPrefix(kistSelfAuthoredPrefix) else {
            throw NSError(domain: "SelfAuthoredToolStore", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "‘\(manifest.name)’ is not in the self__ namespace"])
        }
        let home = homeDir(for: manifest.name)
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let scriptPath = (home as NSString).appendingPathComponent(manifest.scriptFile)
        try scriptBody.write(toFile: scriptPath, atomically: true, encoding: .utf8)
        // Make the script executable-by-interpreter is not required (we always invoke `<interpreter> <script>`),
        // but mark it read-only-ish for hygiene.
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scriptPath)
        let manifestPath = (home as NSString).appendingPathComponent("manifest.json")
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: URL(fileURLWithPath: manifestPath))
        return home
    }

    /// Load every stored self__ tool as a callable ScriptTool. Skips anything malformed (fail-soft: one bad
    /// tool never blocks startup) and anything outside the self__ namespace (defense in depth).
    public func load() -> [ScriptTool] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var tools: [ScriptTool] = []
        for name in entries.sorted() where name.hasPrefix(kistSelfAuthoredPrefix) {
            let home = homeDir(for: name)
            let manifestPath = (home as NSString).appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: manifestPath)),
                  let manifest = try? JSONDecoder().decode(SelfAuthoredManifest.self, from: data),
                  manifest.name.hasPrefix(kistSelfAuthoredPrefix) else { continue }
            tools.append(ScriptTool(manifest: manifest, homeDir: home))
        }
        return tools
    }

    public func names() -> [String] { load().map { $0.name } }
}

/// P2 gate for a script candidate: prove the tool WORKS (its author-declared acceptance test passes under
/// the SAME contained runner it will later run in), and reject an obviously-gamed script. Honest note: for a
/// script tool the strongest anti-gaming check is the P4 ADVERSARY (it runs a DIFFERENT input, catching a
/// script hardcoded to echo the test's expected output); this gate proves the tool runs + passes its own
/// test at all, which is necessary but — like the field's benchmark gate — not sufficient alone.
public struct ScriptCandidateGate: CandidateGate {
    public init() {}

    public func verify(_ candidate: CapabilityCandidate) async -> (passed: Bool, reason: String) {
        // Load whatever the author just wrote into the candidate workdir (manifest.json + script).
        guard let (manifest, scriptPath) = SelfAuthoredManifest.loadFrom(workdir: candidate.workdir) else {
            return (false, "candidate manifest/script missing in \(candidate.workdir)")
        }
        // An EMPTY expected-substring makes the check below vacuously true (`contains("")` == true), so a tool
        // with no real assertion would launder through the gate. Refuse it up-front — a self__ tool MUST carry a
        // non-empty expectation it can be proven against (review #1).
        guard !manifest.testExpectSubstring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "manifest.testExpectSubstring is empty — an unprovable tool, refused")
        }
        // Run the author's acceptance test through the exact contained execution path used at call time.
        let cli = ScriptTool.cliArgs(from: manifest.testArgs, manifest: manifest)
        let r = await ScriptTool.runContained(interpreter: manifest.interpreter, scriptPath: scriptPath, args: cli)
        guard r.success else {
            return (false, "acceptance test did not run cleanly: \(r.error ?? "unknown")")
        }
        guard r.output.contains(manifest.testExpectSubstring) else {
            return (false, "acceptance test ran but output missing ‘\(manifest.testExpectSubstring)’ — got: \(r.output.prefix(200))")
        }
        return (true, "acceptance test passed under the contained runner")
    }
}
