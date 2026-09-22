#!/usr/bin/env python3
"""Admit heavy work by measured CPU. Example: reserve.py -- COMMAND ARGS...

CEO ruling §77 (2026-09-22): test runs and development builds, including land
checks, are admitted by the CPU rule alone and do not take the nightly
release.lock. Pass --release-lock only for a command that writes nightly or
release state; the nightly/release commands hold that lock themselves.
"""
import argparse
from contextlib import contextmanager, ExitStack
import fcntl
import os
from pathlib import Path
import signal
import re
import subprocess
import sys
import time
import math


def cpu_busy_percent():
    """Measure current CPU use; load average also counts work that is not using a CPU."""
    env = {**os.environ, 'LC_ALL': 'C'}
    try:
        result = subprocess.run(['/usr/bin/top', '-l', '2', '-s', '1', '-n', '0', '-stats', 'pid,command'],
                                capture_output=True, text=True, timeout=5, env=env)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise BlockingIOError('CPU measurement unavailable; admission refused: ' + str(exc)) from exc
    idle = re.findall(r'CPU usage:.*?([0-9]+(?:\.[0-9]+)?)% idle', result.stdout)
    if result.returncode or len(idle) < 2 or not 0 <= float(idle[-1]) <= 100:
        raise BlockingIOError('CPU measurement unavailable; expected two valid top samples')
    return 100 - float(idle[-1])


def cpu_admission(max_cpu=80, wait_seconds=0):
    """Bounded admission before work or a paid send; never infer jobs from load."""
    if not math.isfinite(max_cpu) or not 0 < max_cpu <= 100:
        raise ValueError('max_cpu must be greater than 0 and at most 100')
    if not math.isfinite(wait_seconds) or wait_seconds < 0:
        raise ValueError('admission wait must be a finite nonnegative number')
    started = time.monotonic()
    while True:
        busy = cpu_busy_percent()
        elapsed = time.monotonic() - started
        if busy < max_cpu:
            return {'cpu_busy_percent': busy, 'load': os.getloadavg()[0], 'admission_wait_seconds': elapsed}
        remaining = wait_seconds - elapsed
        if remaining <= 0:
            raise BlockingIOError(f'CPU is {busy:.1f}% busy (limit {max_cpu:g}%); admission refused. '
                                  'Load average alone does not identify another running job.')
        time.sleep(min(2, remaining))


@contextmanager
def exclusive_lock(path):
    """Hold one nonblocking exclusive flock on `path` for the whole interval."""
    path = Path(path)
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if parent.is_symlink() or parent.stat().st_uid != os.getuid():
        raise ValueError('lock directory must be owned by the current user and not a symlink: ' + str(parent))
    with path.open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BlockingIOError('reservation unavailable: ' + str(path)) from None
        print('reservation held: ' + str(path.resolve()), file=sys.stderr, flush=True)
        try:
            yield path.resolve()
        finally:
            print('reservation released', file=sys.stderr, flush=True)


@contextmanager
def reservation(state=None, max_load=None, max_cpu=80, release_lock=False, lock=None):
    """Admission for heavy work (CEO ruling §77).

    By default this is the CPU rule alone: nothing is locked and nothing under
    the nightly state directory is touched, so test runs and development builds
    never queue behind one another or behind a nightly. `release_lock=True`
    additionally holds `<state>/release.lock`, the lock `nightly-local.py`'s
    `exclusive()` takes; use it only for work that writes nightly/release state.
    `lock` holds a different single-owner resource lock (the test VM guest).
    Locks are taken first, so a held lock refuses without spending a sample."""
    if release_lock and state is None:
        raise ValueError('release_lock needs the nightly state directory')
    with ExitStack() as held:
        paths = []
        if release_lock:
            state = Path(state)
            paths.append(held.enter_context(exclusive_lock(state / 'release.lock')))
        if lock is not None:
            paths.append(held.enter_context(exclusive_lock(lock)))
        if max_load is not None:
            # Explicit opt-in for a controlled benchmark's historical load criterion.
            if not math.isfinite(max_load) or max_load <= 0 or os.getloadavg()[0] >= max_load:
                raise BlockingIOError('load is above the explicitly requested limit; admission refused')
        else:
            sample = cpu_admission(max_cpu)
            print(f"CPU admission: {sample['cpu_busy_percent']:.1f}% busy; load {sample['load']:.2f} is informational",
                  file=sys.stderr, flush=True)
        if not paths:
            print('admitted by CPU alone; no lock taken (CEO ruling §77)', file=sys.stderr, flush=True)
        yield paths[0] if paths else None


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--state-dir', type=Path, default=Path.home()/'.richos-nightly',
                   help='same --state-dir as nightly-local.py; read only with --release-lock')
    p.add_argument('--release-lock', action='store_true',
                   help='also hold <state-dir>/release.lock: only for work that writes nightly/release state')
    p.add_argument('--max-load', type=float, help='opt in to a strict load-average gate for controlled measurements')
    p.add_argument('--max-cpu', type=float, default=80, help='maximum measured CPU busy percentage (default: 80)')
    p.add_argument('command', nargs=argparse.REMAINDER)
    args = p.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        p.error('a command is required')
    with reservation(args.state_dir, args.max_load, args.max_cpu, release_lock=args.release_lock):
        # Any lock FD stays in the supervisor until the command is reaped.
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
