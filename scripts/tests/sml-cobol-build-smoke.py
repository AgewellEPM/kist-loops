#!/usr/bin/env python3
"""Build real numeric COBOL through Kist's durable SML -> MCP path.

Requires a user-configured cobol-build MCP server and an installed cobc. Uses no
model, network, UI, or VM. The output directory must be new. Retains source,
executables, SML records, compiler logs, and independent behavioral checks.
This bounded demonstration is not a sealed acceptance or evolution authority.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import signal
import subprocess


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + '\n')
    path.chmod(0o600)


def run(argv, cwd, log, stdin=None, timeout=60):
    environment = dict(os.environ, NO_COLOR='1', PYTHONDONTWRITEBYTECODE='1')
    environment.pop('KIST_ACTIVE', None)
    with log.open('w') as output:
        process = subprocess.Popen(argv, cwd=cwd, env=environment, stdin=subprocess.PIPE,
                                   stdout=output, stderr=subprocess.STDOUT,
                                   text=True, start_new_session=True)
        try:
            process.communicate(stdin, timeout=timeout)
        finally:
            # The direct child and any descendants still in its group are always reaped/stopped.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=2)
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    if process.returncode != 0:
        raise RuntimeError(f'{argv[0]} exited {process.returncode}; see {log}')
    return log.read_text()


def configure(project, prompt, server):
    config = project / '.kist/sml'
    write_json(config / 'catalog.json', {'schema_version': 1,
        'tool_capabilities': ['cobol.build'], 'approval_authorities': ['host-operator']})
    write_json(config / 'mcp.json', {'schema_version': 1, 'tools': {
        'cobol.build': {'server': server, 'tool': 'cobol_build'}}})
    write_json(config / 'authority.json', {'schema_version': 1, 'actors': [{
        'id': 'sml-runtime-exporter', 'roles': ['workflow-agent'],
        'operations': ['workflow.run', 'workflow.inspect', 'task.watch', 'receipts.list',
                       'task.approve_request', 'task.claim_capability', 'task.record_step'],
        'approval_authorities': ['host-operator']}]})
    write_json(project / 'workflow.json', {
        'ir_version': 1, 'id': 'build.cobol', 'version': '1.0.0', 'name': 'Build COBOL',
        'source': {'kind': 'native', 'reference': 'test://sml-cobol-build'},
        'trigger': {'kind': 'manual'}, 'state_schema': [
            {'name': 'output', 'type': 'string', 'required': False}],
        'interface': {'output_fields': ['output']}, 'entrypoint': 'build',
        'instructions': [
            {'id': 'build', 'op': 'CALL_TOOL', 'capability': 'cobol.build',
             'arguments': {'prompt': prompt, 'output_field': 'output'}, 'next': 'done'},
            {'id': 'done', 'op': 'EMIT_RECEIPT', 'receipt_fields': ['output']}]})


def snapshot(project):
    return json.loads((project / '.kist/sml/runtime.json').read_text())


def caller(n):
    # Host-owned fixture, independent of cobol-sml's composer and functional_check.
    return f'''identification division.
program-id. HOSTCHECK.
data division.
working-storage section.
01 shared-input.
   05 table-value occurs {n} times pic s9(5).
   05 table-result pic s9(9).
01 idx binary-long.
01 input-line pic x(32).
procedure division.
   perform varying idx from 1 by 1 until idx > {n}
       accept input-line
       compute table-value(idx) = function numval(input-line)
   end-perform
   move 0 to table-result
   call "TABLEOP" using shared-input
   display table-result
   stop run.
'''


def samples(n):
    rng = random.Random(9082026)
    return [[0] * n, [-i - 1 for i in range(n)], list(range(1, n + 1)),
            [(-1 if i % 2 else 1) * (i + 2) for i in range(n)],
            [99999, -99999] + [0] * (n - 2), [100] * n, [101] * n,
            [rng.randint(-1000, 1000) for _ in range(n)]]


CASES = [
    ('reduce-min', 'minimum', min), ('reduce-max', 'maximum', max),
    ('reduce-sum', 'sum', sum), ('range', 'range', lambda v: max(v) - min(v)),
    ('average', 'average', lambda v: int(sum(v) / len(v))),
    ('sum-abs', 'sum of absolute values', lambda v: sum(map(abs, v))),
    ('count-neg', 'count negative', lambda v: sum(x < 0 for x in v)),
    ('count-pos', 'count positive', lambda v: sum(x > 0 for x in v)),
    ('count-zero', 'count zeros', lambda v: sum(x == 0 for x in v)),
    ('count-over', 'count values over 100', lambda v: sum(x > 100 for x in v)),
]


def build_case(binary, compiler, root, server, concept, phrase, oracle):
    project = root / concept
    project.mkdir(mode=0o700)
    n = 7
    configure(project, f'{phrase} of {n} values', server)
    argv = [binary, '--project', str(project), '--sml-runtime-repl',
            'workflow.json', '--sml-runtime-durable']
    run(argv, project, project / '01-start.log', 'start BUILD\nexit\n')
    before = snapshot(project)
    pending = before['tasks']['BUILD']
    if pending.get('capability_claim') or pending.get('state', {}).get('output'):
        raise RuntimeError('COBOL dispatched before approval')
    revision = pending['task_revision']
    run(argv, project, project / '02-approve.log',
        f'approve BUILD {{"task_revision":{revision}}}\nexit\n')
    after = snapshot(project)
    task = after['tasks']['BUILD']
    if task['status'] != 'completed' or task.get('capability_claim'):
        raise RuntimeError(f'COBOL task did not complete: {project / "02-approve.log"}')
    result = json.loads(task['state']['output'])
    if result.get('verified') is not True or result.get('concept') != concept or result.get('n') != n:
        raise RuntimeError(f'COBOL builder returned an unexpected concept or refusal: {result}')
    # The MCP verified bit is insufficient: independently compile and execute the exact returned source.
    source = project / 'routine.cob'
    source.write_text(result['cobol'] + '\n')
    driver = project / 'host-check.cob'
    driver.write_text(caller(n))
    program = project / 'program'
    run([compiler, '-x', '-free', '-o', str(program), str(driver), str(source)],
        project, project / '03-compile.log', timeout=30)
    checks = []
    for i, values in enumerate(samples(n)):
        actual = int(run([str(program)], project, project / f'04-case-{i}.log',
                         '\n'.join(map(str, values)) + '\n', timeout=5).strip())
        expected = oracle(values)
        checks.append({'input': values, 'expected': expected, 'actual': actual,
                       'passed': actual == expected})
    write_json(project / 'checks.json', checks)
    if not all(row['passed'] for row in checks):
        raise RuntimeError(f'independent COBOL check failed: {project / "checks.json"}')
    steps = [r for r in after['receipts'].values() if r['kind'] == 'step_recorded']
    if len(steps) != 1 or steps[0]['payload'].get('outcome') != 'passed':
        raise RuntimeError('expected one passed dispatch result')
    run(argv, project, project / '05-restart.log', 'watch BUILD\nexit\n')
    restarted = snapshot(project)
    if restarted['tasks'] != after['tasks'] or restarted['receipts'] != after['receipts']:
        raise RuntimeError('completed COBOL task changed or replayed on restart')
    return {'concept': concept, 'source_sha256': digest(source),
            'program_sha256': digest(program), 'checks': len(checks),
            'approval_required': True, 'restarted_without_new_dispatch': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default=str(Path(__file__).resolve().parents[2] / '.build/debug/kist'))
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--server', default='cobol-build')
    args = parser.parse_args()
    compiler = shutil.which('cobc')
    if compiler is None:
        parser.error('cobc is required; no compiler will be downloaded')
    binary = str(Path(args.binary).resolve(strict=True))
    root = args.output.resolve()
    root.mkdir(mode=0o700)  # create-only; never overwrite another run's artifacts
    report = {'scope': 'local numeric COBOL build demonstration; not sealed acceptance or evolution',
              'binary': binary, 'binary_sha256': digest(binary),
              'compiler': compiler, 'compiler_sha256': digest(compiler), 'cases': [], 'passed': False}
    try:
        for concept, phrase, oracle in CASES:
            row = build_case(binary, compiler, root, args.server, concept, phrase, oracle)
            report['cases'].append(row)
            print(f'PASS: {concept}: SML approval -> MCP -> artifact -> {row["checks"]} independent runs -> restart')
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        write_json(root / 'build-report.json', report)
    print(f'Built {len(report["cases"])} executable COBOL fixtures; evidence: {root}')


if __name__ == '__main__':
    main()
