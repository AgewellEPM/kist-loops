#!/usr/bin/env python3
"""Benchmark real Kist SML -> recorded stdio -> configured COBOL MCP -> independent executable checks.

Exit 0: complete, with all benchmark contracts passing. Exit 1: complete with measured product
failures. Exit 2: infrastructure/incomplete evidence. Results are always retained when possible.
No models, network, browser, UI, VM, deployment, or autonomy activation.
"""
import argparse
import collections
import json
from pathlib import Path
import platform
import shutil
import sys
import time
from oracle import verify_source
from calibrate import calibrate
from support import run_process, sha256, timing_summary, write_json


HERE = Path(__file__).resolve().parent
SERVER_ALIAS = 'kist-cobol-benchmark'


def configure(project, case, upstream):
    project.mkdir(mode=0o700)
    write_json(project / 'upstream.json', upstream)
    write_json(project / '.mcp.json', {'mcpServers': {SERVER_ALIAS: {
        'command': str(Path(sys.executable).resolve()),
        'args': [str(HERE / 'relay.py'), '--config', str(project / 'upstream.json'),
                 '--trace', str(project / 'mcp.jsonl')],
        'computerUse': False}}})
    config = project / '.kist/sml'
    write_json(config / 'mcp.json', {'schema_version': 1, 'allow_project_config': True,
        'tools': {'cobol.build': {'server': SERVER_ALIAS, 'tool': 'cobol_build'}}})
    write_json(config / 'catalog.json', {'schema_version': 1,
        'tool_capabilities': ['cobol.build'], 'approval_authorities': ['host-operator']})
    write_json(config / 'authority.json', {'schema_version': 1, 'actors': [{
        'id': 'sml-runtime-exporter', 'roles': ['workflow-agent'],
        'operations': ['workflow.run', 'workflow.inspect', 'task.watch', 'receipts.list',
                       'task.approve_request', 'task.claim_capability', 'task.record_step'],
        'approval_authorities': ['host-operator']}]})
    write_json(project / 'workflow.json', {
        'ir_version': 1, 'id': 'benchmark.cobol', 'version': '1.0.0',
        'name': 'COBOL benchmark', 'source': {'kind': 'native', 'reference': 'benchmark://cobol/v1'},
        'trigger': {'kind': 'manual'}, 'state_schema': [
            {'name': 'output', 'type': 'string', 'required': False}],
        'interface': {'output_fields': ['output']}, 'entrypoint': 'build',
        'instructions': [
            {'id': 'build', 'op': 'CALL_TOOL', 'capability': 'cobol.build',
             'arguments': dict(case['arguments'], output_field='output'), 'next': 'done'},
            {'id': 'done', 'op': 'EMIT_RECEIPT', 'receipt_fields': ['output']}]})


def snapshot(project):
    return json.loads((project / '.kist/sml/runtime.json').read_text())


def traces(project):
    path = project / 'mcp.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def tool_calls(project):
    return [r for r in traces(project) if r['direction'] == 'request'
            and r['payload'].get('method') == 'tools/call']


def response_for(project, request):
    matches = [r for r in traces(project) if r['direction'] == 'response'
               and r['instance'] == request['instance']
               and r['payload'].get('id') == request['payload']['id']]
    if len(matches) != 1:
        raise RuntimeError('missing or duplicate real MCP reply')
    return matches[0]


def decode_builder_reply(reply):
    message = reply['payload']
    if 'error' in message:
        raise RuntimeError('real MCP returned protocol/server error: ' + str(message['error']))
    result = message['result']
    texts = [c['text'] for c in result.get('content', []) if c.get('type') == 'text']
    if len(texts) != 1:
        raise RuntimeError('expected one JSON text result from real builder')
    value = json.loads(texts[0])
    if not isinstance(value, dict):
        raise RuntimeError('builder result is not an object')
    return value, result.get('isError', False)


def relay_cleanup(project):
    rows = traces(project)
    starts = {r['instance']: r['payload'] for r in rows if r['direction'] == 'start'}
    stopped = {r['instance'] for r in rows if r['direction'] == 'stop'}
    return {'started': len(starts), 'stopped': len(stopped),
            'all_stopped': bool(starts) and set(starts) == stopped,
            'processes': list(starts.values())}


