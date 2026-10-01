import hashlib
import fcntl
import io
import json
import os
from pathlib import Path
import socket
import sys
import tarfile
import tempfile
import threading
import unittest
from unittest.mock import patch

import install_bundle
import portable
import runtime_install


class PortableTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="kist-portable-test-")
        self.root = Path(self.temporary.name)
        self.models = self.root / "models"
        self.models.mkdir()
        self.config = self.root / "config.json"
        self.value = {"model_root": str(self.models), "ollama_bin": "",
                      "max_model_bytes": 2 * 1024**3, "context_tokens": 16384,
                      "default_context_tokens": 16384, "max_output_tokens": 8192,
                      "request_timeout_seconds": 10, "listen_port": 0,
                      "private_runtime_root": str(self.root / "runtimes"),
                      "worker_lock": str(self.root / "worker.lock"),
                      "disabled_file": str(self.root / "disabled")}
        self.config.write_text(json.dumps(self.value))
        self.env = patch.dict(os.environ, {"KIST_LOCAL_RUNTIME_CONFIG": str(self.config)})
        self.env.start()
        self.runtime = portable.load_runtime()

    def tearDown(self):
        self.runtime.RUNTIME.stop()
        self.env.stop()
        self.temporary.cleanup()

    def fake_backend(self):
        executable = self.root / "fake ollama"
        executable.write_text('#!' + sys.executable + '\n' +
            'import os\nfrom http.server import HTTPServer, BaseHTTPRequestHandler\n' +
            'host, port = os.environ["OLLAMA_HOST"].split(":")\n' +
            'HTTPServer((host,int(port)),BaseHTTPRequestHandler).serve_forever()\n')
        executable.chmod(0o755)
        return executable

    def test_empty_library_offers_downloads_that_fit_without_inference(self):
        choices = portable.choices(self.runtime)
        self.assertEqual([x["model"] for x in choices], [x["model"] for x in portable.CATALOG])
        self.assertTrue(all(not x["installed"] for x in choices))
        self.runtime.CONFIG["max_model_bytes"] = 512 * 1024**2
        self.assertEqual(len(portable.choices(self.runtime)), 1)
        self.assertIsNone(self.runtime.RUNTIME.child)

    def test_install_after_controller_start_reloads_binary_and_cross_session_lock(self):
        self.value["ollama_bin"] = str(self.fake_backend())
        self.config.write_text(json.dumps(self.value))
        first, second = self.runtime.Runtime(), self.runtime.Runtime()
        try:
            port = first.start()
            pid = first.child.pid
            with self.assertRaisesRegex(self.runtime.Rejected, "Another Kist session"):
                second.start()
            first.stop()
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            with socket.socket() as check:
                self.assertNotEqual(check.connect_ex(("127.0.0.1", port)), 0)
            second.start()
        finally:
            first.stop()
            second.stop()

    def test_off_refuses_prepare_before_runtime_install_or_network(self):
        self.runtime.DISABLED.touch()
        with patch.object(portable, "ensure_ollama") as install:
            with self.assertRaisesRegex(RuntimeError, "Local AI is off"):
                portable.prepare(self.runtime, portable.CATALOG[0]["model"])
            install.assert_not_called()

    def test_second_preparation_does_not_duplicate_download_or_wait_forever(self):
        with (self.models / ".kist-prepare.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(self.runtime, "pressure", return_value=1), \
                 patch.object(portable, "ensure_ollama") as install:
                with self.assertRaisesRegex(RuntimeError, "Another Kist session"):
                    portable.prepare(self.runtime, portable.CATALOG[0]["model"])
                install.assert_not_called()

    def test_freeze_stops_active_worker_and_prevents_reload(self):
        self.value["ollama_bin"] = str(self.fake_backend())
        self.config.write_text(json.dumps(self.value))
        backend = self.runtime.Runtime()
        finished = threading.Event()
        client, peer = socket.socketpair()
        watcher = None
        try:
            backend.start()
            pid = backend.child.pid
            watcher = threading.Thread(target=backend.watch, args=(finished, False, client))
            watcher.start()
            self.runtime.DISABLED.touch()
            watcher.join(timeout=3)
            self.assertFalse(watcher.is_alive())
            self.assertIsNone(backend.child)
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
            with self.assertRaisesRegex(self.runtime.Rejected, "stopping"):
                backend.start()
        finally:
            finished.set()
            if watcher: watcher.join(timeout=3)
            backend.stop()
            client.close()
            peer.close()

    def test_failed_preparation_always_stops_private_worker(self):
        class Backend:
            stopped = False
            def start(inner): return 1234
            def stop(inner): inner.stopped = True
        backend = Backend()
        with patch.object(self.runtime, "pressure", return_value=1), \
             patch.object(portable, "ensure_ollama", return_value="/unused"), \
             patch.object(self.runtime, "Runtime", return_value=backend), \
             patch.object(portable, "json_call", side_effect=OSError("disconnected")):
            with self.assertRaises(OSError):
                portable.prepare(self.runtime, portable.CATALOG[0]["model"])
        self.assertTrue(backend.stopped)

    def test_changed_installed_catalog_model_cannot_bypass_download_integrity_check(self):
        from unittest.mock import Mock
        backend = Mock()
        candidate = portable.CATALOG[0]
        with patch.object(self.runtime, "pressure", return_value=1), \
             patch.object(portable, "ensure_ollama", return_value="/unused"), \
             patch.object(self.runtime, "Runtime", return_value=backend), \
             patch.object(portable, "pull") as pull, \
             patch.object(portable, "json_call", return_value={"models": [
                 {"name": candidate["model"], "size": candidate["bytes"], "digest": "changed"}]}):
            with self.assertRaisesRegex(RuntimeError, "differs from its reviewed manifest"):
                portable.prepare(self.runtime, candidate["model"])
            pull.assert_not_called()
            backend.stop.assert_called_once()

    def test_size_and_context_rejections_happen_before_worker_load(self):
        entry = {"name": "test:latest", "size": 3 * 1024**3}
        with patch.object(self.runtime, "inventory", return_value=[entry]), \
             patch.object(self.runtime, "pressure", return_value=1):
            with self.assertRaises(self.runtime.Rejected):
                self.runtime.prepare({"model": "test", "messages": []})
            entry["size"] = 1
            with self.assertRaisesRegex(self.runtime.Rejected, "too large"):
                self.runtime.prepare({"model": "test", "messages": [{"content": "x" * 60000}]})
        self.assertIsNone(self.runtime.RUNTIME.child)

    def test_launcher_preserves_repository_arguments_and_reaps_controller(self):
        fake = self.root / "fake kist"
        record = self.root / "record.json"
        fake.write_text('#!' + sys.executable + '\nimport os,sys,json\nfrom pathlib import Path\n' +
                        'Path(os.environ["TEST_RECORD"]).write_text(json.dumps({"cwd":os.getcwd(),"args":sys.argv[1:],"config":os.environ["KIST_LOCAL_RUNTIME_CONFIG"]}))\n')
        fake.chmod(0o755)
        base = self.root / "data"
        with patch.dict(os.environ, {"KIST_DATA_HOME": str(base), "OLLAMA_MODELS": str(self.models),
                                     "TEST_RECORD": str(record)}):
            self.assertEqual(portable.run(fake, ["an argument with spaces", "$(not a command)"]), 0)
        captured = json.loads(record.read_text())
        self.assertEqual(captured["cwd"], os.getcwd())
        self.assertEqual(captured["args"], ["an argument with spaces", "$(not a command)"])
        self.assertFalse(Path(captured["config"]).exists())
        self.assertEqual(list(base.glob("session-*")), [])

    def test_help_and_protocol_calls_do_not_create_runtime_state(self):
        base = self.root / "must not exist"
        with patch.dict(os.environ, {"KIST_DATA_HOME": str(base)}), \
             patch.object(portable.subprocess, "call", return_value=0) as call:
            for args in [["--version"], ["--help"], ["--operator-action", "{}"]]:
                self.assertEqual(portable.run(Path("/fake/kist"), args), 0)
            self.assertEqual(call.call_count, 3)
        self.assertFalse(base.exists())

    def test_platform_selection_does_not_substitute_native_windows(self):
        self.assertEqual(runtime_install.asset_key("linux", "arm64"), "linux-aarch64")
        self.assertEqual(runtime_install.asset_key("linux", "AMD64"), "linux-x86_64")
        with self.assertRaisesRegex(RuntimeError, "WSL2"):
            runtime_install.asset_key("win32", "AMD64")

    def archive(self, name, link=None):
        path = self.root / "fixture.tar"
        with tarfile.open(path, "w") as archive:
            entry = tarfile.TarInfo(name)
            if link:
                entry.type, entry.linkname = tarfile.SYMTYPE, link
                archive.addfile(entry)
            else:
                entry.size, entry.mode = 2, 0o755
                archive.addfile(entry, io.BytesIO(b"ok"))
        return path

    def test_archive_traversal_and_escaping_links_rejected(self):
        dest = self.root / "unpack"
        dest.mkdir()
        for name, link in [("../escape", None), ("/escape", None), ("bin/link", "../../escape")]:
            with self.assertRaises(RuntimeError):
                runtime_install.extract(self.archive(name, link), dest)
        runtime_install.extract(self.archive("bin/ollama"), dest)
        self.assertEqual((dest / "bin/ollama").read_bytes(), b"ok")
        self.assertTrue(os.access(dest / "bin/ollama", os.X_OK))

    def test_runtime_download_must_match_pinned_size_and_digest(self):
        for size, digest in [(1, hashlib.sha256(b"ok").hexdigest()), (2, "0" * 64)]:
            with patch.object(runtime_install.urllib.request, "urlopen", return_value=io.BytesIO(b"ok")):
                with self.assertRaises(RuntimeError):
                    runtime_install.download("https://example.invalid", self.root / "download", size, digest)

    def test_bundle_installer_rejects_corruption_and_wrong_target(self):
        bundle = self.root / "bundle"
        bundle.mkdir()
        (bundle / "kist").write_text("launcher")
        manifest = {"target": sys.platform + "-" + runtime_install.platform.machine().lower(),
                    "files": {"kist": "0" * 64}}
        (bundle / "manifest.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
            install_bundle.install(bundle, self.root / "prefix")
        manifest["target"] = "win32-unsupported"
        (bundle / "manifest.json").write_text(json.dumps(manifest))
        with self.assertRaisesRegex(RuntimeError, "this computer needs"):
            install_bundle.install(bundle, self.root / "prefix")
        self.assertFalse((self.root / "prefix").exists())


if __name__ == "__main__":
    unittest.main()
