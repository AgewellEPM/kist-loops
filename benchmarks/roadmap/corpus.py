"""Freeze repository-derived coding tasks before any candidate inference."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import sys
import time

from process import save, sha


SWIFT_DRIVER = '''import Foundation
let input = FileHandle.standardInput.readDataToEndOfFile()
let rows = try JSONSerialization.jsonObject(with: input) as! [[String: Any]]
let output: [[String: Any]] = rows.map { row in
    if row["action"] as? String == "terms" {
        return ["value": LexicalSearch.terms(row["text"] as! String)]
    }
    if row["action"] as? String == "rank" {
        let docs = (row["documents"] as! [[String: String]]).map {
            LexicalSearch.Document(id: $0["id"]!, title: $0["title"]!, text: $0["text"]!)
        }
        return ["value": LexicalSearch.rank(docs, query: row["query"] as! String,
                                            limit: row["limit"] as! Int).map { $0.id }]
    }
    let value = LexicalSearch.excerpt(row["text"] as! String, query: row["query"] as! String,
                                      maxCharacters: row["limit"] as! Int)
    return ["value": value, "characters": value.count]
}
let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
'''

PYTHON_DRIVER = '''import json, sys
from support import timing_summary
rows=json.load(sys.stdin)
out=[]
for row in rows:
    try:
        values=(x for x in row["values"]) if row.get("generator") else row["values"]
        out.append({"value":timing_summary(values)})
    except (TypeError, ValueError) as error:
        out.append({"error":type(error).__name__})
json.dump(out,sys.stdout,allow_nan=False,sort_keys=True)
'''

TS_DRIVER = '''const fs = require('node:fs');
const tags = require('./.build/tags.js');
const rows = JSON.parse(fs.readFileSync(0, 'utf8'));
process.stdout.write(JSON.stringify(rows.map(row => ({value: row.list
  ? tags.normalizeTagList(row.input) : tags.normalizeTag(row.input)}))));
'''

CHECK = '''import json, subprocess
from pathlib import Path
cases=json.loads(Path("public-cases.json").read_text())
argv=json.loads(Path("run-argv.json").read_text())
p=subprocess.run(argv,input=json.dumps([c["input"] for c in cases]),text=True,capture_output=True,timeout=15)
assert p.returncode==0,(p.returncode,p.stderr)
results=json.loads(p.stdout)
assert len(results)==len(cases)
for case, actual in zip(cases,results):
    rule=case["rule"]
    if "expected" in rule: assert actual==rule["expected"],(case["name"],actual,rule)
    if "max_characters" in rule: assert actual["characters"]<=rule["max_characters"],(case["name"],actual)
    if "contains" in rule: assert rule["contains"] in actual["value"],(case["name"],actual)
print("PUBLIC CHECKS PASSED",len(cases))
'''


def swift_cases():
    rows = []
    texts = ['short', '', '   \n\t', 'intro\nneedle is here\ntrailer',
             'unrelated text ' * 20 + 'needle more context ' * 4,
             '🙂 café ' * 20 + 'needle ' + '👩🏽‍💻' * 12]
    for index, text in enumerate(texts):
        for limit in [-10, 0, 1, 2, 3, 8, 16, 39, 40, 80, 320]:
            rule = {'max_characters': max(0, limit)}
            if limit <= 0:
                rule['expected'] = {'value': '', 'characters': 0}
            elif text == 'short' and limit >= 5:
                rule['expected'] = {'value': 'short', 'characters': 5}
            elif 'needle' in text and limit >= 80:
                rule['contains'] = 'needle'
            rows.append({'name': f'excerpt-{index}-{limit}',
                         'input': {'text': text, 'query': 'needle', 'limit': limit}, 'rule': rule})
    rows.append({'name': 'terms-unchanged',
                 'input': {'action': 'terms', 'text': 'HTTPRetryQueue café C++ C# shared_memory'},
                 'rule': {'expected': {'value': ['http', 'retry', 'queue', 'cafe', 'cplusplus', 'csharp', 'shared', 'memory']}}})
    documents = [{'id': 'target', 'title': 'SharedMemory.swift',
                  'text': 'func spawnAgentsWithSharedMemory() {} struct HTTPRetryQueue {}'},
                 {'id': 'noise', 'title': 'alpha.swift', 'text': 'let alphaMarker = true'}]
    for query, expected in [('shared-memory', ['target']), ('shared_memory', ['target']),
                            ('HTTPRetryQueue', ['target']), ('betaMarker', []), ('the and how', [])]:
        rows.append({'name': 'rank-' + query, 'input': {'action': 'rank', 'documents': documents,
                    'query': query, 'limit': 5}, 'rule': {'expected': {'value': expected}}})
    return rows


def timing_expected(values):
    import math
    if any(isinstance(x, bool) or not isinstance(x, (int, float)) or not math.isfinite(x) or x < 0
           for x in values):
        return {'error': 'ValueError'}
    ordered = sorted(values)
    def percentile(fraction):
        return ordered[max(0, math.ceil(len(ordered) * fraction) - 1)] if ordered else None
    return {'value': {'count': len(values), 'p50_seconds': percentile(.50),
                     'p90_seconds': percentile(.90), 'p95_seconds': percentile(.95),
                     'p99_seconds': percentile(.99), 'max_seconds': max(values) if values else None,
                     'mean_seconds': math.fsum(values) / len(values) if values else None}}


def python_cases():
    rows = []
    samples = [[], [0], [3, 1, 2], [0.1, 0.5, 3.5, 1], [2] * 20, list(range(101)),
               [-1, 2], [True, 3], ['4'], [None], [1e-9, 1e3, .25]]
    for index, values in enumerate(samples):
        for generator in [False, True]:
            rows.append({'name': f'timing-{index}-generator-{generator}',
                         'input': {'values': values, 'generator': generator},
                         'rule': {'expected': timing_expected(values)}})
    return rows


def normalize_tag(value):
    import re
    if not isinstance(value, str):
        return None
    text = value.strip().removeprefix('#').lower()
    text = re.sub(r'\s+', '-', text)
    text = re.sub(r'[^a-z0-9-]', '', text)
    text = re.sub(r'-+', '-', text).strip('-')
    return text if 2 <= len(text) <= 30 and re.search('[a-z]', text) else None


def typescript_cases():
    samples = ['#Hello World', 'HELLO---world', '12', 'a', 'a' * 30, 'a' * 31,
               ' café ', 'a___b', '-hello-', '#  my\ttag ', '', None, 123, {}, 'x0',
               '🙂 hello', 'two\nwords']
    rows = [{'name': f'tag-{i}', 'input': {'input': value},
             'rule': {'expected': {'value': normalize_tag(value)}}} for i, value in enumerate(samples)]
    for index, values in enumerate([samples, ['#HELLO', 'hello', 'Hello', 'other'],
                                    [f'tag-{i}' for i in range(20)], [], 'hello']):
        output = []
        for value in values if isinstance(values, list) else []:
            normalized = normalize_tag(value)
            if normalized and normalized not in output:
                output.append(normalized)
            if len(output) == 10:
                break
        rows.append({'name': f'tags-{index}', 'input': {'input': values, 'list': True},
                     'rule': {'expected': {'value': output}}})
    return rows


def freeze(output, mission, kist_root, dashboard_root):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    tasks = [
        {'id': 'swift-excerpt', 'language': 'Swift', 'kind': 'bugfix',
         'origin': kist_root / 'Sources/AgentCore/LexicalSearch.swift', 'source': 'LexicalSearch.swift',
         'writable': ['LexicalSearch.swift'], 'driver': ('main.swift', SWIFT_DRIVER),
         'build': ['swiftc', 'LexicalSearch.swift', 'main.swift', '-o', '.build/program'],
         'run': ['./.build/program'], 'cases': swift_cases(),
         'request': 'Repair the existing LexicalSearch.excerpt implementation. maxCharacters is a strict maximum in Swift Characters, including ellipsis markers. Return an empty string for a non-positive maximum. Preserve complete short text when it fits. Keep matching passages useful when the budget permits, including Unicode. Preserve terms and rank behavior and their public APIs. The current code incorrectly imposes a minimum of 40 and can exceed a smaller caller budget.'},
        {'id': 'python-timing', 'language': 'Python', 'kind': 'feature',
         'origin': kist_root / 'benchmarks/cobol/support.py', 'source': 'support.py',
         'writable': ['support.py'], 'driver': ('driver.py', PYTHON_DRIVER),
         'build': [], 'run': [sys.executable, 'driver.py'], 'cases': python_cases(),
         'request': 'Extend the existing timing_summary with p90_seconds and mean_seconds. Preserve all existing output keys and nearest-rank percentile semantics. Consume any finite iterable exactly once, including generators. Empty input returns count 0 and None for every statistic. Reject a negative, non-finite, Boolean or non-numeric duration with ValueError before producing a result. Do not mutate the caller input. Keep all process, file and existing percentile helpers compatible; no changes to their contracts.'},
        {'id': 'typescript-tags', 'language': 'TypeScript', 'kind': 'refactor',
         'origin': dashboard_root / 'packages/board-codec/src/boards/tags.ts', 'source': 'tags.ts',
         'writable': ['tags.ts', 'tag-normalize.ts'], 'driver': ('driver.cjs', TS_DRIVER),
         'build': ['tsc', '--strict', '--target', 'ES2022', '--module', 'commonjs', '--outDir', '.build', 'tags.ts', 'tag-normalize.ts'],
         'run': ['/opt/homebrew/bin/node', 'driver.cjs'], 'cases': typescript_cases(),
         'request': 'Refactor the existing tag utility into two modules without changing observable behavior. Move the single-tag normalization algorithm, its private validation constants, and MAX_TAG_LEN into a new tag-normalize.ts exporting normalizeTag and MAX_TAG_LEN. tags.ts must import those exports, re-export them to preserve its API, and retain MAX_TAGS_PER_BOARD and normalizeTagList. Keep normalization, ordering, deduplication, limits and invalid-input behavior exactly unchanged. Avoid duplicate normalization implementations. No dependencies or compiler configuration changes.'},
    ]
    records = []
    for task in tasks:
        root = output / task['id']
        project = root / 'project'
        project.mkdir(parents=True)
        shutil.copy2(task['origin'], project / task['source'])
        driver_name, driver = task['driver']
        (project / driver_name).write_text(driver)
        (project / 'check.py').write_text(CHECK)
        save(project / 'run-argv.json', task['run'])
        public = [task['cases'][i] for i in sorted({0, 1, 2, len(task['cases']) // 2, len(task['cases']) - 1})]
        save(project / 'public-cases.json', public)
        save(root / 'private-cases.json', task['cases'])
        import shlex
        recipe = 'export TMPDIR := $(CURDIR)/.build/tmp\nexport CLANG_MODULE_CACHE_PATH := $(CURDIR)/.build/clang-cache\nexport SWIFT_MODULECACHE_PATH := $(CURDIR)/.build/swift-cache\n.PHONY: verify\nverify:\n\t/bin/mkdir -p .build/tmp\n'
        if task['build']:
            recipe += '\t' + shlex.join(task['build']) + '\n'
        (project / 'Makefile').write_text(recipe + '\t/usr/bin/python3 check.py\n')
        spec = task['request'] + '\n\nOnly these source files may change: ' + ', '.join(task['writable']) + '.\nUse the complete deterministic verifier make verify after the final edit. Preserve TASK.md, AGENTS.md, Makefile, drivers, cases and verifier. Use only the installed standard-library toolchain. No network, downloads, browser, UI, VM, external systems or access outside this project. Do not delegate in a single-worker trial. Report actual checks and failures.\n'
        (project / 'TASK.md').write_text(spec)
        (project / 'AGENTS.md').write_text('Disposable authorized coding trial. Follow TASK.md. Only the named implementation files may change. Protected tests/specifications are host-owned. Never invent successful checks or widen the tool/permission scope.\n')
        record = {key: task[key] for key in ('id', 'language', 'kind', 'source', 'writable', 'build', 'run')}
        record.update(origin=str(task['origin']), origin_sha256=sha(task['origin']),
                      private_cases_sha256=sha(root / 'private-cases.json'),
                      template={p.name: sha(p) for p in sorted(project.iterdir()) if p.is_file()},
                      public_case_count=len(public), private_case_count=len(task['cases']))
        records.append(record)
    manifest = {'schema': 'kist.roadmap-coding-corpus.v1', 'mission_id': mission,
                'frozen_at': time.time(), 'tasks': records,
                'authority': 'host-owned local functional evaluation; not an evolution activation receipt',
                'exposure': 'public cases are visible; private cases are excluded from candidate project; do not train on this evaluation split'}
    save(output / 'manifest.json', manifest)
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--mission', required=True)
    parser.add_argument('--kist-root', required=True, type=Path)
    parser.add_argument('--dashboard-root', required=True, type=Path)
    args = parser.parse_args()
    result = freeze(args.output, args.mission, args.kist_root, args.dashboard_root)
    print(json.dumps({'tasks': len(result['tasks']), 'manifest_sha256': sha(args.output / 'manifest.json')}))
