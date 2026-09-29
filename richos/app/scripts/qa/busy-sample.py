#!/usr/bin/env python3
"""busy-sample.py -- run ONE command with every CPU admission sample in it reading a given load.

    busy-sample.py [--busy PERCENT] -- COMMAND [ARG ...]

WHY (2026-09-29). testvm/test/scenario.test.py failed in the land checks of c7491c34 at load
average 20 with `ValueError: invalid literal for int() with base 10: ''` (and on 2026-09-24):
the test ran the real reserve.py, whose admission sample read the whole Mac at 100.0% busy, so
its `--max-cpu 100` run was refused and printed nothing. That verdict came from the host, not
from the test process's clock, so stall-run.py cannot reproduce it, and under-load.py loads the
Mac without making the reading land where the check decides (99.6% admits that run, 100.0%
refuses it). This makes the reading certain and adds no load at all.

WHAT IT DOES. Runs COMMAND with lib/busy-sample first on PYTHONPATH. Its sitecustomize makes
every admission sample `scripts/testvm/reserve.py` takes, in every Python process of COMMAND's
tree that starts normally (not `-S`/`-I`), read PERCENT busy (default 100), memory pressure
normal and no swap-out. A check whose verdict follows the host sample changes with --busy; one
that does not, passes under any value. Exit status: COMMAND's own; 2 on bad usage.

WHAT IT NEVER DOES. It adds no CPU load, takes no lock and does no admission of its own, changes
nothing on the host, and signals no process: COMMAND runs in the foreground and its exit status
comes back. Put it behind `scripts/testvm/reserve.py --` like any test run.
"""
import argparse
import os
import subprocess
import sys


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--busy", type=float, default=100.0, help="total CPU percent every sample reads (0-100)")
    p.add_argument("command", nargs=argparse.REMAINDER)
    a = p.parse_args(argv)
    cmd = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not cmd or not 0 <= a.busy <= 100:
        p.print_usage(sys.stderr)
        return 2
    shim = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "busy-sample")
    inherited = os.environ.get("PYTHONPATH")
    env = dict(os.environ, RICHOS_QA_BUSY_PERCENT=repr(a.busy),
               PYTHONPATH=shim + (os.pathsep + inherited if inherited else ""))
    print("busy-sample: every reserve.py admission sample under this command reads %g%% busy, "
          "memory pressure normal, no swap-out" % a.busy, file=sys.stderr, flush=True)
    return subprocess.call(cmd, env=env)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
