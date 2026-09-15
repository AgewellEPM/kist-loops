#!/usr/bin/env python3
"""Exercise review CLI exit statuses using local fake reviewers and no provider calls."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', default=str(Path(__file__).resolve().parents[2] / '.build/debug/designflow'))
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve())
    with tempfile.TemporaryDirectory(prefix='designflow-review-smoke-') as temporary:
        root = Path(temporary)
        diff = root / 'change.diff'
        diff.write_text('diff --git a/example b/example\n+fixed\n')
        fake = root / 'codex'
        fake.write_text('#!/bin/sh\nprintf "%s\\n" "$REVIEW_FIXTURE_VERDICT"\n')
        fake.chmod(0o700)
        environment = dict(os.environ, PATH=str(root) + os.pathsep + os.defpath)
        environment.pop('DEEPSEEK_API_KEY', None)
        environment.pop('KIST_ACTIVE', None)

        def run(reviewers, verdict='', path=diff):
            environment['REVIEW_FIXTURE_VERDICT'] = verdict
            result = subprocess.run(
                [binary, 'tagteam', 'review', '--diff', str(path), '--reviewers', reviewers],
                cwd=root, env=environment, text=True, capture_output=True, timeout=10)
            return result.returncode, result.stdout + result.stderr

        for verdict, expected in [('SHIP', 0), ('NO-SHIP', 3), ('Do not ship', 2),
                                  ('Ownership needs work', 2), ('', 2)]:
            code, output = run('codex', verdict)
            assert code == expected, (verdict, code, output)
        code, output = run('deepseek')
        assert code == 2 and 'DEEPSEEK_API_KEY' in output, (code, output)
        code, output = run('codex,unknown', 'SHIP')
        assert code == 2 and 'recognized' in output, (code, output)
        code, output = run('codex', 'SHIP', root / 'missing.diff')
        assert code == 2 and 'could not read' in output, (code, output)
    print('PASS: only explicit completed reviews ship; errors, unknown reviewers, and missing diffs fail')


if __name__ == '__main__':
    main()
