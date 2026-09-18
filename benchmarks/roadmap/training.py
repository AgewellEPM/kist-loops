"""Freeze a real verifier diagnostics repair separately from evaluation families."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
import sys
import time

from corpus import CHECK
from process import save, sha


DRIVER = '''import importlib.util,json,shutil,sys,tempfile
from pathlib import Path
spec=importlib.util.spec_from_file_location("submitted_verifier",Path("verify.py").resolve())
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
def exercise(case):
 with tempfile.TemporaryDirectory(dir=Path(".build").resolve()) as directory:
  base=Path(directory); corpus=base/"corpus"; project=corpus/"fixture/project"; project.mkdir(parents=True)
  (project/"source.py").write_text("original source\\n"); v.save(corpus/"manifest.json",{})
  rows=[{"name":"one","input":{},"rule":{"expected":{"value":"ok"}}}]
  v.save(corpus/"fixture/private-cases.json",rows)
  task={"id":"fixture","writable":["source.py"],"template":{"source.py":v.sha(project/"source.py")},
   "private_cases_sha256":v.sha(corpus/"fixture/private-cases.json"),"build":[],"run":["cases"]}
  if case in ("module_failure","module_pass"): task["module_boundary_required"]=True
  if case=="compile_failure": task["build"]=["compile"]
  if case=="missing_source": (project/"source.py").unlink()
  original_mkdtemp=tempfile.mkdtemp
  v.tempfile.mkdtemp=lambda **kwargs:original_mkdtemp(prefix=kwargs.get("prefix",""),dir=base)
  v.sandbox_argv=lambda argv,root,env:argv
  v.trial_environment=lambda config,root:{}
  def execute(argv,root,output,**kwargs):
   output.mkdir(parents=True)
   if argv[0]=="compile": return {"passed":False}
   if argv[0]=="cases":
    values=[{"value":"wrong" if case=="case_failure" else "ok"}]
    (output/"stdout.txt").write_text("invalid JSON" if case=="malformed_results" else json.dumps(values))
    if case=="source_changed": (root/"source.py").write_text("changed during execution\\n")
    return {"passed":case!="execution_failure"}
   return {"passed":case!="module_failure"}
  v.execute=execute
  try: result=v.verify(task,corpus,project,base/"output",base/"config")
  finally: v.tempfile.mkdtemp=original_mkdtemp
  diagnostic=result.get("failure")
  return {"accepted":result["passed"],"diagnostic":isinstance(diagnostic,str) and bool(diagnostic.strip()),
   "module_record": "module_boundary" in result}
Path(".build").mkdir(exist_ok=True)
json.dump([exercise(row["case"]) for row in json.load(sys.stdin)],sys.stdout,allow_nan=False)
'''


def freeze(destination, repository, mission):
    destination.mkdir(parents=True, exist_ok=False)
    task_id = 'python-verifier-diagnostics'
    project = destination / task_id / 'project'
    project.mkdir(parents=True)
    for name in ('verify.py', 'process.py'):
        shutil.copy2(repository / 'benchmarks/roadmap' / name, project / name)
    (project / 'driver.py').write_text(DRIVER)
    (project / 'check.py').write_text(CHECK)
    (project / 'TASK.md').write_text(
        'Repair the existing verifier diagnostics in verify.py. A rejected module-boundary check currently '
        'returns passed=false without any failure description. The same omission exists for failed case '
        'assertions, failed case execution, and a submitted source changing during verification. '
        'Ensure every negative final result has a nonempty human-readable failure string identifying '
        'the failing verification stage. Preserve all verdicts, source integrity checks, case comparisons, '
        'module-boundary checks, existing specific error messages and cleanup. Successful results must '
        'not gain a failure description. Edit only verify.py. The protected driver exercises the real '
        'verify function with controlled process outcomes, without invoking arbitrary submitted commands. '
        'Run make verify after the final edit.\n')
    (project / 'AGENTS.md').write_text(
        'Disposable Kist training repair. Only verify.py may change. Use the advertised file tools. '
        'The only shell verification command is make verify. Preserve all protected inputs and verdict '
        'checks. No downloads, UI, browser, VM or external systems. Do not delegate.\n')
    run = [sys.executable, 'driver.py']
    save(project / 'run-argv.json', run)
    cases = []
    for name in ('module_pass', 'module_failure', 'case_failure', 'execution_failure', 'source_changed',
                 'malformed_results', 'compile_failure', 'missing_source'):
        good = name == 'module_pass'
        cases.append({'name': name, 'input': {'case': name}, 'rule': {'expected': {
            'accepted': good, 'diagnostic': not good, 'module_record': name in ('module_pass', 'module_failure')}}})
    save(project / 'public-cases.json', cases[:2])
    save(destination / task_id / 'private-cases.json', cases)
    (project / 'Makefile').write_text('verify:\n\tmkdir -p .build\n\t' + sys.executable + ' check.py\n')
    task = {'id': task_id, 'kind': 'bug-fix', 'language': 'Python',
            'origin': 'benchmarks/roadmap/verify.py', 'origin_sha256': sha(project / 'verify.py'),
            'writable': ['verify.py'], 'build': [], 'run': run,
            'template': {p.name: sha(p) for p in project.iterdir() if p.is_file()},
            'private_cases_sha256': sha(destination / task_id / 'private-cases.json')}
    save(destination / 'manifest.json', {'schema': 'kist.coding-corpus.v1', 'mission_id': mission,
         'frozen_at': time.time(), 'split': 'training', 'tasks': [task],
         'authority': 'host-frozen local training task; not an unseen evolution acceptance suite',
         'exposure': 'This distinct verifier source family is reserved for training; never score it as unseen evaluation.'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repository', type=Path, required=True)
    parser.add_argument('--mission', required=True)
    args = parser.parse_args()
    freeze(args.output, args.repository, args.mission)
