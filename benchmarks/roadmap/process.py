"""Bounded local trial processes; observations are not hard-containment authority."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=True, allow_nan=False) + '\n')
    path.chmod(0o600)


def snapshot():
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,lstart=,comm='],
                            capture_output=True, text=True, check=True)
    rows = {}
    for line in result.stdout.splitlines():
        parts = line.split(None, 7)
        if len(parts) == 8:
            rows[int(parts[0])] = {'pid': int(parts[0]), 'parent': int(parts[1]),
                                  'start': ' '.join(parts[2:7]), 'executable': parts[7]}
    return rows


def same_process(left, right):
    return left is not None and right is not None and all(
        left[key] == right[key] for key in ('pid', 'start', 'executable'))


def execute(argv, cwd, output, *, environment=None, stdin='', timeout=600,
            output_limit=16 * 1024 * 1024):
    """Retain each attempt and clean only observed descendants of this invocation.

    PID/start/executable binding guards against signalling a reused PID. Sampling cannot
    prove containment of deliberately escaped/unobserved descendants; the receipt says so.
    """
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    output.chmod(0o700)
    (output / 'stdin.txt').write_text(stdin)
    observed = {}
    started = time.monotonic()
    timed_out = exceeded_output = False
    process = None
    failures = []
    before = {}
    with (output / 'stdin.txt').open('rb') as input_file, \
         (output / 'stdout.txt').open('wb') as stdout, \
         (output / 'stderr.txt').open('wb') as stderr:
        try:
            if timeout <= 0 or output_limit <= 0:
                raise ValueError('timeout and output_limit must be positive')
            before = snapshot()
            # A file avoids blocking forever while writing to a child that does not read stdin.
            process = subprocess.Popen([str(x) for x in argv], cwd=cwd, env=environment,
                stdin=input_file, stdout=stdout, stderr=stderr, start_new_session=True)
            while True:
                current = snapshot()
                family = {process.pid}
                while True:
                    expanded = family | {pid for pid, row in current.items() if row['parent'] in family}
                    if family == expanded:
                        break
                    family = expanded
                for pid in family:
                    row = current.get(pid)
                    if row is not None and not same_process(row, before.get(pid)):
                        observed[(pid, row['start'], row['executable'])] = row
                timed_out = time.monotonic() - started >= timeout
                exceeded_output = any((output / name).stat().st_size > output_limit
                                      for name in ('stdout.txt', 'stderr.txt'))
                if process.poll() is not None or timed_out or exceeded_output:
                    break
                time.sleep(0.25)
        except Exception as error:
            failures.append(type(error).__name__ + ': ' + str(error))
        finally:
            if process is not None:
                for sig in (signal.SIGTERM, signal.SIGKILL):
                    try:
                        current = snapshot()
                        for row in reversed(list(observed.values())):
                            if same_process(row, current.get(row['pid'])):
                                try:
                                    os.kill(row['pid'], sig)
                                except ProcessLookupError:
                                    pass
                        if process.poll() is None:
                            try:
                                os.killpg(process.pid, sig)
                            except ProcessLookupError:
                                pass
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            pass
                    except Exception as error:
                        failures.append('cleanup: ' + type(error).__name__ + ': ' + str(error))
                    time.sleep(0.15)
    remaining = []
    group_empty = process is None
    try:
        current = snapshot()
        remaining = [row for row in observed.values() if same_process(row, current.get(row['pid']))]
        if process is not None:
            process.poll()
            group = subprocess.run(['/usr/bin/pgrep', '-g', str(process.pid)], capture_output=True)
            group_empty = group.returncode == 1
    except Exception as error:
        failures.append('cleanup verification: ' + type(error).__name__ + ': ' + str(error))
        group_empty = False
    # An instantly exiting child can exceed the limit before the first poll.
    exceeded_output = exceeded_output or any((output / name).stat().st_size > output_limit
                                            for name in ('stdout.txt', 'stderr.txt'))
    result = {'argv': [str(x) for x in argv], 'cwd': str(cwd),
              'pid': process.pid if process else None,
              'exit_code': process.returncode if process else None, 'timed_out': timed_out,
              'output_limit_exceeded': exceeded_output, 'errors': failures,
              'seconds': time.monotonic() - started, 'observed_processes': list(observed.values()),
              'remaining_processes': remaining, 'process_group_empty': group_empty,
              'containment_grade': 'observed local process cleanup; not hard aggregate containment'}
    for name in ('stdin.txt', 'stdout.txt', 'stderr.txt'):
        (output / name).chmod(0o600)
        result[name] = {'sha256': sha(output / name), 'bytes': (output / name).stat().st_size}
    result['passed'] = (process is not None and process.returncode == 0 and not failures
                       and not timed_out and not exceeded_output and not remaining and group_empty)
    save(output / 'process.json', result)
    if remaining or not group_empty:
        raise RuntimeError('Trial cleanup incomplete: ' + str(output))
    return result


def trial_environment(config_root, project):
    environment = os.environ.copy()
    developer = '/Applications/Xcode.app/Contents/Developer'
    typescript = Path('/Users/lukekist/tinkybink-dashboard/node_modules/typescript').resolve()
    compiler_bins = [str(typescript / 'bin'), developer + '/Toolchains/XcodeDefault.xctoolchain/usr/bin',
                     developer + '/usr/bin']
    environment.update(XDG_CONFIG_HOME=str(config_root), NO_COLOR='1',
        GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_TERMINAL_PROMPT='0',
        PYTHONDONTWRITEBYTECODE='1', DEVELOPER_DIR=developer,
        SDKROOT=developer + '/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk',
        PATH=':'.join(compiler_bins + ['/usr/bin', '/bin', '/usr/sbin', '/sbin', '/opt/homebrew/bin',
                                     '/usr/local/bin', '/Users/lukekist/bin']),
        KIST_BUILDER_TOOLCHAIN_ROOTS=json.dumps([str(typescript)]),
        CLANG_MODULE_CACHE_PATH=str(Path(project) / '.build/clang-cache'),
        SWIFT_MODULECACHE_PATH=str(Path(project) / '.build/swift-cache'))
    return environment
