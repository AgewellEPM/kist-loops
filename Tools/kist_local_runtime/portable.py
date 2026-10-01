#!/usr/bin/env python3
"""Per-user, session-owned model setup for the distributable Kist launcher (macOS/Linux/WSL)."""
import argparse
import fcntl
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

from runtime_install import ensure_ollama, find_ollama, asset_key

HERE = Path(__file__).resolve().parent
CATALOG = [
    {"model": "qwen2.5-coder:1.5b", "bytes": 986062089,
     "digest": "d7372fd828518a4d38b1eb196c673c31a85f2ed302b3d1e406c4c2d1b64a0668"},
    {"model": "qwen2.5-coder:0.5b", "bytes": 397821516,
     "digest": "4ff64a7f502a08b7616edb8ca0a79eb1853fc363d842b7df4b46915d11a3fb09"},
]


def physical_memory():
    if sys.platform == "darwin":
        return int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.memsize"], timeout=3))
    if sys.platform.startswith("linux"):
        return int(next(line.split()[1] for line in Path("/proc/meminfo").read_text().splitlines()
                        if line.startswith("MemTotal:"))) * 1024
    raise RuntimeError("Native Windows is not supported; launch through WSL2.")


def load_runtime():
    spec = importlib.util.spec_from_file_location("kist_local_runtime", HERE / "runtime.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_json(path, data):
    temporary = path.with_name(path.name + ".tmp-" + str(os.getpid()))
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def refresh(runtime):
    entries = runtime.scan_inventory()
    if runtime.INVENTORY_ERROR:
        raise RuntimeError("Cannot read model storage: " + runtime.INVENTORY_ERROR)
    write_json(runtime.ROOT / "catalog.json", entries)
    return entries


def choices(runtime):
    cap = runtime.CONFIG["max_model_bytes"]
    installed = {m["name"]: m for m in refresh(runtime)}
    result = []
    for item in CATALOG:
        if item["bytes"] <= cap:
            result.append({"model": item["model"], "bytes": item["bytes"],
                           "installed": item["model"] in installed})
    for item in installed.values():
        if item["size"] <= cap and not any(c["model"] == item["name"] for c in result):
            result.append({"model": item["name"], "bytes": item["size"], "installed": True})
    return result


def json_call(port, path, body=None, timeout=10):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    try:
        connection.request("POST" if body is not None else "GET", path,
                           body=None if body is None else json.dumps(body).encode(),
                           headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        data = response.read(2 * 1024 * 1024 + 1)
        if response.status != 200 or len(data) > 2 * 1024 * 1024:
            raise RuntimeError("Local model service refused the setup operation.")
        return json.loads(data)
    finally:
        connection.close()


def pull(runtime, port, candidate):
    if shutil.disk_usage(runtime.MODELS).free < candidate["bytes"] + 1024**3:
        raise RuntimeError("Not enough space in the selected model directory.")
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    start = time.monotonic()
    totals = {}
    complete = False
    print(f"Downloading {candidate['model']} ({candidate['bytes'] / 1024**2:.0f} MiB)…", file=sys.stderr)
    try:
        connection.request("POST", "/api/pull", body=json.dumps({"model": candidate["model"], "stream": True}),
                           headers={"Content-Type": "application/json"})
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError("Model download was refused by Ollama.")
        while True:
            line = response.readline(65537)
            if not line:
                break
            if len(line) > 65536 or time.monotonic() - start > 1800:
                raise RuntimeError("Model download exceeded its time or progress-frame limit.")
            frame = json.loads(line)
            if not isinstance(frame, dict):
                raise RuntimeError("Invalid model download progress frame.")
            if frame.get("error"):
                raise RuntimeError(str(frame["error"])[:300])
            if "total" in frame:
                digest = frame.get("digest", "")
                total = frame["total"]
                if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest) or type(total) is not int or total < 0:
                    raise RuntimeError("Invalid model download progress.")
                totals[digest] = max(totals.get(digest, 0), total)
                if len(totals) > 32 or sum(totals.values()) > candidate["bytes"] + 1024**2:
                    raise RuntimeError("Model download exceeds the reviewed model size.")
            complete = complete or frame.get("status") == "success"
        if not complete:
            raise RuntimeError("Model download ended without success.")
    finally:
        connection.close()


def prepare(runtime, model):
    if runtime.DISABLED.exists():
        raise RuntimeError("Local AI is off. Use kist local-ai auto to enable it.")
    option = next((m for m in choices(runtime) if m["model"] == model), None)
    if option is None:
        raise RuntimeError("Model is not in the picker for this computer's memory limit.")
    if runtime.pressure() != 1:
        raise RuntimeError("Memory pressure is too high; no model will be loaded. Close other heavy jobs and retry.")
    base = Path(runtime.CONFIG["private_runtime_root"])
    # Concurrent Kist sessions share weights; serialize preparation, not independent REPLs.
    with (runtime.MODELS / ".kist-prepare.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another Kist session is preparing models. Let it finish, then retry.")
        executable = ensure_ollama(base)
        runtime.CONFIG["ollama_bin"] = executable
        write_json(runtime.CONFIG_PATH, runtime.CONFIG)
        backend = runtime.Runtime()
        try:
            port = backend.start()
            installed = json_call(port, "/api/tags").get("models", [])
            match = next((m for m in installed if m.get("name") == model), None)
            candidate = next((m for m in CATALOG if m["model"] == model), None)
            if match is None:
                if candidate is None:
                    raise RuntimeError("This installed model disappeared; no unreviewed download will replace it.")
                pull(runtime, port, candidate)
                installed = json_call(port, "/api/tags").get("models", [])
                match = next((m for m in installed if m.get("name") == model), None)
            if match is None or (candidate is not None and match.get("digest") != candidate["digest"]):
                raise RuntimeError("Installed model differs from its reviewed manifest; model not selected.")
            if match.get("size", float("inf")) > runtime.CONFIG["max_model_bytes"]:
                raise RuntimeError("Installed model exceeds this computer's local size limit.")
            # Show reads template/metadata without loading a GPU model.
            shown = json_call(port, "/api/show", {"model": model})
            capabilities = shown.get("capabilities", [])
            if capabilities and "completion" not in capabilities:
                raise RuntimeError("This model does not support chat/completion.")
            refresh(runtime)
            print("Model installed and configured. It will load only when called.", file=sys.stderr)
        finally:
            backend.stop()


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=4)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=3)


