"""Bounded processes and evidence for the local COBOL benchmark (stdlib only)."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=True) + '\n')
    path.chmod(0o600)


def stop_group(process):
    for sig, grace in [(signal.SIGTERM, 0.25), (signal.SIGKILL, 1)]:
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            continue
    process.wait(timeout=2)


def run_process(argv, cwd, label, stdin='', timeout=60, cap=1024 * 1024):
    """Separate bounded streams; nonzero exit, timeout, signal, and truncation never count as success.

    Process-group cleanup covers these cooperative local fixtures, not deliberately escaped sessions.
    """
    cwd, label = Path(cwd), Path(label)
    label.parent.mkdir(parents=True, exist_ok=True)
    environment = {k: os.environ[k] for k in ('HOME', 'PATH', 'LANG', 'LC_ALL', 'TMPDIR', 'USER')
                   if k in os.environ}
    environment.update(NO_COLOR='1', PYTHONDONTWRITEBYTECODE='1')
    streams = {'stdout': bytearray(), 'stderr': bytearray()}
    started = time.monotonic()
    timed_out = truncated = False
    process = None
    with tempfile.TemporaryFile() as input_file, selectors.DefaultSelector() as selector:
        input_file.write(stdin.encode('utf-8'))
        input_file.seek(0)
        try:
            process = subprocess.Popen([str(a) for a in argv], cwd=cwd, env=environment,
                stdin=input_file, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                start_new_session=True)
            for name in streams:
                pipe = getattr(process, name)
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, name)
            while selector.get_map():
                if time.monotonic() - started > timeout:
                    timed_out = True
                    break
                for key, _ in selector.select(timeout=0.02):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    room = cap - len(streams[key.data])
                    streams[key.data].extend(chunk[:max(0, room)])
                    if len(chunk) > room:
                        truncated = True
                        break
                if truncated:
                    break
            if not timed_out and not truncated:
                try:
                    process.wait(timeout=max(0.01, timeout - (time.monotonic() - started)))
                except subprocess.TimeoutExpired:
                    timed_out = True
        finally:
            if process is not None:
                stop_group(process)
                process.stdout.close()
                process.stderr.close()
    result = {'argv': [str(a) for a in argv], 'exit_code': process.returncode,
              'elapsed_seconds': time.monotonic() - started, 'timed_out': timed_out,
              'truncated': truncated, 'pid': process.pid,
              'success': process.returncode == 0 and not timed_out and not truncated}
    for name, data in streams.items():
        path = Path(str(label) + '.' + name)
        path.write_bytes(data)
        result[name] = bytes(data).decode('utf-8', errors='replace')
        result[name + '_sha256'] = hashlib.sha256(data).hexdigest()
    write_json(str(label) + '.process.json', {k: v for k, v in result.items()
                                             if k not in ('stdout', 'stderr')})
    return result


def percentile(values, percent):
    import math
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percent * len(ordered)) - 1)]


def timing_summary(values):
    return {'count': len(values), 'p50_seconds': percentile(values, 0.50),
            'p95_seconds': percentile(values, 0.95), 'p99_seconds': percentile(values, 0.99),
            'max_seconds': max(values) if values else None}
