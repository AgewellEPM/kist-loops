#!/usr/bin/env python3
"""Transparent stdio recorder in front of the actual configured COBOL MCP server.

No mocked tool responses or imported builder functions. Records requests/responses,
timestamps and process identities, forwards the exact bytes, and cleans up its child.
Only use with the benchmark's secret-free local inputs/configuration.
"""
import argparse
import json
import os
import selectors
import signal
import subprocess
import sys
import time
import uuid
from support import stop_group


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--trace', required=True)
    args = parser.parse_args()
    with open(args.config) as source:
        config = json.load(source)
    environment = dict(os.environ, **config.get('env', {}))
    environment['PYTHONDONTWRITEBYTECODE'] = '1'
    child = None
    instance = uuid.uuid4().hex
    trace_fd = os.open(args.trace, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(trace_fd, 'w', buffering=1) as trace, selectors.DefaultSelector() as selector:
        def record(direction, payload):
            trace.write(json.dumps({'instance': instance, 'monotonic_ns': time.monotonic_ns(),
                'direction': direction, 'payload': payload}) + '\n')

        def shutdown(signum, _frame):
            raise SystemExit(128 + signum)

        signal.signal(signal.SIGTERM, shutdown)
        signal.signal(signal.SIGINT, shutdown)
        buffers = {'request': bytearray(), 'response': bytearray()}
        try:
            child = subprocess.Popen([config['command']] + config.get('args', []),
                env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, start_new_session=True)
            record('start', {'relay_pid': os.getpid(), 'server_pid': child.pid})
            for source, direction in [(sys.stdin.buffer, 'request'),
                                      (child.stdout, 'response'), (child.stderr, 'stderr')]:
                selector.register(source, selectors.EVENT_READ, direction)
            while selector.get_map():
                for key, _ in selector.select(timeout=0.1):
                    chunk = os.read(key.fd, 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        if key.data == 'request':
                            return
                        continue
                    if key.data == 'stderr':
                        # Only bounded diagnostics are recorded; stdout stays a pure MCP stream.
                        record('stderr', chunk[:4096].decode('utf-8', errors='replace'))
                        continue
                    buffer = buffers[key.data]
                    buffer.extend(chunk)
                    if len(buffer) > 2 * 1024 * 1024:
                        raise RuntimeError('MCP line exceeds recorder bound')
                    while b'\n' in buffer:
                        line, _, remainder = buffer.partition(b'\n')
                        buffer[:] = remainder
                        try:
                            payload = json.loads(line)
                        except (ValueError, UnicodeDecodeError):
                            payload = {'invalid_json': line[:4096].decode('utf-8', errors='replace')}
                        record(key.data, payload)
                        destination = child.stdin if key.data == 'request' else sys.stdout.buffer
                        destination.write(line + b'\n')
                        destination.flush()
                if child.poll() is not None and not any(
                    key.data == 'response' for key in selector.get_map().values()):
                    return
        finally:
            if child is not None:
                stop_group(child)
                for pipe in (child.stdin, child.stdout, child.stderr):
                    pipe.close()
                record('stop', {'server_pid': child.pid, 'exit_code': child.returncode})


if __name__ == '__main__':
    main()
