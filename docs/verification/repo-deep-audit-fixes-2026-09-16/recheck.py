#!/usr/bin/env python3
"""Run the permanent regressions for the three deep-audit findings.

Usage: python3 recheck.py [repository-root] [output-directory]
Uses synthetic fixtures. No live account, user corpus or provider turn is used.
"""
import argparse
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('repository', nargs='?', type=Path, default=Path(__file__).resolve().parents[3])
parser.add_argument('output', nargs='?', type=Path)
args = parser.parse_args()
repo = args.repository.resolve()
out = args.output or Path(tempfile.mkdtemp(prefix='richos-deep-recheck-'))
out.mkdir(parents=True, exist_ok=True)
cargo = shutil.which('cargo') or str(Path.home() / '.cargo/bin/cargo')
env = dict(os.environ)
env['PATH'] = str(Path(cargo).parent) + os.pathsep + env.get('PATH', '')
checks = [
    ('loro', ['bash', 'richos/engine/loro/tests/run.test.sh'], repo, False),
    ('desktop-corrections', [cargo, 'test', '--locked', '-p', 'richos-core', '--test', 'delivered_loro_tests'], repo / 'richos/app', True),
    ('worker-settlement', [cargo, 'test', '--locked', '-p', 'richos-core', '--lib', 'worker_settlement_requires_readable_evidence_before_a_normal_turn_end', '--', '--nocapture'], repo / 'richos/app', True),
    ('worker-evidence-lock', [cargo, 'test', '--locked', '-p', 'richos-core', '--lib', 'app_workers::tests'], repo / 'richos/app', True),
]
results = []
for name, command, cwd, rust_summary in checks:
    run = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True)
    log = run.stdout + run.stderr
    (out / (name + '.log')).write_text(log)
    summary_found = not rust_summary or bool(re.search(r'test result: ok\. [1-9][0-9]* passed; 0 failed;', log))
    passed = run.returncode == 0 and summary_found
    results.append(dict(name=name, command=command, exit=run.returncode, expected_summary_found=summary_found, passed=passed))
    print(name, 'PASS' if passed else 'FAIL', flush=True)
(out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print('Evidence:', out)
raise SystemExit(0 if all(r['passed'] for r in results) else 1)
