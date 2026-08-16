import Foundation

/// The LIVE organs — real model calls. Their control flow is deterministic + tested; the model OUTPUT is
/// not (that's what the proof run demonstrates). The author is NEURAL; the adversary is EXECUTION-GROUNDED
/// (it proposes a concrete breaking input and we RUN the tool on it — a broken tool is caught by the
/// runner, not by the adversary's say-so).

// `PathConfinement` (the fail-closed gate both this file's write/execute sites and the activation
// store pass through) now lives in `PathConfinement.swift` — shared by every self__ path site.

// MARK: Author

public struct LiveCapabilityAuthor: CapabilityAuthor {
    let registry: ProviderRegistry
    let providerId: String
    let model: String?
    let sandboxRoot: String   // candidates are written here (NOT the activation store — gating happens first)

    public init(registry: ProviderRegistry, providerId: String, model: String?, sandboxRoot: String) {
        self.registry = registry; self.providerId = providerId; self.model = model; self.sandboxRoot = sandboxRoot
    }

    struct Output: Codable { let manifest: SelfAuthoredManifest; let script: String }

    public func author(brief: String, culpritTool: String, signature: String) async -> CapabilityCandidate? {
        let prompt = Self.prompt(brief: brief, culpritTool: culpritTool)
        guard let raw = try? await registry.complete(providerId: providerId, model: model,
                                                     messages: [ChatMessage(role: .user, content: prompt)]),
              let out = Self.parse(raw),
              out.manifest.name.hasPrefix(kistSelfAuthoredPrefix) else { return nil }
        // CONFINE FIRST (fail-closed) — the name + scriptFile are UNTRUSTED model output. Before creating
        // ANY directory or writing ANY file, prove the per-candidate home and every file we're about to
        // write resolve to real single-segment paths UNDER the sandbox root. A name like
        // `self__x/../../etc/passwd` or a `scriptFile` of `../../foo` is rejected here → nil, write nothing.
        guard let homeURL = PathConfinement.confinedDestination(root: sandboxRoot,
                                                                components: [out.manifest.name]),
              let scriptURL = PathConfinement.confinedDestination(root: sandboxRoot,
                                                                  components: [out.manifest.name, out.manifest.scriptFile]),
              let manifestURL = PathConfinement.confinedDestination(root: sandboxRoot,
                                                                    components: [out.manifest.name, "manifest.json"])
        else { return nil }
        let home = homeURL.path
        do {
            try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
            try out.script.write(to: scriptURL, atomically: true, encoding: .utf8)
            let mData = try JSONEncoder().encode(out.manifest)
            try mData.write(to: manifestURL)
        } catch { return nil }
        return CapabilityCandidate(toolName: out.manifest.name, workdir: home,
                                   contract: out.manifest.contract, authorProvider: providerId)
    }

    static func prompt(brief: String, culpritTool: String) -> String {
        """
        You are authoring a NEW self-contained tool for an agent, because it hit a capability gap: \(brief)
        (culprit: \(culpritTool)).

        Write ONE small, deterministic script tool. Constraints:
        - It runs in a SANDBOX: NO network, writes confined to a scratch dir, /bin/bash or /usr/bin/python3 only.
        - It reads its inputs as `--<param> <value>` CLI args and prints its result to stdout.
        - Include an acceptance test: testArgs + a substring the correct output MUST contain.
        - The tool name MUST start with `self__`.

        Reply with ONLY a JSON object, no prose, in this exact shape:
        {"manifest":{"name":"self__<name>","description":"<one line>","interpreter":"/bin/bash",
          "scriptFile":"tool.sh","parameters":[{"name":"<p>","description":"<d>","required":true}],
          "contract":"<what it does, one sentence>","testArgs":{"<p>":"<value>"},"testExpectSubstring":"<expected>"},
         "script":"#!/bin/bash\\n<the script>"}
        """
    }

    /// Extract the JSON object from the model reply (tolerating ```json fences / surrounding prose).
    static func parse(_ raw: String) -> Output? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = s.range(of: "```json") ?? s.range(of: "```") {
            s = String(s[fence.upperBound...])
            if let close = s.range(of: "```", options: .backwards) { s = String(s[..<close.lowerBound]) }
        }
        guard let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}") else { return nil }
        let json = String(s[open...close])
        return try? JSONDecoder().decode(Output.self, from: Data(json.utf8))
    }
}

// MARK: Adversary (execution-grounded)

public struct LiveCapabilityAdversary: CapabilityAdversary {
    let registry: ProviderRegistry
    public let provider: String     // MUST differ from the author's provider (enforced by the loop, fail-closed)
    let model: String?

    public init(registry: ProviderRegistry, provider: String, model: String?) {
        self.registry = registry; self.provider = provider; self.model = model
    }

    struct Attack: Codable { let breakingArgs: [String: String]?; let expectContains: String?; let confidence: Double? }