def run_case(case, repetition, output, binary, compiler, upstream, suite):
    project = output / f'r{repetition:02d}-{case["id"]}'
    configure(project, case, upstream)
    row = {'id': case['id'], 'repetition': repetition, 'category': case['category'],
           'mode': case['mode'], 'arguments': case['arguments'], 'passed': False,
           'operation': case.get('operation'), 'size': case.get('size'),
           'project': project.name, 'lifecycle': {}}
    argv = [binary, '--project', str(project), '--sml-runtime-repl', 'workflow.json',
            '--sml-runtime-durable']

    def session(name, lines):
        result = run_process(argv, project, project / name, lines + '\nexit\n',
                             timeout=suite['case_timeout_seconds'])
        if not result['success']:
            raise RuntimeError(f'Kist {name} failed; inspect process/stdout/stderr evidence')
        return result

    try:
        first = session('01-start', 'start BUILD')
        before = snapshot(project)
        task = before['tasks']['BUILD']
        row['start_seconds'] = first['elapsed_seconds']
        row['lifecycle']['approval_blocks_dispatch'] = not tool_calls(project) and not task.get('capability_claim')
        revision = task['task_revision']
        session('02-stale', f'approve BUILD {{"task_revision":{revision - 1}}}')
        stale = snapshot(project)
        row['lifecycle']['stale_approval_changes_nothing'] = (
            before['tasks'] == stale['tasks'] and before['receipts'] == stale['receipts']
            and not tool_calls(project))
        approved = session('03-approve', f'approve BUILD {{"task_revision":{revision}}}')
        after = snapshot(project)
        task = after['tasks']['BUILD']
        row['approval_seconds'] = approved['elapsed_seconds']
        calls = tool_calls(project)
        expected_calls = 0 if case['mode'] == 'reject_before_mcp' else 1
        row['lifecycle']['exact_dispatch_count'] = len(calls) == expected_calls
        row['lifecycle']['terminal_without_claim'] = (task['status'] in ('completed', 'failed')
                                                       and not task.get('capability_claim'))
        # A second approval and a new host both must leave the completed/failed attempt untouched.
        session('04-restart', f'approve BUILD {{"task_revision":{revision}}}\nwatch BUILD')
        restarted = snapshot(project)
        row['lifecycle']['restart_and_repeat_approval_do_not_replay'] = (
            restarted['tasks'] == after['tasks'] and restarted['receipts'] == after['receipts']
            and len(tool_calls(project)) == expected_calls)
        row['status'] = task['status']
        if not all(row['lifecycle'].values()):
            row['classification'] = 'lifecycle_failure'
            return row
        if case['mode'] == 'reject_before_mcp':
            row['passed'] = task['status'] == 'failed'
            row['classification'] = 'schema_rejected' if row['passed'] else 'schema_false_acceptance'
            return row
        reply = response_for(project, calls[0])
        row['mcp_seconds'] = (reply['monotonic_ns'] - calls[0]['monotonic_ns']) / 1e9
        value, is_error = decode_builder_reply(reply)
        write_json(project / 'builder-result.json', value)
        row['builder_verified'] = value.get('verified')
        row['builder_concept'] = value.get('concept')
        row['builder_size'] = value.get('n')
        if value.get('verified') is False and value.get('refused') is True:
            row['passed'] = case['mode'] in ('refuse', 'build_or_refuse') and task['status'] == 'failed' and is_error
            row['classification'] = 'safe_refusal' if row['passed'] else 'false_refusal'
            row['reason'] = value.get('reason')
            return row
        if value.get('verified') is not True or is_error or task['status'] != 'completed':
            raise RuntimeError('builder verified/isError and SML task outcome disagree')
        if case['mode'] == 'refuse':
            row['classification'] = 'false_acceptance'
            return row
        if value.get('n') != case['size']:
            row['classification'] = 'wrong_size'
            return row
        row['verification'] = verify_source(value['cobol'], case, project / 'independent',
                                            compiler, suite['seed'], suite['random_cases'])
        row['passed'] = row['verification']['passed']
        row['classification'] = 'correct_build' if row['passed'] else row['verification']['failure_class']
        return row
    except Exception as error:
        row['classification'] = 'infrastructure_error'
        row['error'] = str(error)
        return row
    finally:
        row['cleanup'] = relay_cleanup(project)
        if not row['cleanup']['all_stopped']:
            row['passed'] = False
            row['classification'] = 'infrastructure_error'
            row['error'] = 'MCP recorder did not attest every child stop'
        write_json(project / 'case-result.json', row)


