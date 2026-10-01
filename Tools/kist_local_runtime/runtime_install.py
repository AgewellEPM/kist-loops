"""Install a pinned official Ollama CLI into Kist's private directory, without sudo."""
import ctypes
import ctypes.util
import hashlib
import os
from pathlib import Path
import platform
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.request

VERSION = "0.35.0"
# Official GitHub release metadata, checked 2026-10-01. No unpinned install script is executed.
ASSETS = {
    "darwin": ("ollama-darwin.tgz", 160167937,
               "2608dbb0a0f0136a198db9d48b4f74ece55f452314a39452fca35b7cf20c2589"),
    "linux-x86_64": ("ollama-linux-amd64.tar.zst", 1427765407,
                     "1c114a6b220c5efca2ef2b1e5f01d1e535e26f6cd6d1678c8489325d2835e525"),
    "linux-aarch64": ("ollama-linux-arm64.tar.zst", 1550231393,
                      "cb627d332b1fe5055bd5485ca10d595da8429e447648209e375390ec3bd09374"),
}


def asset_key(system=None, machine=None):
    system = system or sys.platform
    machine = machine or platform.machine()
    if system == "darwin":
        return "darwin"
    if system.startswith("linux"):
        return "linux-" + {"arm64": "aarch64", "amd64": "x86_64"}.get(machine.lower(), machine.lower())
    raise RuntimeError("Use the Windows Terminal/PowerShell launcher with WSL2; native Windows Kist is not supported.")


def download(url, destination, size, digest):
    checksum = hashlib.sha256()
    count = 0
    deadline = time.monotonic() + 1800
    with urllib.request.urlopen(url, timeout=30) as response, destination.open("wb") as out:
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            count += len(chunk)
            if time.monotonic() > deadline:
                raise RuntimeError("Runtime archive download timed out.")
            if count > size:
                raise RuntimeError("Runtime archive exceeds its pinned size.")
            checksum.update(chunk)
            out.write(chunk)
    if count != size or checksum.hexdigest() != digest:
        raise RuntimeError("Official runtime archive checksum or size does not match; nothing installed.")


def decompress_zstd(source, target, maximum=12 * 1024**3):
    """Use the distro's libzstd, avoiding an additional interpreter/package installation."""
    name = ctypes.util.find_library("zstd")
    if not name:
        raise RuntimeError("This Linux install needs libzstd (Ubuntu: sudo apt install libzstd1).")
    lib = ctypes.CDLL(name)
    class Buffer(ctypes.Structure):
        _fields_ = [("data", ctypes.c_void_p), ("size", ctypes.c_size_t), ("pos", ctypes.c_size_t)]
    lib.ZSTD_createDStream.restype = ctypes.c_void_p
    lib.ZSTD_initDStream.argtypes = [ctypes.c_void_p]
    lib.ZSTD_initDStream.restype = ctypes.c_size_t
    lib.ZSTD_decompressStream.argtypes = [ctypes.c_void_p, ctypes.POINTER(Buffer), ctypes.POINTER(Buffer)]
    lib.ZSTD_decompressStream.restype = ctypes.c_size_t
    lib.ZSTD_isError.argtypes = [ctypes.c_size_t]
    lib.ZSTD_isError.restype = ctypes.c_uint
    lib.ZSTD_freeDStream.argtypes = [ctypes.c_void_p]
    stream = lib.ZSTD_createDStream()
    if not stream:
        raise RuntimeError("Cannot allocate the archive decoder.")
    total, remaining = 0, 1
    try:
        if lib.ZSTD_isError(lib.ZSTD_initDStream(stream)):
            raise RuntimeError("Cannot initialize the archive decoder.")
        with source.open("rb") as incoming, target.open("wb") as outgoing:
            while True:
                chunk = incoming.read(1024 * 1024)
                if not chunk:
                    break
                data = ctypes.create_string_buffer(chunk)
                inp = Buffer(ctypes.cast(data, ctypes.c_void_p), len(chunk), 0)
                while inp.pos < inp.size:
                    output = ctypes.create_string_buffer(1024 * 1024)
                    out = Buffer(ctypes.cast(output, ctypes.c_void_p), len(output), 0)
                    remaining = lib.ZSTD_decompressStream(stream, ctypes.byref(out), ctypes.byref(inp))
                    if lib.ZSTD_isError(remaining):
                        raise RuntimeError("Corrupt zstd runtime archive.")
                    total += out.pos
                    if total > maximum:
                        raise RuntimeError("Expanded runtime archive exceeds its size limit.")
                    outgoing.write(output.raw[:out.pos])
        if remaining != 0:
            raise RuntimeError("Truncated zstd runtime archive.")
    finally:
        lib.ZSTD_freeDStream(stream)


