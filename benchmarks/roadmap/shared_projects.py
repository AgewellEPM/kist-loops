"""Installed-CLI proof of default cross-project scope, restart and visible search limits.

Uses disposable synthetic archives and host-owned checks. No UI, VM, shell tool,
provider substitution, or evolution authority is involved. Keep every failed phase.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import uuid

from coding import collect_usage
from memory import DIRECTORY, materialize
from process import execute, save, sha, trial_environment
from release import check_release


def new_usage(project, previous):
    usage = collect_usage(project)
    usage['spans'] = [s for s in usage['spans'] if s['id'] not in previous]
    calls = [s for s in usage['spans'] if s.get('kind') == 'llmCall']
    reported = [s for s in calls if s.get('attributes', {}).get('usage.reported') == 'true']
    usage.update(model_calls=len(calls), estimated_calls=len(calls) - len(reported),
        reported_tokens=sum(s.get('promptTokens', 0) + s.get('completionTokens', 0) for s in reported),
        estimated_tokens=sum(s.get('promptTokens', 0) + s.get('completionTokens', 0) for s in calls if s not in reported),
        provider_policy_ok=all(s.get('vendor') == 'codex-cli' for s in calls))
    return usage


def history(project):
    directory = project / DIRECTORY
    return {p.stem: p for p in directory.glob('*.json')} if directory.exists() else {}


def observations(events):
    result = []
    for event in events:
        if event['kind'] != 'read_observation':
            continue
        try:
            value, _ = json.JSONDecoder().raw_decode(event['detail'].split('\n', 1)[1])
        except (ValueError, IndexError):
            continue
        if isinstance(value, dict) and value.get('mode') == 'history_search':
            result.append(value)
    return result


def catalog_projects(config):
    return {json.loads(p.read_text())['project']['canonicalPath']
            for p in (config / 'kist/agent-memory-projects/v1').glob('*.json')}


def run(corpus, output, binary, repetitions=2):
    if repetitions < 2:
        raise ValueError('at least two separate recall processes are required')
    output.mkdir(parents=True, exist_ok=False)
    output.chmod(0o700)
    manifest = json.loads((corpus / 'manifest.json').read_text())
    save(output / 'harness.json', {'files': {p.name: sha(p) for p in Path(__file__).parent.glob('*.py')},
        'corpus_sha256': sha(corpus / 'manifest.json'), 'mission_id': manifest['mission_id']})
    preflight = check_release(binary, output / 'release-preflight.json')
    if not preflight['passed']:
        raise RuntimeError('release preflight failed before any CLI invocation')
    release = preflight['closure']
    config = output / 'config'
    config_path = config / 'kist/config.json'
    save(config_path, {'provider': 'codex-cli', 'model': 'gpt-5.6-sol',
                      'autoRouting': False, 'allowedProviders': ['codex-cli']})
    policy_hash = sha(config_path)
    fixture = Path(tempfile.mkdtemp(prefix='kist-shared-projects-')).resolve()
    current, granted, denied = fixture / 'current', fixture / 'granted/known', fixture / 'denied'
    for path in (current, granted, denied):
        path.mkdir(parents=True)
    originals = {granted: materialize(corpus, granted)}
    expected = manifest['expected']
    source = str(granted / DIRECTORY / (expected['id'] + '.json'))
    desired = {key: expected[key] for key in ('value', 'at')}
    desired['source'] = source
    # A valid but unauthorized project has the SAME event ID. Exclusion must come
    # from grants; dictionary keys and the model's choice of answer cannot hide it.
    denied_event = json.loads(Path(source).read_text())
    denied_canary = 'excluded-' + uuid.uuid4().hex
    denied_event['detail'] = 'larchArchiveNeedle value=' + denied_canary
    denied_event['originalBytes'] = len(denied_event['detail'].encode())
    denied_event['detailSHA256'] = hashlib.sha256(denied_event['detail'].encode()).hexdigest()
    info = denied.stat()
    denied_event['agent'] = dict(denied_event['agent'], project={
        'canonicalPath': str(denied), 'deviceID': info.st_dev, 'inode': info.st_ino}, executionRoot=str(denied))
    denied_source = denied / DIRECTORY / (expected['id'] + '.json')
    save(denied_source, denied_event)
    denied_source.parent.chmod(0o700)
    originals[denied] = {expected['id']: sha(denied_source)}
    instructions = ('Disposable read-only memory trial. Use shared_memory for original raw events. '
        'Preserve seeded files. No edits, shell, downloads, delegation, UI, VM or outside research.\n')
    for path in (current, denied):
        (path / 'AGENTS.md').write_text(instructions)
    save(output / 'binding.json', {'schema': 'kist.shared-project-memory-trial.v1',
        'mission_id': manifest['mission_id'], 'release_inputs': release,
        'corpus_sha256': sha(corpus / 'manifest.json'), 'current_project': str(current),
        'authorized_read_roots': [str(granted.parent)], 'granted_project': str(granted),
        'denied_project': str(denied), 'expected': desired,
        'denied_canary': denied_canary, 'seeded': {str(k): v for k, v in originals.items()},
        'scope': 'synthetic raw-history behavior, not sealed completion or evolution evidence'})
    results = []

    def session(name, project, prompt=None, broad=False):
        attempt = output / name
        attempt.mkdir()
        before = check_release(binary, attempt / 'release-before.json', release)
        if not before['passed']:
            raise RuntimeError('release changed before invocation; no new inference')
        prior_events = set(history(project))
        prior_spans = {s['id'] for s in collect_usage(project)['spans']}
        argv = [str(binary), '--provider', 'codex-cli', '--model', 'gpt-5.6-sol', '--tools', 'text',
                '--fast', '--auto', '--sandbox', '--delegation-depth', '0', '--max-iterations', '10',
                '--budget', '400000', '--project', str(project), '--allow-read', str(granted.parent)]
        print(json.dumps({'started': name, 'project': str(project)}), flush=True)
        process = execute(argv, project, attempt / 'kist', environment=trial_environment(config, project),
            stdin=(prompt + '\n/usage\n' if prompt else '') + '/quit\n', timeout=600)
        after = check_release(binary, attempt / 'release-after.json', release)
        usage = new_usage(project, prior_spans)
        events = [json.loads(p.read_text()) for key, p in history(project).items() if key not in prior_events]
        seen = observations(events)
        checks = {'process_clean': process['passed'], 'release_unchanged': after['passed'],
            'route_policy_unchanged': sha(config_path) == policy_hash,
            'provider_policy_ok': usage['provider_policy_ok'],
            'usage_complete': not usage['conflicts'] and usage['estimated_calls'] == 0,
            'seeded_bytes_unchanged': all(sha(p / DIRECTORY / (key + '.json')) == digest
                for p, rows in originals.items() for key, digest in rows.items())}
        if prompt is None:
            checks.update(no_model_calls=usage['model_calls'] == 0,
                          host_registered_project=str(project) in catalog_projects(config))
        else:
            starts = [e['detail'] for e in events if e['kind'] == 'tool_started']
            calls = [s for s in starts if 'tool=shared_memory\n' in s]
            checks.update(actual_model_calls=usage['model_calls'] > 0,
                used_default_history_search=bool(calls) and all('mode: history_search' in s and 'project:' not in s for s in calls),
                memory_tool_only=bool(starts) and len(calls) == len(starts),
                parsed_memory_observation=bool(seen),
                unauthorized_value_absent=not any(denied_canary in e['detail'] for e in events),
                observed_sources_in_grant=all(row.get('project') == str(granted)
                    and row.get('source', '').startswith(str(granted) + '/')
                    for observation in seen for row in observation.get('results', [])))
            finals = []
            for event in events:
                if event['kind'] == 'run_finished' and event['detail'].startswith('success=true;'):
                    try:
                        finals.append(json.loads(event['detail'].split('\n', 1)[1]))
                    except (ValueError, IndexError):
                        pass
            if broad:
                checks.update(one_search=len(calls) == 1,
                    explicit_incompleteness=any(o.get('history_search_complete') is False
                        and (o.get('retrieval_issues') or o.get('result_window_limited'))
                        and isinstance(o.get('next_cursor'), str) and o['next_cursor'] for o in seen),
                    correct_final_answer=any(answer == {'complete': False, 'continuation': True} for answer in finals))
            else:
                checks.update(correct_final_answer=any(answer == desired for answer in finals),
                    original_value_time_source_observed=any(row.get('source') == source
                        and row.get('at') == desired['at'] and desired['value'] in row.get('excerpt', '')
                        for observation in seen for row in observation.get('results', [])))
        save(attempt / 'usage.json', usage)
        save(attempt / 'new-events.json', events)
        save(attempt / 'observations.json', seen)
        result = {'phase': name, 'checks': checks, 'passed': all(value is True for value in checks.values()),
                  'model_calls': usage['model_calls'], 'reported_tokens': usage['reported_tokens'],
                  'seconds': process['seconds'], 'separate_process': True}
        save(attempt / 'result.json', result)
        for directory in ('.kist', '.mythos'):
            if (project / directory).is_dir():
                shutil.copytree(project / directory, attempt / 'project-audit' / directory)
        results.append(result)
        save(output / 'summary.json', results)
        print(json.dumps(result), flush=True)
        if not result['passed']:
            raise RuntimeError('retained unsuccessful memory phase: ' + name)

    # Real host registration, then separate current-project sessions. No fixture
    # catalog is forged and no model call is needed merely to register a project.
    session('register-granted', granted)
    session('register-denied', denied)
    prompt = ('Use only shared_memory in history_search mode with query larchArchiveNeedle and '
        'run_id synthetic-history. Omit project so the default authorized-project scope is tested. '
        'Return only a JSON object with value, at (the original ISO8601 timestamp), and source '
        '(the original event locator). Follow continuation only if the requested event is absent. '
        'Do not read files, run commands, guess, delegate or edit.')
    for repeat in range(1, repetitions + 1):
        session(f'recall-{repeat:04d}', current, prompt)
    session('incomplete-window', current,
        'Make exactly one shared_memory history_search call with query "synthetic unrelated observation", '
        'run_id synthetic-history and limit 100, omitting project. Do not continue to another page or use '
        'other tools. Return only JSON with complete equal to history_search_complete and continuation '
        'equal to whether next_cursor is present.', broad=True)
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--corpus', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--repetitions', type=int, default=2)
    args = parser.parse_args()
    run(args.corpus, args.output, args.binary, args.repetitions)
