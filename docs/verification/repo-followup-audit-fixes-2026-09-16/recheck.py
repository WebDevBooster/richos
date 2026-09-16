#!/usr/bin/env python3
"""Run the permanent regressions for the four follow-up audit findings.

Usage: python3 recheck.py [repository-root] [output-directory]
Requires Node with node:sqlite (the delivered Node 24.21 works), Cargo and the
service test prerequisites. Uses synthetic fixtures, no live provider or corpus.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('repository', nargs='?', type=Path, default=Path(__file__).resolve().parents[3])
parser.add_argument('output', nargs='?', type=Path)
args = parser.parse_args()
repo = args.repository.resolve()
out = args.output or Path(tempfile.mkdtemp(prefix='richos-followup-recheck-'))
out.mkdir(parents=True, exist_ok=True)
cargo = shutil.which('cargo') or str(Path.home() / '.cargo/bin/cargo')
env = dict(os.environ)
env['PATH'] = str(Path(cargo).parent) + os.pathsep + env.get('PATH', '')
checks = [
    ('loro', ['bash', 'richos/engine/loro/tests/run.test.sh'], repo, [
        r'ok  write cli: supersession requires acknowledgement for every widening and leaves refused writes untouched',
        r'[1-9][0-9]* passed, 0 failed',
        r'Loro reader boundaries: 10 checks passed',
        r'Loro concurrent writers: .* passed',
    ]),
    ('desktop-corrections', [cargo, 'test', '--locked', '-p', 'richos-core', '--test', 'delivered_loro_tests'], repo / 'richos/app', [
        r'test desktop_replacements_cannot_widen_private_memory \.\.\. ok',
        r'test result: ok\. [1-9][0-9]* passed; 0 failed;',
    ]),
    ('watcher', ['node', 'test/run.js'], repo / 'richos/tools/richos-service', [
        r'ok  watcher isolates a broken recording on every scan and still inspects later sessions',
        r'ok  watcher preserves storage refusal without blocking the next pending pipeline',
        r'[1-9][0-9]* passed, 0 failed',
    ]),
]
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip()
results = []
for name, command, cwd, expected in checks:
    run = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True)
    log = run.stdout + run.stderr
    (out / (name + '.log')).write_text(log)
    missing = [pattern for pattern in expected if not re.search(pattern, log)]
    passed = run.returncode == 0 and not missing
    results.append(dict(name=name, command=command, cwd=str(cwd), source_revision=revision,
                        exit=run.returncode, missing_evidence=missing, passed=passed,
                        sha256=hashlib.sha256(log.encode()).hexdigest()))
    print(name, 'PASS' if passed else 'FAIL', flush=True)
(out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('Evidence:', out)
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
