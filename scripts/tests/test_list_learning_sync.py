import fcntl
import importlib.util
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "list_learning_sync", Path(__file__).resolve().parents[1] / "kist-list-learning-sync.py")
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class ListLearningSyncTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        (self.root / "bin").mkdir()
        self.project = self.root / "project"
        self.project.mkdir()
        self.lease = self.root / "bin/.kist-deployment.lock"
        self.lease.touch(mode=0o600)

    def tearDown(self):
        self.temporary.cleanup()

    def wrapper(self, script):
        binary = self.root / "bin/kist-current"
        binary.write_text("#!/bin/sh\n" + script + "\n")
        binary.chmod(0o700)

    def test_only_deterministic_sync_arguments_reach_installed_wrapper(self):
        self.wrapper('printf "%s\\n" "$@"')
        code, message = sync.run_sync(self.project, installation=self.root)
        self.assertEqual(code, 0)
        self.assertEqual(message.splitlines(), ["--list-learning-sync", "--project", str(self.project)])

    def test_deployment_lock_defers_before_launch(self):
        self.wrapper("touch launched")
        with self.lease.open() as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            code, message = sync.run_sync(self.project, installation=self.root)
        self.assertEqual(code, 0)
        self.assertIn("deferred", message)
        self.assertFalse((self.project / "launched").exists())

    def test_unavailable_sync_remains_a_failure(self):
        self.wrapper('echo "LIST unavailable"; exit 2')
        code, message = sync.run_sync(self.project, installation=self.root)
        self.assertEqual(code, 2)
        self.assertEqual(message, "LIST unavailable")

    def test_output_overflow_stops_the_process(self):
        self.wrapper("exec /usr/bin/yes overflow")
        with self.assertRaisesRegex(ValueError, "output limit"):
            sync.run_sync(self.project, installation=self.root, timeout=5)

    def test_deadline_stops_a_stalled_sync(self):
        self.wrapper("exec /bin/sleep 30")
        with self.assertRaises(TimeoutError):
            sync.run_sync(self.project, installation=self.root, timeout=0.05)

    def test_symlinked_lease_is_refused_before_launch(self):
        self.wrapper("touch launched")
        other = self.root / "other-lock"
        self.lease.rename(other)
        self.lease.symlink_to(other)
        with self.assertRaises(OSError):
            sync.run_sync(self.project, installation=self.root)
        self.assertFalse((self.project / "launched").exists())


if __name__ == "__main__":
    unittest.main()
