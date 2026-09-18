"""Version an existing corpus with post-review numeric contract checks."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

from export import read_file
from process import save, sha

DRIVER = '''import json, sys
from support import timing_summary
out = []
for row in json.load(sys.stdin):
    try:
        values = (x for x in row["values"]) if row.get("generator") else row["values"]
        value = timing_summary(values)
        json.dumps(value, allow_nan=False)
        out.append({"value": value})
    except (TypeError, ValueError, OverflowError) as error:
        out.append({"error": type(error).__name__})
json.dump(out, sys.stdout, allow_nan=False, sort_keys=True)
'''


def extend(parent, output):
    parent, output = parent.resolve(), output.resolve()
    if output == parent or parent in output.parents:
        raise ValueError('a frozen corpus cannot be extended in place')
    manifest = json.loads(read_file(parent, 'manifest.json'))
    parent_digest = sha(parent / 'manifest.json')
    output.mkdir(parents=True, exist_ok=False)
    found = False
    for task in manifest['tasks']:
        project = output / task['id'] / 'project'
        # read_file validates every relative component before the destination is written.
        cases_data = read_file(parent, task['id'] + '/private-cases.json')
        import hashlib
        if hashlib.sha256(cases_data).hexdigest() != task['private_cases_sha256']:
            raise ValueError('parent cases changed')
        for name, digest in task['template'].items():
            data = read_file(parent, task['id'] + '/project/' + name)
            if hashlib.sha256(data).hexdigest() != digest:
                raise ValueError('parent project input changed: ' + name)
            target = project / name
            target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(data)
        cases = json.loads(cases_data)
        if task['id'] == 'python-timing':
            found = True
            existing = {case['name'] for case in cases}
            for label, value in [('integer', 10**400), ('float', 1e308)]:
                for generator in (False, True):
                    name = f'finite-large-{label}-generator-{generator}'
                    if name in existing:
                        raise ValueError('numeric extension is already present')
                    expected = {key: value for key in ('p50_seconds', 'p90_seconds', 'p95_seconds',
                                                       'p99_seconds', 'max_seconds', 'mean_seconds')}
                    expected['count'] = 2
                    cases.append({'name': name, 'input': {'values': [value, value], 'generator': generator},
                                  'rule': {'expected': {'value': expected}}})
            (project / 'driver.py').write_text(DRIVER)
            spec = project / 'TASK.md'
            spec.write_text(spec.read_text() + '\nNumeric range: finite integers are valid without conversion merely for validation. '
                'Compute the mean without intermediate overflow when its result is representable; '
                'retain an exact integral mean for integer inputs when possible.\n')
            task['template'] = {name: sha(project / name) for name in task['template']}
        save(output / task['id'] / 'private-cases.json', cases)
        task['private_cases_sha256'] = sha(output / task['id'] / 'private-cases.json')
        task['private_case_count'] = len(cases)
    if not found:
        raise ValueError('parent corpus has no Python timing task')
    manifest.update(parent_corpus_sha256=parent_digest, frozen_at=time.time(), split='evaluation',
        exposure='Post-review numeric extension; parent outcomes remain intact. Not unseen DGM evaluation. Do not train on this evaluation split.')
    save(output / 'manifest.json', manifest)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--parent', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    result = extend(args.parent, args.output)
    print(json.dumps({'tasks': len(result['tasks']), 'manifest_sha256': sha(args.output / 'manifest.json')}))
