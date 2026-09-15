#!/usr/bin/env python3
"""One bounded LIST observation sync, serialized against Kist deployment.

Run periodically through launchd. This invokes only Kist's deterministic LIST
sync command; it never supplies a model goal or enables the evolution runtime.
"""
import argparse
import fcntl
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import sys
import time

MAX_OUTPUT = 64 * 1024


def run_sync(project, *, installation=None, timeout=90):
    installation = Path(installation or Path.home())
    project = Path(project).resolve(strict=True)
    if not project.is_dir() or project in (Path("/"), Path.home()):
        raise ValueError("LIST sync requires a project directory")
    lease = installation / "bin/.kist-deployment.lock"
    fd = os.open(lease, os.O_RDONLY | os.O_NOFOLLOW)
    child = None
    selector = selectors.DefaultSelector()
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
            raise ValueError("Untrusted Kist deployment lease")
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0, "LIST sync deferred while Kist deployment holds its lease"
        named = lease.lstat()
        if (named.st_dev, named.st_ino) != (info.st_dev, info.st_ino):
            raise ValueError("Kist deployment lease changed")
        # The deterministic mode needs no sourced shell configuration, provider
        # secrets, or wrapper-added shell/computer-use flags.
        binary = installation / "bin/kist-current"
        binary_info = binary.lstat()
        if (not stat.S_ISREG(binary_info.st_mode) or binary_info.st_uid != os.getuid()
                or binary_info.st_mode & 0o022 or not os.access(binary, os.X_OK)):
            raise ValueError("Untrusted installed Kist executable")
        environment = {key: os.environ[key] for key in ("HOME", "USER", "LANG", "TMPDIR")
                       if key in os.environ}
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        child = subprocess.Popen(
            [str(binary), "--list-learning-sync", "--project", str(project)],
            cwd=str(project), env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            start_new_session=True, close_fds=True,
        )
        selector.register(child.stdout, selectors.EVENT_READ)
        deadline = time.monotonic() + timeout
        output = bytearray()
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("LIST sync exceeded its deadline")
            for key, _ in selector.select(min(remaining, 1)):
                chunk = os.read(key.fd, 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output.extend(chunk)
                if len(output) > MAX_OUTPUT:
                    raise ValueError("LIST sync exceeded its output limit")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("LIST sync exceeded its deadline")
        code = child.wait(timeout=remaining)
        return code, output.decode("utf-8", errors="replace").strip()
    finally:
        selector.close()
        if child is not None:
            # This is cleanup of a trusted, observation-only CLI/MCP pair, not an
            # evolution hard-containment claim. No VM or desktop tool is admitted.
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(child.pid, sig)
                except ProcessLookupError:
                    break
            child.wait()
            child.stdout.close()
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    args = parser.parse_args()
    try:
        code, message = run_sync(args.project)
    except (OSError, ValueError, TimeoutError, subprocess.TimeoutExpired) as exc:
        print("LIST sync unavailable: " + str(exc), file=sys.stderr)
        return 2
    if message:
        print(message)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