def extract(source, destination):
    """Extract a verified vendor archive while rejecting traversal, devices and escaping links."""
    root = destination.resolve()
    with tarfile.open(source, "r:*") as archive:
        members = archive.getmembers()
        if len(members) > 50000 or sum(m.size for m in members) > 12 * 1024**3:
            raise RuntimeError("Runtime archive exceeds extraction limits.")
        for member in members:
            path = (root / member.name).resolve()
            if member.name.startswith("/") or root not in path.parents and path != root:
                raise RuntimeError("Runtime archive path escapes its private directory.")
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise RuntimeError("Runtime archive contains a special filesystem entry.")
            if member.issym() or member.islnk():
                target = (path.parent if member.issym() else root) / member.linkname
                if member.linkname.startswith("/") or root not in target.resolve().parents:
                    raise RuntimeError("Runtime archive link escapes its private directory.")
            # Validate against already-created links too, immediately before each write.
            if root not in path.resolve().parents and path.resolve() != root:
                raise RuntimeError("Runtime archive has a linked parent outside its directory.")
            archive.extract(member, root, set_attrs=False)
            if member.isfile() and not path.is_symlink():
                path.chmod(0o755 if member.mode & 0o111 else 0o644)


def find_ollama(base):
    existing = shutil.which("ollama")
    if existing:
        return str(Path(existing).resolve())
    key = asset_key()
    if key not in ASSETS:
        raise RuntimeError("No supported official Ollama archive for this CPU.")
    destination = base / ("ollama-" + VERSION + "-" + key)
    for executable in [destination / "bin/ollama", destination / "ollama"]:
        if executable.is_file() and os.access(executable, os.X_OK):
            return str(executable)
    return None


def ensure_ollama(base):
    existing = find_ollama(base)
    if existing:
        return existing
    key = asset_key()
    asset, size, digest = ASSETS[key]
    destination = base / ("ollama-" + VERSION + "-" + key)
    base.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(base).free < size * 8 + 1024**3:
        raise RuntimeError("Insufficient free disk space to install the private model runtime.")
    print(f"Installing official Ollama {VERSION} ({size / 1024**2:.0f} MiB) into your Kist data directory…", file=sys.stderr)
    with tempfile.TemporaryDirectory(prefix="ollama-install-", dir=base) as temporary:
        staging = Path(temporary)
        archive = staging / asset
        download(f"https://github.com/ollama/ollama/releases/download/v{VERSION}/{asset}", archive, size, digest)
        if asset.endswith(".zst"):
            unpacked = staging / "runtime.tar"
            decompress_zstd(archive, unpacked)
            archive = unpacked
        content = staging / "content"
        content.mkdir()
        extract(archive, content)
        executable = next((p for p in [content / "bin/ollama", content / "ollama"] if p.is_file()), None)
        if executable is None:
            raise RuntimeError("Official archive has no expected Ollama executable.")
        executable.chmod(0o755)
        relative = executable.relative_to(content)
        if destination.exists():
            raise RuntimeError("An incomplete runtime directory already exists; inspect it before retrying.")
        content.rename(destination)
    return str(destination / relative)
