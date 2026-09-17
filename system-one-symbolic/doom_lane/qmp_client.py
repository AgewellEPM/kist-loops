"""One persistent QMP connection for the whole control run.

Spawning a fresh `perslis` CLI process per capture/keypress opens and closes
the QMP socket hundreds of times, racing the runtime's poweroff-observation
watcher for QMP's single client slot -> intermittent `channelClosed`
(diagnosed 2026-09-17: qemu stayed ALIVE across every such error, so it was
never the VM dying — only socket churn). Holding ONE connection open for the
entire session removes the churn and the race.

Talks raw QMP: screendump to PPM (PIL reads it), send-key with QKeyCodes.
"""
from __future__ import annotations

import json
import pathlib
import socket
import time


class QmpError(RuntimeError):
    pass


class PersistentQmp:
    def __init__(self, sock_path: str, capture_dir: str, prefix: str = "symdoom"):
        self.sock_path = sock_path
        self.capture_dir = pathlib.Path(capture_dir)
        self.prefix = prefix
        self._shot = 0
        self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._sock.settimeout(15)
        self._sock.connect(sock_path)
        self._buf = b""
        self._read_json()                       # QMP greeting
        self._execute("qmp_capabilities")       # leave negotiation mode

    # -- wire -------------------------------------------------------------
    def _read_json(self) -> dict:
        while b"\r\n" not in self._buf:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise QmpError("QMP connection closed by peer")
            self._buf += chunk
        line, self._buf = self._buf.split(b"\r\n", 1)
        return json.loads(line)

    def _execute(self, command: str, arguments: dict | None = None) -> dict:
        payload = {"execute": command}
        if arguments:
            payload["arguments"] = arguments
        self._sock.sendall((json.dumps(payload) + "\r\n").encode())
        while True:
            message = self._read_json()
            if "error" in message:
                raise QmpError(f"{command}: {message['error'].get('desc', message['error'])}")
            if "return" in message:
                return message["return"]
            # events (e.g. RESET/STOP) are ignored between request and return

    # -- perception + input ----------------------------------------------
    def capture(self):
        """Screendump to PPM; return an RGB PIL image (kept in memory)."""
        from PIL import Image
        self._shot += 1
        ppm = self.capture_dir / f"{self.prefix}_{self._shot:05d}.ppm"
        self._execute("screendump", {"filename": str(ppm)})
        image = Image.open(ppm).convert("RGB")
        image.load()
        return image, ppm

    def send_key(self, qcode: str) -> None:
        self._execute("send-key",
                      {"keys": [{"type": "qcode", "data": qcode}]})

    def send_keys(self, qcodes: list[str], gap_s: float = 0.6) -> None:
        for code in qcodes:
            self.send_key(code)
            time.sleep(gap_s)

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass
