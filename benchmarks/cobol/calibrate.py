"""Calibration: an evaluator must reject known-wrong code and accept a known-correct control."""
import sys
from oracle import verify_source, check_output
from support import run_process, write_json


def table_program(body):
    return '''identification division.
program-id. TABLEOP.
data division.
working-storage section.
01 idx binary-long.
linkage section.
01 shared-input.
   05 table-value occurs 7 times pic s9(5).
   05 table-result pic s9(9).
procedure division using shared-input.
''' + body + '\n   goback.\n'


def calibrate(root, compiler, seed=9082026):
    root.mkdir()
    maximum = '''   move table-value(1) to table-result
   perform varying idx from 2 by 1 until idx > 7
       if table-value(idx) > table-result
           move table-value(idx) to table-result
       end-if
   end-perform'''
    fixtures = [
        ('correct-maximum', 'reduce-max', table_program(maximum), True),
        ('zero-seeded-maximum', 'reduce-max', table_program(maximum.replace(
            'move table-value(1) to table-result', 'move 0 to table-result')), False),
        ('constant-range', 'range', table_program('   move 0 to table-result'), False),
        ('sum-plus-one', 'reduce-sum', table_program('''   move 1 to table-result
   perform varying idx from 1 by 1 until idx > 7
       add table-value(idx) to table-result
   end-perform'''), False),
        ('invalid-cobol', 'reduce-sum', 'this is not COBOL', False),
    ]
    checks = []
    for name, operation, source, should_pass in fixtures:
        evidence = verify_source(source, {'operation': operation, 'shape': 'numeric', 'size': 7},
                                 root / name, compiler, seed, 1)
        checks.append({'name': name, 'passed': evidence['passed'] == should_pass,
                       'expected_acceptance': should_pass, 'observed_acceptance': evidence['passed']})
    for name, code, timeout, cap, expected_flag in [
        ('nonzero-with-correct-text', 'print(42); raise SystemExit(7)', 5, 4096, 'nonzero'),
        ('deadline', 'import time; time.sleep(30)', 0.1, 4096, 'timed_out'),
        ('output-cap', 'print("x" * 10000)', 5, 128, 'truncated'),
    ]:
        process = run_process([sys.executable, '-c', code], root, root / name,
                              timeout=timeout, cap=cap)
        rejected = not check_output(process, 42, 'numeric')[0]
        expected = process['exit_code'] == 7 if expected_flag == 'nonzero' else process[expected_flag]
        checks.append({'name': name, 'passed': rejected and expected,
                       'exit_code': process['exit_code'], 'timed_out': process['timed_out'],
                       'truncated': process['truncated']})
    result = {'passed': all(c['passed'] for c in checks), 'checks': checks}
    write_json(root / 'calibration.json', result)
    return result
