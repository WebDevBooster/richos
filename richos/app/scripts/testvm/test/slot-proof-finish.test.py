#!/usr/bin/env python3
"""slot-proof.py's Run.finish(timeout) bounds how long it waits for its run.

A run that never ends must not hold the proof forever: at the deadline the run is asked to
stop (SIGTERM to the run itself, so run-walk.py's own cleanup deletes its guest), given a
grace period for that cleanup, and only then is its process group killed. A run that ends
before the deadline is returned as before, untouched.

The verdicts are facts, not durations: the stand-in runs never end on their own, so the only
way finish() can return is by ending them, and how they ended (which signal) and whether the
run is marked timed out is what is checked. A watchdog kills a stand-in that is still alive
after HANG_CATCH seconds, so an unfixed finish() fails instead of hanging the suite.

No guest, no slot, no CPU sample: each run is a Python child this test starts, and the only
processes signaled are those children, by the pid captured at their spawn."""
import importlib.util
import os
import signal
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('slot_proof', HERE / 'slot-proof.py')
slot_proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(slot_proof)
failures = []
HANG_CATCH = 60  # load-bound: a hang catch only; no verdict below reads a clock


def check(name, cond, detail=''):
    print(('  ok    ' if cond else '  FAIL  ') + name + ('' if cond else '\n        ' + str(detail)))
    if not cond:
        failures.append(name)


def child(code):
    return [sys.executable, '-c', code]


def watchdog(proc):
    """Kill an owned stand-in still alive after HANG_CATCH seconds; the test then fails on the facts."""
    def fire():
        if proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    timer = threading.Timer(HANG_CATCH, fire)
    timer.daemon = True
    timer.start()
    return timer


FOREVER = 'import time\nwhile True: time.sleep(1)'

with tempfile.TemporaryDirectory(prefix='slot-proof-finish.') as tmp:
    tmp = Path(tmp)
    owned = []
    try:
        # 1. A run that ends on its own before the deadline: its own exit status, not a timeout.
        run = slot_proof.Run('quick', child('print("slot held: x (waited 0s")'), tmp / 'quick.log')
        owned.append(run.proc)
        rc = run.finish(timeout=HANG_CATCH)
        check('a run that ends before the deadline returns its own exit status',
              rc == 0 and not getattr(run, 'timed_out', False), f'rc={rc}')
        check('...and its output is read', any('slot held' in line for _, line in run.lines()), run.seen)

        # 2. A run that never ends and answers SIGTERM: ended by SIGTERM at the deadline.
        run = slot_proof.Run('hung', child(f'print("started", flush=True)\n{FOREVER}'), tmp / 'hung.log')
        owned.append(run.proc)
        timer = watchdog(run.proc)
        rc = run.finish(timeout=1)  # load-bound: the child never ends by itself, so no timing decides it
        timer.cancel()
        check('a run that never ends is ended at the finish deadline with SIGTERM',
              run.proc.returncode == -signal.SIGTERM,
              f'returncode={run.proc.returncode} (SIGTERM is {-signal.SIGTERM}; SIGKILL means the watchdog fired)')
        check('...and it is marked as timed out, with a status no fact can read as a pass',
              getattr(run, 'timed_out', False) and rc != 0, f'timed_out={getattr(run, "timed_out", None)} rc={rc}')

        # 3. A run that never ends and ignores SIGTERM (a cleanup that hangs): killed when the grace ends.
        slot_proof.FINISH_GRACE = 1  # load-bound: the child ignores SIGTERM, so only SIGKILL can end it
        ready = tmp / 'deaf.ready'
        run = slot_proof.Run('deaf', child('import signal, pathlib, sys\n'
                                           'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                                           'pathlib.Path(sys.argv[1]).touch()\n' + FOREVER)
                             + [str(ready)], tmp / 'deaf.log')
        owned.append(run.proc)
        timer = watchdog(run.proc)
        while not ready.exists() and run.proc.poll() is None:
            run.lines()  # wait for the fact (its handler is installed), not for a clock
            time.sleep(0.05)
        rc = run.finish(timeout=1)  # load-bound: the child never ends by itself, so no timing decides it
        timer.cancel()
        check('a run that ignores SIGTERM is killed when the cleanup grace ends, and marked timed out',
              run.proc.returncode == -signal.SIGKILL and getattr(run, 'timed_out', False) and rc != 0,
              f'returncode={run.proc.returncode} timed_out={getattr(run, "timed_out", None)} rc={rc}')
    finally:
        # Owned children only, by the Popen objects captured above.
        for proc in owned:
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()

if failures:
    print(f'slot-proof-finish.test.py: {len(failures)} FAILED')
    sys.exit(1)
print('slot-proof-finish.test.py: all passed')
