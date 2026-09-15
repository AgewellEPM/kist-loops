"""Resource preflight rejects the historical missing-bundle failure before inference."""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from coding import run_task
from release import capture_release, check_release, REQUIRED_SKILLS


class ReleasePreflightTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='kist-release-preflight-')).resolve()
        self.binary = self.root / 'kist'
        self.binary.write_text('#!/bin/sh\nexit 91\n'); self.binary.chmod(0o700)

    def tearDown(self):
        shutil.rmtree(self.root)

    def resources(self):
        for name in REQUIRED_SKILLS:
            path = self.root / 'AgentCore_AgentCore.bundle' / name
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text('skill procedure\n')

    def test_missing_bundle_retains_failure_without_executing_model(self):
        corpus = self.root / 'corpus'; corpus.mkdir()
        (corpus / 'manifest.json').write_text('{}')
        with patch('coding.execute') as execute:
            with self.assertRaisesRegex(RuntimeError, 'before inference'):
                run_task({'id': 'repair'}, corpus, self.root / 'output', self.binary, repetitions=1)
            execute.assert_not_called()
        report = json.loads((self.root / 'output/repair/release-preflight.json').read_text())
        self.assertFalse(report['passed']); self.assertEqual(report['new_model_calls'], 0)

    def test_changed_or_missing_skill_invalidates_pinned_release(self):
        self.resources(); expected = capture_release(self.binary)
        self.assertTrue(check_release(self.binary, self.root / 'before.json', expected)['passed'])
        skill = self.root / 'AgentCore_AgentCore.bundle' / REQUIRED_SKILLS[0]
        skill.write_text('different procedure\n')
        self.assertFalse(check_release(self.binary, self.root / 'changed.json', expected)['passed'])
        skill.unlink()
        self.assertFalse(check_release(self.binary, self.root / 'missing.json', expected)['passed'])

    def test_resource_alias_and_nonregular_file_are_rejected(self):
        self.resources()
        skill = self.root / 'AgentCore_AgentCore.bundle' / REQUIRED_SKILLS[0]
        outside = self.root / 'outside'; skill.rename(outside); skill.symlink_to(outside)
        self.assertFalse(check_release(self.binary, self.root / 'symlink.json')['passed'])
        skill.unlink(); os.mkfifo(skill)
        self.assertFalse(check_release(self.binary, self.root / 'fifo.json')['passed'])

    def test_resolved_executable_alias_uses_its_actual_adjacent_bundle(self):
        self.resources(); alias = self.root / 'other/kist'; alias.parent.mkdir()
        alias.symlink_to(self.binary)
        self.assertEqual(capture_release(alias), capture_release(self.binary))


if __name__ == '__main__':
    unittest.main()
