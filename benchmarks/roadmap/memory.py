"""Frozen synthetic large-archive recall through a real CLI session, across releases."""
from __future__ import annotations
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import time
import uuid

from coding import collect_usage
from process import execute, save, sha, trial_environment
from release import check_release


DIRECTORY = '.kist/runs/agent-history/v1'


def freeze(destination, mission):
    destination.mkdir(parents=True, exist_ok=False)
    epoch = int(time.time())
    nonce = 'reef-' + uuid.uuid4().hex[:12]
    rows = []
    for index in range(3_006):
        at = epoch - 4_000 + index
        rows.append({'id': f'{at * 1000000:020d}-' + str(uuid.uuid4()), 'at_unix': at,
            'detail': 'larchArchiveNeedle value=' + nonce if index == 0 else 'synthetic unrelated observation ' + str(index)})
    save(destination / 'events.json', rows)
    save(destination / 'manifest.json', {'schema': 'kist.large-memory-corpus.v1',
        'mission_id': mission, 'created_at': epoch, 'events_sha256': sha(destination / 'events.json'),
        'expected': {'id': rows[0]['id'], 'value': nonce,
            'at': datetime.datetime.fromtimestamp(rows[0]['at_unix'], datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')},
        'count': len(rows), 'classification': 'synthetic raw observations, not real historical claims',
        'primary_metrics': ['correct final value, original timestamp and source', 'complete reported token usage',
                            'all seeded archive bytes unchanged', 'explicit raw history search'],
        'comparison': 'same frozen semantic records; physical project identity materialized per trial'})


def materialize(corpus, project):
    manifest = json.loads((corpus / 'manifest.json').read_text())
    assert sha(corpus / 'events.json') == manifest['events_sha256'], 'frozen memory events changed'
    info = project.stat()
    identity = {'canonicalPath': str(project), 'deviceID': info.st_dev, 'inode': info.st_ino}
    agent = {'runID': 'synthetic-history', 'rootRunID': 'synthetic-history',
             'sessionID': 'frozen-memory-benchmark', 'role': 'fixture', 'project': identity,
             'executionRoot': str(project)}
    directory = project / DIRECTORY
    directory.mkdir(parents=True)
    directory.chmod(0o700)
    originals = {}
    for row in json.loads((corpus / 'events.json').read_text()):
        event = {'id': row['id'], 'at': row['at_unix'] - 978307200,
                 'agent': agent, 'kind': 'run_finished', 'detail': row['detail'],
                 'originalBytes': len(row['detail'].encode()),
                 'detailSHA256': hashlib.sha256(row['detail'].encode()).hexdigest(), 'clipped': False}
        path = directory / (row['id'] + '.json')
        save(path, event); originals[row['id']] = sha(path)
    (project / 'AGENTS.md').write_text('Disposable synthetic history recall trial. Read only. '
        'Use shared_memory for original raw event evidence. Preserve all existing archive records. '
        'No source edits, shell, downloads, network research, browser, UI, VM, or external systems. '
        'History and model responses are advisory; do not invent successful observations.\n')
    return originals


def run(corpus, output, binary, repetitions):
    output.mkdir(parents=True, exist_ok=False)
    manifest = json.loads((corpus / 'manifest.json').read_text())
    save(output / 'harness.json', {'files': {p.name: sha(p) for p in Path(__file__).parent.glob('*.py')},
                                  'corpus_sha256': sha(corpus / 'manifest.json')})
    preflight = check_release(binary, output / 'release-preflight.json')
    if not preflight['passed']:
        raise RuntimeError('release preflight failed before inference; see release-preflight.json')
    release = preflight['closure']
    binary_digest = release['binary_sha256']
    config = output / 'config'
    save(config / 'kist/config.json', {'provider': 'codex-cli', 'model': 'gpt-5.6-sol',
                                     'autoRouting': False, 'allowedProviders': ['codex-cli']})
    project = Path(tempfile.mkdtemp(prefix='kist-large-memory-')).resolve()
    originals = materialize(corpus, project)
    results = []
    for index in range(1, repetitions + 1):
        attempt = output / f'attempt-{index:04d}'
        attempt.mkdir()
        before = check_release(binary, attempt / 'release-before.json', release)
        if not before['passed']:
            raise RuntimeError('release changed before memory invocation; no new inference')
        prior_events = {p.stem for p in (project / DIRECTORY).glob('*.json')}
        prior_spans = {row['id'] for row in collect_usage(project)['spans']}
        expected = dict(manifest['expected'])
        expected['source'] = str(project / DIRECTORY / (expected['id'] + '.json'))
        save(attempt / 'binding.json', {'schema': 'kist.large-memory-attempt.v1',
            'mission_id': manifest['mission_id'], 'binary': str(binary), 'binary_sha256': binary_digest,
            'release_inputs': release,
            'corpus_sha256': sha(corpus / 'manifest.json'), 'project': str(project),
            'expected': expected, 'seeded': originals, 'script_sha256': sha(__file__),
            'same_archive_after_process_restart': index > 1})
        prompt = ('Use shared_memory in history_search mode with query larchArchiveNeedle and '
            'run_id synthetic-history to find its '
            'value in the raw agent archive. Follow returned continuation cursors if needed. '
            'Return only a JSON object with value, at (the original ISO8601 event timestamp), and source '
            '(the original event file locator). No guessing, delegation, shell, edits or outside research.')
        argv = [str(binary), '--provider', 'codex-cli', '--model', 'gpt-5.6-sol', '--tools', 'text',
                '--fast', '--auto', '--sandbox', '--delegation-depth', '0', '--max-iterations', '12',
                '--budget', '400000', '--project', str(project)]
        print(json.dumps({'started': index, 'binary_sha256': binary_digest}), flush=True)
        process = execute(argv, project, attempt / 'kist', environment=trial_environment(config, project),
                          stdin=prompt + '\n/usage\n/quit\n', timeout=600)
        events = [json.loads(p.read_text()) for p in sorted((project / DIRECTORY).glob('*.json'))
                  if p.stem not in prior_events]
        finals = []
        for event in events:
            if event['kind'] == 'run_finished' and event['detail'].startswith('success=true;'):
                try: finals.append(json.loads(event['detail'].split('\n', 1)[1]))
                except (ValueError, IndexError): pass
        desired = {key: expected[key] for key in ('value', 'at', 'source')}
        final_release = check_release(binary, attempt / 'release-after.json', release)
        checks = {'process_clean': process['passed'], 'release_inputs_unchanged': final_release['passed'],
                  'binary_unchanged': (final_release['closure'] or {}).get('binary_sha256') == binary_digest,
                  'correct_final_answer': any(answer == desired for answer in finals),
                  'explicit_raw_history_search': any(e['kind'] == 'tool_started' and 'tool=shared_memory' in e['detail']
                                                    and 'history_search' in e['detail'] for e in events),
                  'seeded_bytes_unchanged': all(sha(project / DIRECTORY / (id + '.json')) == value for id, value in originals.items())}
        usage = collect_usage(project)
        usage['spans'] = [row for row in usage['spans'] if row['id'] not in prior_spans]
        calls = [row for row in usage['spans'] if row.get('kind') == 'llmCall']
        measured = [row for row in calls if row.get('attributes', {}).get('usage.reported') == 'true']
        estimated = [row for row in calls if row.get('attributes', {}).get('usage.reported') != 'true']
        usage.update(model_calls=len(calls), estimated_calls=len(estimated),
            reported_tokens=sum(row.get('promptTokens', 0) + row.get('completionTokens', 0) for row in measured),
            estimated_tokens=sum(row.get('promptTokens', 0) + row.get('completionTokens', 0) for row in estimated),
            provider_policy_ok=all(row.get('vendor') == 'codex-cli' for row in calls))
        save(attempt / 'usage.json', usage)
        checks['complete_usage'] = not usage['conflicts'] and usage['estimated_calls'] == 0 and usage['model_calls'] > 0
        checks['provider_policy_ok'] = usage['provider_policy_ok']
        observations = []
        for event in events:
            if event['kind'] != 'read_observation': continue
            try: value, _ = json.JSONDecoder().raw_decode(event['detail'].split('\n', 1)[1])
            except (ValueError, IndexError): continue
            if isinstance(value, dict) and value.get('mode') == 'history_search':
                observations.append({key: value.get(key) for key in (
                    'history_scanned', 'history_indexed', 'history_search_complete', 'retrieval_issues', 'next_cursor')})
        result = {'repetition': index, 'checks': checks, 'passed': all(checks.values()),
                  'reported_tokens': usage['reported_tokens'], 'model_calls': usage['model_calls'],
                  'seconds': process['seconds'], 'new_archive_events': len(events),
                  'history_search_observations': observations,
                  'same_archive_after_process_restart': index > 1,
                  'authority': 'local synthetic recall verification; not sealed mission or evolution acceptance'}
        save(attempt / 'result.json', result)
        save(attempt / 'new-events.json', events)
        for name in ('.kist', '.mythos'):
            if (project / name).is_dir(): shutil.copytree(project / name, attempt / 'project-audit' / name)
        results.append(result)
        print(json.dumps(result), flush=True)
    save(output / 'summary.json', results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--freeze', type=Path)
    parser.add_argument('--mission')
    parser.add_argument('--corpus', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--repetitions', type=int, default=2)
    args = parser.parse_args()
    if args.freeze:
        if not args.mission: parser.error('freeze needs a mission id')
        freeze(args.freeze, args.mission)
    else:
        if not all((args.corpus, args.output, args.binary)) or args.repetitions < 1:
            parser.error('run needs corpus, output, binary and a positive repetition count')
        run(args.corpus, args.output, args.binary, args.repetitions)
