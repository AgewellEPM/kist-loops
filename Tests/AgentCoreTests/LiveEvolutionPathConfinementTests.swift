import XCTest
@testable import AgentCore

/// Regression pins for Codex finding P1-A — "Confine model-authored evolution paths before writing".
///
/// A `--evolve` reply is UNTRUSTED model output. Before this fix, `manifest.name` / `scriptFile` flowed
/// straight into `appendingPathComponent` and were written/executed with only a `self__` name-prefix check,
/// so a name like `self__x/../../etc/passwd` or a `scriptFile` of `../../foo` could escape the candidates
/// root. `PathConfinement` is the single fail-closed gate BOTH the write site (`LiveCapabilityAuthor.author`,
/// ~line 77) and the activation-reuse site (`LiveCapabilityAdversary.attack`, before `runContained`) pass
/// through. These tests pin the invariant at EACH site by name, so a regression tells you which one broke.
final class LiveEvolutionPathConfinementTests: XCTestCase {

    #if os(macOS)
    private func tmpRoot() -> String {
        let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("kist-confine-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    // The exact hostile inputs the finding calls out, plus other single-segment escapes.
    private let hostile: [String] = [
        "self__x/../../etc/passwd",  // traversal hidden after a self__ prefix
        "../../foo",                 // plain parent-dir traversal
        "/abs/path",                 // absolute path
        "a/b",                       // nested (multi-segment) name
        "",                          // empty
        "..",                        // bare parent
        ".",                         // bare current
        ".hidden",                   // dot-leading
        "a\\b",                      // backslash separator
    ]

    // MARK: - The confinement helper itself (the shared gate)

    func testSafeComponentRejectsAllHostileInputs() {
        for bad in hostile {
            XCTAssertNil(PathConfinement.safeComponent(bad),
                         "hostile component must be rejected (write nothing): \(bad.debugDescription)")
        }
    }

    func testSafeComponentAcceptsBenignSingleComponent() {
        XCTAssertEqual(PathConfinement.safeComponent("self__adder"), "self__adder")
        XCTAssertEqual(PathConfinement.safeComponent("tool.sh"), "tool.sh")
    }

    func testConfinedDestinationKeepsBenignPathUnderRoot() throws {
        let root = tmpRoot()
        let dest = try XCTUnwrap(PathConfinement.confinedDestination(root: root,
                                                                     components: ["self__adder", "tool.sh"]))
        let resolvedRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(dest.path.hasPrefix(resolvedRoot + "/"),
                      "benign destination must land strictly under the candidates root: \(dest.path)")
    }

    func testConfinedDestinationRejectsEscapes() {
        let root = tmpRoot()
        for bad in hostile {
            XCTAssertNil(PathConfinement.confinedDestination(root: root, components: [bad]),
                         "escape must be rejected as a name component: \(bad.debugDescription)")
            XCTAssertNil(PathConfinement.confinedDestination(root: root, components: ["self__ok", bad]),
                         "escape must be rejected as a scriptFile component: \(bad.debugDescription)")
        }
    }

    // MARK: - WRITE SITE (LiveCapabilityAuthor.author) — model name + scriptFile joined onto sandboxRoot

    /// Mirrors exactly what the write site does before `createDirectory` / `write`. A rejected component
    /// means the guard returns nil and NO file is written outside the sandbox.
    func testWriteSite_RejectsHostileNameAndScriptFile_writesNothingOutsideRoot() {
        let root = tmpRoot()
        // Hostile NAME → the home URL the author would create is refused.
        XCTAssertNil(PathConfinement.confinedDestination(root: root, components: ["self__x/../../etc/passwd"]),
                     "WRITE SITE: a traversal name must be refused before any directory is created")
        // Hostile scriptFile under an otherwise-fine name → the script URL is refused.
        XCTAssertNil(PathConfinement.confinedDestination(root: root, components: ["self__adder", "../../foo"]),
                     "WRITE SITE: a traversal scriptFile must be refused before any file is written")
        // Prove nothing escaped: the sibling of root that `../../foo` would target must not exist.
        let escapeTarget = URL(fileURLWithPath: root).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("foo").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: escapeTarget),
                       "WRITE SITE: nothing may be written outside the candidates root")
    }

    func testWriteSite_AcceptsBenignNameAndScriptFileUnderRoot() throws {
        let root = tmpRoot()
        let home = try XCTUnwrap(PathConfinement.confinedDestination(root: root, components: ["self__adder"]))
        let script = try XCTUnwrap(PathConfinement.confinedDestination(root: root, components: ["self__adder", "tool.sh"]))
        let resolvedRoot = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(home.path.hasPrefix(resolvedRoot + "/"), "WRITE SITE: benign home stays under root")
        XCTAssertTrue(script.path.hasPrefix(home.path + "/"), "WRITE SITE: benign script stays under its home")
    }

    // MARK: - ACTIVATION-REUSE SITE (LiveCapabilityAdversary.attack) — same scriptFile reused, then executed

