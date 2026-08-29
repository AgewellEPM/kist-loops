import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "codex-capability-campaign.py"
SPEC = importlib.util.spec_from_file_location("codex_capability_campaign", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
campaign = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(campaign)


class CapabilityCampaignRunnerTests(unittest.TestCase):
    def write_manifest(self, root, steps):
        path = Path(root) / "manifest.json"
        path.write_text(json.dumps({
            "schema": campaign.SCHEMA,
            "providerPolicy": {
                "schema": campaign.PROVIDER_POLICY_SCHEMA,
                "allowedProviders": ["codex-cli"],
                "allowedModels": {"codex-cli": ["gpt-5.6-sol"]},
            },
            "phases": [{"id": "resume", "description": "fixture", "steps": steps}],
        }), encoding="utf-8")
        return path

    def runner_argv(self, manifest, output, *extra, script=SCRIPT):
        return [
            sys.executable, str(script), "--manifest", str(manifest), "run",
            "--phase", "resume", "--output-dir", str(output), *extra,
        ]

    def wait_for(self, predicate, message, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.02)
        self.fail(message)

    def test_checked_in_manifest_is_valid_and_has_unique_steps(self):
        manifest = campaign.load_manifest(
            REPO / "Tests" / "Fixtures" / "CapabilityCampaign" / "manifest.json"
        )
        steps = [step["id"] for phase in manifest["phases"] for step in phase["steps"]]
        self.assertEqual(len(steps), len(set(steps)))
        self.assertIn("mcp-inventory", steps)
        self.assertIn("mcp-readonly-calls", steps)
        self.assertIn("codex-repair-cobol", steps)
        self.assertIn("codex-grow-self-tool", steps)
        self_heal = next(
            step for phase in manifest["phases"] for step in phase["steps"]
            if step["id"] == "codex-repair-cobol")
        self.assertEqual(self_heal["critic"], "codex-cli:gpt-5.6-sol")
        self.assertEqual(self_heal["reviewGrade"], "fresh_context_same_model")
        read_probe = next(
            step for phase in manifest["phases"] for step in phase["steps"]
            if step["id"] == "codex-kist-read-probe")
        self.assertEqual(
            read_probe["argv"][read_probe["argv"].index("--budget") + 1], "100000")
        self.assertEqual(
            read_probe["argv"][read_probe["argv"].index("--max-iterations") + 1], "16")
        prompt = read_probe["argv"][-1]
        self.assertIn("AGENTS.md", prompt)
        self.assertIn("KIST_AUTONOMY_FLATLINE_AUTOPSY_2026-08-27.md", prompt)
        self.assertIn("KIST_MEMORY_GOVERNANCE_STATUS_2026-08-28.md", prompt)
        self.assertIn("GREAT_LOOP_EVOLUTION_ROADMAP.md", prompt)
        self.assertIn("CODEX_CAPABILITY_FAILURE_ZONE_CAMPAIGN_2026-08-27.md", prompt)
        self.assertIn("AUTOPSY_ASSESSMENT:", prompt)
        self.assertIn("RED_GATES:", prompt)
        self.assertIn("bounded microtasks", prompt)
        self.assertIn("never request the unscoped full repository diff", prompt)
        self.assertEqual(
            read_probe["expect"]["combinedContains"],
            [
                "tool call(s)",
                "read_file working · path=AGENTS.md",
                "read_file working · path=CLAUDE.md",
                "read_file working · path=docs/KIST_AUTONOMY_FLATLINE_AUTOPSY_2026-08-27.md",
                "read_file working · path=docs/KIST_MEMORY_GOVERNANCE_STATUS_2026-08-28.md",
                "read_file working · path=docs/kist/GREAT_LOOP_EVOLUTION_ROADMAP.md",
                "read_file working · path=docs/CODEX_CAPABILITY_FAILURE_ZONE_CAMPAIGN_2026-08-27.md",
                "git working · subcommand: status",
                "git working · subcommand: diff",
                "AUTOPSY_ASSESSMENT:",
                "RED_GATES:",
            ],
        )
        self.assertEqual(
            read_probe["expect"]["combinedExcludes"],
            [
                "0 tool call(s)",
                "REVIEW INCOMPLETE",
                "AUTOPSY_ASSESSMENT: INCOMPLETE",
                "session exposes none of the specified Kist",
                "claimed repository/file tools were unavailable",
            ],
        )

    def test_mcp_inventory_effect_catalog_is_an_exact_pure_set_audit(self):
        config = {"toolEffects": {"capture": "readOnly", "click": "projectMutation"}}
        with mock.patch.object(
                campaign.subprocess, "Popen", side_effect=AssertionError("must stay pure")) as popen:
            exact = campaign.audit_mcp_tool_effect_catalog(
                "vision", config, ["click", "capture"])
            drifted = campaign.audit_mcp_tool_effect_catalog(
                "vision", config, ["capture", "readback"])
        popen.assert_not_called()
        self.assertEqual(exact["status"], "passed", exact)
        self.assertEqual(drifted["status"], "failed")
        self.assertEqual(drifted["missingDeclarations"], ["readback"])
        self.assertEqual(drifted["staleDeclarations"], ["click"])

    def test_process_runner_resolves_relative_executable_against_step_cwd(self):
        with tempfile.TemporaryDirectory(prefix="campaign-relative-") as raw:
            root = Path(raw)
            probe = root / "probe"
            probe.symlink_to("/usr/bin/true")
            result = campaign.run_process(["./probe"], root, 10, root, label="relative")
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(result["exitCode"], 0)

    def test_process_runner_can_feed_bounded_repl_input(self):
        with tempfile.TemporaryDirectory(prefix="campaign-stdin-") as raw:
            root = Path(raw)
            result = campaign.run_process(
                ["/usr/bin/grep", "needle"], root, 10, root,
                expect={"combinedContains": ["needle"]}, label="stdin",
                stdin_text="needle\n",
            )
        self.assertEqual(result["status"], "passed", result)

    def test_normal_parent_exit_kills_term_ignoring_descendant_group(self):
        child = (
            "import os,pathlib,signal,sys,time; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)"
        )
        parent = """import pathlib
import subprocess
import sys
import time

subprocess.Popen([sys.executable, "-c", sys.argv[1], sys.argv[2]])
path = pathlib.Path(sys.argv[2])
deadline = time.monotonic() + 5
while not path.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
if not path.exists():
    raise SystemExit(5)
"""
        with tempfile.TemporaryDirectory(prefix="campaign-residual-") as raw:
            root = Path(raw)
            pid_path = root / "descendant.pid"
            result = campaign.run_process(
                [sys.executable, "-c", parent, child, str(pid_path)],
                root, 10, root, label="residual")
            descendant_pid = int(pid_path.read_text(encoding="utf-8"))
            with self.assertRaises(ProcessLookupError):
                os.kill(descendant_pid, 0)
        self.assertEqual(result["status"], "passed", result)
        self.assertTrue(result["processCleanup"]["termSent"])
        self.assertTrue(result["processCleanup"]["killSent"])
        self.assertTrue(result["processCleanup"]["groupGone"])

    def test_resume_refuses_changed_explicit_input_binding_without_replay(self):
        increment = (
            "import pathlib,sys; p=pathlib.Path(sys.argv[1]); "
            "n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1))"
        )
        with tempfile.TemporaryDirectory(prefix="campaign-binding-") as raw:
            root = Path(raw)
            binding = root / "input.txt"
            binding.write_text("v1", encoding="utf-8")
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "bound", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                "argv": [sys.executable, "-c", increment, "${TMP}/count"],
                "resumeBindings": [str(binding)],
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output), capture_output=True, text=True, timeout=20)
            self.assertEqual(initial.returncode, 0, initial.stderr)
            campaign_before = (output / "campaign.receipt.json").read_bytes()
            binding.write_text("v2", encoding="utf-8")
            resumed = subprocess.run(
                self.runner_argv(manifest, output, "--resume"),
                capture_output=True, text=True, timeout=20)
            self.assertEqual(resumed.returncode, 2)
            self.assertIn("stale resumeBindings", resumed.stderr)
            self.assertEqual((output / "count").read_text(), "1")
            self.assertEqual((output / "campaign.receipt.json").read_bytes(), campaign_before)

    def test_resume_refuses_changed_unexcluded_workspace_tree_without_reuse(self):
        increment = (
            "import pathlib,sys; p=pathlib.Path(sys.argv[1]); "
            "n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1))"
        )
        with tempfile.TemporaryDirectory(prefix="campaign-tree-binding-") as raw:
            root = Path(raw)
            workspace = root / "workspace"
            workspace.mkdir()
            source = workspace / "Source.swift"
            source.write_text("let value = 1\n", encoding="utf-8")
            excluded = workspace / ".build"
            excluded.mkdir()
            (excluded / "cache").write_text("ignored", encoding="utf-8")
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "tree", "kind": "command", "safety": "workspace_build", "cwd": "${TMP}",
                "argv": [sys.executable, "-c", increment, "${TMP}/count"],
                "resumeTreeBindings": [{
                    "path": str(workspace), "excludeDirectoryNames": [".build"],
                }],
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output, "--allow-workspace-builds"),
                capture_output=True, text=True, timeout=20)
            self.assertEqual(initial.returncode, 0, initial.stderr)
            receipt = json.loads((output / "tree.receipt.json").read_text())
            self.assertEqual(receipt["resumeTreeBindings"][0]["fileCount"], 1)
            source.write_text("let value = 2\n", encoding="utf-8")
            resumed = subprocess.run(
                self.runner_argv(
                    manifest, output, "--allow-workspace-builds", "--resume"),
                capture_output=True, text=True, timeout=20)
            self.assertEqual(resumed.returncode, 2)
            self.assertIn("stale resumeTreeBindings", resumed.stderr)
            self.assertEqual((output / "count").read_text(), "1")

    def test_tree_binding_rejects_symlinks_and_special_files(self):
        with tempfile.TemporaryDirectory(prefix="campaign-tree-types-") as raw:
            root = Path(raw)
            regular = root / "regular"
            regular.write_text("content", encoding="utf-8")
            link = root / "link"
            link.symlink_to(regular)
            with self.assertRaisesRegex(ValueError, "contains a symlink"):
                campaign.capture_tree_binding(root, [], "fixture")
            link.unlink()
            fifo = root / "fifo"
            os.mkfifo(fifo)
            with self.assertRaisesRegex(ValueError, "contains a special file"):
                campaign.capture_tree_binding(root, [], "fixture")

    def test_resume_binds_current_runner_sha(self):
        increment = (
            "import pathlib,sys; p=pathlib.Path(sys.argv[1]); "
            "n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1))"
        )
        with tempfile.TemporaryDirectory(prefix="campaign-runner-binding-") as raw:
            root = Path(raw)
            copied_runner = root / "campaign-runner.py"
            shutil.copy2(SCRIPT, copied_runner)
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "once", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                "argv": [sys.executable, "-c", increment, "${TMP}/count"],
                "resumeBindings": [sys.executable],
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output, script=copied_runner),
                capture_output=True, text=True, timeout=20)
            self.assertEqual(initial.returncode, 0, initial.stderr)
            with copied_runner.open("a", encoding="utf-8") as handle:
                handle.write("\n# changed runner identity\n")
            resumed = subprocess.run(
                self.runner_argv(manifest, output, "--resume", script=copied_runner),
                capture_output=True, text=True, timeout=20)
            self.assertEqual(resumed.returncode, 2)
            self.assertIn("runnerSHA256", resumed.stderr)
            self.assertEqual((output / "count").read_text(), "1")

    def test_missing_grant_yields_incomplete_campaign_and_nonzero_exit(self):
        with tempfile.TemporaryDirectory(prefix="campaign-skipped-") as raw:
            root = Path(raw)
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "mutate", "kind": "command", "safety": "workspace_build",
                "cwd": "${TMP}", "argv": ["/usr/bin/true"],
            }])
            result = subprocess.run(
                self.runner_argv(manifest, output), capture_output=True, text=True, timeout=20)
            receipt = json.loads((output / "campaign.receipt.json").read_text())
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt["status"], "incomplete")
        self.assertEqual(receipt["steps"][0]["status"], "skipped")

    def test_shared_mutable_scope_serializes_across_outputs_but_readonly_does_not(self):
        program = (
            "import pathlib,sys,time; "
            "pathlib.Path(sys.argv[1]).write_text(str(time.time())); "
            "time.sleep(float(sys.argv[3])); "
            "pathlib.Path(sys.argv[2]).write_text(str(time.time()))"
        )

        def run_pair(root, safety, grant):
            scope = f"test-resource:{uuid.uuid4().hex}"
            processes = []
            intervals = []
            for index in range(2):
                campaign_root = root / f"{safety}-{index}"
                campaign_root.mkdir()
                start = campaign_root / "start"
                end = campaign_root / "end"
                output = campaign_root / "out"
                process_tmp = campaign_root / "process-tmp"
                process_tmp.mkdir()
                manifest = self.write_manifest(campaign_root, [{
                    "id": "hold", "kind": "command", "safety": safety, "cwd": "${TMP}",
                    "argv": [sys.executable, "-c", program, str(start), str(end), "0.6"],
                    "resourceScopes": [scope],
                }])
                processes.append((subprocess.Popen(
                    self.runner_argv(manifest, output, *grant),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                    env={**os.environ, "TMPDIR": str(process_tmp)}), start, end))
            for process, start, end in processes:
                stdout, stderr = process.communicate(timeout=20)
                self.assertEqual(process.returncode, 0, (stdout, stderr))
                intervals.append((float(start.read_text()), float(end.read_text())))
            return intervals

        with tempfile.TemporaryDirectory(prefix="campaign-scopes-") as raw:
            root = Path(raw)
            mutable = run_pair(root, "workspace_build", ("--allow-workspace-builds",))
            readonly = run_pair(root, "read_only", ())
        self.assertTrue(
            mutable[0][1] <= mutable[1][0] or mutable[1][1] <= mutable[0][0], mutable)
        self.assertLess(max(item[0] for item in readonly), min(item[1] for item in readonly), readonly)

    def test_readonly_failure_requires_explicit_validated_retry_policy(self):
        fail = (
            "import pathlib,sys; p=pathlib.Path(sys.argv[1]); "
            "n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1)); sys.exit(9)"
        )
        with tempfile.TemporaryDirectory(prefix="campaign-retry-policy-") as raw:
            root = Path(raw)
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "fail", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                "argv": [sys.executable, "-c", fail, "${TMP}/count"],
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output), capture_output=True, text=True, timeout=20)
            resumed = subprocess.run(
                self.runner_argv(manifest, output, "--resume"),
                capture_output=True, text=True, timeout=20)
            self.assertEqual(initial.returncode, 1)
            self.assertEqual(resumed.returncode, 2)
            self.assertIn("resumePolicy does not explicitly permit replay", resumed.stderr)
            self.assertEqual((output / "count").read_text(), "1")

            invalid = self.write_manifest(root, [{
                "id": "unsafe-retry", "kind": "command", "safety": "workspace_build",
                "resumePolicy": "retry", "cwd": "${TMP}", "argv": ["/usr/bin/true"],
            }])
            with self.assertRaisesRegex(ValueError, "confined to read_only"):
                campaign.load_manifest(invalid)

            invalid_rerun = self.write_manifest(root, [{
                "id": "unsafe-rerun", "kind": "command", "safety": "subscription",
                "resumePolicy": "rerun", "cwd": "${TMP}", "argv": ["/usr/bin/true"],
            }])
            with self.assertRaisesRegex(ValueError, "rerun resumePolicy is confined to read_only"):
                campaign.load_manifest(invalid_rerun)

    def test_readonly_rerun_executes_again_after_a_pass(self):
        increment = (
            "import pathlib,sys; p=pathlib.Path(sys.argv[1]); "
            "n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1))"
        )
        with tempfile.TemporaryDirectory(prefix="campaign-rerun-pass-") as raw:
            root = Path(raw)
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "current", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                "argv": [sys.executable, "-c", increment, "${TMP}/count"],
                "resumeBindings": [sys.executable], "resumePolicy": "rerun",
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output), capture_output=True, text=True, timeout=20)
            resumed = subprocess.run(
                self.runner_argv(manifest, output, "--resume"),
                capture_output=True, text=True, timeout=20)
            receipt = json.loads((output / "current.receipt.json").read_text())
            count = (output / "count").read_text()
        self.assertEqual(initial.returncode, 0, initial.stderr)
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertNotIn("REUSED", resumed.stdout)
        self.assertEqual(count, "2")
        self.assertEqual(receipt["attempt"], 2)
        self.assertEqual(receipt["resumePolicy"], "rerun")

    def test_rerun_rebinds_changed_input_and_mcp_config(self):
        with tempfile.TemporaryDirectory(prefix="campaign-rerun-binding-") as raw:
            root = Path(raw)
            config = root / "mcp.json"
            config.write_text(json.dumps({"mcpServers": {"control": {
                "command": "/usr/bin/true", "computerUse": True,
                "toolEffects": {"click": "externalMutation"},
            }}}), encoding="utf-8")
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "denial", "kind": "mcp_unarmed_denial", "safety": "read_only",
                "config": str(config), "resumeBindings": [str(config)],
                "resumePolicy": "rerun", "assertions": [{
                    "server": "control", "tool": "click", "effect": "externalMutation",
                    "expected": "denied_unarmed",
                }],
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output), capture_output=True, text=True, timeout=20)
            self.assertEqual(initial.returncode, 0, initial.stderr)
            first = json.loads((output / "denial.receipt.json").read_text())
            changed = json.loads(config.read_text())
            changed["metadata"] = "current-state-change"
            config.write_text(json.dumps(changed), encoding="utf-8")
            resumed = subprocess.run(
                self.runner_argv(manifest, output, "--resume"),
                capture_output=True, text=True, timeout=20)
            current = json.loads((output / "denial.receipt.json").read_text())
            expected_hash = campaign.sha256_file(config)
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertNotEqual(
            first["configBinding"]["bindingSHA256"], current["configBinding"]["bindingSHA256"])
        self.assertEqual(current["configBinding"]["bindingSHA256"], expected_hash)
        self.assertEqual(current["resumeBindings"][0]["bindingSHA256"], expected_hash)
        self.assertEqual(current["attempt"], 2)

    def test_retry_keeps_same_input_binding_instead_of_refreshing_it(self):
        with tempfile.TemporaryDirectory(prefix="campaign-retry-binding-") as raw:
            root = Path(raw)
            binding = root / "input"
            binding.write_text("first", encoding="utf-8")
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "retry", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                "argv": [sys.executable, "-c", "raise SystemExit(3)"],
                "resumePolicy": "retry", "resumeBindings": [str(binding)],
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output), capture_output=True, text=True, timeout=20)
            self.assertEqual(initial.returncode, 1)
            binding.write_text("second", encoding="utf-8")
            resumed = subprocess.run(
                self.runner_argv(manifest, output, "--resume"),
                capture_output=True, text=True, timeout=20)
        self.assertEqual(resumed.returncode, 2)
        self.assertIn("stale resumeBindings", resumed.stderr)

    def test_unsafe_step_and_server_ids_are_rejected_before_process_launch(self):
        with tempfile.TemporaryDirectory(prefix="campaign-safe-ids-") as raw:
            root = Path(raw)
            manifest = self.write_manifest(root, [{
                "id": "../escape", "kind": "command", "safety": "read_only",
                "cwd": "${TMP}", "argv": ["/usr/bin/true"],
            }])
            with self.assertRaisesRegex(ValueError, "invalid step id"):
                campaign.load_manifest(manifest)
            with mock.patch.object(campaign.subprocess, "Popen") as popen:
                result = campaign.probe_mcp_server(
                    "../escape", {"command": "/usr/bin/true"}, 1, root)
            popen.assert_not_called()
            self.assertEqual(result["status"], "failed")
            with self.assertRaises(ValueError):
                campaign.mcp_log_path(root, "mcp", "../escape")
            config = root / "mcp.json"
            config.write_text(json.dumps({"mcpServers": {"safe": {
                "command": "/usr/bin/true", "toolEffects": {"status": "readOnly"},
            }}}), encoding="utf-8")
            step = {
                "config": str(config), "expectedServers": ["safe"],
                "calls": [
                    {"server": "safe", "tool": "status", "arguments": {}},
                    {"server": "../escape", "tool": "status", "arguments": {}},
                ],
            }
            with mock.patch.object(campaign.subprocess, "Popen") as popen:
                safe_call_result = campaign.run_mcp_safe_calls(step, {}, root)
            popen.assert_not_called()
            self.assertEqual(safe_call_result["subprocessInvocations"], 0)

    def test_non_live_mcp_call_is_explicit_not_applicable_without_launch(self):
        with tempfile.TemporaryDirectory(prefix="campaign-mcp-not-applicable-") as raw:
            root = Path(raw)
            config = root / "mcp.json"
            config.write_text(json.dumps({"mcpServers": {"guest": {
                "command": "/usr/bin/true",
                "toolEffects": {"guest_frame": "readOnly"},
            }}}), encoding="utf-8")
            step = {
                "config": str(config), "expectedServers": ["guest"],
                "calls": [{
                    "server": "guest", "tool": "guest_frame", "arguments": {},
                    "notApplicableReason": "live guest capture is outside this campaign",
                }],
            }
            with mock.patch.object(
                    campaign.subprocess, "Popen",
                    side_effect=AssertionError("not-applicable must not launch")) as popen:
                result = campaign.run_mcp_safe_calls(step, {}, root)
            popen.assert_not_called()
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(result["calls"][0]["status"], "not_applicable")
        self.assertEqual(result["calls"][0]["subprocessInvocations"], 0)

    def test_resume_refuses_symlinked_step_output_before_retry(self):
        fail = (
            "import pathlib,sys; p=pathlib.Path(sys.argv[1]); "
            "n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1)); sys.exit(4)"
        )
        with tempfile.TemporaryDirectory(prefix="campaign-output-topology-") as raw:
            root = Path(raw)
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "retry", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                "argv": [sys.executable, "-c", fail, "${TMP}/count"],
                "resumePolicy": "retry", "resumeBindings": [sys.executable],
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output), capture_output=True, text=True, timeout=20)
            self.assertEqual(initial.returncode, 1)
            original = output / "retry"
            original.rename(output / "retry.original")
            outside = root / "outside"
            outside.mkdir()
            original.symlink_to(outside, target_is_directory=True)
            resumed = subprocess.run(
                self.runner_argv(manifest, output, "--resume"),
                capture_output=True, text=True, timeout=20)
            self.assertEqual(resumed.returncode, 2)
            self.assertIn("unsafe step output directory", resumed.stderr)
            self.assertEqual((output / "count").read_text(), "1")
            self.assertEqual(list(outside.iterdir()), [])

    def test_reusable_command_receipt_recomputes_success_semantics(self):
        with tempfile.TemporaryDirectory(prefix="campaign-command-receipt-") as raw:
            root = Path(raw)
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "command", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                "argv": ["/usr/bin/true"], "resumeBindings": ["/usr/bin/true"],
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output), capture_output=True, text=True, timeout=20)
            self.assertEqual(initial.returncode, 0, initial.stderr)
            step_path = output / "command.receipt.json"
            step_receipt = json.loads(step_path.read_text())
            step_receipt["exitCode"] = 7
            step_path.write_text(json.dumps(step_receipt), encoding="utf-8")
            campaign_path = output / "campaign.receipt.json"
            aggregate = json.loads(campaign_path.read_text())
            aggregate["steps"][0]["exitCode"] = 7
            campaign_path.write_text(json.dumps(aggregate), encoding="utf-8")
            resumed = subprocess.run(
                self.runner_argv(manifest, output, "--resume"),
                capture_output=True, text=True, timeout=20)
        self.assertEqual(resumed.returncode, 2)
        self.assertIn("no longer satisfies expectations", resumed.stderr)

    def test_mcp_unarmed_denial_is_static_and_never_spawns(self):
        with tempfile.TemporaryDirectory(prefix="campaign-denial-") as raw:
            root = Path(raw)
            config = root / "mcp.json"
            config.write_text(json.dumps({"mcpServers": {
                "control": {
                    "command": "/usr/bin/true", "computerUse": True,
                    "toolEffects": {"capture": "readOnly", "click": "externalMutation"},
                },
                "mixed": {
                    "command": "/usr/bin/true",
                    "computerUseTools": ["drag", "vm_capture"],
                    "toolEffects": {"drag": "workspaceMutation", "vm_capture": "readOnly"},
                },
            }}), encoding="utf-8")
            step = {
                "config": str(config),
                "assertions": [
                    {"server": "control", "tool": "capture", "effect": "readOnly",
                     "expected": "denied_unarmed"},
                    {"server": "control", "tool": "click", "effect": "externalMutation",
                     "expected": "denied_unarmed"},
                    {"server": "mixed", "tool": "drag", "effect": "workspaceMutation",
                     "expected": "denied_unarmed"},
                    {"server": "mixed", "tool": "vm_capture", "effect": "readOnly",
                     "expected": "denied_unarmed"},
                ],
            }
            with mock.patch.object(
                    campaign.subprocess, "Popen", side_effect=AssertionError("must not spawn")) as popen:
                result = campaign.run_mcp_unarmed_denial(step, {})
            popen.assert_not_called()
            self.assertEqual(result["status"], "passed", result)
            self.assertEqual(result["subprocessInvocations"], 0)
            self.assertTrue(all(item["wouldDenyUnarmed"] for item in result["assertions"]))

            unprotected = json.loads(config.read_text())
            unprotected["mcpServers"]["control"]["computerUse"] = False
            config.write_text(json.dumps(unprotected), encoding="utf-8")
            with mock.patch.object(campaign.subprocess, "Popen") as popen:
                denied = campaign.run_mcp_unarmed_denial(step, {})
            popen.assert_not_called()
            self.assertEqual(denied["status"], "failed")
            self.assertIn("not explicitly computer-use protected", denied["failures"][0])

    def test_sigterm_cleans_process_group_and_resume_does_not_replay_passed_step(self):
        increment = (
            "import pathlib,sys; p=pathlib.Path(sys.argv[1]); "
            "n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1)); print(n+1)"
        )
        interrupt_once = (
            "import pathlib,subprocess,sys,time; "
            "p=pathlib.Path(sys.argv[1]); n=int(p.read_text()) if p.exists() else 0; "
            "p.write_text(str(n+1)); "
            "pid=pathlib.Path(sys.argv[2]); gpid=pathlib.Path(sys.argv[3]); "
            "child=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']) if n == 0 else None; "
            "pid.write_text(str(__import__('os').getpid())); "
            "gpid.write_text(str(child.pid) if child else ''); print(n+1,flush=True); "
            "time.sleep(60) if n == 0 else None"
        )
        with tempfile.TemporaryDirectory(prefix="campaign-resume-") as raw:
            root = Path(raw)
            output = root / "out"
            manifest = self.write_manifest(root, [
                {"id": "first", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                 "argv": [sys.executable, "-c", increment, "${TMP}/first.count"],
                 "resumeBindings": [sys.executable]},
                {"id": "interrupt", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                 "argv": [sys.executable, "-c", interrupt_once, "${TMP}/interrupt.count",
                          "${TMP}/child.pid", "${TMP}/grandchild.pid"], "timeoutSeconds": 90,
                 "resumeBindings": [sys.executable], "resumePolicy": "retry"},
                {"id": "last", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                 "argv": [sys.executable, "-c", increment, "${TMP}/last.count"],
                 "resumeBindings": [sys.executable]},
            ])
            first_run = subprocess.Popen(
                self.runner_argv(manifest, output), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True)
            self.wait_for(lambda: (output / "grandchild.pid").is_file(),
                          "interrupt fixture never launched")
            child_pid = int((output / "child.pid").read_text(encoding="utf-8"))
            grandchild_pid = int((output / "grandchild.pid").read_text(encoding="utf-8"))
            first_run.terminate()
            stdout, stderr = first_run.communicate(timeout=10)
            self.assertEqual(first_run.returncode, 128 + 15, (stdout, stderr))

            def gone(pid):
                try:
                    os.kill(pid, 0)
                    return False
                except ProcessLookupError:
                    return True

            self.wait_for(lambda: gone(child_pid), "active campaign child survived SIGTERM")
            self.wait_for(lambda: gone(grandchild_pid), "campaign grandchild survived process-group cleanup")
            interrupted = json.loads((output / "campaign.receipt.json").read_text())
            self.assertEqual(interrupted["status"], "interrupted")
            self.assertEqual(next(x for x in interrupted["steps"] if x["step"] == "first")["status"],
                             "passed")

            resumed = subprocess.run(
                self.runner_argv(manifest, output, "--resume"), capture_output=True, text=True,
                timeout=20)
            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.assertIn("REUSED  resume/first", resumed.stdout)
            self.assertEqual((output / "first.count").read_text(), "1",
                             "a verified successful step was replayed")
            self.assertEqual((output / "interrupt.count").read_text(), "2")
            self.assertEqual((output / "last.count").read_text(), "1")
            completed = json.loads((output / "campaign.receipt.json").read_text())
            self.assertEqual(completed["status"], "passed")
            attempts = {item["step"]: item["attempt"] for item in completed["steps"]}
            self.assertEqual(attempts, {"first": 1, "interrupt": 2, "last": 1})
            self.assertFalse(any(path.name.endswith(".tmp") for path in output.rglob("*")))

    def test_resume_reverifies_successful_log_hash_and_refuses_stale_receipt_without_replay(self):
        increment = (
            "import pathlib,sys; p=pathlib.Path(sys.argv[1]); "
            "n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1)); print('stable')"
        )
        with tempfile.TemporaryDirectory(prefix="campaign-stale-") as raw:
            root = Path(raw)
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "once", "kind": "command", "safety": "read_only", "cwd": "${TMP}",
                "argv": [sys.executable, "-c", increment, "${TMP}/once.count"],
                "resumeBindings": [sys.executable],
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output), capture_output=True, text=True, timeout=20)
            self.assertEqual(initial.returncode, 0, initial.stderr)
            accidental = subprocess.run(
                self.runner_argv(manifest, output), capture_output=True, text=True, timeout=20)
            self.assertEqual(accidental.returncode, 2)
            self.assertIn("non-empty --output-dir requires --resume", accidental.stderr)
            self.assertEqual((output / "once.count").read_text(), "1")
            campaign_before = (output / "campaign.receipt.json").read_bytes()
            receipt = json.loads((output / "once.receipt.json").read_text())
            stdout_path = Path(receipt["stdout"]["path"])
            stdout_path.write_bytes(stdout_path.read_bytes() + b"tampered\n")

            resumed = subprocess.run(
                self.runner_argv(manifest, output, "--resume"), capture_output=True, text=True,
                timeout=20)
            self.assertEqual(resumed.returncode, 2)
            self.assertIn("artifact hash is stale", resumed.stderr)
            self.assertEqual((output / "once.count").read_text(), "1")
            self.assertEqual((output / "campaign.receipt.json").read_bytes(), campaign_before,
                             "failed resume validation must not rewrite trusted campaign state")

    def test_resume_refuses_to_replay_failed_mutable_step(self):
        fail_once = (
            "import pathlib,sys; p=pathlib.Path(sys.argv[1]); "
            "n=int(p.read_text()) if p.exists() else 0; p.write_text(str(n+1)); sys.exit(7)"
        )
        with tempfile.TemporaryDirectory(prefix="campaign-mutable-") as raw:
            root = Path(raw)
            output = root / "out"
            manifest = self.write_manifest(root, [{
                "id": "mutable", "kind": "command", "safety": "workspace_build",
                "cwd": "${TMP}", "argv": [sys.executable, "-c", fail_once, "${TMP}/mutable.count"],
            }])
            initial = subprocess.run(
                self.runner_argv(manifest, output, "--allow-workspace-builds"),
                capture_output=True, text=True, timeout=20)
            self.assertEqual(initial.returncode, 1)
            resumed = subprocess.run(
                self.runner_argv(
                    manifest, output, "--allow-workspace-builds", "--resume"),
                capture_output=True, text=True, timeout=20)
            self.assertEqual(resumed.returncode, 2)
            self.assertIn("resumePolicy does not explicitly permit replay", resumed.stderr)
            self.assertEqual((output / "mutable.count").read_text(), "1")

    def test_author_and_same_model_critic_become_literal_kist_flags(self):
        options = campaign.kist_author_options(
            {"authorModel": "gpt-5.6-sol", "critic": "codex-cli:gpt-5.6-sol",
             "reviewGrade": "fresh_context_same_model"}, {})
        self.assertEqual(
            options, ["--model", "gpt-5.6-sol", "--critic", "codex-cli:gpt-5.6-sol",
                      "--review-grade", "fresh_context_same_model"])

    def test_self_heal_builder_invocation_is_auto_sandboxed_and_exactly_pinned(self):
        argv = campaign.kist_disposable_builder_argv({
            "kistBinary": "/tmp/kist", "provider": "codex-cli",
            "authorModel": "gpt-5.6-sol", "critic": "codex-cli:gpt-5.6-sol",
            "reviewGrade": "fresh_context_same_model",
        }, {}, Path("/private/tmp/disposable"), "repair")
        self.assertEqual(argv[0], "/tmp/kist")
        self.assertIn("--headless", argv)
        self.assertIn("--auto", argv)
        self.assertIn("--sandbox", argv)
        self.assertEqual(argv[argv.index("--provider") + 1], "codex-cli")
        self.assertEqual(argv[argv.index("--model") + 1], "gpt-5.6-sol")
        self.assertEqual(argv[argv.index("--critic") + 1], "codex-cli:gpt-5.6-sol")
        self.assertEqual(
            argv[argv.index("--review-grade") + 1], "fresh_context_same_model")

    def test_self_tool_requires_identity_distinct_kist_review_receipt(self):
        step = {
            "provider": "codex-cli", "authorModel": "gpt-5.6-sol",
            "critic": "onyx:review-model",
            "reviewGrade": "independent",
        }
        receipt = {
            "activated": True, "outcome": "promoted",
            "grade": "independent", "independent": True,
            "authorIdentity": "codex-cli:gpt-5.6-sol",
            "criticIdentity": "onyx:review-model",
            "authorInvocationID": "author-call",
            "criticInvocationID": "critic-call",
            "freshConversation": True, "separateInvocation": True,
        }
        with tempfile.TemporaryDirectory(prefix="campaign-review-receipt-") as raw:
            output = Path(raw) / "stdout.log"
            output.write_text(
                campaign.EVOLUTION_REVIEW_RECEIPT_PREFIX
                + json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8")
            parsed = campaign.verified_evolution_review_receipt(
                {"stdout": {"path": str(output)}}, step, {})
            self.assertEqual(parsed, receipt)

            for key, dishonest in (("independent", False), ("freshConversation", False),
                                    ("separateInvocation", False), ("activated", False)):
                forged = dict(receipt)
                forged[key] = dishonest
                output.write_text(
                    campaign.EVOLUTION_REVIEW_RECEIPT_PREFIX
                    + json.dumps(forged, sort_keys=True) + "\n", encoding="utf-8")
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                    campaign.verified_evolution_review_receipt(
                        {"stdout": {"path": str(output)}}, step, {})

            output.write_text("ACTIVATED self__fake\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "exactly one"):
                campaign.verified_evolution_review_receipt(
                    {"stdout": {"path": str(output)}}, step, {})

    def test_same_model_self_tool_phase_is_skipped_without_spending_or_activation(self):
        step = {
            "provider": "codex-cli", "authorModel": "gpt-5.6-sol",
            "critic": "codex-cli:gpt-5.6-sol",
            "reviewGrade": "fresh_context_same_model",
            "promotionExpectation": "blocked_identity_distinct_reviewer",
        }
        with tempfile.TemporaryDirectory(prefix="campaign-self-tool-blocked-") as raw:
            result = campaign.run_kist_grow_tool(step, {}, Path(raw))
        self.assertEqual(result["status"], "skipped")
        self.assertEqual(result["reason"], "blocked_identity_distinct_reviewer")
        self.assertEqual(result["activatedToolCount"], 0)
        self.assertEqual(result["author"]["status"], "not-run")

    def test_builder_self_heal_requires_nonindependent_disjoint_review_receipt(self):
        step = {
            "provider": "codex-cli", "authorModel": "gpt-5.6-sol",
            "critic": "codex-cli:gpt-5.6-sol",
            "reviewGrade": "fresh_context_same_model",
        }
        receipt = {
            "receiptType": "kist.builder-review", "schemaVersion": 1,
            "decision": "approve", "accepted": True,
            "grade": "fresh_context_same_model", "independent": False,
            "freshConversation": True, "separateInvocation": True,
            "reviewThreshold": 3,
            "producerIdentities": ["codex-cli:gpt-5.6-sol"],
            "reviewerIdentity": "codex-cli:gpt-5.6-sol",
            "invocationIDKind": "sealed_cli_telemetry_observation_id",
            "producerInvocationIDs": ["producer-observation"],
            "reviewerInvocationIDs": ["reviewer-observation-a", "reviewer-observation-b"],
            "evidencePacketDigest": "a" * 64,
        }
        with tempfile.TemporaryDirectory(prefix="campaign-builder-review-") as raw:
            output = Path(raw) / "stdout.log"
            output.write_text(
                campaign.BUILDER_REVIEW_RECEIPT_PREFIX
                + json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8")
            parsed = campaign.verified_builder_review_receipt(
                {"stdout": {"path": str(output)}}, step, {})
            self.assertEqual(parsed, receipt)

            for key, dishonest in (("independent", True), ("freshConversation", False),
                                    ("separateInvocation", False), ("accepted", False),
                                    ("reviewThreshold", 2)):
                forged = dict(receipt)
                forged[key] = dishonest
                output.write_text(
                    campaign.BUILDER_REVIEW_RECEIPT_PREFIX
                    + json.dumps(forged, sort_keys=True) + "\n", encoding="utf-8")
                with self.subTest(key=key), self.assertRaisesRegex(ValueError, key):
                    campaign.verified_builder_review_receipt(
                        {"stdout": {"path": str(output)}}, step, {})

            overlapping = dict(receipt)
            overlapping["reviewerInvocationIDs"] = ["producer-observation"]
            output.write_text(
                campaign.BUILDER_REVIEW_RECEIPT_PREFIX
                + json.dumps(overlapping, sort_keys=True) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "overlap"):
                campaign.verified_builder_review_receipt(
                    {"stdout": {"path": str(output)}}, step, {})

            duplicate = dict(receipt)
            duplicate["reviewerInvocationIDs"] = ["review-call", "review-call"]
            output.write_text(
                campaign.BUILDER_REVIEW_RECEIPT_PREFIX
                + json.dumps(duplicate, sort_keys=True) + "\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "non-empty and unique"):
                campaign.verified_builder_review_receipt(
                    {"stdout": {"path": str(output)}}, step, {})

    def test_provider_policy_rejects_disallowed_or_implicit_model_routes(self):
        policy = {
            "schema": campaign.PROVIDER_POLICY_SCHEMA,
            "allowedProviders": ["codex-cli"],
            "allowedModels": {"codex-cli": ["gpt-5.6-sol"]},
        }
        with self.assertRaisesRegex(ValueError, "provider .* is not allowed"):
            campaign.validate_inference_step({
                "id": "bad-provider", "kind": "codex_repair_cobol",
                "safety": "subscription", "modelInference": True,
                "provider": "ollama", "authorModel": "qwen2.5-coder",
            }, policy)
        with self.assertRaisesRegex(ValueError, "same-model critic must be labeled"):
            campaign.validate_inference_step({
                "id": "dishonest-review", "kind": "kist_grow_tool",
                "safety": "subscription", "modelInference": True,
                "provider": "codex-cli", "authorModel": "gpt-5.6-sol",
                "critic": "codex-cli:gpt-5.6-sol",
            }, policy)

    def test_inference_identity_distinguishes_independent_and_same_model_review(self):
        independent = campaign.inference_identity({
            "modelInference": True, "provider": "codex-cli",
            "authorModel": "gpt-5.6-sol", "critic": "onyx:legacy-code",
        })
        self.assertEqual(independent["review"]["grade"], "independent")
        self.assertTrue(independent["review"]["independent"])

        same_model = campaign.inference_identity({
            "modelInference": True, "provider": "codex-cli",
            "authorModel": "gpt-5.6-sol", "critic": "codex-cli:gpt-5.6-sol",
            "reviewGrade": "fresh_context_same_model",
        })
        self.assertEqual(same_model["review"]["grade"], "fresh_context_same_model")
        self.assertFalse(same_model["review"]["independent"])

    def test_checked_in_manifest_is_codex_only_and_labels_same_model_review(self):
        manifest = campaign.load_manifest(
            REPO / "Tests" / "Fixtures" / "CapabilityCampaign" / "manifest.json")
        self.assertEqual(manifest["providerPolicy"]["allowedProviders"], ["codex-cli"])
        self.assertNotIn("local_critic", {phase["id"] for phase in manifest["phases"]})
        model_steps = [
            step for phase in manifest["phases"] for step in phase["steps"]
            if step.get("modelInference") is True
        ]
        self.assertTrue(model_steps)
        self.assertTrue(all(step["provider"] == "codex-cli" for step in model_steps))
        self.assertTrue(all(step["authorModel"] == "gpt-5.6-sol" for step in model_steps))
        grow = next(step for step in model_steps if step["id"] == "codex-grow-self-tool")
        self.assertEqual(grow["reviewGrade"], "fresh_context_same_model")
        self.assertEqual(
            grow["promotionExpectation"], "blocked_identity_distinct_reviewer")

    def test_symbolic_claim_gate_requires_allow_and_same_host_correlation(self):
        with tempfile.TemporaryDirectory(prefix="campaign-symbolic-gate-") as raw:
            root = Path(raw)
            config = root / "mcp.json"
            config.write_text(json.dumps({
                "mcpServers": {"perslis": {
                    "command": "/usr/bin/true", "args": [],
                    "toolEffects": {"legacy_claim_gate": "readOnly"},
                }}
            }), encoding="utf-8")
            step = {
                "mcpConfig": str(config),
                "symbolicClaim": "A COMP-3 field is a packed decimal",
            }
            mission = "a" * 64
            allowed = {
                "status": "passed", "toolJSON": {
                    "verdict": "allow", "may_proceed": True,
                    "correlation_id": mission,
                },
            }
            with mock.patch.object(
                    campaign, "call_mcp_read_only_tool", return_value=allowed) as call:
                result = campaign.run_symbolic_claim_gate(step, {}, root, mission)
            self.assertEqual(result["status"], "passed", result)
            self.assertEqual(
                call.call_args.args[2]["metadata"], {"kist.correlation_id": mission})

            unknown = {
                "status": "passed", "toolJSON": {
                    "verdict": "research", "may_proceed": False,
                    "correlation_id": "b" * 64,
                },
            }
            with mock.patch.object(
                    campaign, "call_mcp_read_only_tool", return_value=unknown):
                refused = campaign.run_symbolic_claim_gate(step, {}, root, mission)
            self.assertEqual(refused["status"], "failed")
            self.assertTrue(any("did not explicitly allow" in item for item in refused["failures"]))
            self.assertTrue(any("did not echo" in item for item in refused["failures"]))

    def test_mcp_host_metadata_rejects_invalid_correlation_before_launch(self):
        config = {
            "command": "/usr/bin/true", "args": [],
            "toolEffects": {"legacy_claim_gate": "readOnly"},
        }
        with tempfile.TemporaryDirectory(prefix="campaign-invalid-correlation-") as raw:
            with mock.patch.object(
                    campaign.subprocess, "Popen",
                    side_effect=AssertionError("invalid metadata must not launch")) as popen:
                result = campaign.call_mcp_read_only_tool(
                    "perslis", config, {
                        "tool": "legacy_claim_gate",
                        "arguments": {"claim": "x", "correlation_id": "a" * 64},
                        "metadata": {"kist.correlation_id": "NOT-A-MISSION"},
                    }, 1, Path(raw))
            popen.assert_not_called()
        self.assertEqual(result["status"], "failed")
        self.assertIn("64 lowercase hexadecimal", result["failure"])

    def test_final_json_object_accepts_pretty_receipt_after_diagnostics(self):
        with tempfile.TemporaryDirectory(prefix="campaign-final-json-") as raw:
            stdout = Path(raw) / "stdout.log"
            receipt = {"ok": True, "nested": {"engine": "cobol"}}
            stdout.write_text(
                "diagnostic before final receipt\n" + json.dumps(receipt, indent=2) + "\n",
                encoding="utf-8",
            )
            parsed = campaign.final_json_object(
                {"stdout": {"path": str(stdout)}}, "Perslis detect")
        self.assertEqual(parsed, receipt)

    def test_final_json_object_rejects_output_after_pretty_receipt(self):
        with tempfile.TemporaryDirectory(prefix="campaign-final-json-trailing-") as raw:
            stdout = Path(raw) / "stdout.log"
            stdout.write_text(
                json.dumps({"ok": True}, indent=2) + "\ntrailing diagnostic\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "does not end with a JSON object"):
                campaign.final_json_object(
                    {"stdout": {"path": str(stdout)}}, "Perslis detect")

    def test_perslis_cobol_evidence_requires_final_structured_execution_receipt(self):
        fake_perslis = """#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import sys

command = sys.argv[1]
source = Path(sys.argv[2])
digest = hashlib.sha256(source.read_bytes()).hexdigest()
if command == "detect":
    print("diagnostic before final receipt")
    print(json.dumps({
        "ok": True, "mode": "detect", "detected_engine": "cobol",
        "artifact_path": str(source), "artifact_sha256": digest,
    }, indent=2))
elif command == "run":
    app_support = os.environ.get("PERSLIS_APP_SUPPORT")
    binary = (
        Path(app_support) / "Vault" / "cobol" / source.stem
        if app_support else source.parent / source.stem
    )
    binary.parent.mkdir(parents=True, exist_ok=True)
    binary.write_bytes(b"deterministic-cobol-binary")
    binary.chmod(0o700)
    stdout = "KIST-COBOL-OK 0042\\n"
    print(json.dumps({
        "schema": "perslis.run.v1", "launched": True, "engine": "cobol",
        "status": "completed", "exit_code": 0, "binary": str(binary),
        "compiler_outcome": "exited", "compiler_exit_code": 0,
        "stdout": stdout, "stdout_encoding": "utf-8", "stdout_complete": True,
        "stdout_truncated": False, "stdout_bytes": len(stdout.encode()),
        "stdout_sha256": hashlib.sha256(stdout.encode()).hexdigest(),
    }))
else:
    raise SystemExit(2)
"""
        with tempfile.TemporaryDirectory(prefix="campaign-perslis-") as raw:
            root = Path(raw)
            executable = root / "Perslis"
            executable.write_text(fake_perslis, encoding="utf-8")
            executable.chmod(0o700)
            source = root / "ledger.cob"
            source.write_text(campaign.FIXED_COBOL.replace("KISTHEAL", "LEDGER"), encoding="utf-8")
            logs = root / "logs"
            logs.mkdir()
            app_support = root / "Library" / "Application Support" / "Perslis"
            with mock.patch.dict(
                    os.environ, {"PERSLIS_APP_SUPPORT": str(app_support)}, clear=False):
                result = campaign.run_perslis_cobol_evidence(
                    str(executable), source, "KIST-COBOL-OK 0042", logs)
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(result["detectJSON"]["detected_engine"], "cobol")
        self.assertEqual(result["runJSON"]["status"], "completed")
        self.assertRegex(result["source"]["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(result["compiledBinary"]["sha256"], r"^[0-9a-f]{64}$")
        self.assertIn("Library/Application Support/Perslis/Vault/cobol",
                      result["compiledBinary"]["path"])

    def test_perslis_compiled_binary_binding_rejects_escape_and_name_spoof(self):
        with tempfile.TemporaryDirectory(prefix="campaign-perslis-spoof-") as raw:
            root = Path(raw)
            source = root / "ledger.cob"
            source.write_text(campaign.FIXED_COBOL, encoding="utf-8")
            app_support = root / "Library" / "Application Support" / "Perslis"
            vault = app_support / "Vault" / "cobol"
            vault.mkdir(parents=True)
            legitimate = vault / "ledger"
            legitimate.write_bytes(b"legitimate")
            legitimate.chmod(0o700)
            outside = root / "outside" / "ledger"
            outside.parent.mkdir()
            outside.write_bytes(b"spoof")
            outside.chmod(0o700)
            wrong_name = vault / "other-program"
            wrong_name.write_bytes(b"spoof")
            wrong_name.chmod(0o700)
            with mock.patch.dict(
                    os.environ, {"PERSLIS_APP_SUPPORT": str(app_support)}, clear=False):
                bound = campaign.capture_perslis_reported_binary(str(legitimate), source)
                with self.assertRaisesRegex(ValueError, "outside its allowed COBOL roots"):
                    campaign.capture_perslis_reported_binary(str(outside), source)
                with self.assertRaisesRegex(ValueError, "does not match the COBOL source stem"):
                    campaign.capture_perslis_reported_binary(str(wrong_name), source)
        self.assertEqual(bound["reportedPath"], str(legitimate))
        self.assertRegex(bound["sha256"], r"^[0-9a-f]{64}$")

    def test_cobol_self_heal_verifier_is_portable_make_target(self):
        makefile = campaign.COBOL_VERIFY_MAKEFILE
        self.assertIn("verify:\n", makefile)
        self.assertIn("\tmkdir -p .build\n", makefile)
        self.assertIn("\tcobc -x -free -o .build/ledger ledger.cob\n", makefile)
        self.assertIn("\t./.build/ledger | grep -F 'KIST-COBOL-OK 0042'\n", makefile)
        self.assertNotIn("--eval", makefile)

    @unittest.skipUnless(shutil.which("cobc"), "GnuCOBOL is required")
    def test_cobol_fixture_detects_failure_then_heals_and_runs(self):
        with tempfile.TemporaryDirectory(prefix="campaign-cobol-") as raw:
            result = campaign.run_cobol_heal({}, Path(raw))
            output = campaign.read_text(Path(result["fixedRun"]["stdout"]["path"]))
        self.assertEqual(result["status"], "passed", result)
        self.assertEqual(result["brokenCompile"]["status"], "passed")
        self.assertIn("KIST-COBOL-OK 0042", output)


if __name__ == "__main__":
    unittest.main()
