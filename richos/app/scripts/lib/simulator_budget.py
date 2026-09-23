#!/usr/bin/env python3
"""Machine-wide simulator limits: two live test devices and one boot at a time.

A simulator is an OS service tree, not one worker. Keep resource leases through
shutdown, across checkouts and independent proof/nightly runs. Boot admission
also measures the host; worker availability alone cannot admit a boot storm.
"""
import os
from pathlib import Path
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "testvm"))
sys.path.insert(0, str(HERE.parents[2] / "engine/scripts/lib"))
import reserve
import worker_tokens


def boot_admitted(sample):
    return not reserve._refusal(sample, 80, 16) and sample["cpu_user_percent"] + sample["cpu_system_percent"] < 90


def acquire(kind, timeout=1800, sampler=None):
    directory = Path(worker_tokens.machine_directory()).parent / ("simulator-" + kind + "-v1")
    worker_tokens.init(directory, 2 if kind == "live" else 1)
    budget = worker_tokens.Budget(directory, runner=True, shared=False)
    deadline = time.monotonic() + timeout
    sample = sampler or reserve.host_sample
    while time.monotonic() < deadline:
        token = budget.try_acquire()
        if token is None:
            time.sleep(.2)
            continue
        try:
            if kind == "live" or boot_admitted(sample()):
                return token
        except BaseException:
            token.release()
            raise
        token.release()
        print("simulator-budget: boot waits for CPU/memory headroom", flush=True)
        time.sleep(min(30, max(0, deadline - time.monotonic())))
    raise TimeoutError("simulator %s admission exceeded %gs" % (kind, timeout))


def main(argv):
    if len(argv) < 3 or argv[0] not in ("live", "boot") or argv[1] != "--":
        print("usage: simulator_budget.py live|boot -- COMMAND ...", file=sys.stderr)
        return 64
    return worker_tokens.run_command(argv[2:], acquire(argv[0]), worker=False)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
