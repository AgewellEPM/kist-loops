"""Host-owned numeric/string/indexed-file checks; never imports the COBOL builder's oracle."""
import random
import re
from pathlib import Path
from support import run_process, sha256, write_json


def numeric_expected(operation, values):
    if operation == 'reduce-min': return min(values)
    if operation == 'reduce-max': return max(values)
    if operation == 'reduce-sum': return sum(values)
    if operation == 'range': return max(values) - min(values)
    if operation == 'average':
        total = sum(values)
        return (abs(total) // len(values)) * (-1 if total < 0 else 1)
    if operation == 'sum-abs': return sum(abs(x) for x in values)
    if operation == 'count-neg': return sum(x < 0 for x in values)
    if operation == 'count-pos': return sum(x > 0 for x in values)
    if operation == 'count-zero': return sum(x == 0 for x in values)
    if operation == 'count-over': return sum(x > 100 for x in values)
    if operation == 'sum-positive': return sum(x for x in values if x > 0)
    if operation == 'count-over-50': return sum(x > 50 for x in values)
    raise ValueError('unknown host oracle: ' + operation)


def numeric_samples(n, seed, random_cases):
    def cycle(values):
        return [values[i % len(values)] for i in range(n)]
    samples = [('zero', [0] * n), ('all-negative', cycle([-9, -4, -7])),
               ('all-positive', cycle([9, 4, 7])), ('mixed-sign', cycle([-17, 0, 19, -1, 7])),
               ('maximum-positive', [99999] * n), ('minimum-negative', [-99999] * n),
               ('mixed-boundaries', cycle([99999, -99999, 0])),
               ('threshold-boundaries', cycle([99, 100, 101, 0, -100, 50, 51])),
               ('fractional-positive-average', cycle([1, 2, 2])),
               ('fractional-negative-average', cycle([-1, -2, -2]))]
    rng = random.Random(seed + n)
    samples.extend((f'random-{i}', [rng.randint(-99999, 99999) for _ in range(n)])
                   for i in range(random_cases))
    # Permutations should preserve reductions; keep both inputs in the recorded evidence.
    values = samples[-1][1]
    samples.append(('reversed-last', list(reversed(values))))
    return samples


def string_samples(n):
    return [(name, value[:n]) for name, value in [
        ('empty', ''), ('uppercase-vowels', 'AEIOU' * (n // 5 + 1)),
        ('lowercase-vowels', 'aeiou' * (n // 5 + 1)),
        ('mixed-case', 'AeIoU aEiOu COBOL cobol'), ('digits', '0123456789' * (n // 10 + 1)),
        ('consonants', 'bcdfghjklmnpqrstvwxyz'), ('mixed-text', 'COBOL 2026 rules OK 42'),
        ('spaces', ' ' * n), ('boundary-last-character', 'x' * (n - 1) + 'a')]]


def caller(n, shape):
    if shape == 'numeric':
        fields = f'05 table-value occurs {n} times pic s9(5).\n   05 table-result pic s9(9).'
        body = f'''perform varying idx from 1 by 1 until idx > {n}
       accept input-line
       compute table-value(idx) = function numval(input-line)
   end-perform
   move 0 to table-result
   call "TABLEOP" using shared-input
   display table-result'''
    elif shape == 'string':
        fields = f'05 text-value pic x({n}).\n   05 text-result pic 9(4).'
        body = '''accept input-line
   move input-line to text-value
   move 0 to text-result
   call "STROP" using shared-input
   display text-result'''
    else:
        raise ValueError('no caller for shape ' + shape)
    return f'''identification division.
program-id. HOSTCHECK.
data division.
working-storage section.
01 shared-input.
   {fields}
01 idx binary-long.
01 input-line pic x(4096).
procedure division.
   {body}
   stop run.
'''


def check_output(process, expected, shape):
    if not process['success']:
        return False, None
    output = process['stdout'].strip()
    if shape == 'indexed':
        actual = output.splitlines()
    elif re.fullmatch(r'[+-]?\d+', output):
        actual = int(output)
    else:
        return False, output
    return actual == expected, actual


def verify_source(source, case, root, compiler, seed, random_cases):
    root = Path(root)
    root.mkdir()
    source_file = root / 'routine.cob'
    source_file.write_text(source + '\n')
    shape, n = case['shape'], case['size']
    program = root / 'program'
    argv = [compiler, '-x', '-free', '-o', program]
    if shape != 'indexed':
        driver = root / 'host-check.cob'
        driver.write_text(caller(n, shape))
        argv.append(driver)
    argv.append(source_file)
    compile_result = run_process(argv, root, root / 'compile', timeout=30)
    result = {'source_sha256': sha256(source_file), 'compiled': compile_result['success'],
              'compile_seconds': compile_result['elapsed_seconds'], 'checks': []}
    if not compile_result['success']:
        result['passed'] = False
        result['failure_class'] = 'independent_compile_failed'
        write_json(root / 'verification.json', result)
        return result
    result['program_sha256'] = sha256(program)
    if shape == 'numeric':
        samples = numeric_samples(n, seed, random_cases)
    elif shape == 'string':
        samples = string_samples(n)
    else:
        samples = [('sorted-records', None), ('repeat-in-fresh-directory', None)]
    for index, (name, values) in enumerate(samples):
        cwd = root / f'case-{index:02d}'
        cwd.mkdir()
        if shape == 'numeric':
            expected = numeric_expected(case['operation'], values)
            stdin = '\n'.join(map(str, values)) + '\n'
        elif shape == 'string':
            expected = (sum(c.upper() in 'AEIOU' for c in values) if case['operation'] == 'vowel-count'
                        else sum(c in '0123456789' for c in values))
            stdin = values + '\n'
        else:
            expected, stdin = [f'{i:03d}' for i in range(1, n + 1)], ''
        observed = run_process([program], cwd, cwd / 'run', stdin, timeout=5)
        passed, actual = check_output(observed, expected, shape)
        result['checks'].append({'name': name, 'input': values, 'expected': expected,
            'actual': actual, 'passed': passed, 'elapsed_seconds': observed['elapsed_seconds'],
            'exit_code': observed['exit_code'], 'timed_out': observed['timed_out'],
            'truncated': observed['truncated'], 'stdout_sha256': observed['stdout_sha256']})
    result['passed'] = all(check['passed'] for check in result['checks'])
    if not result['passed']:
        result['failure_class'] = 'wrong_behavior'
    write_json(root / 'verification.json', result)
    return result
