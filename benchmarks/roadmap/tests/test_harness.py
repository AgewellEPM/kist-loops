"""Real local process and sandbox probes; no model calls or downloaded tools."""
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from process import execute, sha, trial_environment
from verify import sandbox_argv


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='kist-roadmap-harness-')).resolve()

    def tearDown(self):
        shutil.rmtree(self.root)

    def run_child(self, code, **kwargs):
        return execute([sys.executable, '-c', code], self.root, self.root / 'attempt', **kwargs)

    def test_launch_failure_still_has_receipt_and_raw_streams(self):
        result = execute([str(self.root / 'absent-executable')], self.root, self.root / 'attempt')
        self.assertFalse(result['passed'])
        self.assertIsNone(result['pid'])
        self.assertTrue(result['process_group_empty'])
        self.assertTrue(result['errors'])
        self.assertEqual(json.loads((self.root / 'attempt/process.json').read_text()), result)

    def test_zero_exit_and_exact_stream_hashes(self):
        result = self.run_child('import sys; print(sys.stdin.read()); print("diagnostic",file=sys.stderr)', stdin='nonce')
        self.assertTrue(result['passed'], result)
        self.assertEqual(result['stdout.txt']['sha256'], sha(self.root / 'attempt/stdout.txt'))
        self.assertIn('nonce', (self.root / 'attempt/stdout.txt').read_text())

    def test_timeout_cleans_observed_child_and_preserves_output(self):
        result = self.run_child('import time; print("started",flush=True); time.sleep(30)', timeout=.3)
        self.assertFalse(result['passed'])
        self.assertTrue(result['timed_out'])
        self.assertTrue(result['process_group_empty'])
        self.assertEqual(result['remaining_processes'], [])
        self.assertIn('started', (self.root / 'attempt/stdout.txt').read_text())

    def test_immediate_output_overflow_is_failure_even_with_zero_exit(self):
        result = self.run_child('print("x"*100000)', output_limit=1024)
        self.assertFalse(result['passed'])
        self.assertTrue(result['output_limit_exceeded'])

    def test_large_stdin_does_not_block_timeout_when_child_never_reads(self):
        result = self.run_child('import time; time.sleep(30)', stdin='x' * 1000000, timeout=.3)
        self.assertTrue(result['timed_out'])
        self.assertLess(result['seconds'], 5)

    def test_node_toolchain_access_preserves_private_file_and_network_denial(self):
        project = self.root / 'project'
        project.mkdir()
        private = self.root / 'private-canary.txt'
        private.write_text('host-only-nonce')
        code = '''const fs=require('node:fs'),net=require('node:net');
let denied=false; try {fs.readFileSync(process.argv[1]);} catch(e){denied=['EPERM','EACCES'].includes(e.code);}
if(!denied)process.exit(11);
fs.writeFileSync('allowed.txt','local-only');
const client=net.createConnection({host:'127.0.0.1',port:9});
client.on('connect',()=>process.exit(12));
client.on('error',e=>{if(!['EPERM','EACCES'].includes(e.code))process.exit(13); console.log('ISOLATION PASSED');});
setTimeout(()=>process.exit(14),1000).unref();'''
        env = trial_environment(self.root / 'config', project)
        result = execute(sandbox_argv(['/opt/homebrew/bin/node', '-e', code, str(private)], project, env),
                         project, self.root / 'node', environment=env, timeout=5)
        self.assertTrue(result['passed'], result)
        self.assertEqual(private.read_text(), 'host-only-nonce')
        self.assertEqual((project / 'allowed.txt').read_text(), 'local-only')
        self.assertIn('ISOLATION PASSED', (self.root / 'node/stdout.txt').read_text())

    def test_typescript_compiler_works_inside_verifier_sandbox(self):
        project = self.root / 'project'
        project.mkdir()
        (project / 'source.ts').write_text('export const value: string = "compiler-probe";\n')
        env = trial_environment(self.root / 'config', project)
        result = execute(sandbox_argv(['tsc', '--strict', '--skipLibCheck', '--outDir', '.build', 'source.ts'], project, env),
                         project, self.root / 'tsc', environment=env, timeout=30)
        self.assertTrue(result['passed'], result)
        self.assertIn('compiler-probe', (project / '.build/source.js').read_text())


if __name__ == '__main__':
    unittest.main()
