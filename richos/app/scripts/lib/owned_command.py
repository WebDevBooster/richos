"""Shared admission-aware command deadline used by commit and nightly checks."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

# Written by the command's first instruction AFTER worker_tokens.py admitted it, and before
# it execs the real command (same pid, so the owned group is unchanged).
ADMITTED_SHIM = ': > "$0" && exec "$@"'
ADMISSION_POLL = 0.1


def owned_run(args, *, library, finish, timeout=None, groups=None, cleanup=False, release_build=False, **kwargs):
    """subprocess.run's result shape with bounded, owned-group cleanup on all exits.

    `groups`, when given, is the run's OwnedGroups: the command is registered there for as
    long as it lives, so a failing gate elsewhere can stop it (Runner.run_gates).

    `release_build` registers the supervisor with the CPU guard as a release build
    instead of a plain session, which gives the compiler under it the guard's longer
    per-process window (cpu_guard.BUILD_WINDOW). Only the build step passes it: on
    2026-09-28 the guard's 10-second rule stopped rustc compiling the app binary at
    4.52 cores after every gate had passed (run 20260928T190111Z-40a16163).

    `timeout` MEASURES EXECUTION, NEVER QUEUEING. Every command first waits in
    worker_tokens.py for one of the machine's worker tokens, and until 2026-09-29 the deadline
    ran from the spawn, so a gate beside the mutation pool spent its budget in the queue: run
    20260929T003824Z-01545196, the UI gate's 30 s `git status` cleanup "timed out" while the
    pool held the tokens. The clock now starts when the command is ADMITTED (the shim above
    writes a marker as its first act under the token), as ci-shard.sh does per unit. The wait
    for a token keeps its own bound: worker_tokens.py gives up after 1800 s and exits 75.
    The result carries `admission_seconds`, `execution_seconds` and `admitted`; so does the
    TimeoutExpired raised when execution runs past `timeout`."""
    worker = library / "worker_tokens.py"
    # The worker wrapper owns its command, but does not watch this coordinator.
    # Keep an independent supervisor tied to our identity around the entire
    # admission/worker lifetime, so even SIGKILL here cancels waiting or active work.
    supervisor = library / "proc_tree.py"
    role = ["--guard-role", "release-build"] if release_build else []
    scratch = Path(tempfile.mkdtemp(prefix="richos-nightly-admission-"))
    marker, timing = scratch / "admitted", scratch / "timing.json"
    started = time.monotonic()
    admitted_at = None

    def admitted():
        nonlocal admitted_at
        if admitted_at is None and marker.exists():
            admitted_at = time.monotonic()
        return admitted_at is not None

    process = None
    try:
        process = subprocess.Popen([sys.executable, str(supervisor), "run", str(os.getpid()), *role, "--",
                                    sys.executable, str(worker), "machine", "--timing", str(timing), "--",
                                    "/bin/sh", "-c", ADMITTED_SHIM, str(marker), *map(str, args)],
                                   start_new_session=True, **kwargs)
        if groups is not None:
            groups.add(process, cleanup)
        while True:
            # Queued: look for the admission marker every ADMISSION_POLL seconds (communicate()
            # keeps draining the pipes meanwhile). Admitted: the rest of the budget, once.
            if not admitted():
                wait = ADMISSION_POLL
            elif timeout is None:
                wait = None
            else:
                wait = max(0.0, admitted_at + timeout - time.monotonic())
            try:
                stdout, stderr = process.communicate(timeout=wait)
                break
            except subprocess.TimeoutExpired:
                # Retrying communicate() after its timeout loses no output (subprocess docs).
                if admitted_at is not None and timeout is not None and \
                        time.monotonic() >= admitted_at + timeout:
                    expired = subprocess.TimeoutExpired(args, timeout)
                    expired.admitted = True
                    expired.admission_seconds = admitted_at - started
                    expired.execution_seconds = time.monotonic() - admitted_at
                    raise expired from None
        result = subprocess.CompletedProcess(args, process.returncode, stdout, stderr)
        ended = time.monotonic()
        admitted()
        try:
            row = json.loads(timing.read_text())
            result.admitted = bool(row["admitted"])
            result.admission_seconds = float(row["admission_seconds"])
            result.execution_seconds = float(row["execution_seconds"])
        except (OSError, ValueError, KeyError, TypeError):
            result.admitted = admitted_at is not None
            result.admission_seconds = (admitted_at or ended) - started
            result.execution_seconds = ended - admitted_at if admitted_at is not None else 0.0
        return result
    finally:
        try:
            if process is not None:
                finish(process)
        finally:
            if groups is not None and process is not None:
                groups.discard(process)
            if process is not None:
                for stream in (process.stdout, process.stderr):
                    if stream is not None:
                        stream.close()
            shutil.rmtree(scratch, ignore_errors=True)

