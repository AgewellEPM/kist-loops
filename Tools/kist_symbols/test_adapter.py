"""Run with PYTHONPATH=<existing symbolic-floor>:tools/kist_symbols python -m unittest discover -s tools/kist_symbols."""
from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import floor
from catalog import TOOLS, effects
from runtime import NoRedirect, Observer, csv_bytes, flatten, page, pointer
from server import call, handle
from service import Service
from store import decode, encoded, publish, read, verify


SPEC = {"question_class": "test:paid_total", "pipeline": [
    {"op": "rows"}, {"op": "filter", "column": "status", "equals": "paid"},
    {"op": "sum", "column": "amount"}]}
DATA = {"sales": [{"status": "paid", "amount": "12.50"},
                  {"status": "paid", "amount": "7.25"}, {"status": "open", "amount": "999"}]}


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.service = Service({"root": str(self.root), "targets": {}, "sources": {},
                                "liberate": "/missing/liberate"})
        self.args = {"spec_json": json.dumps(SPEC), "table": "sales", "question": "Total paid amount",
                     "data_json": json.dumps(DATA)}

    def tearDown(self):
        self.temp.cleanup()

    def test_build_persists_and_reruns_with_floor(self):
        result = self.service.symbols_build("paid", **self.args)
        self.assertEqual(result["status"], "DRAFT_VALIDATED")
        self.assertEqual(result["review"]["answer"], 19.75)
        self.assertFalse(result["approved"])
        self.assertGreaterEqual(len(result["checks"]), 9)
        self.assertEqual(self.service.symbols_run("paid")["review"]["answer"], 19.75)
        self.assertFalse(list(self.root.rglob("*.sig*")))

    def test_wrong_column_and_executable_ops_refused(self):
        for op in ({"op": "sum", "column": "imaginary"}, {"op": "exec", "code": "print(1)"}):
            args = dict(self.args, spec_json=json.dumps({**SPEC, "pipeline": [{"op": "rows"}, op]}))
            result = self.service.symbols_build("bad", **args)
            self.assertEqual(result["status"], "REFUSED")
            self.assertFalse((self.root / "systems/bad").exists())

    def test_changed_data_and_spec_are_refused(self):
        for field in ("data.json", "spec.json", "review.json"):
            identifier = field.split(".")[0]
            self.service.symbols_build(identifier, **self.args)
            (self.root / "systems" / identifier / field).write_text("{}")
            with self.assertRaisesRegex(ValueError, "Artifact changed"):
                self.service.symbols_run(identifier)

    def test_no_overwrite_or_traversal(self):
        self.service.symbols_build("paid", **self.args)
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.service.symbols_build("paid", **self.args)
        for identifier in ("../outside", "/tmp/escape", "a/b", "", "UPPER"):
            with self.assertRaises(ValueError):
                self.service.symbols_build(identifier, **self.args)

    def test_symlink_evidence_and_root_refused(self):
        outside = self.root / "outside"
        outside.mkdir()
        (self.root / "systems").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "Symlink"):
            self.service.symbols_build("paid", **self.args)
        self.assertFalse(list(outside.iterdir()))

    def test_duplicate_nonfinite_nested_json_refused(self):
        for value in ('{"a":1,"a":2}', '{"a":NaN}', '{"x":{"b":1,"b":2}}'):
            with self.assertRaises(ValueError):
                decode(value)
        for value in ('{"sales":[{"a":NaN}]}', '{"sales":[{"amount":1,"amount":2}]}'):
            with self.assertRaises(ValueError):
                self.service.dataset(data_json=value)

    def test_exact_decimal_evidence(self):
        args = dict(self.args, data_json='{"sales":[{"status":"paid","amount":123456789.123456789}]}')
        result = self.service.symbols_build("precise", **args)
        raw = (self.root / "systems/precise/data.json").read_text()
        self.assertIn('"123456789.123456789"', raw)
        self.assertEqual(result["status"], "DRAFT_VALIDATED")

    def test_dataset_must_be_unambiguous_and_flat(self):
        with self.assertRaises(ValueError):
            self.service.dataset("capture:a", "{}")
        with self.assertRaises(ValueError):
            self.service.dataset()
        with self.assertRaises(ValueError):
            self.service.dataset(data_json='{"a":[{"nested":{"x":1}}]}')

    def test_missing_evidence_never_claims_success(self):
        args = dict(self.args, data_json='{"sales":[]}')
        self.assertEqual(self.service.symbols_check(**args)["status"], "REFUSED")

    def test_runtime_capture_preserves_all_fields_and_origin(self):
        state = {"game": "goldeneye-dam", "paused": True, "health": 45, "perception": {"enemy": False}, "null": None}
        meta = {"target": "goldeneye", "transport": "live_endpoint_read", "sample_freshness": "unknown", "observed_at": "2026-09-30T00:00:00Z"}
        with patch.object(self.service.observer, "fetch", return_value=(encoded(state), state, meta)):
            result = self.service.runtime_capture("goldeneye", "dam")
        self.assertEqual(result["fields"], 5)
        data, origin = self.service.dataset(dataset="capture:dam")
        self.assertEqual(origin["kind"], "recorded_runtime")
        self.assertEqual(next(r for r in data["fields"] if r["path"] == "/perception/enemy")["value"], False)
        self.assertEqual(decode(read(self.root / "captures/dam/snapshot.json")), state)

    def test_stage_sequence_keeps_distinct_snapshots_and_does_not_claim_full_coverage(self):
        samples = [{"game": "goldeneye-dam", "phase": p, "combat": {"health": h}}
                   for p, h in (("menu", 100), ("playing", 90), ("death", 0))]
        replies = [(encoded(s), s, {"target": "goldeneye", "observed_at": str(i), "complete_runtime_coverage": False})
                   for i, s in enumerate(samples)]
        with patch.object(self.service.observer, "fetch", side_effect=replies), patch("time.sleep") as sleep:
            result = self.service.runtime_capture("goldeneye", "sequence", path="/combat", samples=3)
        self.assertEqual(sleep.call_count, 2)
        data, origin = self.service.dataset(dataset="capture:sequence")
        self.assertEqual([r["phase"] for r in data["state"]], ["menu", "playing", "death"])
        self.assertEqual([r["value"] for r in data["fields"]], [100, 90, 0])
        self.assertEqual(origin["samples"], 3)
        self.assertFalse(result["observation"]["complete_runtime_coverage"])
        self.assertEqual(len(list((self.root / "captures/sequence/snapshots").iterdir())), 3)

    def test_pointer_paging_and_truncation_explicit(self):
        value = {"a/b": {"x~y": [None, False, "x" * 600]}}
        self.assertIs(pointer(value, "/a~1b/x~0y/1"), False)
        result = page(value, limit=2)
        self.assertEqual(result["next_offset"], 2)
        self.assertTrue(page(value, offset=2)["fields"][0]["truncated"])
        for args in ((-1, 1), (0, 101), (False, 1)):
            with self.assertRaises(ValueError):
                page(value, *args)

    def test_runtime_depth_and_row_budget(self):
        with self.assertRaises(ValueError):
            flatten(list(range(15001)))
        value = 1
        for _ in range(50):
            value = {"x": value}
        with self.assertRaises(ValueError):
            flatten(value)

    def test_formula_export(self):
        raw = csv_bytes([{"path": "/label", "kind": "string", "value": "=RUN()"}])
        self.assertIn(b"'=RUN()", raw)

    def test_nonlocal_and_unregistered_runtime_refused(self):
        with self.assertRaises(ValueError):
            self.service.runtime_read("unknown")
        for url in ("http://example.com/api/state", "file:///tmp/x", "http://user@127.0.0.1:123/x"):
            observer = Observer({"bad": {"url": url}})
            with self.assertRaises(ValueError):
                observer.fetch("bad")

    def test_runtime_identity_rate_and_origin_are_checked(self):
        url = "http://127.0.0.1:8093/api/state"
        config = {"game": {"url": url, "identity_pointer": "/game",
                           "identity_prefix": "goldeneye-", "coverage": "test adapter"}}
        reply = MagicMock()
        reply.__enter__.return_value = reply
        reply.status = 200
        reply.geturl.return_value = url
        reply.read.return_value = b'{"game":"goldeneye-dam","paused":true}'
        opener = MagicMock()
        opener.open.return_value = reply
        with patch("urllib.request.build_opener", return_value=opener):
            observer = Observer(config)
            _, _, meta = observer.fetch("game")
            self.assertFalse(meta["complete_runtime_coverage"])
            self.assertTrue(meta["paused"])
            with self.assertRaisesRegex(ValueError, "one second"):
                observer.fetch("game")
            reply.read.return_value = b'{"game":"wrong-runtime"}'
            with self.assertRaisesRegex(ValueError, "identity mismatch"):
                Observer(config).fetch("game")
            reply.geturl.return_value = "http://127.0.0.1:9000/elsewhere"
            with self.assertRaisesRegex(ValueError, "registered endpoint"):
                Observer(config).fetch("game")
        with self.assertRaisesRegex(ValueError, "redirects"):
            NoRedirect().redirect_request(None)

    def test_malformed_rpc_does_not_execute_tool(self):
        with patch.object(self.service, "runtime_capture") as capture:
            with self.assertRaises(ValueError):
                handle(self.service, {"id": 1, "method": "tools/call", "params": ["bad"]})
            capture.assert_not_called()

    def test_bounded_sequence_refuses_before_observation(self):
        for samples, interval in ((0, 1), (6, 1), (1, 0), (1, 6), (True, 1)):
            with patch.object(self.service.observer, "fetch") as fetch:
                with self.assertRaises(ValueError):
                    self.service.runtime_capture("game", "test", samples=samples, interval_seconds=interval)
                fetch.assert_not_called()

    def test_unknown_source_and_cli_unavailable(self):
        with self.assertRaises(ValueError):
            self.service.recover("/Users/secret", "test")
        with self.assertRaises(ValueError):
            self.service.liberate("doctor")

    def test_mcp_discovery_calls_and_errors(self):
        result = handle(self.service, {"id": 1, "method": "tools/list"})
        self.assertEqual(len(result["result"]["tools"]), 8)
        request = {"id": 2, "method": "tools/call", "params": {"name": "symbols_check", "arguments": self.args}}
        self.assertFalse(handle(self.service, request)["result"]["isError"])
        request["params"]["arguments"] = {"bogus": "value"}
        self.assertTrue(handle(self.service, request)["result"]["isError"])
        self.assertIsNone(handle(self.service, {"method": "notifications/initialized"}))

    def test_mutations_are_never_marked_readonly(self):
        for name in ("runtime_capture", "recover", "symbols_build"):
            self.assertEqual(effects()[name], "projectMutation")
        self.assertEqual(effects()["runtime_read"], "readOnly")
        self.assertLess(len(encoded(TOOLS)), 9000)

    def test_schema_rejects_wrong_types_and_extra_arguments(self):
        for args in ({"grammar": "true"}, {"extra": 1}):
            with self.assertRaises(ValueError):
                call(self.service, "capabilities", args)


if __name__ == "__main__":
    unittest.main()
