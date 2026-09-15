"""Paired release metrics including unsuccessful attempts and explicit reassessments."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import statistics

from process import save, sha


def load_campaigns(campaigns):
    rows = {}
    for campaign in campaigns:
        for result_file in sorted(campaign.glob('*/attempt-*/result.json')):
            attempt = result_file.parent
            result = json.loads(result_file.read_text())
            binding = json.loads((attempt / 'binding.json').read_text())
            usage = json.loads((attempt / 'usage.json').read_text())
            key = (binding['task_id'], binding['repetition'])
            if key in rows:
                raise ValueError('duplicated paired trial: ' + str(key))
            if usage['estimated_calls'] or usage['conflicts'] or not usage['provider_policy_ok']:
                raise ValueError('usage or provider policy gap in ' + str(attempt))
            if result['reported_tokens'] != usage['reported_tokens'] or result['model_calls'] != usage['model_calls']:
                raise ValueError('result/accounting mismatch in ' + str(attempt))
            rows[key] = {'attempt': str(attempt), 'result_sha256': sha(result_file),
                         'binding_sha256': sha(attempt / 'binding.json'),
                         'binary_sha256': binding['binary_sha256'], 'corpus_sha256': binding['corpus_sha256'],
                         'original_passed': result['passed'], 'assessed_passed': result['passed'],
                         'reported_tokens': usage['reported_tokens'], 'model_calls': usage['model_calls'],
                         'seconds': result['seconds'], 'reassessments': [], 'result': result}
    if not rows:
        raise ValueError('no completed attempt records in supplied campaigns')
    return rows


def reassess(rows, paths):
    by_attempt = {row['attempt']: row for row in rows.values()}
    for path in paths:
        value = json.loads(path.read_text())
        row = by_attempt.get(value['original_attempt'])
        if row is None:
            raise ValueError('reassessment has no original paired attempt: ' + str(path))
        if value['original_result_sha256'] != row['result_sha256'] or value['original_failed_result_preserved'] is not True:
            raise ValueError('reassessment does not preserve the original result')
        oracle = value['verification']
        attempt = Path(row['attempt'])
        if not oracle.get('source') or not all(sha(attempt / 'submitted' / name) == digest for name, digest in oracle['source'].items()):
            raise ValueError('reassessment did not verify these retained source bytes')
        original = row['result']
        remaining = all(original[key] for key in ('process_passed', 'protected_inputs_unchanged', 'binary_unchanged', 'provider_policy_ok'))
        row['assessed_passed'] = remaining and oracle.get('passed') is True and not original['usage_conflicts']
        row['reassessments'].append({'path': str(path), 'sha256': sha(path),
                                    'assessed_passed': row['assessed_passed']})


def summarize(rows):
    values = list(rows.values())
    return {'attempts': len(values), 'original_passes': sum(row['original_passed'] for row in values),
            'assessed_passes': sum(row['assessed_passed'] for row in values),
            'median_reported_tokens_all_attempts': statistics.median(row['reported_tokens'] for row in values),
            'total_reported_tokens': sum(row['reported_tokens'] for row in values),
            'model_calls': sum(row['model_calls'] for row in values),
            'median_seconds_all_attempts': statistics.median(row['seconds'] for row in values),
            'binary_sha256': sorted({row['binary_sha256'] for row in values})}


def compare(baseline, candidate):
    if set(baseline) != set(candidate):
        raise ValueError('paired task/repetition coverage differs')
    for key in baseline:
        if baseline[key]['corpus_sha256'] != candidate[key]['corpus_sha256']:
            raise ValueError('frozen corpus differs for ' + str(key))
    before, after = summarize(baseline), summarize(candidate)
    regressions = [list(key) for key in baseline if baseline[key]['assessed_passed'] and not candidate[key]['assessed_passed']]
    median_before = before['median_reported_tokens_all_attempts']
    reduction = 1 - after['median_reported_tokens_all_attempts'] / median_before if median_before else None
    return {'schema': 'kist.paired-release-comparison.v1', 'baseline': before, 'candidate': after,
            'token_reduction_fraction': reduction, 'paired_regressions': regressions,
            'proposed_half_token_target_met': reduction is not None and reduction >= .5 and not regressions,
            'recall_accuracy_gate': 'reported separately; coding metrics alone cannot establish unchanged recall',
            'paired_attempts': [{'task_id': key[0], 'repetition': key[1],
                                'baseline': baseline[key], 'candidate': candidate[key]} for key in sorted(baseline)],
            'authority': 'local benchmark comparison; not independent review or evolution acceptance'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', type=Path, action='append', required=True)
    parser.add_argument('--candidate', type=Path, action='append', required=True)
    parser.add_argument('--baseline-reassessment', type=Path, action='append', default=[])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    baseline, candidate = load_campaigns(args.baseline), load_campaigns(args.candidate)
    reassess(baseline, args.baseline_reassessment)
    result = compare(baseline, candidate)
    save(args.output, result)
    print(json.dumps({key: value for key, value in result.items() if key != 'paired_attempts'}))
