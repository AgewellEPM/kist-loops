import json
import tempfile
import unittest
from pathlib import Path

from scientist.events import EventLog, LedgerIntegrityError


class EventLogTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = Path(self.dir.name) / "events.jsonl"

    def test_chain_appends_and_reloads(self):
        log = EventLog(self.path)
        first = log.append("a", {"x": 1})
        second = log.append("b", {"y": 2})
        self.assertEqual(second.prev_sha, first.sha)
        reloaded = EventLog(self.path)
        self.assertEqual([e.sha for e in reloaded.events()], [first.sha, second.sha])

    def test_edited_history_is_detected(self):
        log = EventLog(self.path)
        log.append("a", {"x": 1})
        log.append("b", {"y": 2})
        lines = self.path.read_text().splitlines()
        tampered = json.loads(lines[0])
        tampered["payload"]["x"] = 999          # quiet history rewrite
        lines[0] = json.dumps(tampered)
        self.path.write_text("\n".join(lines) + "\n")
        with self.assertRaises(LedgerIntegrityError):
            EventLog(self.path)

    def test_deleted_event_is_detected(self):
        log = EventLog(self.path)
        log.append("a", {"x": 1})
        log.append("b", {"y": 2})
        lines = self.path.read_text().splitlines()
        self.path.write_text(lines[1] + "\n")   # drop the first event
        with self.assertRaises(LedgerIntegrityError):
            EventLog(self.path)

    def test_unencodable_payload_never_touches_disk(self):
        log = EventLog(self.path)
        with self.assertRaises(TypeError):
            log.append("a", {"bad": object()})
        self.assertFalse(self.path.exists(), "encode failure must precede any write")
        self.assertEqual(len(EventLog(self.path)), 0)

    def test_truncation_from_the_end_is_detected(self):
        # Review finding 2026-09-17: a clean tail-truncation leaves a valid sub-chain, so the
        # hash chain alone cannot catch it — the head sidecar must.
        log = EventLog(self.path)
        log.append("a", {"x": 1})
        log.append("b", {"y": 2})
        log.append("c", {"z": 3})
        lines = self.path.read_text().splitlines()
        self.path.write_text("\n".join(lines[:2]) + "\n")    # drop the LAST event only
        with self.assertRaises(LedgerIntegrityError) as caught:
            EventLog(self.path)
        self.assertIn("truncated", str(caught.exception))

    def test_deleted_log_with_surviving_sidecar_is_detected(self):
        log = EventLog(self.path)
        log.append("a", {"x": 1})
        self.path.unlink()
        with self.assertRaises(LedgerIntegrityError):
            EventLog(self.path)

    def test_interrupted_append_repairs_instead_of_bricking(self):
        # Crash between log append and sidecar write leaves the sidecar exactly one behind —
        # provably crash-shaped (the last event chains FROM the recorded head), so reload
        # repairs rather than refusing the whole ledger.
        log = EventLog(self.path)
        first = log.append("a", {"x": 1})
        log.append("b", {"y": 2})
        log.head_path.write_text(first.sha + "\n")           # simulate the lost sidecar write
        recovered = EventLog(self.path)
        self.assertEqual(len(recovered), 2)
        self.assertEqual(recovered.head_path.read_text().strip(), recovered.head_sha)

    def test_sidecar_pointing_elsewhere_is_detected(self):
        log = EventLog(self.path)
        log.append("a", {"x": 1})
        log.append("b", {"y": 2})
        log.head_path.write_text("f" * 64 + "\n")            # neither head nor one-behind
        with self.assertRaises(LedgerIntegrityError):
            EventLog(self.path)


if __name__ == "__main__":
    unittest.main()
