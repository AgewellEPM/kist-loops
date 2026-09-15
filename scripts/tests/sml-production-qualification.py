#!/usr/bin/env python3
"""Real CLI qualification using temporary projects and an offline loopback fixture.

Exercises sustained/concurrent approved dispatch, operator latency, conflicting
approvals, graceful termination, crash/restart effect accounting, fresh-project
restore, archive/restart cycles, maximum responses, capacity backpressure and health.
Never uses a provider, browser, VM, container, or installed Kist state. Writes a
machine-readable result even when a gate fails; measurements describe this host
and binary, not a universal capacity or exactly-once external-effects guarantee.
"""
import argparse
import collections
import concurrent.futures
import hashlib
import http.server
import json
import math
import os
from pathlib import Path
import platform
import signal
import socket
import subprocess
import tempfile
import threading
import time
import traceback
import urllib.error
import urllib.request


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')
    path.chmod(0o600)


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def distribution(values):
    return {'count': len(values), 'p50_seconds': percentile(values, .50),
            'p95_seconds': percentile(values, .95), 'p99_seconds': percentile(values, .99),
            'maximum_seconds': max(values) if values else None}


def write_report(output, result):
    lines = ['# SML production qualification evidence', '',
             'Campaign result: **' + ('PASS' if result.get('passed') else 'FAIL') + '**.', '',
             'This result describes the measured binary, machine, and workload. It does not establish '
             'external provider availability, multi-tenant isolation, or unlimited capacity.', '',
             '- Binary: `' + result.get('binary', 'unknown') + '`',
             '- SHA-256: `' + result.get('binary_sha256', 'unknown') + '`',
             '- Workload: `' + json.dumps(result.get('workload', {}), sort_keys=True) + '`', '']
    load = result.get('load')
    if load:
        lines += ['| Measurement | Result |', '|---|---:|',
                  '| Completed tasks | %s |' % load['completed_tasks'],
                  '| Elapsed seconds | %.3f |' % load['elapsed_seconds'],
                  '| Completed tasks per second | %.3f |' % load['completed_tasks_per_second'],
                  '| Hot runtime bytes | %s |' % load['runtime_bytes'],
                  '| Maximum sampled RSS bytes | %s |' % load['maximum_rss_bytes']]
        for label, field in [('Operator API p95 seconds', 'operator_latency'),
                             ('Mutation API p95 seconds', 'mutation_latency'),
                             ('Offered-to-completed p95 seconds', 'completion_lag_from_offered_schedule')]:
            value = load.get(field, {}).get('p95_seconds')
            lines.append('| %s | %s |' % (label, 'unavailable' if value is None else '%.3f' % value))
        lines += ['']
    if result.get('gates'):
        lines += ['| Gate | Result |', '|---|---|']
        lines += ['| %s | %s |' % (name, 'PASS' if passed else 'FAIL')
                  for name, passed in result['gates'].items()]
        lines += ['']
    if result.get('error'):
        lines += ['Failure: `' + result['error'].replace('`', "'") + '`.', '']
    lines += ['Each host and fixture is stopped in guaranteed cleanup. Exact lifecycle, effect counts, '
              'maintenance results, cleanup state, and measurements are in [qualification.json](qualification.json).', '']
    (output / 'report.md').write_text('\n'.join(lines))


class Fixture:
    def __init__(self, root, response_bytes):
        self.lock = threading.Lock()
        self.counts = collections.Counter()
        self.entered = {name: threading.Event() for name in ('graceful', 'crash')}
        self.release = {name: threading.Event() for name in ('graceful', 'crash')}
        self.ledger_path = root / 'external-effects.jsonl'
        self.response_body = b'{"ok":"' + b'x' * (response_bytes - 9) + b'"}'
        fixture = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                name = self.path.rsplit('/', 1)[-1]
                with fixture.lock:
                    fixture.counts[name] += 1
                    with fixture.ledger_path.open('a') as ledger:
                        ledger.write(json.dumps({'effect': name, 'at': time.time()}) + '\n')
                        ledger.flush()
                        os.fsync(ledger.fileno())
                if name in fixture.entered:
                    fixture.entered[name].set()
                    fixture.release[name].wait(timeout=45)
                else:
                    time.sleep(.02)
                body = (b'{"ok":"' + b'x' * (65_536 - 9) + b'"}'
                        if name.startswith('large-') else fixture.response_body)
                try:
                    self.send_response(200)
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass  # Expected when the host is deliberately killed after the effect.

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={'poll_interval': .05}, daemon=True)
        self.thread.start()

    def close(self):
        for event in self.release.values():
            event.set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        assert not self.thread.is_alive(), 'fixture thread survived cleanup'


