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
        self.assertEqual(len(EventLog(self.path)), 0)


if __name__ == "__main__":
    unittest.main()
