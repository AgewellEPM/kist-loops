import XCTest
@testable import AgentCore

final class ToolEffectsTests: XCTestCase {
    func testCatalogClassifiesMutationsFromLiveArguments() {
        let unconfirmed = ToolEffectCatalog.observe(
            tool: "edit_file", arguments: ["path": "Sources/App/Main.swift"]
        )
        XCTAssertEqual(unconfirmed.mutation, .source)
        XCTAssertEqual(unconfirmed.mutationEvidence, .mayMutate)
        XCTAssertFalse(unconfirmed.confirmsMutation)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "write_file", arguments: ["path": "README.md"]
        ).mutation, .nonSource)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "make_dir", arguments: ["path": "Sources/NewFeature"]
        ).mutation, .nonSource)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "ast_grep_apply", arguments: ["path": "."]
        ).mutation, .unknownTarget)
    }

    func testPatchClassificationConsidersEveryTarget() {
        let docsOnly = """
        *** Begin Patch
        *** Update File: README.md
        *** Add File: docs/usage.md
        *** End Patch
        """
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "apply_patch", arguments: ["patch": docsOnly]
        ).mutation, .nonSource)

        let mixed = docsOnly.replacingOccurrences(of: "docs/usage.md", with: "Sources/Usage.swift")
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "apply_patch", arguments: ["patch": mixed]
        ).mutation, .source)
    }

    func testCommandsAreInvocationSensitive() {
        let ls = ToolEffectCatalog.observe(tool: "run_command", arguments: ["command": "ls -la"])
        XCTAssertEqual(ls.verification, .nonVerifyingCommand)
        XCTAssertFalse(ls.advancesBuild)

        // Full live arguments are not clipped at the old 40-character fingerprint boundary.
        let test = ToolEffectCatalog.observe(
            tool: "run_command",
            arguments: ["command": "cd /a/very/long/project/path/that/exceeds/forty/characters && swift test"]
        )
        XCTAssertEqual(test.verification, .buildOrTest)
        XCTAssertTrue(test.advancesBuild)
    }

    func testLiveCommandClassificationMatchesExecutorPrecedenceAndTypes() {
        let conflicting: [String: Any] = [
            "executable": "true", "args": [String](), "command": "swift test",
        ]
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "run_command", arguments: conflicting
        ).verification, .nonVerifyingCommand,
        "the executor runs executable+args when both forms are present")

        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "run_command", arguments: ["cmd": "swift test"]
        ).verification, .nonVerifyingCommand,
        "cmd is not accepted by RunCommandTool and cannot become evidence")

        let wrongArrayType: [String: Any] = [
            "executable": "swift", "args": ["test", 1] as [Any],
        ]
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "run_command", arguments: wrongArrayType
        ).verification, .nonVerifyingCommand,
        "the classifier must use the same [String] cast as the executor")
    }

    func testQuotedAndInspectionMentionsDoNotMasqueradeAsVerification() {
        let nonVerifiers = [
            #"echo "swift test""#,
            #"printf 'npm test\n'"#,
            #"grep "cargo test" README.md"#,
            #"echo done # swift test"#,
            #"'swift test'"#, // one quoted executable name, not the `swift` executable plus `test`
        ]
        for command in nonVerifiers {
            let effect = ToolEffectCatalog.observe(tool: "run_command", arguments: ["command": command])
            XCTAssertEqual(effect.verification, .nonVerifyingCommand, command)
        }
    }

    func testRealCommandSegmentsAndExplicitShellCommandsVerify() {
        let verifiers = [
            "echo preparing && swift test",
            "cd Package && npm run build",
            "swift test && echo done",
            #"sh -c "go test ./...""#,
            #"sh -c "cd Package && go test ./...""#,
            "gradle test", "mvn test", "ruff check .", "ruff format --check .",
            "python -m ruff check .", "python -m tox", "pre-commit run --all-files",
            "rubocop app.rb", "flake8 .",
        ]
        for command in verifiers {
            let effect = ToolEffectCatalog.observe(tool: "run_command", arguments: ["command": command])
            XCTAssertEqual(effect.verification, .buildOrTest, command)
        }
    }

    func testVerifierExecutableMustBeATrustedBareToken() {
        for command in [
            "/repo/swift test", "./swift test", "tools/npm test", "/tmp/env swift test",
        ] {
            XCTAssertEqual(ToolEffectCatalog.observe(
                tool: "run_command", arguments: ["command": command]
            ).verification, .nonVerifyingCommand, command)
        }

        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "run_command", arguments: ["executable": "/repo/swift", "args": ["test"]]
        ).verification, .nonVerifyingCommand,
        "structured argv must not let a project-local binary impersonate a trusted verifier")
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "run_command", arguments: ["executable": "swift", "args": ["test"]]
        ).verification, .buildOrTest)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "run_command", arguments: ["command": "env swift test"]
        ).verification, .buildOrTest,
        "a supported bare wrapper around a supported bare verifier remains proof")
    }

    func testComposedCommandsCannotLaunderVerifierSuccess() {
        let bypasses = [
            "swift test || true", "true || swift test", "swift test; true", "swift test\ntrue",
            "swift test | tee test.log", "swift test & wait", "! swift test",
            #"sh -c "swift test || true""#, #"sh -c "! swift test""#,
        ]
        for command in bypasses {
            XCTAssertEqual(ToolEffectCatalog.observe(
                tool: "run_command", arguments: ["command": command]
            ).verification, .nonVerifyingCommand, command)
        }
    }

    func testShellExpansionCannotSynthesizeVerifierArgumentsAfterClassification() {
        let expanded = [
            #"KIST_FLAGS=--skip-build sh -c 'swift test $KIST_FLAGS'"#,
            #"export KIST_FLAGS=--skip-build && swift test $KIST_FLAGS"#,
            #"set -- --skip-build && swift test "$@""#,
            #"swift test ${KIST_FLAGS:---skip-build}"#,
            #"swift test $((1 + 1))"#,
            #"swift test $(printf -- --skip-build)"#,
            #"swift test $'--skip-build'"#,
            #"swift test --skip-buil?"#,
        ]
        for command in expanded {
            XCTAssertEqual(ToolEffectCatalog.observe(
                tool: "run_command", arguments: ["command": command]
            ).verification, .nonVerifyingCommand, command)
        }

        // These metacharacters are inert data in single quotes (and a glob is inert in double quotes).
        for command in [#"echo '$KIST_FLAGS' && swift test"#,
                        #"echo '$(not executed)' && swift test"#,
                        #"swift test --filter 'Suite.*'"#,
                        #"swift test --filter "Suite.*""#] {
            XCTAssertEqual(ToolEffectCatalog.observe(
                tool: "run_command", arguments: ["command": command]
            ).verification, .buildOrTest, command)
        }
    }

    func testIntrospectionAndDiscoveryCommandsDoNotVerify() {
        let commands = [
            "swift --version", "swift test --help", "swift test --list-tests", "pytest --collect-only",
            "pytest --fixtures", "pytest --markers", "pytest -V", "jest --listTests", "jest --showConfig",
            "ctest -N", "tsc -v", "tsc --showConfig", "xcodebuild -list", "xcodebuild -version",
            "xcodebuild -showBuildSettings", "xcodebuild -help", "make -n test", "make -q test",
            "npm test -- --help", "npm test --if-present", "gradle test --dry-run", "gradle -m test",
            "command -v swift test", "env command -V swift test", "rspec --dry-run", "vitest list",
            "phpunit --list-tests", "ctest --show-only", "eslint --print-config app.js",
            "ruff check --show-settings", "gcc -dumpversion", "ruby -c /dev/null", "node --check /dev/null",
            "env --help swift test", "env --version swift test", "time --help swift test",
            "nice --help swift test", "swift test --skip-build", "xcodebuild test-without-building",
            "cmake --build build --target help", "cmake --build build --target clean",
            "dotnet test --no-build --list-tests", "bazel test --nobuild", "tsc --init",
            "tsc --listFilesOnly", "jest --clearCache", "rspec --init", "ruff clean",
            "ctest --show-only=json-v1", "ctest --print-labels",
            #"sh -n -c "swift test""#, #"bash --help -c "swift test""#,
            "xcodebuild -checkFirstLaunchStatus", "xcodebuild -license check",
            "ruby -c -", "ruby -c /dev/stdin", "node --check -", "node --check /dev/stdin",
            "clang /tmp/trivial.c", "gcc ../unrelated.c",
            "swift test --show-codecov-path", "swift build --print-manifest-job-graph",
            "swift build --print-pif-manifest-graph", "go build -n", "go test -n",
            "make -t test", "make --touch test", "cmake --build build -t clean",
            "cmake --build build --target=help", "cmake --build build -- -n",
            "tsc -b --dry", "tsc -b --clean",
            "gradle help --task build", "gradle tasks --group build",
            "mvn test --fail-never", "mvn test -fn", "mvn test -Dmaven.test.failure.ignore=true",
            "mvn test -Dmaven.test.failure.ignore",
            "ruff format .", "python -m ruff format .", "python -m ruff clean",
            "tox --showconfig", "python -m tox --showconfig", "tox list",
            "pre-commit install", "rubocop --init", "flake8 --bug-report",
        ]
        for command in commands {
            XCTAssertEqual(ToolEffectCatalog.observe(
                tool: "run_command", arguments: ["command": command]
            ).verification, .nonVerifyingCommand, command)
        }
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "run_command", arguments: ["command": "pytest -v"]
        ).verification, .buildOrTest)
    }

    func testBuildAndOracleConfigurationChangesRequireFreshVerification() {
        for path in [
            "package.json", "pyproject.toml", "Cargo.lock", "requirements-dev.txt",
            ".github/workflows/ci.yml", "tsconfig.build.json", "CMakeLists.txt",
        ] {
            XCTAssertEqual(ToolEffectCatalog.mutationKind(forPath: path), .source, path)
        }
        XCTAssertEqual(ToolEffectCatalog.mutationKind(forPath: "fixtures/data.json"), .nonSource)
        XCTAssertEqual(ToolEffectCatalog.mutationKind(forPath: "docs/config.yml"), .nonSource)
    }

    func testShellMutatorsAreRecordedWithoutMatchingQuotedMentions() {
        for command in [
            "git apply fix.patch",
            "sed -i.bak 's/old/new/' Sources/App.swift",
            "printf 'let x = 1' > Sources/Generated.swift",
            "python3 -c 'open(\"Sources/X.swift\", \"w\").write(\"x\")'",
        ] {
            let effect = ToolEffectCatalog.observe(tool: "run_command", arguments: ["command": command])
            XCTAssertTrue(effect.requiresBuildVerification, command)
        }

        for command in [#"echo "git apply fix.patch""#, #"grep 'sed -i' README.md"#, "echo ok > /dev/null"] {
            let effect = ToolEffectCatalog.observe(tool: "run_command", arguments: ["command": command])
            XCTAssertEqual(effect.mutation, .none, command)
        }
    }

    func testAutoFixingLintersRemainMutationsThatNeedFreshProof() {
        for command in [
            "ruff format .", "ruff check --fix .", "ruff check --fix-only .",
            "python -m ruff format .", "python -m ruff check --fix .",
            "rubocop -A app.rb", "rubocop --autocorrect app.rb",
            "eslint --fix .", "eslint --fix=true .", "cargo clippy --fix",
            "jest --updateSnapshot", "jest --updateSnapshot=true", "jest -u",
            "vitest --update", "vitest --update=true", "vitest -u",
            "pre-commit run --all-files",
        ] {
            let effect = ToolEffectCatalog.observe(tool: "run_command", arguments: ["command": command])
            XCTAssertTrue(effect.requiresBuildVerification, command)
        }
    }

    func testEslintFixDryRunVerifiesWithoutClaimingAMutation() {
        let effect = ToolEffectCatalog.observe(
            tool: "run_command", arguments: ["command": "eslint --fix-dry-run ."]
        )
        XCTAssertEqual(effect.verification, .buildOrTest)
        XCTAssertEqual(effect.mutation, .none)
    }

    func testAutoFixingVerifierCannotSupplyItsOwnFreshProof() {
        let sourceEdit = ActionRecord(
            tool: "edit_file", argsFingerprint: "path=src/App.ts", success: true,
            effectObservation: ToolEffectObservation(mutation: .source)
        )
        for command in [
            "eslint --fix .", "cargo clippy --fix", "jest --updateSnapshot",
            "vitest --update", "pre-commit run --all-files",
        ] {
            let effect = ToolEffectCatalog.observe(
                tool: "run_command", arguments: ["command": command]
            )
            XCTAssertEqual(effect.verification, .buildOrTest, command)
            XCTAssertTrue(effect.requiresBuildVerification, command)
            let fixingVerifier = ActionRecord(
                tool: "run_command", argsFingerprint: "command=\(command)", success: true,
                effectObservation: effect
            )
            XCTAssertFalse(CompletionVerifier().check(
                trajectory: [sourceEdit, fixingVerifier], canRunCommands: true
            ).isAccept, "a mutating verifier must be followed by fresh proof: \(command)")
        }
    }

    func testUnknownExecutablesAndCommandSubstitutionMayMutate() {
        for command in [
            "./scripts/project-fixer",
            "python3 scripts/project_fixer.py",
            #"echo "$(touch Sources/Generated.swift)""#,
            "echo `./unknown-helper`",
        ] {
            let effect = ToolEffectCatalog.observe(tool: "run_command", arguments: ["command": command])
            XCTAssertEqual(effect.mutation, .unknownTarget, command)
        }

        for command in [
            "ls -la", "pwd", "rg TODO Sources", "git status --short", "git diff --check",
            #"echo '$(touch Sources/quoted.swift)'"#, // single quotes make substitution inert
            "swift test 2>&1",
        ] {
            let effect = ToolEffectCatalog.observe(tool: "run_command", arguments: ["command": command])
            XCTAssertEqual(effect.mutation, .none, command)
        }
        XCTAssertEqual(
            ToolEffectCatalog.observe(tool: "run_command", arguments: ["command": "swift test 2>&1"]).verification,
            .buildOrTest
        )
    }

    func testCustomAndMCPUnknownEffectsFailConservative() {
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "custom_tool", arguments: ["action": "list"]
        ).mutation, .none)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "custom_tool", arguments: ["action": "run", "name": "helper"]
        ).mutation, .unknownTarget)

        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "github__get_issue", arguments: ["number": 1]
        ).mutation, .none)
        let external = ToolEffectCatalog.observe(
            tool: "filesystem__write_file", arguments: ["path": "Sources/App.swift"]
        )
        XCTAssertEqual(external.mutation, .none)
        XCTAssertEqual(external.progress, .externalState)
    }

    func testUnknownMutatorCannotCompleteWithoutLaterVerification() {
        let mutation = ActionRecord(
            tool: "run_command", argsFingerprint: "command=git apply fix.patch", success: true,
            effectObservation: ToolEffectCatalog.observe(
                tool: "run_command", arguments: ["command": "git apply fix.patch"])
        )
        guard case .needsVerification = CompletionVerifier().check(
            trajectory: [mutation], canRunCommands: true, taskIntent: .build
        ) else { return XCTFail("a successful may-mutate command must remain unverified") }

        let verification = ActionRecord(
            tool: "run_command", argsFingerprint: "command=swift test", success: true,
            effectObservation: ToolEffectCatalog.observe(
                tool: "run_command", arguments: ["command": "swift test"])
        )
        XCTAssertFalse(CompletionVerifier().check(
            trajectory: [mutation, verification], canRunCommands: true,
            expectedOutcome: .mutation, taskIntent: .build
        ).isAccept, "a may-mutate shell call plus passing tests is still not an observed deliverable")
    }

    func testExplicitFileToolsConfirmOnlyObservedChanges() async throws {
        let root = NSTemporaryDirectory() + "tool-effects-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let context = ToolContext(projectRoot: root)
        let writeArgs: [String: Any] = ["path": "Sources/App.swift", "content": "let value = 1\n"]

        let first = try await WriteFileTool().execute(arguments: writeArgs, context: context)
        let changed = ToolEffectCatalog.observe(tool: "write_file", arguments: writeArgs,
                                                outcomeMetadata: first.metadata)
        XCTAssertEqual(first.metadata["changed"], "true")
        XCTAssertTrue(changed.confirmsMutation)

        let second = try await WriteFileTool().execute(arguments: writeArgs, context: context)
        let unchanged = ToolEffectCatalog.observe(tool: "write_file", arguments: writeArgs,
                                                  outcomeMetadata: second.metadata)
        XCTAssertEqual(second.metadata["changed"], "false")
        XCTAssertEqual(unchanged, .none)

        let noOpArgs: [String: Any] = [
            "path": "Sources/App.swift", "old_text": "let value = 1", "new_text": "let value = 1",
        ]
        let noOpEdit = try await EditFileTool().execute(arguments: noOpArgs, context: context)
        XCTAssertEqual(noOpEdit.metadata["changed"], "false")
        XCTAssertFalse(ToolEffectCatalog.observe(tool: "edit_file", arguments: noOpArgs,
                                                 outcomeMetadata: noOpEdit.metadata).confirmsMutation)

        let editArgs: [String: Any] = [
            "path": "Sources/App.swift", "old_text": "let value = 1", "new_text": "let value = 2",
        ]
        let realEdit = try await EditFileTool().execute(arguments: editArgs, context: context)
        let realEffect = ToolEffectCatalog.observe(tool: "edit_file", arguments: editArgs,
                                                   outcomeMetadata: realEdit.metadata)
        XCTAssertEqual(realEdit.metadata["changed"], "true")
        XCTAssertTrue(realEffect.confirmsMutation)

        let verification = ToolEffectCatalog.observe(
            tool: "run_command", arguments: ["command": "swift test"])
        let trajectory = [
            ActionRecord(tool: "edit_file", argsFingerprint: "path=Sources/App.swift", success: true,
                         effectObservation: realEffect),
            ActionRecord(tool: "run_command", argsFingerprint: "command=swift test", success: true,
                         effectObservation: verification),
        ]
        XCTAssertTrue(CompletionVerifier().check(
            trajectory: trajectory, canRunCommands: true, expectedOutcome: .mutation,
            taskIntent: .build).isAccept)
    }

    func testCatalogKeepsInternalAndExternalStateOutOfWorkspaceMutation() {
        let cases: [(String, [String: Any], ToolEffectObservation.Progress)] = [
            ("tasks", ["action": "add"], .taskBoard),
            ("cortex", ["action": "remember"], .memory),
            ("remember", ["text": "preference"], .memory),
            ("job", ["action": "kill"], .externalState),
            ("analyze_media", ["path": "movie.mp4"], .evidence),
        ]
        for (tool, args, progress) in cases {
            let effect = ToolEffectCatalog.observe(tool: tool, arguments: args)
            XCTAssertEqual(effect.progress, progress, tool)
            XCTAssertFalse(effect.confirmsMutation, tool)
        }
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "tasks", arguments: ["action": "list"]).progress, .none)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "cortex", arguments: ["action": "recall"]).progress, .none)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "research_run", arguments: ["action": "synthesize"]
        ).progress, .none, "a synthesis request alone is not observed research evidence")
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "research_run", arguments: ["action": "search"],
            outcomeMetadata: ["evidence_id": "e-1"]
        ).progress, .research)
    }

    func testMediaArtifactsNeedChangedEvidenceAndBackgroundLaunchDoesNotVerify() {
        let args: [String: Any] = ["out": "Artifacts/result.png"]
        let possible = ToolEffectCatalog.observe(tool: "generate_image", arguments: args,
                                                 outcomeMetadata: ["path": "Artifacts/result.png"])
        XCTAssertEqual(possible.mutation, .nonSource)
        XCTAssertEqual(possible.mutationEvidence, .mayMutate)
        XCTAssertFalse(possible.confirmsMutation)
        XCTAssertEqual(ToolEffectCatalog.observe(
            tool: "generate_image", arguments: args, outcomeMetadata: ["changed": "false"]
        ).mutation, .none)
        XCTAssertFalse(ToolEffectCatalog.observe(
            tool: "generate_image", arguments: args, outcomeMetadata: ["changed": "true"]
        ).confirmsMutation, "changed=true without a confined actual target is not proof")
        XCTAssertTrue(ToolEffectCatalog.observe(
            tool: "generate_image", arguments: args,
            outcomeMetadata: ["changed": "true", "artifact_path": "Artifacts/result.png",
                              "artifact_kind": "file", "artifact_confined": "true"]
        ).confirmsMutation)

        let background = ToolEffectCatalog.observe(
            tool: "run_command", arguments: ["command": "swift test", "background": true])
        XCTAssertEqual(background.verification, .none)
        XCTAssertEqual(background.progress, .externalState)
    }

    func testDelegationProgressIsSeparateAndIntentScoped() {
        let effect = ToolEffectCatalog.observe(tool: "spawn_agent", arguments: ["task": "implement"])
        XCTAssertEqual(effect.mutation, .none)
        XCTAssertEqual(effect.verification, .none)
        XCTAssertEqual(effect.progress, .delegation)
        XCTAssertTrue(effect.advances(intent: .fleet))
        XCTAssertFalse(effect.advances(intent: .build))
    }

    func testOldActionRecordJSONDecodesAndInfersEffects() throws {
        let json = #"{"tool":"edit_file","argsFingerprint":"content=x&path=Sources/App.swift","success":true}"#
        let record = try JSONDecoder().decode(ActionRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.effectObservation)
        XCTAssertEqual(record.observedEffects.mutation, .source)
    }

    func testExplicitObservationRoundTripsAndOverridesLegacyNameInference() throws {
        let original = ActionRecord(
            tool: "future_refactor_tool", argsFingerprint: "opaque", success: true,
            effectObservation: ToolEffectObservation(mutation: .source)
        )
        let decoded = try JSONDecoder().decode(ActionRecord.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.observedEffects.mutation, .source)
    }

    func testObservationWithoutProgressFieldRemainsDecodable() throws {
        let json = #"{"mutation":"source","verification":"none"}"#
        let decoded = try JSONDecoder().decode(ToolEffectObservation.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.progress, .none)
        XCTAssertEqual(decoded.mutationEvidence, .mayMutate)
        XCTAssertFalse(decoded.confirmsMutation, "legacy observations without evidence must fail closed")
    }

    // cobol_generate is a HYBRID (2026-08-07): WITH a path it writes a .cbl (source mutation -> the
    // driving agent must then cobc it, per verify-before-done); WITHOUT a path it just returns COBOL
    // text (no artifact, no mutation). Closes the fabricate-the-build gap the first E2E exposed.
    func testCobolGeneratePathIsSourceMutationTextIsNot() {
        let wrote = ToolEffectCatalog.observe(tool: "cobol_generate",
                                              arguments: ["path": "payroll.cbl"],
                                              outcomeMetadata: ["changed": "true"])
        XCTAssertEqual(wrote.mutation, .source, "a written .cbl is a source mutation")
        XCTAssertTrue(wrote.confirmsMutation, "changed:true confirms the write")
        let textOnly = ToolEffectCatalog.observe(tool: "cobol_generate",
                                                 arguments: ["request": "hello"])
        XCTAssertEqual(textOnly.mutation, .none, "a path-less call only returns text - not a mutation")
    }
}