class Host:
    def __init__(self, binary, project, source, output, sequence, environment):
        self.project = project
        self.token_path = project / '.kist/sml/serve/session-token'
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        self.base = 'http://127.0.0.1:%s' % port
        self.log = (output / ('host-%s.log' % sequence)).open('w')
        self.process = subprocess.Popen(
            [binary, '--project', str(project), '--sml-runtime-serve', source,
             '--sml-port', str(port)], cwd=project, env=environment,
            stdout=self.log, stderr=subprocess.STDOUT)
        self.token = ''
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and self.process.poll() is None:
                if self.token_path.exists():
                    self.token = self.token_path.read_text()
                    try:
                        status, _, _ = self.request('/approvals')
                        if status == 200:
                            workflow_id = next(iter(self.snapshot()['workflows'].values()))['workflow']['id']
                            self.task_base = '/sml/workflows/' + workflow_id + '/tasks'
                            return
                    except OSError:
                        pass
                time.sleep(.05)
            raise AssertionError('SML host did not become ready; inspect host-%s.log' % sequence)
        except BaseException:
            self.close()
            raise

    def request(self, path, body=None, timeout=20):
        started = time.monotonic()
        request = urllib.request.Request(self.base + path,
            data=None if body is None else json.dumps(body).encode(),
            headers={'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, json.loads(response.read()), time.monotonic() - started
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read()), time.monotonic() - started

    def snapshot(self):
        return json.loads((self.project / '.kist/sml/runtime.json').read_text())

    def start_and_approve(self, task_id, effect):
        base = self.task_base
        status, body, start_latency = self.request(base, {'task_id': task_id, 'input': {'path_id': effect}})
        assert status == 201, (status, body)
        status, body, approval_latency = self.request(base + '/' + task_id + '/approve', {'task_revision': 1})
        assert status == 200, (status, body)
        return start_latency, approval_latency

    def wait_task(self, task_id, expected, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            task = self.snapshot()['tasks'].get(task_id)
            if task and task['status'] == expected:
                return task
            if self.process.poll() is not None:
                raise AssertionError('host exited while waiting for task ' + task_id)
            time.sleep(.025)
        raise AssertionError(('task did not reach ' + expected, task))

    def stop(self, timeout=40):
        started = time.monotonic()
        self.process.send_signal(signal.SIGTERM)
        code = self.process.wait(timeout=timeout)
        assert code == 0, ('host shutdown exit', code)
        assert not self.token_path.exists(), 'session token survived graceful shutdown'
        return time.monotonic() - started

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=5)
        self.log.close()


def configure(binary, project, fixture, environment):
    config = project / '.kist/sml'
    write_json(config / 'catalog.json', {'schema_version': 1,
        'tool_capabilities': ['qualification.effect'], 'approval_authorities': ['host-operator']})
    write_json(config / 'authority.json', {'schema_version': 1, 'actors': [{
        'id': 'sml-runtime-exporter', 'roles': ['workflow-agent'],
        'operations': ['workflow.run', 'workflow.inspect', 'task.watch', 'receipts.list',
                       'task.approve_request', 'task.refuse_request', 'task.rollback',
                       'task.claim_capability', 'task.record_step', 'task.reconcile'],
        'approval_authorities': ['host-operator']}]})
    write_json(project / 'api.json', {'openapi': '3.0.3',
        'info': {'title': 'Qualification', 'version': '1.0.0'},
        'servers': [{'url': 'http://127.0.0.1:%s' % fixture.server.server_port}],
        'paths': {'/effects/{id}': {'post': {'operationId': 'qualification.effect',
            'parameters': [{'name': 'id', 'in': 'path', 'required': True, 'schema': {'type': 'string'}}],
            'responses': {'200': {'description': 'Accepted'}}}}}})
    imported = subprocess.run([binary, '--project', str(project), '--sml-import-openapi',
                               'api.json', '--sml-api-id', 'qualification'], cwd=project,
                              env=environment, capture_output=True, text=True, timeout=20)
    assert imported.returncode == 0, imported.stdout + imported.stderr
    return json.loads(imported.stdout)['workflow_source_set']


def run_retention_cycles(binary, project, source, output, environment, fixture, hosts, maintenance, result):
    retention = {'cycles': [], 'all_effects_once': False, 'retired_id_reuse_refused': False}
    result['retention_cycles'] = retention
    for cycle in range(1, 4):
        host = Host(binary, project, source, output, 'cycle-%d' % cycle, environment)
        hosts.append(host)
        latencies, errors = [], []
        stop = threading.Event()

        def monitor():
            while not stop.is_set():
                try:
                    code, body, latency = host.request('/approvals')
                    assert code == 200, (code, body)
                    latencies.append(latency)
                except BaseException as error:
                    errors.append(repr(error))
                    return
                stop.wait(.2)

        watcher = threading.Thread(target=monitor, daemon=True)
        watcher.start()
        started = time.monotonic()

        def execute(index):
            task = 'CYCLE-%d-%05d' % (cycle, index)
            host.start_and_approve(task, 'cycle-%d-%05d' % (cycle, index))
            # Bound the producer backlog independently of the service's admission limits.
            host.wait_task(task, 'completed')

        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                list(pool.map(execute, range(300)))
        finally:
            stop.set()
            watcher.join(timeout=25)
            assert not watcher.is_alive(), 'retention monitor survived cleanup'
        assert not errors, errors
        hot_bytes = (project / '.kist/sml/runtime.json').stat().st_size
        hot_tasks = len(host.snapshot()['tasks'])
        host.stop()
        archive_started = time.monotonic()
        cutoff = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() + 2))
        archived = maintenance(project, ['--sml-store', 'archive', '--sml-archive-before', cutoff])
        maintenance(project, ['--sml-store', 'verify'])
        record = {'added_task_count': 300, 'elapsed_seconds': archive_started - started,
            'operator_latency': distribution(latencies), 'hot_runtime_bytes_before_archive': hot_bytes,
            'hot_tasks_before_archive': hot_tasks, 'archived_tasks_after': archived['archivedTaskCount'],
            'archive_seconds': time.monotonic() - archive_started}
        retention['cycles'].append(record)
        print('RETENTION:', json.dumps(record), flush=True)
        assert all(fixture.counts['cycle-%d-%05d' % (cycle, i)] == 1 for i in range(300))
    host = Host(binary, project, source, output, 'cycle-history', environment)
    hosts.append(host)
    assert host.request(host.task_base + '/LOAD-00000')[0] == 200
    assert host.request(host.task_base + '/LOAD-00000/receipts')[0] == 200
    reused, _, _ = host.request(host.task_base,
        {'task_id': 'LOAD-00000', 'input': {'path_id': 'retention-duplicate'}})
    assert reused == 422 and fixture.counts['retention-duplicate'] == 0
    host.stop()
    retention.update({'final_archived_tasks': archived['archivedTaskCount'],
                      'retired_id_reuse_refused': True, 'all_effects_once': True})
    assert retention['final_archived_tasks'] > 1_000, retention
    return all(c['operator_latency']['p95_seconds'] < 1 for c in retention['cycles'])


