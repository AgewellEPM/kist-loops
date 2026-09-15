"""Pure validation of retained benchmark evidence; never executes submitted code."""
from __future__ import annotations

def validate_oracle(oracle, source, task):
    issues = []
    if oracle.get('passed') is not True:
        issues.append('external oracle did not pass')
    if oracle.get('task_id') != task['id'] or oracle.get('source') != source:
        issues.append('external oracle is not bound to this task and exact source')
    cases = oracle.get('checks')
    if (not isinstance(cases, list) or not cases
            or any(not isinstance(row, dict) or row.get('passed') is not True for row in cases)):
        issues.append('external case results are absent, malformed or failing')
    elif (type(oracle.get('checks_total')) is not int or oracle['checks_total'] != len(cases)
          or type(oracle.get('checks_passed')) is not int or oracle['checks_passed'] != len(cases)):
        issues.append('external case counts do not match retained results')
    elif task.get('private_case_names') is not None and [row.get('name') for row in cases] != task['private_case_names']:
        issues.append('external checks do not cover the frozen case sequence')
    if oracle.get('copied_source_unchanged') is not True:
        issues.append('external copied-source integrity was not confirmed')
    stages = ['execution'] + (['compile'] if task.get('build') else [])
    if task['id'] == 'typescript-tags' or task.get('module_boundary_required'):
        stages.append('module_boundary')
    for stage in stages:
        issues.extend(stage + ': ' + item for item in validate_process(oracle.get(stage, {})))
    return issues


def validate_process(process):
    issues = []
    if process.get('passed') is not True or type(process.get('exit_code')) is not int or process['exit_code'] != 0:
        issues.append('process did not exit successfully')
    if process.get('timed_out') is not False or process.get('output_limit_exceeded') is not False:
        issues.append('timeout or output-limit status is not clean')
    if process.get('errors'):
        issues.append('process retained infrastructure errors')
    if process.get('process_group_empty') is not True or process.get('remaining_processes') != []:
        issues.append('observed process cleanup is not complete')
    return issues


def validate_usage(usage):
    issues = []
    spans = usage.get('spans')
    if not isinstance(spans, list):
        return ['retained usage spans are missing']
    ids = set()
    calls = reported = estimated = tokens = estimated_tokens = 0
    for span in spans:
        if not isinstance(span, dict) or not isinstance(span.get('id'), str) or span['id'] in ids:
            issues.append('usage span identity is malformed or duplicated')
            continue
        ids.add(span['id'])
        if span.get('kind') != 'llmCall':
            continue
        calls += 1
        values = [span.get(key, 0) for key in ('promptTokens', 'completionTokens')]
        if any(type(value) is not int or value < 0 for value in values):
            issues.append('token counts are not nonnegative integers')
            continue
        if span.get('attributes', {}).get('usage.reported') == 'true':
            reported += 1; tokens += sum(values)
        else:
            estimated += 1; estimated_tokens += sum(values)
        if span.get('vendor') != 'codex-cli':
            issues.append('retained call is outside the current provider policy')
    expected = {'model_calls': calls, 'estimated_calls': estimated, 'reported_tokens': tokens,
                'estimated_tokens': estimated_tokens}
    for key, value in expected.items():
        if type(usage.get(key)) is not int or usage[key] != value:
            issues.append('usage aggregate does not match retained spans: ' + key)
    if not calls or estimated or usage.get('conflicts') != []:
        issues.append('usage has no calls, estimated calls or conflicts')
    return issues


def validate_reassessment(binding, original_attempt, original_result_sha256, source, task):
    issues = []
    if binding.get('original_attempt') != str(original_attempt):
        issues.append('reassessment refers to another attempt')
    if binding.get('original_result_sha256') != original_result_sha256:
        issues.append('reassessment is not bound to the original retained result')
    if binding.get('original_failed_result_preserved') is not True:
        issues.append('reassessment does not preserve the original failure')
    oracle = binding.get('verification', {})
    issues.extend(validate_oracle(oracle, source, task))
    return oracle, issues