def data_home():
    return Path(os.environ.get("KIST_DATA_HOME", Path.home() / ".local/share/kist")).expanduser().resolve()


def control(base, action):
    disabled = base / "local-ai-disabled"
    if action in ("off", "freeze", "kill"):
        base.mkdir(parents=True, exist_ok=True)
        disabled.touch()
    elif action in ("auto", "on"):
        disabled.unlink(missing_ok=True)
    elif action != "status":
        raise RuntimeError("Use kist local-ai auto|off|status (freeze and kill also switch off).")
    print("Local AI: " + ("off" if disabled.exists() else "auto · loads only when called"))
    if base.exists():
        for config_path in base.glob("session-*/config.json"):
            try:
                config = json.loads(config_path.read_text())
                print(json.dumps(json_call(config["listen_port"], "/_kist/status", timeout=1)))
            except (OSError, ValueError, RuntimeError, http.client.HTTPException):
                continue
    return 0


def run(binary, arguments):
    if arguments in (["--version"], ["-V"], ["--help"], ["-h"]) or any(
            arg in arguments for arg in ("--operator-action", "--inspect-builder-evidence")):
        return subprocess.call([str(binary), *arguments])
    asset_key()  # Reject unsupported operating systems before creating state.
    base = data_home()
    if arguments[:1] == ["local-ai"]:
        if len(arguments) > 2:
            raise RuntimeError("Use kist local-ai auto|off|status.")
        return control(base, arguments[1] if len(arguments) == 2 else "status")
    base.mkdir(parents=True, exist_ok=True)
    # Reuse an existing external symlink rather than duplicating the user's library.
    existing_models = Path.home() / ".ollama/models"
    existing_library = existing_models.exists() or existing_models.is_symlink() or existing_models.parent.is_symlink()
    default_models = existing_models if existing_library else base / "models"
    model_root = Path(os.environ.get("OLLAMA_MODELS", default_models)).expanduser().resolve()
    volume = None
    if str(model_root).startswith("/Volumes/"):
        volume = Path(*model_root.parts[:3])
        if not volume.is_mount():
            raise RuntimeError("Selected external model volume is not mounted; no internal fallback.")
    model_root.mkdir(parents=True, exist_ok=True)
    # Preserve the invoking repo: neither subprocess changes cwd to the installation directory.
    with tempfile.TemporaryDirectory(prefix="session-", dir=base) as temporary:
        session = Path(temporary)
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        config = {"model_root": str(model_root), "ollama_bin": find_ollama(base / "runtimes") or "",
                  "model_volume": str(volume) if volume else None,
                  "private_runtime_root": str(base / "runtimes"), "disabled_file": str(base / "local-ai-disabled"),
                  "worker_lock": str(base / "local-worker.lock"),
                  "max_model_bytes": min(8 * 1024**3, physical_memory() // 8),
                  "context_tokens": 16384, "default_context_tokens": 16384,
                  "max_output_tokens": 8192, "request_timeout_seconds": 120, "listen_port": port}
        config_path = session / "config.json"
        write_json(config_path, config)
        env = os.environ.copy()
        env.update(KIST_LOCAL_RUNTIME_CONFIG=str(config_path), KIST_LOCAL_SETUP_HELPER=str(Path(__file__).resolve()),
                   KIST_LOCAL_SETUP_PYTHON=sys.executable, KIST_LOCAL_CONTEXT_TOKENS=str(config["context_tokens"]),
                   OLLAMA_HOST=f"http://127.0.0.1:{port}")
        # Inventory is refreshed through the normal user session; no launchd permission inheritance.
        subprocess.run([sys.executable, str(Path(__file__).resolve()), "inventory"], env=env,
                       stdout=subprocess.DEVNULL, check=True)
        gateway = subprocess.Popen([sys.executable, str(HERE / "runtime.py")], env=env,
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while True:
                if gateway.poll() is not None:
                    raise RuntimeError("Session model controller could not start.")
                try:
                    json_call(port, "/_kist/status", timeout=1)
                    break
                except (OSError, http.client.HTTPException):
                    if time.monotonic() > deadline:
                        raise RuntimeError("Session model controller startup timed out.")
                    time.sleep(.05)
            child = subprocess.Popen([str(binary), *arguments], env=env)
            # Ctrl-C belongs to the REPL. Terminating the launcher must still reap its children.
            old_int = signal.signal(signal.SIGINT, lambda *_: None)
            def terminated(*_):
                raise KeyboardInterrupt
            old_term = signal.signal(signal.SIGTERM, terminated)
            try:
                return child.wait()
            finally:
                signal.signal(signal.SIGINT, old_int)
                signal.signal(signal.SIGTERM, old_term)
                if child.poll() is None:
                    child.terminate()
                    try:
                        child.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        child.kill()
                        child.wait(timeout=3)
        finally:
            stop_group(gateway)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("inventory")
    prep = sub.add_parser("prepare")
    prep.add_argument("model")
    launch = sub.add_parser("run")
    launch.add_argument("--binary", required=True, type=Path)
    launch.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command == "run":
        arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
        return run(args.binary.resolve(), arguments)
    runtime = load_runtime()
    if args.command == "inventory":
        print(json.dumps(choices(runtime)))
    else:
        prepare(runtime, args.model)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("Kist local setup: " + str(error), file=sys.stderr)
        raise SystemExit(2)