def summarize(report):
    rows = report['results']
    complete = len(rows) == report['expected_runs']
    infrastructure = [r for r in rows if r.get('classification') == 'infrastructure_error']
    counts = collections.Counter(r['classification'] for r in rows)
    groups = {}
    for group in sorted(set(r['category'] for r in rows)):
        subset = [r for r in rows if r['category'] == group]
        groups[group] = {'runs': len(subset), 'passed': sum(r['passed'] for r in subset)}
    families = {}
    for family in sorted({r['operation'] for r in rows if r.get('operation') and r['category'] == 'construction'}):
        subset = [r for r in rows if r.get('operation') == family and r['category'] == 'construction']
        families[family] = {'runs': len(subset), 'passed': sum(r['passed'] for r in subset)}
    checks = [c for r in rows for c in r.get('verification', {}).get('checks', [])]
    lifecycle = collections.Counter()
    for row in rows:
        for key, passed in row['lifecycle'].items():
            if passed: lifecycle[key] += 1
    builds = [r for r in rows if r.get('classification') == 'correct_build']
    stable = []
    for case_id in sorted(set(r['id'] for r in rows)):
        repeated = [r for r in rows if r['id'] == case_id]
        signatures = {(r.get('classification'), r.get('builder_concept'), r.get('builder_size'),
                       r.get('verification', {}).get('source_sha256')) for r in repeated}
        if len(repeated) > 1:
            stable.append({'id': case_id, 'stable': len(signatures) == 1})
    summary = {'complete': complete, 'infrastructure_errors': len(infrastructure),
        'passed': complete and not infrastructure and all(r['passed'] for r in rows)
                  and report.get('source_closure_unchanged') is True
                  and report.get('calibration', {}).get('passed') is True,
        'total_runs': len(rows), 'passed_runs': sum(r['passed'] for r in rows),
        'classifications': dict(counts), 'categories': groups, 'construction_families': families,
        'compiled_programs': sum(r.get('verification', {}).get('compiled', False) for r in rows),
        'behavioral_checks': len(checks), 'behavioral_passes': sum(c['passed'] for c in checks),
        'lifecycle_pass_counts': dict(lifecycle), 'repeatability': stable,
        'timings': {'mcp_success': timing_summary([r['mcp_seconds'] for r in builds]),
            'approval_success': timing_summary([r['approval_seconds'] for r in builds]),
            'compile': timing_summary([r['verification']['compile_seconds'] for r in rows if 'verification' in r]),
            'program_run': timing_summary([c['elapsed_seconds'] for c in checks])}}
    report['summary'] = summary
    return summary


