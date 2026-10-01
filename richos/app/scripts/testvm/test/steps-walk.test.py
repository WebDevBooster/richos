#!/usr/bin/env python3
"""steps-walk.py: a list of steps runs in order, each is recorded, the first failure stops the walk
unless that step says allow_fail, and an unknown step is a failure (never a silent skip).
Only the steps that need no guest are used: wait and an unknown op."""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / 'steps-walk.py'
failures = []


def check(name, cond, detail=''):
    print(('  ok    ' if cond else '  FAIL  ') + name + ('' if cond else '\n        ' + str(detail)))
    if not cond:
        failures.append(name)


def walk(tmp, name, steps):
    plan, out = Path(tmp) / (name + '.json'), Path(tmp) / name
    plan.write_text(json.dumps(steps))
    r = subprocess.run([sys.executable, str(TOOL), 'no-such-vm', '--steps', str(plan), '--out', str(out)],
                       capture_output=True, text=True)
    record = json.loads((out / 'steps.json').read_text()) if (out / 'steps.json').exists() else []
    return r.returncode, record, r.stdout + r.stderr


with tempfile.TemporaryDirectory(prefix='steps-walk-test-') as tmp:
    rc, rec, said = walk(tmp, 'ok', [{'op': 'wait', 'seconds': 0}, {'op': 'wait', 'seconds': 0}])
    check('two passing steps exit 0 and both are recorded', rc == 0 and len(rec) == 2, (rc, rec, said))

    rc, rec, said = walk(tmp, 'stop', [{'op': 'nonsense'}, {'op': 'wait', 'seconds': 0}])
    check('an unknown step fails the walk and stops it before the next step',
          rc == 1 and len(rec) == 1 and rec[0]['exit'] == 2, (rc, rec, said))

    rc, rec, said = walk(tmp, 'allow', [{'op': 'nonsense', 'allow_fail': True}, {'op': 'wait', 'seconds': 0}])
    check('allow_fail records the failure and carries on; the walk still exits 0',
          rc == 0 and len(rec) == 2 and rec[0]['exit'] == 2 and rec[1]['exit'] == 0, (rc, rec, said))

print('steps-walk.test.py: %d failed' % len(failures))
sys.exit(1 if failures else 0)
