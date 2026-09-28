#!/usr/bin/env python3
"""The test agent's work for the pause acceptance test (pause-acceptance.py).

Harmless and self-contained: it writes only inside --dir, starts nothing, reads
nothing else, and needs no network.

  count --dir D [--ticks N]
      The long-running counter. Every tick it spends a little CPU (so a freeze is
      measurable), then appends one line to D/progress.log:
          <epoch seconds> <pid> <n> <hash>
      where hash(n) = sha256(hash(n-1) + str(n)) from a fixed seed. So the harness
      can prove the SAME process continued from the SAME point: one pid throughout,
      n rising by exactly one, and an unbroken hash chain (a restart begins again at
      n=1; a lost step breaks the chain).

  step --dir D [--seconds S]
      One of the agent's own commands. It appends "<epoch> <pid> start" to
      D/commands.log the moment it runs, waits S seconds, and prints the counter.
      A command started while the agent is held runs, and so logs, only after RESUME.
"""
import argparse
import hashlib
import os
import sys
import time

SEED = b"richos-pause-acceptance"
TICK_SECONDS = 0.25
BURN_ROUNDS = 60000       # about 20 ms of CPU per tick on this Mac: visible in `ps -o time`


def seed_hash():
    return hashlib.sha256(SEED).hexdigest()


def next_hash(previous, n):
    return hashlib.sha256((previous + str(n)).encode()).hexdigest()


def count(directory, ticks):
    os.makedirs(directory, exist_ok=True)
    h = seed_hash()
    with open(os.path.join(directory, "progress.log"), "a") as out:
        for n in range(1, ticks + 1):
            x = h.encode()
            for _ in range(BURN_ROUNDS):
                x = hashlib.sha256(x).digest()
            h = next_hash(h, n)
            out.write("%.3f %d %d %s\n" % (time.time(), os.getpid(), n, h))
            out.flush()
            time.sleep(TICK_SECONDS)
    return 0


def last_count(directory):
    try:
        with open(os.path.join(directory, "progress.log")) as f:
            lines = f.read().splitlines()
        return int(lines[-1].split()[2]) if lines else 0
    except (OSError, ValueError, IndexError):
        return 0


def step(directory, seconds):
    os.makedirs(directory, exist_ok=True)
    with open(os.path.join(directory, "commands.log"), "a") as out:
        out.write("%.3f %d start\n" % (time.time(), os.getpid()))
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        time.sleep(0.5)
    print("step done: the counter is at %d" % last_count(directory))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("count")
    c.add_argument("--dir", required=True)
    c.add_argument("--ticks", type=int, default=4800)       # about 20 minutes of work
    s = sub.add_parser("step")
    s.add_argument("--dir", required=True)
    s.add_argument("--seconds", type=float, default=60)
    a = p.parse_args(argv)
    if a.cmd == "count":
        return count(a.dir, a.ticks)
    return step(a.dir, a.seconds)


if __name__ == "__main__":
    sys.exit(main())
