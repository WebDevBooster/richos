#!/usr/bin/env python3
"""run-walk.py --wait reaches the guest-lock reservation; the default still refuses at once.

No guest, no lock, no CPU sample: `reservation` is replaced by a stub that records what it
was asked for and refuses, so main() stops before anything is booted."""
import contextlib
import importlib.util
import io
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
spec = importlib.util.spec_from_file_location('run_walk', HERE / 'run-walk.py')
run_walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run_walk)
failures = []


def check(name, cond, detail=''):
    print(('  ok    ' if cond else '  FAIL  ') + name + ('' if cond else '\n        ' + str(detail)))
    if not cond:
        failures.append(name)


asked = []


@contextlib.contextmanager
def stub_reservation(**kw):
    asked.append(kw)
    raise BlockingIOError('stub: refused before anything boots')
    yield  # pragma: no cover


run_walk.reservation = stub_reservation


def main_with(*extra):
    with tempfile.TemporaryDirectory() as t:
        sys.argv = ['run-walk.py', '--bundle', 'b.zip', '--home', t, '--engine', 'e.tar.gz',
                    '--report', str(Path(t) / 'r.json'), *extra, '--', 'true']
        try:
            run_walk.main()
        except BlockingIOError:
            return 'refused'
    return 'ran'


asked.clear()
outcome = main_with()
check('without --wait the reservation is asked for no wait (refuse at once, as before)',
      outcome == 'refused' and asked and asked[-1].get('wait_seconds', 0) == 0, asked)
asked.clear()
outcome = main_with('--wait', '900')
check('--wait 900 reaches the guest-lock reservation as wait_seconds=900',
      outcome == 'refused' and asked and asked[-1].get('wait_seconds') == 900, asked)
check('...and the guest lock is still the lock it holds', asked and str(asked[-1].get('lock', '')).endswith('guest.lock'), asked)

print(f'run-walk-wait.test.py: {len(failures)} failed')
sys.exit(1 if failures else 0)
