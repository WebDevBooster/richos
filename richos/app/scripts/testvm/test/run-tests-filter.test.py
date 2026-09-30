#!/usr/bin/env python3
"""run-tests.sh <pattern> runs only the bodies whose names match.

Builds a scratch copy of the testvm tree whose runner carries two extra tests: an unrelated one
that writes a marker file, and a failing one that is not selected. A named run must leave no
marker and must not count the unselected failure; an unnamed run must run both."""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TESTVM = Path(__file__).resolve().parents[1]
failures = []


def check(name, cond, detail=''):
    print(('  ok    ' if cond else '  FAIL  ') + name + ('' if cond else '\n        ' + str(detail)))
    if not cond:
        failures.append(name)


scratch = Path(tempfile.mkdtemp(prefix='runtests-filter.'))
try:
    tree = scratch / 'testvm'
    tree.mkdir()
    for entry in TESTVM.iterdir():
        if entry.name != 'test':
            os.symlink(entry, tree / entry.name)
    (tree / 'test').mkdir()
    os.symlink(TESTVM / 'test' / 'stub-guest.sh', tree / 'test' / 'stub-guest.sh')
    marker = scratch / 'unrelated-body-ran'
    src = (TESTVM / 'test' / 'run-tests.sh').read_text()
    extra = ('t "zz unrelated: writes a marker"\n  touch "%s"\nt_done\n\n'
             't "zz unselected: fails"\n  ok 1 "boom"\nt_done\n\n') % marker
    footer = '# ===========================================================================\necho\nif [ "$FAIL" -eq 0 ]'
    assert footer in src
    (tree / 'test' / 'run-tests.sh').write_text(src.replace(footer, extra + footer))

    def run(*args):
        env = {k: v for k, v in os.environ.items() if not k.startswith('RUN_TESTS_')}
        return subprocess.run(['bash', str(tree / 'test' / 'run-tests.sh'), *args],
                              capture_output=True, text=True, env=env, timeout=300)

    r = run('node name: uppercase')
    check('a named run passes exactly the named test', '1 passed, 0 failed' in r.stdout and r.returncode == 0, r.stdout + r.stderr)
    check('a named run does not execute an unrelated body', not marker.exists())
    check('a named run does not count an unselected failure', 'zz unselected' not in r.stdout, r.stdout)

    r = run()
    check('an unnamed run executes every body', marker.exists())
    check('an unnamed run reports the unselected failure', r.returncode == 1 and 'zz unselected' in r.stdout, r.stdout)
finally:
    shutil.rmtree(scratch, ignore_errors=True)

sys.exit(1 if failures else 0)
