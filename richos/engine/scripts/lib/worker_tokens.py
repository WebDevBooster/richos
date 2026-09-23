#!/usr/bin/env python3
"""worker_tokens.py — one budget of concurrent workers for a whole run, nested workers included.

    worker_tokens.py init <dir> <n>          make a budget of n tokens in <dir>
    worker_tokens.py run <dir> -- <cmd...>   wait for a free token, run cmd holding it, exit with
                                             cmd's status; the token is released when this
                                             process ends, however it ends (an flock the kernel
                                             drops, never a file somebody must remember to delete)
    worker_tokens.py held <dir>              how many tokens are held right now

    import: Budget(dir).try_acquire() -> token or None; token.release()

WHY (2026-09-23). proof-run.py limited how many CHECKS ran at once, and a check is not one worker:
an engine shard reaching workspace-spec-fourteen starts a mutation pool of eight suites of its own,
so "ten checks at once" could be eighty processes. The runner now holds one token per check it
starts, and exports RICHOS_WORKER_TOKENS=<dir>; a nested pool (scripts/lib/mutation-pool.sh) runs
its first worker on its parent's token and takes a token of this budget for every worker beyond
that. So the total is bounded by the budget however deep the nesting, and nothing can deadlock:
every check can always make progress one worker at a time on the token it already holds.

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
    def __init__(self, directory):
        self.dir = directory
        self.files = sorted(os.path.join(directory, f) for f in os.listdir(directory) if f.startswith("token-"))
        if not self.files:
            raise ValueError("no tokens in %s; make them with `worker_tokens.py init`" % directory)

    def try_acquire(self):
        for path in self.files:
            fd = os.open(path, os.O_RDWR)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(fd)
                continue
            return Token(fd, path)
        return None

    def acquire(self):
        while True:
            t = self.try_acquire()
            if t:
                return t
            time.sleep(POLL_SECONDS)

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
    if len(argv) == 3 and argv[0] == "init":
        init(argv[1], argv[2])
        return 0
    if len(argv) == 2 and argv[0] == "held":
        print(Budget(argv[1]).held())
        return 0
    if len(argv) >= 4 and argv[0] == "run" and argv[2] == "--":
        token = Budget(argv[1]).acquire()
        # The child must not inherit the token's descriptor: if it outlived this process it would
        # keep the token held after the work it was counted for had ended.
        rc = subprocess.run(argv[3:], pass_fds=()).returncode
        token.release()
        return rc if rc >= 0 else 128 - rc
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
