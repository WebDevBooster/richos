#!/usr/bin/env python3
"""stall-run.py -- run ONE command while the scheduler keeps taking the CPU away from it.

    stall-run.py [--run-ms R] [--stop-ms S] [--max-seconds T] -- COMMAND [ARG ...]

WHY (2026-09-29). The nightly's load-sensitive failures (audit
docs/verification/2026-09-29-load-sensitive-checks-audit.md) come from checks that time a window
of the test's own work and fail when the test process was not on a core for part of it: a
Mac swapping, or three gates side by side. under-load.py makes a busy Mac, but a busy Mac only
sometimes lands a long enough gap inside a one-second window, so a fix proven on it is proven
by luck. This makes the gap certain: it lands the stall where the check's own clock is running.

WHAT IT DOES. Starts COMMAND in a process group of its own and, until it exits, lets that group
run for R milliseconds and then holds it stopped (SIGSTOP) for S milliseconds, over and over.
Children that put themselves in another process group keep running; every RichOS child does
(`OwnedChild::configure`, `process_group(0)`). That is a test process descheduled on a busy
Mac: the fixtures on the other end of its pipes carry on, the wall clock keeps moving, and the
test does not get to look at it. A check that decides its verdict by the wall clock fails under
this; a check whose clocks are only hang guards passes. `--run-ms 1 --stop-ms 2500` is the
profile the R9 proofs used. Exit status: COMMAND's own; 124 when COMMAND ran past
--max-seconds (its group is killed); 2 on bad usage.

WHAT IT NEVER DOES. It signals only the process group it created, by the pid it holds, and
stops signaling the moment that pid has exited. It never looks a process up by name. However
it ends short of SIGKILL (normal exit, an exception, SIGTERM, SIGINT, SIGHUP), it continues
the group before it goes, so nothing is left stopped. It takes no lock and does no admission:
put it behind `scripts/testvm/reserve.py --`. It adds no CPU load of its own.
"""
import argparse
import os
import signal
import subprocess
import sys
import time


class _Ended(Exception):
    pass


def _raise(signum, frame):
    raise _Ended(signal.Signals(signum).name)


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--run-ms", type=float, default=1.0)
    p.add_argument("--stop-ms", type=float, default=2500.0)
    p.add_argument("--max-seconds", type=float, default=600.0)
    p.add_argument("command", nargs=argparse.REMAINDER)
    a = p.parse_args(argv)
    cmd = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not cmd or a.run_ms <= 0 or a.stop_ms < 0 or a.max_seconds <= 0:
        p.print_usage(sys.stderr)
        return 2

    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(signum, _raise)
    child = subprocess.Popen(cmd, process_group=0)
    group = child.pid
    began = time.monotonic()
    stalls = 0
    rc = None

    def signal_group(signum):
        # Only while our own child is unreaped: after that the group may be empty (EPERM or
        # ESRCH on macOS) and the number is no longer ours to use.
        if child.poll() is not None:
            return False
        try:
            os.killpg(group, signum)
            return True
        except (ProcessLookupError, PermissionError):
            return False

    try:
        while child.poll() is None:
            if time.monotonic() - began > a.max_seconds:
                signal_group(signal.SIGCONT)
                signal_group(signal.SIGKILL)
                child.wait()
                print("stall-run: the command ran past %gs and its group was killed" % a.max_seconds,
                      file=sys.stderr, flush=True)
                rc = 124
                break
            time.sleep(a.run_ms / 1000.0)
            if not signal_group(signal.SIGSTOP):
                break
            stalls += 1
            try:
                time.sleep(a.stop_ms / 1000.0)
            finally:
                signal_group(signal.SIGCONT)
    except _Ended as ended:
        print("stall-run: %s received; the command's group is continued and left to finish" % ended,
              file=sys.stderr, flush=True)
    finally:
        signal_group(signal.SIGCONT)
    if rc is None:
        rc = child.wait()
    print("stall-run: %d stalls of %g ms, one after every %g ms of running, %.1fs in all; exit %d"
          % (stalls, a.stop_ms, a.run_ms, time.monotonic() - began, rc), file=sys.stderr, flush=True)
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