def run_capacity_drills(binary, project, output, environment, fixture, hosts, result):
    capacity = {}
    result['capacity'] = capacity

    def new_host(name, native=False):
        directory = project / ('capacity-' + name)
        directory.mkdir()
        source = configure(binary, directory, fixture, environment)
        if native:
            write_json(directory / 'workflow.json', {
                'ir_version': 1, 'id': 'qualification.count', 'version': '1.0.0',
                'name': 'Capacity count', 'source': {'kind': 'native', 'reference': 'test://capacity'},
                'trigger': {'kind': 'manual'}, 'state_schema': [], 'entrypoint': 'done',
                'instructions': [{'id': 'done', 'op': 'EMIT_RECEIPT', 'receipt_fields': ['task']}]})
            source = 'workflow.json'
        host = Host(binary, directory, source, output, 'capacity-' + name, environment)
        hosts.append(host)
        return host

    def reject_without_claim(host, task_id, effect):
        before = host.snapshot()
        code, body, _ = host.request(host.task_base, {'task_id': task_id, 'input': {'path_id': effect}})
        assert code == 503, (code, body)
        after = host.snapshot()
        assert after['replay_claims'] == before['replay_claims'], 'capacity rejection wrote replay claims'
        assert after['tasks'] == before['tasks'], 'capacity rejection changed tasks'
        return code

    active = new_host('active')
    for i in range(64):
        code, body, _ = active.request(active.task_base,
            {'task_id': 'ACTIVE-%02d' % i, 'input': {'path_id': 'active-%02d' % i}})
        assert code == 201, (code, body)
    rejected = reject_without_claim(active, 'ACTIVE-OVER', 'active-over')
    assert active.request('/approvals')[0] == 200
    health_status, health, _ = active.request('/health')
    assert health_status == 200 and health['status'] == 'capacity_limited', health
    assert health['admission']['unfinishedTaskCount'] == 64 and not health['admission']['acceptingNewTasks'], health
    assert health['admission']['limits']['maximumUnfinishedTasks'] == 64, health
    code, body, _ = active.request(active.task_base + '/ACTIVE-00/approve', {'task_revision': 1})
    assert code == 200, (code, body)
    active.wait_task('ACTIVE-00', 'completed')
    assert fixture.counts['active-00'] == 1
    assert active.request('/health')[1]['status'] == 'ready'
    code, body, _ = active.request(active.task_base,
        {'task_id': 'ACTIVE-AFTER', 'input': {'path_id': 'active-after'}})
    assert code == 201, (code, body)
    active.stop()
    capacity['active'] = {'limit': 64, 'rejected_status': rejected,
        'rejection_preserved_replay_claims': True, 'existing_task_completed': True,
        'new_task_after_drain_accepted': True, 'health_reported_capacity_and_recovery': True}

    retained = new_host('retained', native=True)
    for i in range(500):
        code, body, _ = retained.request(retained.task_base, {'task_id': 'COUNT-%03d' % i, 'input': {}})
        assert code == 201, (i, code, body)
    before = retained.snapshot()
    assert len(before['tasks']) == 500 and all(t['status'] == 'completed' for t in before['tasks'].values())
    code, body, _ = retained.request(retained.task_base, {'task_id': 'COUNT-OVER', 'input': {}})
    assert code == 503, (code, body)
    assert retained.snapshot()['replay_claims'] == before['replay_claims']
    assert retained.request('/approvals')[0] == 200
    health_status, health, _ = retained.request('/health')
    assert health_status == 200 and health['status'] == 'capacity_limited', health
    assert health['admission']['hotTaskCount'] == 500, health
    retained.stop()
    capacity['retained'] = {'limit': 500, 'rejected_status': code, 'rejection_preserved_replay_claims': True}

    large = new_host('bytes')
    latencies, accepted = [], []
    for i in range(32):
        task_id = 'LARGE-%02d' % i
        before = large.snapshot()
        code, body, _ = large.request(large.task_base,
            {'task_id': task_id, 'input': {'path_id': 'large-%02d' % i}})
        if code == 503:
            assert large.snapshot()['replay_claims'] == before['replay_claims']
            break
        assert code == 201, (code, body)
        approved, body, _ = large.request(large.task_base + '/' + task_id + '/approve', {'task_revision': 1})
        assert approved == 200, (approved, body)
        large.wait_task(task_id, 'completed')
        accepted.append(i)
        status, body, latency = large.request('/approvals')
        assert status == 200, (status, body)
        latencies.append(latency)
    else:
        raise AssertionError('maximum responses grew beyond the documented hot byte envelope')
    assert accepted and all(fixture.counts['large-%02d' % i] == 1 for i in accepted)
    hot_bytes = (large.project / '.kist/sml/runtime.json').stat().st_size
    assert hot_bytes <= 2_097_152 + 4 * 65_536, hot_bytes
    health_status, health, _ = large.request('/health')
    assert health_status == 200 and health['status'] == 'capacity_limited', health
    assert health['admission']['limits']['maximumHotBytes'] == 2_097_152, health
    large.stop()
    capacity['bytes'] = {'limit': 2_097_152, 'response_bytes': 65_536,
        'accepted_tasks': len(accepted), 'rejected_status': code, 'hot_runtime_bytes': hot_bytes,
        'all_accepted_tasks_completed': True, 'all_effects_once': True,
        'operator_latency': distribution(latencies)}
    print('CAPACITY:', json.dumps(capacity), flush=True)
    return percentile(latencies, .95) < 1


