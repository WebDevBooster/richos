#!/usr/bin/env python3
"""worker_tokens.py — one budget of concurrent workers for a whole run, nested workers included.

    worker_tokens.py init <dir> <n>          make a budget of exactly n tokens in <dir>
    worker_tokens.py run <dir> -- <cmd...>   wait for a free token, run cmd holding it, exit with
                                             cmd's status; the token is released when this
                                             process ends, however it ends (an flock the kernel
                                             drops, never a file somebody must remember to delete)
    worker_tokens.py run <dir> --free <lock> -- <cmd...>
                                             the same, but <lock> (the caller's own free slot) is
                                             tried first and taken instead of a budget token
    worker_tokens.py held <dir>              how many tokens are held right now

    import: Budget(dir, reserved=R).try_acquire() -> token or None; .acquire(free=...) waits;
            token.release(); .held(); .waiting()

WHY (2026-09-23). proof-run.py limited how many CHECKS ran at once, and a check is not one worker:
an engine shard reaching workspace-spec-fourteen starts a mutation pool of eight suites of its own,
so "ten checks at once" could be eighty processes. The runner now holds one token per check it
starts, and exports RICHOS_WORKER_TOKENS=<dir>; a nested pool (scripts/lib/mutation-pool.sh) runs
one worker at a time on its caller's token (the pool's free slot, whichever worker holds it now)
and takes a token of this budget for every other worker. So the total is bounded by the budget
however deep the nesting, and nothing can deadlock: every check can always make progress one
worker at a time on the token it already holds.

A RESERVE FOR CHECKS NOT YET STARTED. With the whole budget open to nested workers, four mutation
pools wanting eight workers each took every token the moment one was freed, and the runner could
not start a single further check until every pool had drained: in the third full run
native-ios-share waited 2519 s to start. So the last RICHOS_WORKER_TOKENS_RESERVED tokens (set by
the runner) are never taken by a nested worker; only the runner starts checks on them, and only
once the shared ones are all held, so a light check can always start and finish beside the pools.

Tokens are files locked with flock(2): a crashed or killed holder releases its token with its
last file descriptor. No token is ever handed out by name or reclaimed by guessing.

This is a budget for ONE run. A budget shared by separate simultaneous runs (another agent's, the
nightly's) is a larger design; a directory of lock files is its natural seed, not an obstacle.
"""
import fcntl
import os
import subprocess
import sys
import time

POLL_SECONDS = 0.2


class Token:
    def __init__(self, fd, path):
        self.fd, self.path = fd, path

    def release(self):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None


class Budget:
    def __init__(self, directory, reserved=0, runner=False):
        """`reserved` tokens at the end of the budget are the runner's alone. `runner=True` is the
        runner itself: every token is open to it, the shared ones first, so the reserved ones
        are left for the moments nested workers hold all the rest."""
        self.dir = directory
        self.files = sorted(os.path.join(directory, f) for f in os.listdir(directory) if f.startswith("token-"))
        if not self.files:
            raise ValueError("no tokens in %s; make them with `worker_tokens.py init`" % directory)
        reserved = max(0, min(int(reserved), len(self.files) - 1))
        if runner:
            self.usable = list(self.files)
        else:
            self.usable = self.files[:len(self.files) - reserved]

    def try_acquire(self):
        for path in self.usable:
            fd = os.open(path, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(fd)
                continue
            return Token(fd, path)
        return None

    def acquire(self, free=None):
        """Wait for a token. With `free` (a lock file of the caller's own), that lock is tried
        first and taken instead of a budget token when it is free: it is the ONE worker a nested
        pool runs on its caller's token, held by whichever of its workers holds the lock now —
        not by the first worker ever submitted, which starved every later worker of the pool
        in the second full run (2026-09-23: workspaces.test.sh at one worker for 40 minutes).
        While waiting, a `wait-<pid>` marker says so (Budget.waiting, for the run's report)."""
        t = self._try_free(free) or self.try_acquire()
        if t:
            return t
        marker = os.path.join(self.dir, "wait-%d" % os.getpid())
        open(marker, "w").close()
        try:
            while True:
                t = self._try_free(free) or self.try_acquire()
                if t:
                    return t
                time.sleep(POLL_SECONDS)
        finally:
            try:
                os.remove(marker)
            except OSError:
                pass

    @staticmethod
    def _try_free(path):
        if not path:
            return None
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return None
        return Token(fd, path)

    def held(self):
        n = 0
        for path in self.files:
            fd = os.open(path, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(fd, fcntl.LOCK_UN)
            except BlockingIOError:
                n += 1
            finally:
                os.close(fd)
        return n

    def waiting(self):
        """How many nested workers are waiting for a token right now (markers of live pids)."""
        n = 0
        for f in os.listdir(self.dir):
            if f.startswith("wait-") and f[5:].isdigit():
                try:
                    os.kill(int(f[5:]), 0)
                    n += 1
                except ProcessLookupError:
                    try:
                        os.remove(os.path.join(self.dir, f))
                    except OSError:
                        pass
                except PermissionError:
                    n += 1
        return n


def init(directory, n):
    """Exactly n tokens in <directory>: made if missing, extras beyond n removed."""
    n = int(n)
    if n < 1:
        raise ValueError("a budget needs at least one token")
    os.makedirs(directory, exist_ok=True)
    for i in range(n):
        open(os.path.join(directory, "token-%03d" % i), "a").close()
    for f in os.listdir(directory):
        if f.startswith("token-") and f[6:].isdigit() and int(f[6:]) >= n:
            os.remove(os.path.join(directory, f))


def main(argv):
    reserved = os.environ.get("RICHOS_WORKER_TOKENS_RESERVED", "0")
    reserved = int(reserved) if reserved.isdigit() else 0
    if len(argv) == 3 and argv[0] == "init":
        init(argv[1], argv[2])
        return 0
    if len(argv) == 2 and argv[0] == "held":
        print(Budget(argv[1]).held())
        return 0
    free = None
    if len(argv) >= 6 and argv[0] == "run" and argv[2] == "--free" and argv[4] == "--":
        free, cmd = argv[3], argv[5:]
    elif len(argv) >= 4 and argv[0] == "run" and argv[2] == "--":
        cmd = argv[3:]
    else:
        print(__doc__, file=sys.stderr)
        return 2
    token = Budget(argv[1], reserved).acquire(free=free)
    # The token's descriptor is not inherited (Python opens it close-on-exec): if the child
    # outlived this process it must not keep a token held after its counted work had ended.
    rc = subprocess.run(cmd).returncode
    token.release()
    return rc if rc >= 0 else 128 - rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