def render(report):
    s = report['summary']
    lines = ['# Kist / COBOL benchmark results', '',
        f"Suite `{report['suite_id']}`: {s['total_runs']}/{report['expected_runs']} runs completed; "
        f"{s['passed_runs']} contract passes; {s['infrastructure_errors']} infrastructure errors.", '',
        f"{s['compiled_programs']} independently linked programs; "
        f"{s['behavioral_passes']}/{s['behavioral_checks']} runtime checks passed.", '',
        f"Calibration: {'passed' if report.get('calibration', {}).get('passed') else 'incomplete or failed'}. "
        f"Source closure unchanged: {report.get('source_closure_unchanged', 'not yet checked')}. "
        f"Scope: {'selected subset' if report.get('subset') else 'full suite'}.", '',
        'This is measured local benchmark evidence, not sealed mission acceptance, autonomous evolution, '
        'or universal correctness. The recording relay forwards to the real configured MCP process.', '',
        '| Category | Contract passes | Runs |', '|---|---:|---:|']
    lines += [f"| {k} | {v['passed']} | {v['runs']} |" for k, v in s['categories'].items()]
    lines += ['', '| Construction family | Correct builds | Runs |', '|---|---:|---:|']
    lines += [f"| {k} | {v['passed']} | {v['runs']} |" for k, v in s['construction_families'].items()]
    lines += ['', '| Lifecycle check | Passes | Runs |', '|---|---:|---:|']
    lines += [f"| {k} | {v} | {len(report['results'])} |" for k, v in s['lifecycle_pass_counts'].items()]
    lines += ['', f"Repeatability: {sum(r['stable'] for r in s['repeatability'])}/{len(s['repeatability'])} "
              'repeated cases retained their classification, returned concept/size, and independently compiled source hash.']
    lines += ['', '| Timing | Samples | p50 seconds | p95 seconds | p99 seconds |', '|---|---:|---:|---:|---:|']
    for key, v in s['timings'].items():
        fmt = lambda n: '-' if n is None else f'{n:.4f}'
        lines.append(f"| {key} | {v['count']} | {fmt(v['p50_seconds'])} | {fmt(v['p95_seconds'])} | {fmt(v['p99_seconds'])} |")
    lines += ['', 'Timings include local process scheduling and recorder overhead. They are observations '
              'on this machine, not cross-machine performance thresholds.', '', '## Failed contracts', '']
    for row in report['results']:
        if row['passed']:
            continue
        failures = [c for c in row.get('verification', {}).get('checks', []) if not c['passed']]
        detail = row.get('reason') or row.get('error') or ''
        if failures:
            c = failures[0]
            detail = f"{c['name']}: expected {c['expected']}, observed {c['actual']}"
        lines.append(f"- [{row['id']} / repeat {row['repetition']}]({row['project']}/case-result.json): "
                     f"**{row['classification']}**. {detail}")
    lines += ['', 'Every case directory retains the workflow, runtime snapshot, actual MCP request/reply '
              'trace, source where returned, independent caller, executable, process records, and input/output cases.', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--suite', type=Path, default=HERE / 'suite.v1.json')
    parser.add_argument('--mcp-config', type=Path, default=Path.home() / '.mcp.json')
    parser.add_argument('--server', default='cobol-build')
    parser.add_argument('--case', action='append', help='Exact case ID; repeat to select a subset')
    parser.add_argument('--repetitions', type=int)
    args = parser.parse_args()
    suite = json.loads(args.suite.read_text())
    if suite['schema_version'] != 1 or suite['case_count'] != len(suite['cases']):
        parser.error('invalid suite manifest')
    repetitions = args.repetitions if args.repetitions is not None else suite['repetitions']
    if not 1 <= repetitions <= 5:
        parser.error('repetitions must be 1...5')
    selected = [c for c in suite['cases'] if not args.case or c['id'] in args.case]
    if not selected or (args.case and set(args.case) != {c['id'] for c in selected}):
        parser.error('unknown or empty case selection')
    binary = args.binary.resolve(strict=True)
    compiler = shutil.which('cobc')
    if not compiler:
        parser.error('installed cobc required; nothing will be downloaded')
    config = json.loads(args.mcp_config.read_text())['mcpServers'][args.server]
    if not Path(config.get('command', '')).is_absolute() or 'url' in config:
        parser.error('an existing absolute-command stdio MCP server is required')
    # Restrict this campaign to the reviewed local COBOL MCP implementation. Do not record arbitrary
    # credential-bearing servers or silently substitute another tool/provider.
    if len(config.get('args', [])) != 1 or Path(config['args'][0]).name != 'cobol_build_mcp.py':
        parser.error('this campaign requires the actual local cobol_build_mcp.py server')
    if set(config.get('env', {})) - {'PATH', 'PYTHONDONTWRITEBYTECODE'}:
        parser.error('benchmark recorder accepts only the secret-free COBOL server environment')
    upstream = {k: config[k] for k in ('command', 'args', 'env') if k in config}
    source = Path(config['args'][0]).resolve(strict=True)
    source_paths = [source, source.with_name('cobol_build.py')]
    closure = {str(p): sha256(p) for p in source_paths}
    execution_closure = {str(p): sha256(p) for p in [*source_paths, binary, Path(compiler).resolve(),
        args.suite.resolve(), Path(sys.executable).resolve(), Path(config['command']).resolve(), *HERE.glob('*.py')]}
    output = args.output.resolve()
    output.mkdir(mode=0o700)  # always create-only
    write_json(output / 'suite.json', suite)
    report = {'schema_version': 1, 'suite_id': suite['id'], 'suite_sha256': sha256(args.suite),
        'binary': str(binary), 'binary_sha256': sha256(binary),
        'compiler': compiler, 'compiler_sha256': sha256(compiler),
        'server_sources': closure, 'harness_sources': {p.name: sha256(p) for p in HERE.glob('*.py')},
        'execution_closure': execution_closure,
        'machine': platform.platform(), 'python': sys.version, 'repetitions': repetitions,
        'expected_runs': len(selected) * repetitions, 'selected_cases': [c['id'] for c in selected],
        'subset': len(selected) != len(suite['cases']), 'results': []}
    started = time.monotonic()
    try:
        report['calibration'] = calibrate(output / 'calibration', compiler, suite['seed'])
        if not report['calibration']['passed']:
            raise RuntimeError('benchmark oracle calibration failed; refusing to grade the product')
        for repetition in range(1, repetitions + 1):
            for case in selected:
                row = run_case(case, repetition, output, str(binary), compiler, upstream, suite)
                report['results'].append(row)
                summarize(report)
                write_json(output / 'benchmark.json', report)
                print(f"{len(report['results']):3}/{report['expected_runs']} {case['id']}: {row['classification']}", flush=True)
        report['source_closure_unchanged'] = all(sha256(p) == h for p, h in execution_closure.items())
    finally:
        report['elapsed_seconds'] = time.monotonic() - started
        summarize(report)
        write_json(output / 'benchmark.json', report)
        (output / 'report.md').write_text(render(report))
    if not report.get('source_closure_unchanged') or not report['summary']['complete'] or report['summary']['infrastructure_errors']:
        return 2
    return 0 if report['summary']['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
