#!/usr/bin/env python3
"""stop-at-line.py — run a command, and stop it the moment its output shows a named line.

    stop-at-line.py --out <file> --line <text> --marker <file> -- <command> [args...]

The command's stdout and stderr go to --out, exactly as `cmd >out 2>&1` would put them.
While it runs, --out is read as it grows. The first complete line CONTAINING --line (a
fixed string, never a pattern) ends the run: the marker file is written, the command's
whole process group gets SIGTERM, then SIGKILL after a grace period, and this exits 0.
If the command ends first, this exits with the command's own exit status and writes no
marker, so a caller that sees no marker judges the run exactly as it would have without
this helper.

WHY IT EXISTS (2026-09-23). The mutation harness (mutation-harness.sh) proves a property
is load-bearing by removing it and watching ONE named case go red. For a suite whose
checks run in sequence and share one sandbox — workspace-spec-fourteen.test.sh, measured
at 84 s a run, 86 mutants — every mutant ran the whole suite even though its verdict was
settled at the named line, on average about 40% of the way in. The rest of the run could
only print more lines nobody reads. A harness opts in with `mutation_focus stop-at-want`,
which is a claim about ITS suite: a printed `FAIL  <case>` line always ends the run red.

What is stopped is the command's whole tree (scripts/lib/proc_tree.py: every descendant and
every group they are in), never a pid chosen by name. The command runs in a session of its own,
so a signal to THIS process's group does not reach it by itself; this process therefore
forwards SIGTERM, SIGINT and SIGHUP as a kill of that tree before it exits, which is what lets
ci-shard.sh's deadline, or an interrupt, take a mutant's suite down with the harness.
"""
import argparse
import os
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from proc_tree import kill_tree  # noqa: E402

POLL_SECONDS = 0.1
GRACE_SECONDS = 10


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--out", required=True)
    p.add_argument("--line", required=True)
    p.add_argument("--marker", required=True)
    p.add_argument("command", nargs=argparse.REMAINDER)
    a = p.parse_args()
    cmd = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not cmd or not a.line:
        p.error("a command and a non-empty --line are required")
    needle = a.line.encode()
    with open(a.out, "wb") as out:
        child = subprocess.Popen(cmd, stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                 start_new_session=True)

    def forward(signum, _frame):
        kill_tree(child.pid, GRACE_SECONDS)
        child.wait()
        sys.exit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, forward)
    pending = b""
    with open(a.out, "rb") as reader:
        while True:
            rc = child.poll()
            chunk = reader.read()
            if chunk:
                pending += chunk
                *lines, pending = pending.split(b"\n")
                if any(needle in line for line in lines):
                    return stop(child, a.marker)
            if rc is not None:
                # One last read: the command may have written its final line and exited
                # between the read above and the poll.
                tail = pending + reader.read()
                if needle in tail:
                    return stop(child, a.marker)
                return rc if rc >= 0 else 128 - rc
            time.sleep(POLL_SECONDS)


def stop(child, marker):
    with open(marker, "w") as fh:
        fh.write("stopped at the named line\n")
    # TERM to the whole tree (EXIT traps run), KILL after the grace for whatever ignored it.
    kill_tree(child.pid, GRACE_SECONDS)
    child.wait()
    return 0


if __name__ == "__main__":
    sys.exit(main())
