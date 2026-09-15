"""Repeatable installed-Kist trials over an immutable, repository-derived corpus."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import tempfile
import time

from process import execute, save, sha, trial_environment
from verify import verify
from release import check_release


def collect_usage(project):
    ledger = Path(project) / '.kist/usage.jsonl'
    rows = [json.loads(line) for line in ledger.read_text().splitlines() if line.strip()] if ledger.exists() else []
    unique = {}
    conflicts = []
    for row in rows:
        identifier = row.get('id')
        if not identifier:
            conflicts.append('missing span id')
        elif identifier in unique and unique[identifier] != row:
            conflicts.append('conflicting span: ' + identifier)
        else:
            unique[identifier] = row
    calls = [row for row in unique.values() if row.get('kind') == 'llmCall']
    reported = [row for row in calls if row.get('attributes', {}).get('usage.reported') == 'true']
    estimated = [row for row in calls if row.get('attributes', {}).get('usage.reported') != 'true']
    return {'spans': list(unique.values()), 'conflicts': conflicts, 'model_calls': len(calls),
            'reported_tokens': sum(row.get('promptTokens', 0) + row.get('completionTokens', 0) for row in reported),
            'estimated_tokens': sum(row.get('promptTokens', 0) + row.get('completionTokens', 0) for row in estimated),
            'estimated_calls': len(estimated), 'dollar_cost': None,
            'provider_policy_ok': all(row.get('vendor') == 'codex-cli' for row in calls)}


def run_task(task, corpus, output, binary, *, repetitions, max_iterations=20, budget=600000,
             expected_release=None):
    manifest = json.loads((corpus / 'manifest.json').read_text())
    preflight = check_release(binary, output / task['id'] / 'release-preflight.json', expected_release)
    if not preflight['passed']:
        raise RuntimeError('release preflight failed before inference: ' + '; '.join(preflight['issues']))
    expected_release = preflight['closure']
    config = output / 'config'
    save(config / 'kist/config.json', {'provider': 'codex-cli', 'model': 'gpt-5.6-sol',
         'autoRouting': False, 'allowedProviders': ['codex-cli']})
    expected_binary = expected_release['binary_sha256']
    summary = []
    for repetition in range(1, repetitions + 1):
        attempt = output / task['id'] / f'attempt-{repetition:04d}'
        attempt.mkdir(parents=True, exist_ok=False)
        project = Path(tempfile.mkdtemp(prefix='kist-roadmap-' + task['id'] + '-')).resolve()
        shutil.copytree(corpus / task['id'] / 'project', project, dirs_exist_ok=True)
        protected = {name: digest for name, digest in task['template'].items() if name not in task['writable']}
        prompt = ('Read TASK.md and perform its ' + task['kind'] + '. Only ' + ', '.join(task['writable'])
                  + ' may change. Use Kist file tools to inspect and edit the existing implementation. '
                  + 'The complete deterministic verifier is make verify; run it after the final edit. '
                  + 'Use the advertised Kist JSON actions. Do not delegate. Report actual results.')
        argv = [str(binary), '--provider', 'codex-cli', '--model', 'gpt-5.6-sol',
                '--critic', 'codex-cli:gpt-5.6-sol', '--review-grade', 'fresh_context_same_model',
                '--headless', '--tools', 'text', '--fast', '--auto', '--no-memory',
                '--delegation-depth', '0', '--max-iterations', str(max_iterations), '--budget', str(budget),
                '--project', str(project), prompt]
        binding = {'schema': 'kist.roadmap-coding-attempt.v1', 'mission_id': manifest['mission_id'],
                   'task_id': task['id'], 'repetition': repetition, 'project': str(project),
                   'binary': str(binary), 'binary_sha256': expected_binary,
                   'release_inputs': expected_release,
                   'corpus_sha256': sha(corpus / 'manifest.json'), 'started_at': time.time(),
                   'provider': 'codex-cli', 'model': 'gpt-5.6-sol', 'independent': False,
                   'mode': 'single_worker', 'protected': protected}
        save(attempt / 'binding.json', binding)
        print(json.dumps({'started': task['id'], 'repetition': repetition, 'project': str(project)}), flush=True)
        processes = []
        if task['id'] == 'typescript-tags':
            stages = [
                'Read TASK.md and tags.ts. Perform the first bounded step of the requested refactor: create only tag-normalize.ts, containing the existing single-tag normalization implementation and its private constants, exporting normalizeTag and MAX_TAG_LEN. Leave tags.ts unchanged in this step. The complete deterministic verifier is make verify. Run it after creating the module; report actual results. Do not delegate.',
                'Read TASK.md and both tag modules. Complete the refactor by editing only tags.ts to import normalizeTag and MAX_TAG_LEN from tag-normalize.ts, re-export them, and keep normalizeTagList and MAX_TAGS_PER_BOARD. Remove the duplicate normalization implementation and its private constants from tags.ts. Leave tag-normalize.ts unchanged. The complete deterministic verifier is make verify. Run it after the final edit; report actual results. Do not delegate.',
            ]
        else:
            stages = [prompt]
        for index, stage in enumerate(stages, 1):
            ready = check_release(binary, attempt / f'release-before-{index}.json', expected_release)
            if not ready['passed']:
                processes.append({'passed': False, 'seconds': 0, 'kind': 'release_preflight_failure',
                                  'issues': ready['issues']})
                break
            process = execute(argv[:-1] + [stage], project, attempt / f'kist-{index}',
                              environment=trial_environment(config, project), timeout=600)
            processes.append(process)
            if not process['passed']:
                break
        verification = verify(task, corpus, project, attempt / 'oracle', config)
        usage = collect_usage(project)
        save(attempt / 'usage.json', usage)
        final_release = check_release(binary, attempt / 'release-after.json', expected_release)
        protected_ok = all((project / name).is_file() and not (project / name).is_symlink()
                           and sha(project / name) == digest for name, digest in protected.items())
        # The host oracle determines functional correctness; neither prose nor exit 0 suffices.
        result = {'mission_id': manifest['mission_id'], 'task_id': task['id'], 'repetition': repetition,
                  'process_passed': len(processes) == len(stages) and all(p['passed'] for p in processes),
                  'external_verification_passed': verification['passed'],
                  'protected_inputs_unchanged': protected_ok,
                  'binary_unchanged': (final_release['closure'] or {}).get('binary_sha256') == expected_binary,
                  'release_inputs_unchanged': final_release['passed'],
                  'seconds': sum(p['seconds'] for p in processes), 'model_calls': usage['model_calls'],
                  'reported_tokens': usage['reported_tokens'], 'estimated_tokens': usage['estimated_tokens'],
                  'usage_conflicts': usage['conflicts'], 'provider_policy_ok': usage['provider_policy_ok']}
        result['passed'] = all(result[key] for key in ('process_passed', 'external_verification_passed',
            'protected_inputs_unchanged', 'binary_unchanged', 'release_inputs_unchanged',
            'provider_policy_ok')) and not usage['conflicts']
        result['label_authority'] = 'local host functional verification; not independently reviewed or evolution accepted'
        save(attempt / 'result.json', result)
        for name in ('.kist', '.mythos'):
            if (project / name).is_dir():
                shutil.copytree(project / name, attempt / 'project-audit' / name)
        for name in task['writable']:
            if (project / name).is_file():
                target = attempt / 'submitted' / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(project / name, target)
        summary.append(result)
        print(json.dumps(result), flush=True)
    return summary


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--corpus', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--task', action='append')
    parser.add_argument('--repetitions', type=int, default=2)
    parser.add_argument('--baseline-source', action='store_true')
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error('repetitions must be positive')
    manifest = json.loads((args.corpus / 'manifest.json').read_text())
    selected = [task for task in manifest['tasks'] if not args.task or task['id'] in args.task]
    if not selected or args.task and set(args.task) != {task['id'] for task in selected}:
        parser.error('unknown or empty task selection')
    args.output.mkdir(parents=True, exist_ok=False)
    save(args.output / 'harness.json', {'files': {p.name: sha(p) for p in Path(__file__).parent.glob('*.py')},
                                      'corpus_sha256': sha(args.corpus / 'manifest.json')})
    results = []
    release = None
    if not args.baseline_source:
        preflight = check_release(args.binary, args.output / 'release-preflight.json')
        if not preflight['passed']:
            parser.error('release preflight failed before inference; see release-preflight.json')
        release = preflight['closure']
    for task in selected:
        if args.baseline_source:
            result = verify(task, args.corpus, args.corpus / task['id'] / 'project',
                            args.output / task['id'], args.output / 'config')
            results.append({'task_id': task['id'], 'passed': result['passed'],
                            'checks_passed': result.get('checks_passed'), 'failure': result.get('failure')})
        else:
            results += run_task(task, args.corpus, args.output, args.binary, repetitions=args.repetitions,
                                expected_release=release)
    save(args.output / 'summary.json', results)
    print(json.dumps(results), flush=True)
