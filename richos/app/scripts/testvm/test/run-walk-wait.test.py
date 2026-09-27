#!/usr/bin/env python3
"""run-walk.py --wait reaches the guest-slot admission; the default still refuses at once;
a command that cannot run, or the retired hold-walk.py, is refused before any slot is asked for.

No guest, no lock, no CPU sample: `guest_slot` is replaced by a stub that records what it
was asked for and refuses, so main() stops before anything is booted."""
import contextlib
import importlib.util
import io
import os
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
def stub_slot(**kw):
    asked.append(kw)
    raise BlockingIOError('stub: refused before anything boots')
    yield  # pragma: no cover


run_walk.guest_slot = stub_slot


def main_with(*extra, command=('true',)):
    with tempfile.TemporaryDirectory() as t:
        sys.argv = ['run-walk.py', '--bundle', 'b.zip', '--home', t, '--engine', 'e.tar.gz',
                    '--report', str(Path(t) / 'r.json'), *extra, '--', *command]
        err = io.StringIO()
        try:
            with contextlib.redirect_stderr(err):
                run_walk.main()
        except BlockingIOError:
            return 'refused', err.getvalue()
        except SystemExit as exc:
            return 'exit %s' % exc.code, err.getvalue()
    return 'ran', ''


os.environ['TESTVM_ROOT'] = '/nonexistent/testvm-root'
asked.clear()
outcome, _ = main_with()
check('without --wait the slot is asked for no wait (refuse at once, as before)',
      outcome == 'refused' and asked and asked[-1].get('wait_seconds', 0) == 0, asked)
asked.clear()
outcome, _ = main_with('--wait', '900')
check('--wait 900 reaches the guest-slot admission as wait_seconds=900',
      outcome == 'refused' and asked and asked[-1].get('wait_seconds') == 900, asked)
check('...under the TESTVM_ROOT the walk runs in', asked and str(asked[-1].get('root')) == '/nonexistent/testvm-root',
      asked)
asked.clear()
outcome, said = main_with(command=(str(HERE / 'hold-walk.py'), '--out', '/tmp/x'))
check('hold-walk.py is refused before a slot is asked for, and the refusal says what to do instead',
      outcome == 'exit 2' and not asked and 'retired' in said and 'script' in said, (outcome, asked, said))
asked.clear()
outcome, said = main_with(command=('/nonexistent/walk.py',))
check('a command that cannot run is refused before a slot is asked for',
      outcome == 'exit 2' and not asked and 'not an executable file' in said, (outcome, asked, said))

print(f'run-walk-wait.test.py: {len(failures)} failed')
sys.exit(1 if failures else 0)