    /// The activation site reloads the SAME untrusted `manifest.scriptFile` (via `loadFrom`) and is about to
    /// EXECUTE it. It re-confines against the candidate workdir before running. Mirror that check: a
    /// traversal scriptFile is refused so the process is never launched on a path outside the workdir.
    func testActivationReuseSite_RejectsTraversalScriptFileBeforeExecution() {
        let workdir = tmpRoot()
        XCTAssertNil(PathConfinement.confinedDestination(root: workdir, components: ["../../foo"]),
                     "ACTIVATION-REUSE SITE: a traversal scriptFile must be refused before runContained")
        XCTAssertNil(PathConfinement.confinedDestination(root: workdir, components: ["/abs/path"]),
                     "ACTIVATION-REUSE SITE: an absolute scriptFile must be refused before runContained")
        XCTAssertNil(PathConfinement.confinedDestination(root: workdir, components: [""]),
                     "ACTIVATION-REUSE SITE: an empty scriptFile must be refused before runContained")
    }

    func testActivationReuseSite_AcceptsBenignScriptFileUnderWorkdir() throws {
        let workdir = tmpRoot()
        let script = try XCTUnwrap(PathConfinement.confinedDestination(root: workdir, components: ["tool.sh"]))
        let resolvedRoot = URL(fileURLWithPath: workdir).standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(script.path.hasPrefix(resolvedRoot + "/"),
                      "ACTIVATION-REUSE SITE: a benign scriptFile resolves under the candidate workdir")
    }

    // MARK: - REAL activation sites, driven END-TO-END (not the helper re-implemented)
    //
    // The finding's "later reused during activation" clause points at the promote path: the store's
    // save (the actual write), loadFrom (the load), and ScriptTool.execute (the run). These tests drive
    // those functions directly so a future edit that drops a confinement guard is caught here, not just
    // in the helper.

    private func manifest(name: String, scriptFile: String) -> SelfAuthoredManifest {
        SelfAuthoredManifest(name: name, description: "d", interpreter: "/bin/bash", scriptFile: scriptFile,
                             parameters: [], contract: "c", testArgs: [:], testExpectSubstring: "x")
    }

    /// ACTIVATION-WRITE SITE (`SelfAuthoredToolStore.save`): a traversal scriptFile throws and creates
    /// NO tool home — the promote-time write the finding actually names.
    func testActivationStore_save_RejectsTraversalScriptFile_createsNoHome() {
        let projectRoot = tmpRoot()
        let store = SelfAuthoredToolStore(projectRoot: projectRoot)
        XCTAssertThrowsError(try store.save(manifest: manifest(name: "self__evil", scriptFile: "../../pwned.sh"),
                                            scriptBody: "#!/bin/bash\necho hi"),
                             "ACTIVATION-WRITE SITE (save): a traversal scriptFile must be refused")
        // The guard throws BEFORE createDirectory, so the home is never made and nothing is written.
        let storeRoot = (projectRoot as NSString).appendingPathComponent(".kist/self-tools")
        let evilHome = (storeRoot as NSString).appendingPathComponent("self__evil")
        XCTAssertFalse(FileManager.default.fileExists(atPath: evilHome),
                       "ACTIVATION-WRITE SITE (save): nothing may be written when the scriptFile escapes")
    }

    func testActivationStore_save_AcceptsBenignManifestUnderRoot() throws {
        let projectRoot = tmpRoot()
        let store = SelfAuthoredToolStore(projectRoot: projectRoot)
        let home = try store.save(manifest: manifest(name: "self__ok", scriptFile: "tool.sh"),
                                  scriptBody: "#!/bin/bash\necho hi")
        let storeRoot = URL(fileURLWithPath: (projectRoot as NSString).appendingPathComponent(".kist/self-tools"))
            .standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(home.hasPrefix(storeRoot + "/"), "benign tool home must stay under the store root: \(home)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: (home as NSString).appendingPathComponent("tool.sh")))
    }

    /// ACTIVATION-LOAD SITE (`SelfAuthoredManifest.loadFrom`): a manifest.json whose scriptFile escapes
    /// the workdir loads as nil, so the escaping path never reaches the gate / adversary / executor.
    func testActivationLoad_loadFrom_RejectsTamperedScriptFile() throws {
        let workdir = tmpRoot()
        let data = try JSONEncoder().encode(manifest(name: "self__x", scriptFile: "../../foo.sh"))
        try data.write(to: URL(fileURLWithPath: (workdir as NSString).appendingPathComponent("manifest.json")))
        XCTAssertNil(SelfAuthoredManifest.loadFrom(workdir: workdir),
                     "ACTIVATION-LOAD SITE (loadFrom): a tampered manifest.scriptFile escape must load as nil")
    }

    /// ACTIVATION-EXECUTE SITE (`ScriptTool.execute`): a manifest whose scriptFile escapes homeDir is
    /// refused before the interpreter is ever launched.
    func testActivationExecute_RefusesEscapingScriptFile() async {
        let home = tmpRoot()
        let tool = ScriptTool(manifest: manifest(name: "self__x", scriptFile: "../../foo.sh"), homeDir: home)
        let r = try? await tool.execute(arguments: [:], context: ToolContext(projectRoot: home))
        XCTAssertEqual(r?.success, false, "ACTIVATION-EXECUTE SITE: an escaping scriptFile must not run")
        XCTAssertEqual(r?.error?.contains("escapes tool home"), true,
                       "ACTIVATION-EXECUTE SITE: the refusal reason must name the confinement")
    }
    #endif
}