def qualify(args, result):
    binary = str(Path(args.binary).resolve())
    environment = dict(os.environ, NO_COLOR='1')
    environment.pop('KIST_ACTIVE', None)
    result['binary'] = binary
    result['binary_sha256'] = hashlib.sha256(Path(binary).read_bytes()).hexdigest()
    result['machine'] = {'system': platform.system(), 'release': platform.release(),
                         'architecture': platform.machine(), 'cpus': os.cpu_count()}
    result['workload'] = {'tasks': args.tasks, 'concurrent_clients': args.clients,
                          'minimum_seconds': args.seconds, 'fixture_delay_seconds': .02,
                          'fixture_response_bytes': args.response_bytes,
                          'operator_poll_seconds': .2, 'operation': 'approved HTTP POST'}

    def maintenance(project, arguments, expected=0):
        response = subprocess.run([binary, '--project', str(project)] + arguments,
                                  cwd=project, env=environment, capture_output=True, text=True, timeout=180)
        assert response.returncode == expected, response.stdout + response.stderr
        return json.loads(response.stdout) if expected == 0 else response.stderr

    with tempfile.TemporaryDirectory(prefix='kist-sml-qualification-') as temporary:
        project = Path(temporary).resolve()
        fixture = Fixture(project, args.response_bytes)
        hosts = []
        try:
            source = configure(binary, project, fixture, environment)
            host = Host(binary, project, source, args.output, 1, environment)
            hosts.append(host)
            health_status, health, _ = host.request('/health')
            assert health_status == 200 and health['status'] == 'ready', health
            assert not health['admission']['qualifiedLimitsExceeded'], health
            load_start = time.monotonic()
            stop_monitor = threading.Event()
            operator_latencies, request_latencies, errors, completion_times, rss = [], [], [], {}, []
            lock = threading.Lock()

            def monitor():
                while not stop_monitor.is_set():
                    try:
                        status, body, latency = host.request('/approvals')
                        with lock:
                            operator_latencies.append(latency)
                        if status != 200:
                            raise AssertionError((status, body))
                        snap = host.snapshot()
                        with lock:
                            for task_id, task in snap['tasks'].items():
                                if task['status'] == 'completed' and task_id not in completion_times:
                                    completion_times[task_id] = time.monotonic() - load_start
                        sample = subprocess.run(['ps', '-o', 'rss=', '-p', str(host.process.pid)],
                                                capture_output=True, text=True, timeout=2)
                        if sample.stdout.strip():
                            rss.append(int(sample.stdout.strip()) * 1024)
                    except BaseException as error:
                        errors.append('operator: ' + repr(error))
                        return
                    stop_monitor.wait(.2)

            watcher = threading.Thread(target=monitor, daemon=True)
            watcher.start()

            def submit(index):
                # Fixed offered-rate schedule makes overload visible as rising completion lag.
                scheduled = load_start + index * args.seconds / args.tasks
                delay = scheduled - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                task_id = 'LOAD-%05d' % index
                latencies = host.start_and_approve(task_id, 'load-%05d' % index)
                with lock:
                    request_latencies.extend(latencies)

            try:
                with concurrent.futures.ThreadPoolExecutor(max_workers=args.clients) as pool:
                    for future in concurrent.futures.as_completed([pool.submit(submit, i) for i in range(args.tasks)]):
                        future.result()
                deadline = time.monotonic() + args.drain_timeout
                while len(completion_times) < args.tasks and time.monotonic() < deadline and not errors:
                    time.sleep(.1)
                elapsed = time.monotonic() - load_start
            finally:
                stop_monitor.set()
                watcher.join(timeout=25)
                assert not watcher.is_alive(), 'operator monitor survived cleanup'
            snap = host.snapshot()
            completed = sum(t['status'] == 'completed' for t in snap['tasks'].values())
            completion_lag = [observed - int(task_id.rsplit('-', 1)[-1]) * args.seconds / args.tasks
                              for task_id, observed in completion_times.items()]
            result['load'] = {'elapsed_seconds': elapsed, 'completed_tasks': completed,
                'completed_tasks_per_second': completed / elapsed,
                'operator_latency': distribution(operator_latencies),
                'mutation_latency': distribution(request_latencies), 'errors': errors,
                'maximum_rss_bytes': max(rss) if rss else None,
                'runtime_bytes': (project / '.kist/sml/runtime.json').stat().st_size,
                'receipts': len(snap['receipts']), 'replay_claims': len(snap['replay_claims']),
                'last_completion_seconds': max(completion_times.values()) if completion_times else None,
                'completion_lag_from_offered_schedule': distribution(completion_lag),
                'completion_windows': [sum(low <= t < low + 10 for t in completion_times.values())
                                       for low in range(0, math.ceil(elapsed), 10)]}
            assert not errors, errors
            assert completed == args.tasks, ('incomplete workload', completed, args.tasks)
            assert all(fixture.counts['load-%05d' % i] == 1 for i in range(args.tasks)), dict(fixture.counts)
            print('LOAD:', json.dumps(result['load']), flush=True)

            # Two operators approving one revision must admit exactly one external dispatch.
            base = host.task_base
            status, body, _ = host.request(base, {'task_id': 'RACE', 'input': {'path_id': 'race'}})
            assert status == 201, (status, body)
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                races = list(pool.map(lambda _: host.request(base + '/RACE/approve', {'task_revision': 1}), range(2)))
            host.wait_task('RACE', 'completed')
            codes = sorted(value[0] for value in races)
            assert codes == [200, 409], codes
            assert fixture.counts['race'] == 1, fixture.counts['race']
            result['conflicting_approvals'] = {'http_statuses': codes, 'effect_count': 1}

            # A stalled operator client must not monopolize the listener and hide healthy work.
            with socket.create_connection(('127.0.0.1', int(host.base.rsplit(':', 1)[-1])), timeout=2) as stalled:
                stalled.sendall(('GET /approvals HTTP/1.1\r\nHost: localhost\r\n'
                                 'Authorization: Bearer ' + host.token + '\r\n').encode())
                time.sleep(.1)
                status, body, slow_client_latency = host.request('/approvals')
                assert status == 200, (status, body)
            result['stalled_client'] = {'operator_latency_seconds': slow_client_latency,
                'incomplete_request_deadline_seconds': 5}

            # A second CLI must fail before acquiring the live project's host lease or token.
            token_before = host.token_path.read_text()
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                duplicate_port = probe.getsockname()[1]
            duplicate = subprocess.run([binary, '--project', str(project), '--sml-runtime-serve', source,
                                        '--sml-port', str(duplicate_port)], cwd=project, env=environment,
                                       capture_output=True, text=True, timeout=10)
            assert duplicate.returncode != 0, 'duplicate host unexpectedly started'
            assert 'another sml runtime host holds' in duplicate.stderr.lower(), duplicate.stderr
            assert host.token_path.read_text() == token_before, 'duplicate launch replaced active token'
            assert host.request('/approvals')[0] == 200
            result['exclusive_host'] = {'duplicate_exit_code': duplicate.returncode,
                                        'active_token_preserved': True}

            # SIGTERM while an effect has happened but its response is still in flight.
            host.start_and_approve('GRACEFUL', 'graceful')
            assert fixture.entered['graceful'].wait(timeout=10), 'graceful fixture not entered'
            timer = threading.Timer(1, fixture.release['graceful'].set)
            timer.start()
            try:
                stopped_in = host.stop()
            finally:
                timer.cancel()
                timer.join(timeout=2)
            assert host.snapshot()['tasks']['GRACEFUL']['status'] == 'completed'
            assert fixture.counts['graceful'] == 1
            result['graceful_stop'] = {'seconds': stopped_in, 'completed_inflight_effects': 1,
                                       'token_removed': True}

            # Restart, kill after one counted external effect, then prove restart does not replay.
            host = Host(binary, project, source, args.output, 2, environment)
            hosts.append(host)
            host.start_and_approve('CRASH', 'crash')
            assert fixture.entered['crash'].wait(timeout=10), 'crash fixture not entered'
            before = host.snapshot()['tasks']['CRASH']
            assert before.get('capability_claim'), before
            health_status, health, _ = host.request('/health')
            assert health_status == 200 and health['inFlightOrUnresolvedClaimCount'] == 1, health
            assert health['oldestClaimAgeSeconds'] >= 0, health
            old_token = host.token
            host.process.kill()
            host.process.wait(timeout=5)
            fixture.release['crash'].set()
            host = Host(binary, project, source, args.output, 3, environment)
            hosts.append(host)
            assert host.token != old_token, 'crash restart reused session token'
            time.sleep(6)  # Includes the five-second periodic drain, beyond initial restart drain.
            after = host.snapshot()['tasks']['CRASH']
            assert after == before, 'restart rewrote/replayed unresolved claim'
            assert fixture.counts['crash'] == 1, fixture.counts['crash']
            status, body, _ = host.request(base + '/CRASH/reconcile', {
                'task_revision': after['task_revision'],
                'dispatch_id': after['capability_claim']['dispatch_id'],
                'note': 'Qualification killed previous host after fixture effect; retire without replay'})
            assert status == 200, (status, body)
            reconciled = host.snapshot()['tasks']['CRASH']
            assert reconciled['status'] == 'failed' and not reconciled.get('capability_claim'), reconciled
            assert fixture.counts['crash'] == 1
            result['crash_restart'] = {'effect_count': 1, 'claim_preserved': True,
                'token_rotated': True, 'reconciled_status': 'failed', 'observation_seconds': 6}

            # Back up work before its effect, later restore that older backup into a fresh host.
            # Resuming the backup's unclaimed work would duplicate an effect already sent after it.
            status, body, _ = host.request(base, {'task_id': 'BACKUP-PENDING',
                                                'input': {'path_id': 'backup-pending'}})
            assert status == 201, (status, body)
            host.stop()
            verified = maintenance(project, ['--sml-store', 'verify'])
            cutoff = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(time.time() + 2))
            archived = maintenance(project, ['--sml-store', 'archive', '--sml-archive-before', cutoff,
                                             '--sml-archive-max', str(min(10_000, args.tasks + 3))])
            assert archived['archivedTaskCount'] == args.tasks + 3, archived
            assert archived['liveTaskCount'] == 1, archived
            assert archived['receiptCount'] == verified['receiptCount'], (archived, verified)
            backup = project / 'qualification-backup.json'
            maintenance(project, ['--sml-store', 'backup', '--sml-backup', str(backup)])

            host = Host(binary, project, source, args.output, 4, environment)
            hosts.append(host)
            status, body, _ = host.request(base + '/BACKUP-PENDING/approve', {'task_revision': 1})
            assert status == 200, (status, body)
            host.wait_task('BACKUP-PENDING', 'completed')
            assert fixture.counts['backup-pending'] == 1
            host.stop()

            recovered_project = project / 'restored-project'
            recovered_project.mkdir()
            # Fresh restore must reconstruct configuration and restartable sources from the
            # backup itself; copying original host files would hide missing recovery payloads.
            damaged_backup = project / 'damaged-backup.json'
            envelope = json.loads(backup.read_text())
            envelope['sha256'] = '0' * 64
            write_json(damaged_backup, envelope)
            rejection = maintenance(recovered_project, ['--sml-store', 'restore', '--sml-backup',
                                                        str(damaged_backup)], expected=2)
            assert 'checksum' in rejection, rejection
            assert not (recovered_project / '.kist/sml/runtime.json').exists()
            restored = maintenance(recovered_project, ['--sml-store', 'restore', '--sml-backup', str(backup)])
            assert restored['archivedTaskCount'] == args.tasks + 3, restored
            assert restored['quarantinedTaskCount'] == 1, restored
            maintenance(recovered_project, ['--sml-store', 'verify'])
            source_sets = list((recovered_project / '.kist/sml/recovery-sources').glob('*/source-set.json'))
            assert len(source_sets) == 1, source_sets
            recovered_source = str(source_sets[0].relative_to(recovered_project))
            source_set = json.loads(source_sets[0].read_text())
            backed_up_roles = {row['role'] for row in host.snapshot()['workflows'].values()}
            assert {row['role'] for row in source_set['sources']} == backed_up_roles
            assert (recovered_project / '.kist/sml/catalog.json').read_bytes() == (project / '.kist/sml/catalog.json').read_bytes()
            recovered = Host(binary, recovered_project, recovered_source, args.output, 5, environment)
            hosts.append(recovered)
            time.sleep(6)
            restored_task = recovered.snapshot()['tasks']['BACKUP-PENDING']
            assert restored_task['status'] == 'failed', restored_task
            assert fixture.counts['backup-pending'] == 1, 'restored backup replayed an already performed effect'
            archived_watch, _, _ = recovered.request(base + '/LOAD-00000')
            archived_receipts, _, _ = recovered.request(base + '/LOAD-00000/receipts')
            assert archived_watch == 200 and archived_receipts == 200, (archived_watch, archived_receipts)
            reused, _, _ = recovered.request(base, {'task_id': 'LOAD-00000', 'input': {'path_id': 'duplicate-archive'}})
            assert reused == 422, reused
            assert fixture.counts['duplicate-archive'] == 0
            recovered.start_and_approve('RESTORED-NEW', 'restored-new')
            recovered.wait_task('RESTORED-NEW', 'completed')
            assert fixture.counts['restored-new'] == 1
            recovered.stop()

            # A different owner configuration is preserved even in a project without runtime.
            conflict_project = project / 'conflicting-restore'
            conflict_project.mkdir()
            conflicting_catalog = json.loads((project / '.kist/sml/catalog.json').read_text())
            conflicting_catalog['tool_capabilities'].append('operator.newer-capability')
            conflict_catalog_path = conflict_project / '.kist/sml/catalog.json'
            write_json(conflict_catalog_path, conflicting_catalog)
            catalog_before = conflict_catalog_path.read_bytes()
            conflict = maintenance(conflict_project, ['--sml-store', 'restore', '--sml-backup', str(backup)], expected=2)
            assert 'recovery file differs' in conflict, conflict
            assert conflict_catalog_path.read_bytes() == catalog_before
            assert not (conflict_project / '.kist/sml/runtime.json').exists()

            # Replacing the newer original store requires its exact digest and preserves its
            # terminal knowledge, so an old backup cannot erase a subsequently completed task.
            current_bytes = (project / '.kist/sml/runtime.json').read_bytes()
            rejection = maintenance(project, ['--sml-store', 'restore', '--sml-backup', str(backup),
                                               '--sml-replace-sha256', '0' * 64], expected=2)
            assert 'exact current' in rejection, rejection
            replacement = maintenance(project, ['--sml-store', 'restore', '--sml-backup', str(backup),
                '--sml-replace-sha256', hashlib.sha256(current_bytes).hexdigest()])
            quarantine = Path(replacement['destinationPath']) / 'runtime.json'
            assert quarantine.read_bytes() == current_bytes, 'replacement did not preserve exact newer bytes'
            original_after_restore = json.loads((project / '.kist/sml/runtime.json').read_text())
            assert original_after_restore['tasks']['BACKUP-PENDING']['status'] == 'completed'
            maintenance(project, ['--sml-store', 'verify'])
            result['backup_restore'] = {'archived_task_count': archived['archivedTaskCount'],
                'receipt_count_preserved': archived['receiptCount'], 'corrupt_backup_refused': True,
                'fresh_restore_quarantined_tasks': restored['quarantinedTaskCount'],
                'post_backup_effect_count': fixture.counts['backup-pending'],
                'fresh_project_config_restored': True, 'pinned_source_set_restarted': True,
                'restored_new_task_completed': True, 'conflicting_config_preserved': True,
                'archived_watch_and_receipts_available': True, 'archived_task_reuse_refused': True,
                'replacement_digest_required': True, 'newer_terminal_history_preserved': True,
                'replaced_bytes_quarantined': True}
            retention_passed = run_retention_cycles(binary, project, source, args.output,
                environment, fixture, hosts, maintenance, result)
            maximum_response_passed = run_capacity_drills(binary, project, args.output,
                environment, fixture, hosts, result)
            result['gates'] = {
                'all_tasks_completed_once': True,
                'operator_p95_under_one_second': percentile(operator_latencies, .95) < 1,
                'operator_p99_under_two_seconds': percentile(operator_latencies, .99) < 2,
                'mutation_p95_under_two_seconds': percentile(request_latencies, .95) < 2,
                'sustained_completion_p95_under_five_seconds':
                    args.seconds == 0 or percentile(completion_lag, .95) < 5,
                'stalled_client_operator_under_one_second': slow_client_latency < 1,
                'graceful_stop_under_five_seconds': stopped_in < 5,
                'crash_restart_does_not_replay': True,
                'backup_restore_preserves_evidence_without_replay': True,
                'retention_cycles_preserve_history_and_responsiveness': retention_passed,
                'capacity_rejection_preserves_existing_work': True,
                'maximum_response_capacity_is_bounded': maximum_response_passed,
                'health_reports_capacity_and_unresolved_work': True}
            result['passed'] = all(result['gates'].values())
        finally:
            for host in reversed(hosts):
                host.close()
            fixture.close()
            result['cleanup'] = {'host_processes_reaped': all(h.process.poll() is not None for h in hosts),
                                 'fixture_stopped': not fixture.thread.is_alive()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default=str(Path(__file__).resolve().parents[2] / '.build/debug/kist'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--tasks', type=int, default=300)
    parser.add_argument('--clients', type=int, default=4)
    parser.add_argument('--seconds', type=float, default=120)
    parser.add_argument('--drain-timeout', type=float, default=180)
    parser.add_argument('--response-bytes', type=int, default=17,
                        help='HTTP fixture response body size, 9...65536 bytes')
    args = parser.parse_args()
    if args.tasks < 1 or args.clients < 1 or args.seconds < 0 or args.drain_timeout <= 0:
        parser.error('tasks/clients/drain timeout must be positive; seconds must be nonnegative')
    if not 9 <= args.response_bytes <= 65_536:
        parser.error('response bytes must be in 9...65536')
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    result = {'schema_version': 1, 'started_at_epoch': time.time(), 'passed': False}
    try:
        qualify(args, result)
    except BaseException as error:
        result['error'] = repr(error)
        result['traceback'] = traceback.format_exc()
        print(result['traceback'], flush=True)
    finally:
        result['finished_at_epoch'] = time.time()
        write_json(args.output / 'qualification.json', result)
        write_report(args.output, result)
    print('PASS' if result['passed'] else 'FAIL', args.output / 'qualification.json', flush=True)
    raise SystemExit(0 if result['passed'] else 1)


if __name__ == '__main__':
    main()