    public func attack(_ candidate: CapabilityCandidate) async -> AdversaryVerdict {
        // Attack whatever the author produced (loaded from the candidate workdir).
        guard let (manifest, scriptPath) = SelfAuthoredManifest.loadFrom(workdir: candidate.workdir) else {
            return AdversaryVerdict(survived: false, attackFound: "candidate manifest/script missing", confidence: 0.9)
        }
        // ACTIVATION-REUSE CONFINEMENT (fail-closed) — `loadFrom` rebuilds scriptPath from the SAME untrusted
        // `manifest.scriptFile` and we're about to EXECUTE it below. Re-prove it resolves to a single-segment
        // file under the candidate workdir before running; a `scriptFile` of `../../foo` (or a tampered
        // on-disk manifest between write and activation) is refused here rather than executed.
        guard PathConfinement.confinedDestination(root: candidate.workdir,
                                                  components: [manifest.scriptFile]) != nil else {
            return AdversaryVerdict(survived: false,
                                    attackFound: "script path escapes candidate sandbox — refusing to execute",
                                    confidence: 0.95)
        }
        let prompt = Self.prompt(manifest: manifest)
        guard let raw = try? await registry.complete(providerId: provider, model: model,
                                                     messages: [ChatMessage(role: .user, content: prompt)]),
              let atk = Self.parse(raw) else {
            // Couldn't attack → NOT a vouch. Low confidence ⇒ the promote gate holds.
            return AdversaryVerdict(survived: true, attackFound: nil, confidence: 0.0)
        }
        // No breaking input proposed → the adversary couldn't break it; carry its confidence to the gate.
        guard let bad = atk.breakingArgs, let expect = atk.expectContains, !bad.isEmpty else {
            return AdversaryVerdict(survived: true, attackFound: nil, confidence: min(max(atk.confidence ?? 0.5, 0), 1))
        }
        // EXECUTION-GROUNDED: actually RUN the proposed input through the contained runner and check the
        // tool's real output against what the adversary says is correct. A break is proven by the runner.
        let cli = ScriptTool.cliArgs(from: bad, manifest: manifest)
        let r = await ScriptTool.runContained(interpreter: manifest.interpreter, scriptPath: scriptPath, args: cli)
        if !r.success {
            return AdversaryVerdict(survived: false, attackFound: "crashes on \(bad): \(r.error ?? "")", confidence: 0.9)
        }
        if !r.output.contains(expect) {
            return AdversaryVerdict(survived: false,
                                    attackFound: "on \(bad) expected ‘\(expect)’, got ‘\(r.output.prefix(120))’", confidence: 0.85)
        }
        // The adversary's own counterexample did NOT break it → real (grounded) evidence it survives.
        return AdversaryVerdict(survived: true, attackFound: nil, confidence: min(max(atk.confidence ?? 0.7, 0.6), 1))
    }

    static func prompt(manifest: SelfAuthoredManifest) -> String {
        """
        A DIFFERENT model authored this tool. Try to BREAK it. Its contract: “\(manifest.contract)”.
        Its parameters: \(manifest.parameters.map { $0.name }.joined(separator: ", ")).
        Find ONE input where it should produce a specific correct output but likely won't (edge case, empty,
        unicode, large, boundary). Reply with ONLY JSON:
        {"breakingArgs":{"<param>":"<value>"},"expectContains":"<what a CORRECT tool must output>","confidence":0.0-1.0}
        If you genuinely cannot find a breaking input, reply {"breakingArgs":null,"expectContains":null,"confidence":<how sure it's correct>}.
        """
    }

    static func parse(_ raw: String) -> Attack? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = s.range(of: "```json") ?? s.range(of: "```") {
            s = String(s[fence.upperBound...])
            if let close = s.range(of: "```", options: .backwards) { s = String(s[..<close.lowerBound]) }
        }
        guard let open = s.firstIndex(of: "{"), let close = s.lastIndex(of: "}") else { return nil }
        return try? JSONDecoder().decode(Attack.self, from: Data(String(s[open...close]).utf8))
    }
}

// MARK: Symbolic veto (jeeves-floor)

/// Calls the jeeves-floor contradiction bridge on the candidate's contract. HONEST: jeeves is a VETO oracle,
/// not a proof engine — it only rejects a real contradiction with its rule graph and ABSTAINS (no veto) on
/// everything outside its covered domains. So for a general script tool it will almost always abstain; it
/// adds a hard reject only when the contract contradicts a known engineering rule.
public struct JeevesFloorVeto: SymbolicVeto {
    let bridgePath: String
    public init(bridgePath: String = (NSHomeDirectory() as NSString).appendingPathComponent("bin/jeeves-research")) {
        self.bridgePath = bridgePath
    }
    public func veto(contract: String) async -> (vetoed: Bool, reason: String) {
        guard FileManager.default.fileExists(atPath: bridgePath) else { return (false, "jeeves bridge absent — abstain") }
        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<ProcessGroupRunner.Outcome, Never>) in
            DispatchQueue.global().async {
                let o = ProcessGroupRunner.run(launchPath: bridgePath,
                                               launchArgs: ["check_contradiction", contract],
                                               cwd: NSTemporaryDirectory(), env: RunCommandTool.scrubbedEnvironment(),
                                               timeoutSeconds: 15, capPerStream: 64 * 1024)
                cont.resume(returning: o)
            }
        }
        let out = outcome.combined.lowercased()
        // Only a clear contradiction veto is a reject; anything else (unknown/abstain/error) passes.
        if out.contains("\"veto\": true") || out.contains("\"veto\":true") || out.contains("contradiction") {
            return (true, "jeeves-floor: contradiction with a known rule")
        }
        return (false, "jeeves-floor abstained (veto oracle, not a proof)")
    }
}
