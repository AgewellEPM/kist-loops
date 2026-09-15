"""Evaluate copied submitted source with frozen host cases and installed compilers."""
from __future__ import annotations

import json
from pathlib import Path
import shutil
import tempfile

from process import execute, save, sha, trial_environment


def sandbox_argv(argv, project, environment):
    """Filesystem/network confinement for benign local evaluation, not DGM hard limits."""
    sandbox = Path('/usr/bin/sandbox-exec')
    if not sandbox.is_file():
        raise RuntimeError('Required macOS evaluation sandbox is unavailable')
    roots = ['/System', '/usr/lib', '/usr/share', '/usr/bin', '/usr/sbin', '/bin', '/sbin',
             '/Library/Apple', '/Library/Developer', '/private/var/db/dyld',
             '/private/var/db/timezone', '/opt/homebrew/Cellar', '/opt/homebrew/opt',
             '/opt/homebrew/bin', '/Applications/Xcode.app/Contents', str(project)]
    profile = '(version 1) (deny default) (import "system.sb")\n'
    profile += '(allow process-exec) (allow process-fork) (allow sysctl-read)\n'
    profile += '(deny process-info*) (allow process-info* (target self)) (deny network*)\n'
    profile += '(deny sysctl-read (sysctl-name "kern.procargs")) (deny sysctl-read (sysctl-name "kern.procargs2"))\n'
    profile += '(allow file-read-metadata)\n'
    profile += '(allow file-read* ' + ' '.join('(subpath ' + json.dumps(root) + ')' for root in roots) + ')\n'
    profile += '(allow file-read* (literal "/dev/random") (literal "/dev/urandom"))\n'
    profile += '(allow file-read* (literal "/opt/homebrew/etc/openssl@3/openssl.cnf"))\n'
    profile += '(allow file-read* file-write* (literal "/dev/null") (subpath ' + json.dumps(str(project)) + '))\n'
    # The preinstalled TypeScript compiler is a pinned read-only input, not another runtime download.
    for root in json.loads(environment.get('KIST_BUILDER_TOOLCHAIN_ROOTS', '[]')):
        profile += '(allow file-read* (subpath ' + json.dumps(root) + '))\n'
    return [str(sandbox), '-p', profile] + [str(x) for x in argv]


def verify(task, corpus, submission, output, config):
    corpus, submission, output = Path(corpus), Path(submission), Path(output)
    output.mkdir(parents=True, exist_ok=False)
    frozen = corpus / task['id']
    if sha(frozen / 'private-cases.json') != task['private_cases_sha256']:
        raise RuntimeError('Frozen external cases changed')
    root = Path(tempfile.mkdtemp(prefix='kist-roadmap-oracle-', dir='/var/tmp')).resolve()
    result = {'task_id': task['id'], 'project': str(root), 'source': {}, 'checks': [],
              'corpus_sha256': sha(corpus / 'manifest.json'),
              'private_cases_sha256': task['private_cases_sha256'],
              'verifier_sha256': sha(__file__), 'process_harness_sha256': sha(Path(__file__).with_name('process.py')),
              'authority': 'host-owned local final-source verification; not sealed evolution authority'}
    try:
        for name, digest in task['template'].items():
            source = frozen / 'project' / name
            if sha(source) != digest:
                raise RuntimeError('Frozen project input changed: ' + name)
            if name not in task['writable']:
                shutil.copy2(source, root / name)
        for name in task['writable']:
            source = submission / name
            if source.is_symlink() or not source.is_file():
                result.update(passed=False, failure='missing or unsafe submitted source: ' + name)
                save(output / 'verification.json', result)
                return result
            if source.stat().st_size > 1024 * 1024:
                raise RuntimeError('Submitted source exceeds bound')
            shutil.copy2(source, root / name)
            result['source'][name] = sha(root / name)
            retained = output / 'submitted' / name
            retained.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root / name, retained)
        (root / '.build/tmp').mkdir(parents=True)
        environment = trial_environment(config, root)
        environment['TMPDIR'] = str(root / '.build/tmp')
        if task['build']:
            compiled = execute(sandbox_argv(task['build'], root, environment), root, output / 'compile',
                               environment=environment, timeout=120)
            result['compile'] = compiled
            if not compiled['passed']:
                result.update(passed=False, failure='external compilation failed')
                save(output / 'verification.json', result)
                return result
        cases = json.loads((frozen / 'private-cases.json').read_text())
        execution = execute(sandbox_argv(task['run'], root, environment), root, output / 'cases',
            environment=environment, stdin=json.dumps([row['input'] for row in cases]), timeout=30)
        result['execution'] = execution
        try:
            actual = json.loads((output / 'cases/stdout.txt').read_text())
        except (json.JSONDecodeError, UnicodeError):
            actual = None
        if not isinstance(actual, list) or len(actual) != len(cases):
            result.update(passed=False, failure='external driver returned malformed/incomplete results')
        else:
            for expected, observed in zip(cases, actual):
                rule = expected['rule']
                passed = isinstance(observed, dict)
                if 'expected' in rule:
                    passed = passed and observed == rule['expected']
                if 'max_characters' in rule:
                    passed = passed and type(observed.get('characters')) is int and (
                        0 <= observed['characters'] <= rule['max_characters'])
                if 'contains' in rule:
                    passed = passed and isinstance(observed.get('value'), str) and rule['contains'] in observed['value']
                result['checks'].append({'name': expected['name'], 'passed': bool(passed),
                                         'expected': rule, 'actual': observed})
            result['passed'] = execution['passed'] and all(row['passed'] for row in result['checks'])
            if not execution['passed']:
                result['failure'] = 'external case execution failed'
            elif not result['passed']:
                result['failure'] = 'external case assertions failed'
        if (task['id'] == 'typescript-tags' or task.get('module_boundary_required')) and result['passed']:
            # Substitute only the imported module: both old public APIs must delegate to it.
            probe = "const p=require.resolve('./.build/tag-normalize.js');require.cache[p]={id:p,filename:p,loaded:true,exports:{normalizeTag:()=> 'host-sentinel',MAX_TAG_LEN:123}};const t=require('./.build/tags.js');if(t.normalizeTag('foo')!=='host-sentinel'||t.normalizeTagList(['foo','bar']).join(',')!=='host-sentinel'||t.MAX_TAG_LEN!==123)process.exit(1);console.log('MODULE DELEGATION PASSED')"
            check = execute(sandbox_argv(['/opt/homebrew/bin/node', '-e', probe], root, environment),
                            root, output / 'module-boundary', environment=environment, timeout=15)
            result['module_boundary'] = check
            result['passed'] = result['passed'] and check['passed']
            if not check['passed']:
                result['failure'] = 'module-boundary verification failed'
        result['copied_source_unchanged'] = all(sha(root / name) == digest for name, digest in result['source'].items())
        result['passed'] = result['passed'] and result['copied_source_unchanged']
        if not result['copied_source_unchanged'] and not result.get('failure'):
            result['failure'] = 'submitted source changed during verification'
        result['checks_passed'] = sum(row['passed'] for row in result['checks'])
        result['checks_total'] = len(result['checks'])
        save(output / 'verification.json', result)
        return result
    except Exception as error:
        result.update(passed=False, failure=type(error).__name__ + ': ' + str(error))
        save(output / 'verification.json', result)
        return result
    finally:
        # Original submitted bytes were retained before any untrusted code ran.
        shutil.rmtree(root)
