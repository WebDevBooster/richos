#!/usr/bin/env python3
"""reserve.py's stop path ends the whole command group, not only its leader (hunt finding R15).

The command is a shell that starts a descendant ignoring SIGTERM and then exits on SIGTERM
itself. stop_group must still SIGKILL the descendant: the leader's exit is not the group's.
Only the descendant this test started (PID read from its own file) is ever signaled.

RESERVE_MODULE_DIR (test only) points at another copy of reserve.py, to show the case red.
"""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

HERE = Path(os.environ.get('RESERVE_MODULE_DIR') or Path(__file__).resolve().parents[1])
sys.path.insert(0, str(HERE))
import reserve  # noqa: E402

reserve.STOP_GRACE = 1  # load-bound: the descendant ignores SIGTERM, so the grace always elapses
reserve.KILL_GRACE = 3

with tempfile.TemporaryDirectory() as tmp:
    pidfile = Path(tmp) / 'descendant.pid'
    # sleep inherits the ignored SIGTERM; the shell then installs its own exit-on-TERM handler
    script = (f"trap '' TERM; sleep 300 & echo $! > {pidfile}; "
              "trap 'exit 0' TERM; while :; do sleep 1; done")
    child = subprocess.Popen(['/bin/bash', '-c', script], start_new_session=True)
    descendant = None
    try:
        for _ in range(100):
            if pidfile.exists() and pidfile.read_text().strip():
                descendant = int(pidfile.read_text())
                break
            time.sleep(0.05)
        time.sleep(0.3)  # let both traps install
        try:
            reserve.stop_group(child, signal.SIGTERM)
            code = 'returned'
        except SystemExit as exc:
            code = exc.code
        alive = False
        if descendant:
            try:
                os.kill(descendant, 0)
                alive = True
            except ProcessLookupError:
                pass
        fail = []
        if descendant is None:
            fail.append('descendant never started')
        if code != 128 + signal.SIGTERM:
            fail.append(f'exit code {code}')
        if alive:
            fail.append(f'descendant {descendant} still alive after stop_group')
    finally:
        if descendant:
            try:
                os.kill(descendant, signal.SIGKILL)  # owned: its PID came from this test's own file
            except ProcessLookupError:
                pass
        if child.poll() is None:
            child.kill()
            child.wait()
if fail:
    print('\n'.join(fail))
    sys.exit(1)
print('ok')
