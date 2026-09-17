"""Pipe raw ViZDoom frames into ffmpeg -> mp4. Evidence, not vibes.

Fail-fast: if recording is requested and ffmpeg is missing or dies, that is
an error — a run that claims to be recorded must produce a playable file.
"""
from __future__ import annotations

import shutil
import subprocess


class RecorderError(RuntimeError):
    pass


class FrameRecorder:
    """RGB24 frames in, H.264 mp4 out. Call add() per tic, then close()."""

    def __init__(self, path: str, width: int, height: int, fps: int = 35):
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg:
            raise RecorderError("ffmpeg not found — cannot honor --record")
        self.path = path
        self.frames = 0
        self._proc = subprocess.Popen(
            [ffmpeg, "-y", "-loglevel", "error",
             "-f", "rawvideo", "-pixel_format", "rgb24",
             "-video_size", f"{width}x{height}", "-framerate", str(fps),
             "-i", "-",
             "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "23", path],
            stdin=subprocess.PIPE)

    def add(self, frame_rgb24: bytes) -> None:
        if self._proc.poll() is not None:
            raise RecorderError(f"ffmpeg exited early (code {self._proc.returncode})")
        self._proc.stdin.write(frame_rgb24)
        self.frames += 1

    def close(self) -> None:
        self._proc.stdin.close()
        if self._proc.wait(timeout=60) != 0:
            raise RecorderError(f"ffmpeg failed (code {self._proc.returncode})")
