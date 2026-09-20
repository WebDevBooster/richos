#!/usr/bin/env python3
"""Hold the nightly release lock around heavy work. Example: reserve.py -- COMMAND ARGS..."""
import argparse
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys


@contextmanager
def reservation(state,max_load=8):
    state=Path(state)
    state.mkdir(parents=True, exist_ok=True, mode=0o700)
    if state.is_symlink() or state.stat().st_uid != os.getuid():
        raise ValueError('nightly state must be owned by the current user and not a symlink')
    with (state/'release.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BlockingIOError('reservation unavailable: '+str(state/'release.lock')) from None
        if os.getloadavg()[0] >= max_load:
            raise BlockingIOError('load is above admission limit; reservation released')
        print('reservation held: '+str((state/'release.lock').resolve()), file=sys.stderr, flush=True)
        try:
            yield (state/'release.lock').resolve()
        finally:
            print('reservation released',file=sys.stderr,flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--state-dir', type=Path, default=Path.home()/'.richos-nightly',
                   help='same --state-dir as nightly-local.py')
    p.add_argument('--max-load', type=float, default=8)
    p.add_argument('command', nargs=argparse.REMAINDER)
    args = p.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        p.error('a command is required')
    with reservation(args.state_dir,args.max_load):
        # The lock FD stays in the supervisor until the command is reaped.
        child = subprocess.Popen(command, start_new_session=True)
        def stop(signum, frame):
            try:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            except ProcessLookupError:
                pass
            raise SystemExit(128+signum)
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, stop)
        try:
            return child.wait()
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()


if __name__ == '__main__':
    try:sys.exit(main())
    except BlockingIOError as exc:print(str(exc),file=sys.stderr);sys.exit(75)
