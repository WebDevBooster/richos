#!/usr/bin/env python3
"""under-load.py -- run ONE command while this Mac carries a known CPU load, and say what the load was.

    under-load.py [--workers N] [--warmup S] [--max-seconds S] -- COMMAND [ARG ...]

WHY (2026-09-29). Nightly run 20260929T044015Z-588457c3 failed its UI gate on a check that
passed on a quiet Mac: with three gates side by side (load average 13.0 on 10 cores, the CPU
guard reading 89-92% busy) a helper process the check depended on could not start in time.
A fix for that kind of failure is proven by running the check on a Mac that is that busy, and
there was no committed way to make one, so each proof improvised its own.

WHAT IT DOES. Starts N workers (default: one per core plus two, which is how a
load average above the core count looks), each spinning ONE core at normal priority. It
waits --warmup seconds for the load to build, prints the host sample
`scripts/testvm/reserve.py` admits on, runs COMMAND in the foreground with its output
unchanged, prints a second sample, and stops the workers. Exit status: COMMAND's own, 124 when
COMMAND ran past --max-seconds, 2 on bad usage.

WHAT IT NEVER DOES. It stops only the workers it started, by the process handles it holds, and
never looks a process up by name. Each worker also leaves on its own the moment this
process's end of its stdin pipe closes, however this process ends, so a killed run cannot leave
spinning cores behind. It takes no lock and does no admission of its own: put it behind
`scripts/testvm/reserve.py --`, so a Mac that is already busy refuses it before it adds load.
Keep the command short. This loads the whole Mac for as long as it runs.
"""
import argparse
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "testvm"))
from reserve import describe, host_sample  # noqa: E402  (the admission sampler, not a copy)

# One core, normal priority, gone when its stdin closes. The spin runs in a thread so the main
# thread can block on stdin; a blocking read releases the GIL, so the spin keeps its core.
WORKER = (
    "import os, sys, threading\n"
    "def spin():\n"
    "    while True:\n"
    "        pass\n"
    "threading.Thread(target=spin, daemon=True).start()\n"
    "sys.stdin.read()\n"
    "os._exit(0)\n"
)


def sample(label):
    try:
        s = host_sample()
        line = describe(s)
    except BlockingIOError as exc:
        line = "unavailable: %s" % exc
    load = ", ".join("%.2f" % v for v in os.getloadavg())
    print("under-load: %s: %s; load average %s" % (label, line, load), file=sys.stderr, flush=True)


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--workers", type=int, default=(os.cpu_count() or 4) + 2)
    p.add_argument("--warmup", type=float, default=5.0)
    p.add_argument("--max-seconds", type=float, default=600.0)
    p.add_argument("command", nargs=argparse.REMAINDER)
    args = p.parse_args(argv)
    cmd = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not cmd or args.workers < 1 or args.warmup < 0 or args.max_seconds <= 0:
        p.print_usage(sys.stderr)
        return 2

    workers = []
    try:
        for _ in range(args.workers):
            workers.append(subprocess.Popen([sys.executable, "-c", WORKER], stdin=subprocess.PIPE))
        print("under-load: %d one-core workers started (pids %s)"
              % (len(workers), " ".join(str(w.pid) for w in workers)), file=sys.stderr, flush=True)
        time.sleep(args.warmup)
        sample("before the command")
        t0 = time.monotonic()
        try:
            rc = subprocess.run(cmd, timeout=args.max_seconds).returncode
        except subprocess.TimeoutExpired:
            print("under-load: the command ran past %gs and was stopped" % args.max_seconds, file=sys.stderr)
            rc = 124
        print("under-load: the command exited %d after %.1fs" % (rc, time.monotonic() - t0), file=sys.stderr, flush=True)
        sample("after the command")
        return rc
    finally:
        for w in workers:
            try:
                w.stdin.close()
            except OSError:
                pass
        left = []
        for w in workers:
            try:
                w.wait(timeout=5)
            except subprocess.TimeoutExpired:
                w.terminate()
                w.wait(timeout=5)
                left.append(w.pid)
        print("under-load: %d workers stopped%s" % (len(workers), (" (terminated: %s)" % left) if left else ""),
              file=sys.stderr, flush=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
