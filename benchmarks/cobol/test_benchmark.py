import json
from pathlib import Path
import shutil
import tempfile
import unittest
from calibrate import calibrate
from oracle import numeric_expected, numeric_samples, check_output
from support import percentile
from run import summarize, decode_builder_reply


class BenchmarkTests(unittest.TestCase):
    def test_numeric_oracles_handle_sign_and_truncation(self):
        self.assertEqual(numeric_expected('average', [-1, -2]), -1)
        self.assertEqual(numeric_expected('average', [1, 2]), 1)
        self.assertEqual(numeric_expected('reduce-max', [-9, -4, -7]), -4)
        self.assertEqual(numeric_expected('range', [-99999, 99999]), 199998)
        self.assertEqual(numeric_expected('sum-positive', [-2, 3, 8]), 11)
        self.assertEqual(numeric_expected('count-over', [99, 100, 101]), 1)

    def test_samples_fit_every_declared_size_and_numeric_domain(self):
        for n in (1, 2, 7, 31, 100, 999):
            cases = numeric_samples(n, 9082026, 4)
            self.assertEqual(len(cases), 15)
            self.assertTrue(all(len(values) == n for _, values in cases))
            self.assertTrue(all(-99999 <= v <= 99999 for _, values in cases for v in values))
            self.assertTrue(all(v < 0 for v in dict(cases)['all-negative']))
            if n > 1:
                self.assertGreater(len(set(dict(cases)['random-0'])), 1)
            self.assertEqual(cases, numeric_samples(n, 9082026, 4))

    def test_output_requires_whole_value_and_process_success(self):
        for text in ['42 trailing', '42\n42', 'pretend 42', '']:
            self.assertFalse(check_output({'success': True, 'stdout': text}, 42, 'numeric')[0])
        self.assertFalse(check_output({'success': False, 'stdout': '42'}, 42, 'numeric')[0])
        self.assertTrue(check_output({'success': True, 'stdout': '+00042\n'}, 42, 'numeric')[0])

    def test_percentile_is_nearest_rank_and_empty_is_not_zero(self):
        self.assertIsNone(percentile([], .95))
        self.assertEqual(percentile([3, 1, 2], .50), 2)
        self.assertEqual(percentile([3, 1, 2], .95), 3)

    def test_incomplete_or_changed_source_cannot_pass(self):
        report = {'results': [], 'expected_runs': 1}
        self.assertFalse(summarize(report)['passed'])
        row = {'id': 'fixture', 'passed': True, 'classification': 'safe_refusal',
               'category': 'refusal', 'lifecycle': {}}
        report.update(results=[row], source_closure_unchanged=False)
        self.assertFalse(summarize(report)['passed'])

    def test_mcp_protocol_error_is_not_a_refusal(self):
        with self.assertRaises(RuntimeError):
            decode_builder_reply({'payload': {'error': {'code': -32000, 'message': 'compiler missing'}}})
        value, error = decode_builder_reply({'payload': {'result': {'content': [
            {'type': 'text', 'text': '{"verified":false,"refused":true}'}], 'isError': True}}})
        self.assertTrue(value['refused'])
        self.assertTrue(error)

    def test_corpus_is_unique_and_covers_all_shapes_and_policies(self):
        suite = json.loads(Path(__file__).with_name('suite.v1.json').read_text())
        self.assertEqual(suite['case_count'], len(suite['cases']))
        self.assertEqual(len({c['id'] for c in suite['cases']}), len(suite['cases']))
        nominal = [c for c in suite['cases'] if c['category'] == 'construction']
        self.assertEqual(len({c['operation'] for c in nominal}), 13)
        self.assertEqual({c['shape'] for c in nominal}, {'numeric', 'string', 'indexed'})
        self.assertEqual({c['mode'] for c in suite['cases']},
                         {'build', 'refuse', 'build_or_refuse', 'reject_before_mcp'})

    def test_real_compiler_and_process_calibration(self):
        compiler = shutil.which('cobc')
        self.assertIsNotNone(compiler, 'benchmark qualification requires the installed real compiler')
        with tempfile.TemporaryDirectory(prefix='kist-cobol-oracle-') as temporary:
            result = calibrate(Path(temporary) / 'calibration', compiler)
            self.assertTrue(result['passed'], result)
            self.assertEqual(len(result['checks']), 8)


if __name__ == '__main__':
    unittest.main()
