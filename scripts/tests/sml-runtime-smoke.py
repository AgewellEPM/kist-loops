#!/usr/bin/env python3
"""Offline CLI regression: failed tasks, free-run, HTTP inputs, responsive serving.

Only temporary projects and a loopback HTTP fixture are used. No provider keys,
MCP servers, browsers, or containers are needed.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))
    path.chmod(0o600)


def configure(project, capabilities, policy=None):
    config = project / '.kist/sml'
    write_json(config / 'catalog.json', {
        'schema_version': 1, 'tool_capabilities': capabilities,
        'approval_authorities': ['host-operator']})
    write_json(config / 'authority.json', {'schema_version': 1, 'actors': [{
        'id': 'sml-runtime-exporter', 'roles': ['workflow-agent'],
        'operations': ['workflow.run', 'workflow.inspect', 'task.watch', 'receipts.list',
                       'task.approve_request', 'task.refuse_request', 'task.rollback',
                       'task.claim_capability', 'task.record_step', 'task.reconcile'],
        'approval_authorities': ['host-operator']}]})
    if policy:
        write_json(config / 'policy.json', {'schema_version': 1, 'default': policy})


def workflow(project, capability, arguments):
    write_json(project / 'workflow.json', {
        'ir_version': 1, 'id': 'smoke.tool', 'version': '1.0.0', 'name': 'Smoke tool',
        'source': {'kind': 'native', 'reference': 'test://sml-smoke'},
        'trigger': {'kind': 'manual'}, 'state_schema': [
            {'name': 'output', 'type': 'string', 'required': False}],
        'interface': {'output_fields': ['output']}, 'entrypoint': 'call',
        'instructions': [
            {'id': 'call', 'op': 'CALL_TOOL', 'capability': capability,
             'arguments': dict(arguments, output_field='output'), 'next': 'done'},
            {'id': 'done', 'op': 'EMIT_RECEIPT', 'receipt_fields': ['output']}]})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default=str(Path(__file__).resolve().parents[2] / '.build/debug/kist'))
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    environment = dict(os.environ, NO_COLOR='1')
    environment.pop('KIST_ACTIVE', None)

    def run(project, arguments, stdin=None):
        result = subprocess.run([binary, '--project', str(project)] + arguments,
                                cwd=project, env=environment, input=stdin, text=True,
                                capture_output=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        return result

    def repl(project, source, lines):
        return run(project, ['--sml-runtime-repl', source, '--sml-runtime-durable'], lines)

    def snapshot(project):
        return json.loads((project / '.kist/sml/runtime.json').read_text())

    with tempfile.TemporaryDirectory(prefix='kist-sml-smoke-') as temporary:
        root = Path(temporary).resolve()
        missing = root / 'missing-capability'
        missing.mkdir()
        configure(missing, ['missing.build'])
        workflow(missing, 'missing.build', {})
        repl(missing, 'workflow.json', 'start MISSING\napprove MISSING {"task_revision":1}\nexit\n')
        state = snapshot(missing)
        task = state['tasks']['MISSING']
        assert task['status'] == 'waiting_capability', task
        assert not task.get('capability_claim'), 'unavailable tool acquired a phantom dispatch claim'
        assert not any(r['kind'] == 'capability_claimed' for r in state['receipts'].values()), state
        repl(missing, 'workflow.json', 'watch MISSING\nexit\n')
        assert snapshot(missing)['tasks']['MISSING'] == task, 'parked task changed on restart'
        print('PASS: admitted missing tool stays parked without a dispatch claim across restart')

        failed = root / 'failed'
        failed.mkdir()
        configure(failed, ['read_file'])
        workflow(failed, 'read_file', {'path': 'does-not-exist.txt'})
        repl(failed, 'workflow.json', 'start FAIL\napprove FAIL {"task_revision":1}\nexit\n')
        state = snapshot(failed)
        task = state['tasks']['FAIL']
        assert task['status'] == 'failed', task
        assert not task.get('capability_claim'), task
        assert any(r['kind'] == 'step_recorded' and r['payload'].get('outcome') == 'failed'
                   for r in state['receipts'].values()), state['receipts']
        repl(failed, 'workflow.json', 'watch FAIL\nexit\n')
        assert snapshot(failed)['tasks']['FAIL'] == task, 'failed task changed on restart'
        print('PASS: missing file records durable failure and clears the in-flight claim')

        for policy in ['free_run']:
            free = root / policy
            free.mkdir()
            configure(free, ['list_files'], policy)
            workflow(free, 'list_files', {'path': '.'})
            repl(free, 'workflow.json', 'start FREE\nwatch\nexit\n')
            assert snapshot(free)['tasks']['FREE']['status'] == 'completed', policy
            print('PASS: %s dispatches a read without an impossible approval' % policy)

        requests = []
        entered = threading.Event()
        release = threading.Event()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                requests.append(self.path)
                # Simulate a side effect followed by a lost reply: retrying would duplicate it.
                self.connection.shutdown(socket.SHUT_RDWR)
                self.connection.close()

            def do_GET(self):
                requests.append(self.path)
                if self.path == '/public/slow/details':
                    entered.set()
                    release.wait(timeout=10)
                body = b'{"ok":true}'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        fixture = http.server.HTTPServer(('127.0.0.1', 0), Handler)
        fixture_thread = threading.Thread(target=fixture.serve_forever,
                                          kwargs={'poll_interval': 0.05}, daemon=True)
        fixture_thread.start()
        host = None
        try:
            interrupted = root / 'interrupted'
            interrupted.mkdir()
            write_json(interrupted / 'api.json', {
                'openapi': '3.0.3', 'info': {'title': 'Recovery', 'version': '1.0.0'},
                'servers': [{'url': 'http://127.0.0.1:%s' % fixture.server_port}],
                'paths': {'/effect': {'post': {'operationId': 'smoke.effect',
                    'responses': {'200': {'description': 'OK'}}}}}})
            imported = run(interrupted, ['--sml-import-openapi', 'api.json', '--sml-api-id', 'recovery'])
            recovery_source = json.loads(imported.stdout)['workflow_source_set']
            configure(interrupted, ['smoke.effect'])
            repl(interrupted, recovery_source, 'start EFFECT\napprove EFFECT {"task_revision":1}\nexit\n')
            uncertain = snapshot(interrupted)['tasks']['EFFECT']
            assert uncertain['status'] == 'waiting_capability' and uncertain.get('capability_claim'), uncertain
            claim = uncertain['capability_claim']
            before_count = requests.count('/effect')
            assert before_count == 1, requests
            body = {'task_revision': uncertain['task_revision'], 'dispatch_id': claim['dispatch_id'],
                    'note': 'Fixture lost its reply; retire this task without repeating its effect'}
            repl(interrupted, recovery_source, 'reconcile EFFECT ' + json.dumps(body) + '\nexit\n')
            recovered = snapshot(interrupted)
            assert recovered['tasks']['EFFECT']['status'] == 'failed'
            assert not recovered['tasks']['EFFECT'].get('capability_claim')
            assert any(r['kind'] == 'reconciled' and r['payload']['external_outcome'] == 'unknown'
                       for r in recovered['receipts'].values())
            assert requests.count('/effect') == before_count, 'reconciliation replayed an external operation'
            requests.clear()
            print('PASS: lost-reply dispatch can be retired after restart without replay')

            project = root / 'http'
            project.mkdir()
            write_json(project / 'api.json', {
                'openapi': '3.0.3', 'info': {'title': 'Smoke', 'version': '1.0.0'},
                'servers': [{'url': 'http://127.0.0.1:%s' % fixture.server_port}],
                'paths': {'/public/{id}/details': {'get': {
                    'operationId': 'smoke.details',
                    'parameters': [{'name': 'id', 'in': 'path', 'required': True,
                                    'schema': {'type': 'string'}}],
                    'responses': {'200': {'description': 'OK'}}}}}})
            imported = run(project, ['--sml-import-openapi', 'api.json', '--sml-api-id', 'smoke'])
            source = json.loads(imported.stdout)['workflow_source_set']
            configure(project, ['smoke.details'])
            repl(project, source, 'start DOTS {"path_id":".."}\napprove DOTS {"task_revision":1}\nexit\n')
            assert not requests, requests
            assert snapshot(project)['tasks']['DOTS']['status'] == 'failed'
            print('PASS: invalid path value is refused before any HTTP request')

            with socket.socket() as port_probe:
                port_probe.bind(('127.0.0.1', 0))
                port = port_probe.getsockname()[1]
            base = 'http://127.0.0.1:%s' % port
            host = subprocess.Popen([binary, '--project', str(project), '--sml-runtime-serve',
                                     source, '--sml-port', str(port)], cwd=project, env=environment,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            token_path = project / '.kist/sml/serve/session-token'
            token = None

            def request(path, body=None):
                data = None if body is None else json.dumps(body).encode()
                req = urllib.request.Request(base + path, data=data,
                    headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
                with urllib.request.urlopen(req, timeout=2) as response:
                    return json.loads(response.read())

            deadline = time.monotonic() + 10
            while time.monotonic() < deadline and host.poll() is None:
                if token_path.exists():
                    token = token_path.read_text()
                    try:
                        request('/approvals')
                        break
                    except OSError:
                        pass
                time.sleep(0.05)
            else:
                raise AssertionError('SML server did not become ready')
            workflow_id = next(iter(snapshot(project)['tasks'].values()))['workflow_id']
            task_base = '/sml/workflows/' + workflow_id + '/tasks'
            request(task_base, {'task_id': 'SLOW', 'input': {'path_id': 'slow'}})
            pending = request('/approvals')['approvals']
            revision = next(p['task_revision'] for p in pending if p['task_id'] == 'SLOW')
            start = time.monotonic()
            request(task_base + '/SLOW/approve', {'task_revision': revision})
            assert time.monotonic() - start < 1.5, 'approval waited on external tool'
            assert entered.wait(timeout=2), 'slow fixture did not receive dispatch'
            start = time.monotonic()
            request('/approvals')
            assert time.monotonic() - start < 1.5, 'status blocked behind external tool'
            release.set()
            deadline = time.monotonic() + 5
            while snapshot(project)['tasks']['SLOW']['status'] != 'completed':
                assert time.monotonic() < deadline, snapshot(project)['tasks']['SLOW']
                time.sleep(0.02)
            host.send_signal(signal.SIGTERM)
            stdout, stderr = host.communicate(timeout=5)
            assert host.returncode == 0, stdout + stderr
            assert not token_path.exists(), 'session token survived shutdown'
            print('PASS: approval and status stay responsive during dispatch; shutdown cleans up')
        finally:
            release.set()
            if host is not None and host.poll() is None:
                host.kill()
                host.communicate(timeout=5)
            fixture.shutdown()
            fixture.server_close()
            fixture_thread.join(timeout=5)
            assert not fixture_thread.is_alive(), 'fixture thread survived cleanup'
    print('SML runtime smoke passed')


if __name__ == '__main__':
    main()
