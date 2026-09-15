"""Evidence-join regressions; synthetic fixtures never acquire acceptance authority."""
from __future__ import annotations
import copy
import importlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from evidence import validate_oracle, validate_process, validate_usage, validate_reassessment
from process import save, sha

export = importlib.import_module('export')


def clean_process():
    return {'passed': True, 'exit_code': 0, 'timed_out': False, 'output_limit_exceeded': False,
            'process_group_empty': True, 'remaining_processes': [], 'errors': []}


def oracle():
    return {'task_id': 'repair', 'source': {'source.py': 'digest'}, 'passed': True,
            'checks': [{'name': 'one', 'passed': True}], 'checks_passed': 1, 'checks_total': 1,
            'copied_source_unchanged': True, 'execution': clean_process()}


def usage():
    return {'spans': [{'id': 'span-1', 'kind': 'llmCall', 'vendor': 'codex-cli',
            'promptTokens': 11, 'completionTokens': 3, 'attributes': {'usage.reported': 'true'}}],
            'model_calls': 1, 'estimated_calls': 0, 'reported_tokens': 14,
            'estimated_tokens': 0, 'conflicts': []}


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.task = {'id': 'repair', 'build': [], 'private_case_names': ['one']}

    def test_oracle_requires_exact_source_and_complete_frozen_cases(self):
        self.assertEqual(validate_oracle(oracle(), {'source.py': 'digest'}, self.task), [])
        for mutate in [lambda o: o.update(source={'source.py': 'other'}),
                       lambda o: o['checks'][0].update(name='another'),
                       lambda o: o.update(checks=[]),
                       lambda o: o.update(checks_total=True),
                       lambda o: o.update(checks_passed=True),
                       lambda o: o['checks'][0].update(passed=1)]:
            value = oracle(); mutate(value)
            self.assertTrue(validate_oracle(value, {'source.py': 'digest'}, self.task))

    def test_process_exit_zero_cannot_hide_timeout_or_remaining_descendants(self):
        for mutation in [{'timed_out': True}, {'remaining_processes': [{'pid': 1}]},
                         {'process_group_empty': False}, {'errors': ['lost pipe']}, {'exit_code': False}]:
            value = clean_process(); value.update(mutation)
            self.assertTrue(validate_process(value))

    def test_module_boundary_is_required_even_when_functional_cases_pass(self):
        task = dict(self.task, module_boundary_required=True)
        self.assertTrue(validate_oracle(oracle(), {'source.py': 'digest'}, task))
        value = oracle(); value['module_boundary'] = clean_process()
        self.assertEqual(validate_oracle(value, {'source.py': 'digest'}, task), [])

    def test_usage_recomputed_and_no_estimates_silently_promoted(self):
        self.assertEqual(validate_usage(usage()), [])
        for mutate in [lambda u: u.update(reported_tokens=15),
                       lambda u: u['spans'].append(copy.deepcopy(u['spans'][0])),
                       lambda u: u['spans'][0].update(promptTokens=True),
                       lambda u: u['spans'][0]['attributes'].clear(),
                       lambda u: u['spans'][0].update(vendor='unadmitted-provider')]:
            value = usage(); mutate(value)
            self.assertTrue(validate_usage(value))

    def test_reassessment_must_join_original_attempt_and_result(self):
        value = {'original_attempt': '/proof/a', 'original_result_sha256': 'original',
                 'original_failed_result_preserved': True, 'verification': oracle()}
        self.assertEqual(validate_reassessment(value, '/proof/a', 'original', {'source.py': 'digest'}, self.task)[1], [])
        self.assertTrue(validate_reassessment(value, '/proof/b', 'original', {'source.py': 'digest'}, self.task)[1])
        self.assertTrue(validate_reassessment(value, '/proof/a', 'changed', {'source.py': 'digest'}, self.task)[1])

    def test_no_follow_rejects_leaf_ancestor_and_parent_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root / 'real').mkdir(); (root / 'real/file').write_text('evidence')
            (root / 'leaf').symlink_to('real/file'); (root / 'alias').symlink_to('real', target_is_directory=True)
            self.assertEqual(export.read_file(root, 'real/file'), b'evidence')
            for name in ['leaf', 'alias/file', '../file', '/real/file']:
                with self.assertRaises((OSError, ValueError)): export.read_file(root, name)

    def test_cross_split_source_overlap_excludes_training_even_with_new_prompt(self):
        previous = [{'split': 'evaluation', 'source_fingerprint': 'same', 'task_fingerprint': 'old'}]
        rows = [{'split': 'training', 'source_fingerprint': 'same', 'task_fingerprint': 'new',
                 'training_eligible': True, 'issues': []}]
        export.mark_contamination(rows, previous)
        self.assertFalse(rows[0]['training_eligible'])
        self.assertEqual(rows[0]['evaluation_contamination'], ['source_fingerprint'])
        self.assertFalse(rows[0]['semantic_overlap_assessed'])

    def test_source_chain_rejects_changed_postimage_and_wrong_preimage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); corpus = root/'corpus'; attempt = root/'attempt'
            source = corpus/'repair/project/source.py'; source.parent.mkdir(parents=True); source.write_text('before\n')
            submitted = attempt/'submitted/source.py'; submitted.parent.mkdir(parents=True); submitted.write_text('after\n')
            task = {'id': 'repair', 'writable': ['source.py'], 'template': {'source.py': sha(source)}}
            receipt = {'accepted': True, 'report': {'mutations': [{'operations': [
                {'path': 'source.py', 'preimageSHA256': sha(source), 'postimageSHA256': sha(submitted)}]}]}}
            self.assertEqual(export.source_binding(task, corpus, attempt, [receipt])[1], [])
            submitted.write_text('tampered\n')
            self.assertTrue(export.source_binding(task, corpus, attempt, [receipt])[1])
            receipt['report']['mutations'][0]['operations'][0]['preimageSHA256'] = 'wrong'
            self.assertTrue(export.source_binding(task, corpus, attempt, [receipt])[1])

    def test_partial_failed_attempt_remains_exported_with_available_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            attempt = Path(directory)
            original = {'passed': False, 'reported_tokens': 17, 'failure': 'worker interrupted'}
            save(attempt / 'result.json', original)
            row = export.failed_export(attempt, self.task, 'training', FileNotFoundError('missing oracle'))
            self.assertFalse(row['training_eligible'])
            self.assertEqual(row['retained_artifacts']['result.json']['retained_result'], original)
            self.assertEqual(row['retained_artifacts']['result.json']['reference']['sha256'], sha(attempt / 'result.json'))
            self.assertIn('read_error', row['retained_artifacts']['oracle/verification.json'])

    def test_build_manifest_cannot_have_ambiguous_binary_or_source_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'build.manifest'
            good = 'binary-sha256: ' + 'a' * 64 + '\nsource-state-sha256: ' + 'b' * 64 + '\n'
            path.write_text(good)
            self.assertEqual(len(export.load_builds([path])), 1)
            with self.assertRaises(ValueError): export.load_builds([path, path])
            path.write_text(good + 'binary-sha256: ' + 'c' * 64 + '\n')
            with self.assertRaises(ValueError): export.load_builds([path])
            path.write_text('binary-sha256: ' + 'a' * 64 + '\n')
            with self.assertRaises(ValueError): export.load_builds([path])

    def test_later_failure_withdraws_label_and_preserves_earlier_outcome(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); diagnostic = root / 'diagnostic.json'
            save(diagnostic, {'passed': False, 'source': {'source.py': 'source-digest'},
                              'checks': [{'name': 'numeric-edge', 'passed': False}]})
            observations = root / 'observations.json'
            save(observations, {'schema': 'kist.training-adverse-observation.v1', 'records': [{
                'example_id': 'example', 'source_sha256': 'source-digest',
                'diagnostic': {'path': str(diagnostic), 'sha256': sha(diagnostic)}}]})
            row = {'id': 'example', 'outcome': 'verified_pass', 'training_eligible': True,
                   'patches': [{'after_sha256': 'source-digest'}], 'issues': []}
            refs = export.apply_adverse_observations([row], [observations])
            self.assertEqual(row['outcome'], 'not_verified')
            self.assertEqual(row['prior_verification_outcome'], 'verified_pass')
            self.assertFalse(row['training_eligible'])
            self.assertEqual(row['later_adverse_verification'][0]['sha256'], sha(diagnostic))
            self.assertEqual(refs[0]['sha256'], sha(observations))

    def test_adverse_claim_must_match_artifact_and_cannot_create_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); diagnostic = root / 'diagnostic.json'
            observations = root / 'observations.json'
            for source, passed, digest_override in [('wrong-source', False, None),
                                                     ('source-digest', True, None),
                                                     ('source-digest', False, 'changed')]:
                save(diagnostic, {'passed': passed, 'source': {'source.py': source},
                                  'checks': [{'name': 'edge', 'passed': passed}]})
                save(observations, {'schema': 'kist.training-adverse-observation.v1', 'records': [{
                    'example_id': 'example', 'source_sha256': 'source-digest',
                    'diagnostic': {'path': str(diagnostic), 'sha256': digest_override or sha(diagnostic)}}]})
                row = {'id': 'example', 'outcome': 'not_verified', 'training_eligible': False,
                       'patches': [{'after_sha256': 'source-digest'}], 'issues': []}
                with self.assertRaises(ValueError):
                    export.apply_adverse_observations([row], [observations])
                self.assertEqual(row['outcome'], 'not_verified')
                self.assertFalse(row['training_eligible'])


if __name__ == '__main__':
    unittest.main()
