"""Export versioned coding evidence with authenticated historical Builder outcomes.

No model calls, execution of submitted code, training, or upload. The installed CLI
only inspects sealed snapshots. Private evaluation cases are referenced by hash.
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import time

from process import execute, save, sha
from evidence import validate_oracle, validate_process, validate_usage, validate_reassessment


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_file(root, relative, maximum=16 * 1024 * 1024):
    """No-follow bounded read, including ancestors inside the explicit evidence root."""
    parts = str(relative).split('/')
    if not parts or any(part in ('', '.', '..') for part in parts):
        raise ValueError('Evidence path must be normalized and relative')
    descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        leaf = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=descriptor)
        try:
            before = os.fstat(leaf)
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > maximum:
                raise ValueError('Evidence is not a bounded single-link regular file')
            data = b''
            while len(data) <= maximum:
                block = os.read(leaf, min(65536, maximum + 1 - len(data)))
                if not block:
                    break
                data += block
            after = os.fstat(leaf)
            fields = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
            if len(data) != before.st_size or any(getattr(before, k) != getattr(after, k) for k in fields):
                raise ValueError('Evidence changed during read')
            return data
        finally:
            os.close(leaf)
    finally:
        os.close(descriptor)


def record(root, relative):
    data = read_file(root, relative)
    return json.loads(data), {'path': str(root / relative), 'sha256': digest(data)}


def redact(text):
    return re.sub(r'\b(?:sk-[A-Za-z0-9_-]{16,}|AKIA[A-Z0-9]{16}|gh[pousr]_[A-Za-z0-9]{20,})\b',
                  '[REDACTED]', text)


def inspect_stages(attempt, binding, output, binary, binary_sha256):
    physical = Path(binding['project']).resolve()
    canonical = str(physical)
    # Foundation's resolvingSymlinksInPath().standardizedFileURL.path uses the
    # public Darwin /var alias. pathlib resolves that alias back to /private/var.
    # Accept the spelling only when it still names this same physical directory.
    for prefix in ('/private/var/', '/private/tmp/', '/private/etc/'):
        if canonical.startswith(prefix):
            alias = Path(canonical.removeprefix('/private'))
            if alias.samefile(physical): canonical = str(alias)
            break
    project_key = digest(canonical.encode())
    store_root = Path('/private/var/tmp/kist-builder-v2') / project_key
    inspections = []
    for number, store in enumerate(sorted(store_root.glob('*/run.json')), 1):
        if sha(binary) != binary_sha256:
            raise ValueError('Inspector binary changed')
        data = read_file(store_root, str(store.relative_to(store_root)))
        copied = output / 'builder' / str(number) / 'run.json'
        copied.parent.mkdir(parents=True, exist_ok=False)
        copied.write_bytes(data)
        copied.chmod(0o600)
        process = execute([str(binary), '--inspect-builder-evidence', str(copied)], output,
                          output / 'builder' / str(number) / 'inspection', timeout=30)
        report, ref = record(output, 'builder/' + str(number) + '/inspection/stdout.txt')
        accepted = process['passed'] and report.get('historicalAccepted') is True
        accepted = accepted and report.get('snapshotSHA256') == digest(data)
        if sha(binary) != binary_sha256:
            raise ValueError('Inspector binary changed during inspection')
        final = json.loads(data)['snapshot'].get('finalReceipt') or {}
        workers = final.get('workers', []) if accepted else []
        inspections.append({'accepted': bool(accepted), 'snapshot': {'path': str(copied), 'sha256': digest(data)},
                            'store_project_path': canonical,
                            'authenticated_workers': workers,
                            'inspection': ref, 'report': report, 'process': process})
    return sorted(inspections, key=lambda x: x['report'].get('observedAt', ''))


def source_binding(task, corpus, attempt, inspections):
    current = {name: task['template'].get(name) for name in task['writable']}
    issues = []
    mutations = []
    for inspection in inspections:
        if not inspection['accepted']:
            issues.append('a Builder stage has no authenticated accepted final')
            continue
        for receipt in inspection['report'].get('mutations', []):
            for operation in receipt['operations']:
                name = operation['path']
                if name not in current:
                    issues.append('accepted mutation is outside the task source allowlist: ' + name)
                    continue
                if current[name] != operation.get('preimageSHA256'):
                    issues.append('source preimage does not join the preceding accepted stage: ' + name)
                current[name] = operation.get('postimageSHA256')
                mutations.append(operation)
    patches = []
    for name in task['writable']:
        before = read_file(corpus / task['id'] / 'project', name, 1024 * 1024) if name in task['template'] else b''
        submitted = attempt / 'submitted' / name
        after = read_file(attempt, 'submitted/' + name, 1024 * 1024) if submitted.exists() else b''
        actual_digest = digest(after) if submitted.exists() else None
        if current[name] != actual_digest:
            issues.append('submitted source is not the final sealed postimage: ' + name)
        patch = ''.join(difflib.unified_diff(before.decode().splitlines(True), after.decode().splitlines(True),
                                            fromfile='before/' + name, tofile='after/' + name))
        safe = redact(patch)
        patches.append({'path': name, 'before_sha256': digest(before) if name in task['template'] else None,
                        'after_sha256': actual_digest, 'unified_diff': safe, 'redacted': safe != patch})
    if not mutations:
        issues.append('no sealed source mutation was retained for this coding attempt')
    return patches, issues


def export_attempt(attempt, task, corpus, output, binary, binary_sha256, split, reassessments=(), producer_builds=None):
    binding, binding_ref = record(attempt, 'binding.json')
    original, result_ref = record(attempt, 'result.json')
    usage, usage_ref = record(attempt, 'usage.json')
    oracle, oracle_ref = record(attempt, 'oracle/verification.json')
    output.mkdir(parents=True, exist_ok=False)
    inspections = inspect_stages(attempt, binding, output, binary, binary_sha256)
    patches, issues = source_binding(task, corpus, attempt, inspections)
    producing_build = (producer_builds or {}).get(binding['binary_sha256'])
    if producing_build is None:
        issues.append('no retained producing build manifest matches this binary')
    expected_route = (binding['provider'], binding['model'])
    for item in inspections:
        workers = item['authenticated_workers']
        if not workers or any((row.get('provider'), row.get('model')) != expected_route for row in workers):
            issues.append('authenticated worker routes do not match the declared producer')
    for name, expected in task['template'].items():
        if digest(read_file(corpus / task['id'] / 'project', name)) != expected:
            issues.append('frozen project input changed: ' + name)
    private_data = read_file(corpus / task['id'], 'private-cases.json')
    if digest(private_data) != task['private_cases_sha256']:
        issues.append('frozen external cases changed')
    task = dict(task, private_case_names=[row['name'] for row in json.loads(private_data)])
    if not inspections:
        issues.append('no host Builder snapshot is available')
    if binding['corpus_sha256'] != sha(corpus / 'manifest.json'):
        issues.append('attempt refers to another frozen corpus')
    if binding['task_id'] != task['id']:
        issues.append('attempt task id mismatch')
    if original.get('protected_inputs_unchanged') is not True or original.get('binary_unchanged') is not True:
        issues.append('original inputs or producing binary did not remain fixed')
    if binding.get('release_inputs') is not None and original.get('release_inputs_unchanged') is not True:
        issues.append('producing release resources did not remain fixed')
    if original.get('process_passed') is not True:
        issues.append('one or more original CLI processes failed')
    expected_final = {patch['path']: patch['after_sha256'] for patch in patches}
    initial_oracle = oracle
    assessment_refs = []
    for assessment_path in reassessments:
        assessment, assessment_ref = record(assessment_path.parent, assessment_path.name)
        if assessment.get('original_attempt') != str(attempt):
            continue
        revised, revision_issues = validate_reassessment(
            assessment, attempt, result_ref['sha256'], expected_final, task)
        assessment_refs.append({'reference': assessment_ref, 'issues': revision_issues,
                                'accepted': not revision_issues})
        if revision_issues:
            issues.extend(revision_issues)
        else:
            oracle = revised
    issues.extend(validate_oracle(oracle, expected_final, task))
    accounting_issues = validate_usage(usage)
    requests = []
    for process_file in sorted(attempt.glob('kist-*/process.json')):
        process, process_ref = record(attempt, str(process_file.relative_to(attempt)))
        issues.extend('producing CLI: ' + item for item in validate_process(process))
        if process['argv'][0] != binding['binary'] or process.get('cwd') != binding['project']:
            issues.append('producing CLI process is not bound to the recorded binary and project')
        for stream in ('stdin.txt', 'stdout.txt', 'stderr.txt'):
            data = read_file(process_file.parent, stream)
            if digest(data) != process.get(stream, {}).get('sha256'):
                issues.append('producing CLI stream digest mismatch: ' + str(process_file.parent.name) + '/' + stream)
        requests.append({'text': redact(process['argv'][-1]), 'process': process_ref,
                         'exit_code': process['exit_code'], 'timed_out': process['timed_out'],
                         'cleanup_complete': process['process_group_empty'] and not process['remaining_processes']})
    if not requests or len(inspections) != len(requests):
        issues.append('each producing CLI invocation must join one retained Builder snapshot')
    if len({item['report'].get('contractID') for item in inspections}) != len(inspections):
        issues.append('Builder snapshot contract identity is duplicated')
    task_bytes = read_file(corpus / task['id'] / 'project', 'TASK.md')
    fingerprint = digest(json.dumps({'origin': task['origin_sha256'], 'task': digest(task_bytes)}, sort_keys=True).encode())
    row = {'schema': 'kist.training-example.v1', 'mission_id': binding['mission_id'],
           'id': digest(json.dumps(binding_ref, sort_keys=True).encode()), 'split': split,
           'task_id': task['id'], 'task_fingerprint': fingerprint,
           'source_fingerprint': task['origin_sha256'], 'language': task['language'],
           'kind': task['kind'], 'attempt': binding_ref, 'initial_outcome': result_ref,
           'producer': {'binary_sha256': binding['binary_sha256'], 'provider': binding['provider'],
                        'model': binding['model'], 'build': producing_build,
                        'release_inputs': binding.get('release_inputs')},
           'requests': requests, 'task': {'text': redact(task_bytes.decode()), 'sha256': digest(task_bytes)},
           'patches': patches, 'builder_evidence': inspections,
           'independent_review': bool(inspections) and all(item['accepted'] and
                (item['report'].get('review') or {}).get('independent') is True for item in inspections),
           'review_grades': sorted({(item['report'].get('review') or {}).get('reviewGrade', 'unavailable')
                                   for item in inspections}),
           'external_verification': {'initial_reference': oracle_ref,
               'initial_passed': initial_oracle.get('passed', False),
               'initial_failure': initial_oracle.get('failure'),
               'reassessments': assessment_refs, 'passed': oracle.get('passed', False),
               'checks_passed': oracle.get('checks_passed'), 'checks_total': oracle.get('checks_total'),
               'cases_sha256': task['private_cases_sha256'], 'private_cases_included': False},
           'usage': {'reference': usage_ref, 'model_calls': usage['model_calls'],
               'reported_tokens': usage['reported_tokens'], 'estimated_tokens': usage['estimated_tokens'],
               'estimated_calls': usage.get('estimated_calls'), 'conflicts': usage['conflicts'],
               'accounting_issues': accounting_issues,
               'dollar_cost': None, 'authority': 'retained runtime-reported ledger; unavailable USD remains null'},
           'outcome': 'verified_pass' if not issues else 'not_verified', 'issues': issues,
           'training_eligible': split == 'training' and not issues and not accounting_issues,
           'retained_failures': {'initial_result_passed': original.get('passed'),
               'initial_external_passed': initial_oracle.get('passed'),
               'initial_external_failure': initial_oracle.get('failure'),
               'builder_failures': [failure for item in inspections for failure in item['report'].get('failures', [])]},
           'evaluation_contamination': [], 'exported_at': time.time(), 'inspector_sha256': binary_sha256}
    save(output / 'example.json', row)
    return row


def mark_contamination(rows, previous):
    """Record cross-split exact-task/source exposure; never claim semantic overlap is solved."""
    exposures = {}
    for row in previous + rows:
        for kind in ('task_fingerprint', 'source_fingerprint'):
            if row.get(kind):
                exposures.setdefault((kind, row[kind]), set()).add(row['split'])
    for row in rows:
        overlap = [kind for kind in ('task_fingerprint', 'source_fingerprint')
                   if row.get(kind) and len(exposures[(kind, row[kind])]) > 1]
        row['evaluation_contamination'] = overlap
        row['semantic_overlap_assessed'] = False
        if overlap:
            row['training_eligible'] = False
            row.setdefault('issues', []).append('training/evaluation overlap detected; keep out of unseen evaluation')
    return rows


def apply_adverse_observations(rows, paths):
    """Later source-bound failures can withdraw a label; they can never confer success."""
    references = []
    by_id = {row['id']: row for row in rows if row.get('id')}
    for path in paths:
        observations, reference = record(path.parent, path.name)
        if observations.get('schema') != 'kist.training-adverse-observation.v1':
            raise ValueError('unsupported adverse-observation schema')
        references.append(reference)
        for observation in observations.get('records', []):
            row = by_id.get(observation.get('example_id'))
            if row is None:
                continue
            source = observation.get('source_sha256')
            if source not in {patch['after_sha256'] for patch in row['patches']}:
                raise ValueError('adverse observation does not match exported source')
            artifact = observation['diagnostic']
            diagnostic_path = Path(artifact['path'])
            diagnostic, diagnostic_ref = record(diagnostic_path.parent, diagnostic_path.name)
            if diagnostic_ref['sha256'] != artifact['sha256']:
                raise ValueError('adverse verification artifact changed')
            checks = diagnostic.get('checks', [])
            if (diagnostic.get('passed') is not False
                    or source not in diagnostic.get('source', {}).values()
                    or not any(isinstance(check, dict) and check.get('passed') is False for check in checks)):
                raise ValueError('adverse verification must contain an actual failure on this source')
            row.setdefault('prior_verification_outcome', row['outcome'])
            row['outcome'] = 'not_verified'
            row['training_eligible'] = False
            row.setdefault('issues', []).append('later source-bound contract verification failed')
            row.setdefault('later_adverse_verification', []).append(diagnostic_ref)
    return references


def load_builds(paths):
    result = {}
    for path in paths:
        data = read_file(path.parent, path.name, 128_000)
        fields = {}
        for line in data.decode().splitlines():
            if ': ' not in line: raise ValueError('malformed build manifest')
            key, value = line.split(': ', 1)
            if key in fields: raise ValueError('duplicated build manifest field')
            fields[key] = value
        binary = fields.get('binary-sha256', '')
        source = fields.get('source-state-sha256', '')
        if not all(re.fullmatch('[a-f0-9]{64}', value) for value in (binary, source)):
            raise ValueError('build manifest lacks exact binary/source identity')
        if binary in result:
            raise ValueError('duplicate producing binary manifest')
        result[binary] = {'reference': {'path': str(path), 'sha256': digest(data)},
            'source_state_sha256': source, 'commit': fields.get('commit'),
            'source_dirty': fields.get('source-dirty'), 'test_evidence': fields.get('test-evidence'),
            'product_version': fields.get('product-version'),
            'authority': 'retained local deployment manifest; no independent or evolution authority'}
    return result


def failed_export(attempt, task, split, error):
    artifacts = {}
    for name in ('binding.json', 'result.json', 'usage.json', 'oracle/verification.json'):
        try:
            value, reference = record(attempt, name)
            artifacts[name] = {'reference': reference}
            if name == 'result.json': artifacts[name]['retained_result'] = value
        except Exception as failure:
            artifacts[name] = {'read_error': redact(type(failure).__name__ + ': ' + str(failure))}
    return {'schema': 'kist.training-example.v1', 'split': split, 'task_id': task['id'],
            'original_attempt': str(attempt), 'outcome': 'export_error', 'training_eligible': False,
            'issues': [redact(type(error).__name__ + ': ' + str(error))],
            'retained_artifacts': artifacts, 'evaluation_contamination': []}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--corpus', type=Path, required=True)
    parser.add_argument('--campaign', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--binary-sha256', required=True)
    parser.add_argument('--prior-export', action='append', type=Path, default=[])
    parser.add_argument('--reassessment', action='append', type=Path, default=[])
    parser.add_argument('--producer-build-manifest', action='append', type=Path, required=True)
    parser.add_argument('--adverse-observation', action='append', type=Path, default=[])
    args = parser.parse_args()
    manifest = json.loads((args.corpus / 'manifest.json').read_text())
    split = manifest.get('split', 'evaluation')
    if split not in ('training', 'evaluation'):
        parser.error('corpus split must be training or evaluation')
    if split == 'training' and 'do not train' in manifest.get('exposure', '').lower():
        parser.error('this frozen corpus is reserved for evaluation')
    if sha(args.binary) != args.binary_sha256:
        parser.error('inspector binary does not match the expected digest')
    producer_builds = load_builds(args.producer_build_manifest)
    args.output.mkdir(parents=True, exist_ok=False)
    args.output.chmod(0o700)
    rows = []
    for task in manifest['tasks']:
        for attempt in sorted((args.campaign / task['id']).glob('attempt-*')):
            destination = args.output / task['id'] / attempt.name
            try:
                row = export_attempt(attempt, task, args.corpus, destination,
                                     args.binary, args.binary_sha256, split, args.reassessment, producer_builds)
            except Exception as error:
                row = failed_export(attempt, task, split, error)
                save(destination / 'example.json', row)
            rows.append(row)
    previous = []
    prior_refs = []
    for prior in args.prior_export:
        data = read_file(prior.parent, prior.name, maximum=64 * 1024 * 1024)
        previous.extend(json.loads(line) for line in data.decode().splitlines() if line.strip())
        prior_refs.append({'path': str(prior), 'sha256': digest(data)})
    mark_contamination(rows, previous)
    adverse_refs = apply_adverse_observations(rows, args.adverse_observation)
    for row in rows:
        if row.get('attempt'):
            destination = args.output / row['task_id'] / Path(row['attempt']['path']).parent.name
            save(destination / 'example.json', row)
    data = ''.join(json.dumps(row, ensure_ascii=True, allow_nan=False, sort_keys=True) + '\n' for row in rows)
    destination = args.output / (split + '.jsonl')
    destination.write_text(data); destination.chmod(0o600)
    save(args.output / 'manifest.json', {'schema': 'kist.training-export.v1', 'split': split,
        'records': len(rows), 'verified_passes': sum(row['outcome'] == 'verified_pass' for row in rows),
        'training_eligible': sum(row['training_eligible'] for row in rows), 'jsonl_sha256': sha(destination),
        'inspector_sha256': args.binary_sha256, 'corpus_sha256': sha(args.corpus / 'manifest.json'),
        'script_sha256': sha(__file__), 'failures_retained': True,
        'producer_builds': producer_builds,
        'contamination_scope': 'exact task/source overlap among this corpus and supplied prior exports only; semantic and unprovided-history overlap are not assessed',
        'prior_exports': prior_refs, 'contaminated_records': sum(bool(row['evaluation_contamination']) for row in rows),
        'adverse_observations': adverse_refs,
        'adversely_reassessed_records': sum(bool(row.get('later_adverse_verification')) for row in rows)})
