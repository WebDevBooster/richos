#!/usr/bin/env python3
"""reserve.py's stop path never raises on a group that is gone or going.

macOS can raise PermissionError (EPERM) from killpg on a group whose members are exiting.
The wrapper must still reap the child and exit 128+signum, with no traceback. The child is
a real command that ignores SIGTERM; only `killpg` is replaced (the group really is killed,
by the PID this test captured, and the call then reports the error) and the 10 s wait is
shortened by a Popen subclass.

  1. SIGTERM ignored, the SIGKILL killpg raises PermissionError: SystemExit(128+15)
  2. the first killpg raises ProcessLookupError: SystemExit(128+2)
  3. another error (OSError EIO) is not swallowed

RESERVE_MODULE_DIR (test only) points at another copy of reserve.py, to show the case red.
"""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

HERE = Path(os.environ.get('RESERVE_MODULE_DIR') or Path(__file__).resolve().parents[1])
sys.path.insert(0, str(HERE))
import reserve  # noqa: E402

if hasattr(reserve, 'STOP_GRACE'):
    reserve.STOP_GRACE = 0.5  # load-bound: the child ignores SIGTERM, so the grace always elapses
    reserve.KILL_GRACE = 3

failures = []
real_killpg = os.killpg


class FastWait(subprocess.Popen):
    def wait(self, timeout=None):
        # load-bound: the child ignores SIGTERM and never exits on its own, so the timeout always elapses
        return super().wait(timeout=0.5 if timeout else None)


def run(killpg, signum):
    child = FastWait(['/bin/sh', '-c', "trap '' TERM; while :; do sleep 1; done"], start_new_session=True)
    os.killpg = lambda pid, sig: killpg(child, pid, sig)
    try:
        time.sleep(0.3)  # let the trap install
        stop = getattr(reserve, 'stop_group', None)
        try:
            if stop:
                stop(child, signum)
            else:  # the pre-fix shape: the handler lived inside main()
                raise AttributeError('reserve.stop_group missing')
        except SystemExit as exc:
            return child, exc.code, None
        except BaseException as exc:  # noqa: BLE001
            return child, None, exc
        return child, 'returned', None
    finally:
        os.killpg = real_killpg
        if child.poll() is None:
            child.kill()
            child.wait()


def eperm_kill(child, pid, sig):
    if sig == signal.SIGKILL:
        child.kill()
        raise PermissionError(1, 'Operation not permitted')
    real_killpg(pid, sig)


def gone_kill(child, pid, sig):
    child.kill()
    raise ProcessLookupError(3, 'No such process')


def io_kill(child, pid, sig):
    raise OSError(5, 'Input/output error')


for name, kill, signum, want in (('eperm', eperm_kill, signal.SIGTERM, 128 + signal.SIGTERM),
                                 ('gone', gone_kill, signal.SIGINT, 128 + signal.SIGINT)):
    child, code, err = run(kill, signum)
    if err is not None or code != want or child.poll() is None:
        failures.append(f'{name}: code={code} err={err!r}')
child, code, err = run(io_kill, signal.SIGTERM)
if not isinstance(err, OSError):
    failures.append(f'other: code={code} err={err!r}')

if failures:
    print('\n'.join(failures))
    sys.exit(1)
print('ok')
