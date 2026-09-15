"""Freeze a repair starting at a real refactor's accepted intermediate file state.

This fixture models a stopped task between CLI invocations, not a killed process or
proof of checkpoint recovery. The separate operational recovery trials cover those.
"""
import argparse
import copy
import json
from pathlib import Path
import shutil
import time

from process import save, sha


def freeze(base, prior_attempt, output):
    manifest = json.loads((base / 'manifest.json').read_text())
    task = copy.deepcopy(next(row for row in manifest['tasks'] if row['id'] == 'typescript-tags'))
    output.mkdir(parents=True, exist_ok=False)
    task['id'] = 'typescript-interrupted-refactor'
    task['kind'] = 'interrupted-repair'
    task['writable'] = ['tags.ts']
    task['module_boundary_required'] = True
    root = output / task['id']
    shutil.copytree(base / 'typescript-tags', root)
    module = prior_attempt / 'submitted/tag-normalize.ts'
    shutil.copy2(module, root / 'project/tag-normalize.ts')
    task_file = root / 'project/TASK.md'
    task_file.write_text('Complete the stopped refactor. A previous CLI invocation created tag-normalize.ts, '
        'but tags.ts still contains its old implementation. Inspect the existing files, then edit only tags.ts '
        'to import and re-export normalizeTag and MAX_TAG_LEN from tag-normalize.ts. Remove the duplicate '
        'single-tag algorithm and private validation constants. Preserve normalizeTagList, MAX_TAGS_PER_BOARD '
        'and all public behavior. Do not edit the already-created module. This is a repair fixture restored '
        'at an invocation boundary, not permission to rerun or replace the earlier step.\n\n'
        'Only tags.ts may change. Preserve TASK.md, AGENTS.md, tag-normalize.ts, Makefile, drivers and cases. '
        'The complete deterministic verifier is make verify; run it after the final edit. No dependencies, '
        'downloads, network, browser, UI, VM or external systems. Do not delegate. Report actual checks.\n')
    task['template'] = {p.name: sha(p) for p in sorted((root / 'project').iterdir()) if p.is_file()}
    task['intermediate_state'] = {'module_sha256': sha(module),
        'prior_attempt': str(prior_attempt), 'prior_first_invocation_sha256': sha(prior_attempt / 'kist-1/stdout.txt'),
        'boundary': 'previous invocation created module; original tags.ts remains',
        'process_crash_recovery_proven': False}
    manifest.update(frozen_at=time.time(), tasks=[task], parent_corpus_sha256=sha(base / 'manifest.json'))
    save(output / 'manifest.json', manifest)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--prior-attempt', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    freeze(args.base, args.prior_attempt, args.output)
    print(sha(args.output / 'manifest.json'))
