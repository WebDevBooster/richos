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

THE CONTRACT FOR A NESTED WORKER: it passes `--free <a lock of its caller's own>`. A check holds
its token for as long as it runs, so once running checks hold every shared token, a worker that
can only wait for a budget token waits for a check that is waiting for it. The free slot is what
keeps every check moving (proof-run.test.py P12 deadlocked without it; mutation-harness.sh and
native-ios-ui.test.sh both pass one).

Tokens are files locked with flock(2): a crashed or killed holder releases its token with its
last file descriptor. No token is ever handed out by name or reclaimed by guessing.

Each run also acquires from the per-user machine budget. Independent checkouts and nightlies
share that ceiling. A local --capacity can lower a run's limit without resizing shared lock files.
"""
import fcntl
import json
import signal
import os
import subprocess
import sys
import time

POLL_SECONDS = 0.2


class Token:
    def __init__(self, fd, path):
        self.fd, self.path = fd, path
        self.extra = None

    @property
    def fds(self):
        return ([self.fd] if self.fd is not None else []) + (self.extra.fds if self.extra else [])

    def release(self):
        if self.extra:
            self.extra.release()
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None


class Budget:
    def __init__(self, directory, reserved=0, runner=False, shared=None):
        """`reserved` tokens at the end of the budget are the runner's alone. `runner=True` is the
        runner itself: every token is open to it, the shared ones first, so the reserved ones
        are left for the moments nested workers hold all the rest."""
        self.dir = directory
        shared = shared or os.environ.get("RICHOS_MACHINE_WORKERS")
        self.shared = (Budget(shared, reserved, runner, shared=shared)
                       if shared and os.path.realpath(shared) != os.path.realpath(directory) else None)
        self.files = sorted(os.path.join(directory, f) for f in os.listdir(directory) if f.startswith("token-") and f[6:].isdigit())
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
            token = Token(fd, path)
            if self.shared:
                token.extra = self.shared.try_acquire()
                if token.extra is None:
                    token.release()
                    continue
            return token
        return None

    def acquire(self, free=None, timeout=1800):
        """Wait for a token. With `free` (a lock file of the caller's own), that lock is tried
        first and taken instead of a budget token when it is free: it is the ONE worker a nested
        pool runs on its caller's token, held by whichever of its workers holds the lock now —
        not by the first worker ever submitted, which starved every later worker of the pool
        in the second full run (2026-09-23: workspaces.test.sh at one worker for 40 minutes).
        While waiting, a `wait-<pid>` marker says so (Budget.waiting, for the run's report)."""
        if free:
            free = os.environ.get("RICHOS_WORKER_BORROW_LOCK", free)
        t = self._try_free(free) or self.try_acquire()
        if t:
            return t
        deadline = time.monotonic() + timeout
        marker = os.path.join(self.dir, "wait-%d" % os.getpid())
        open(marker, "w").close()
        try:
            while True:
                t = self._try_free(free) or self.try_acquire()
                if t:
                    return t
                if time.monotonic() >= deadline:
                    raise TimeoutError("worker admission timed out after %gs: %s" % (timeout, self.dir))
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
    """Create an immutable budget under an initialization lock. Never unlink a live lease."""
    n = int(n)
    if n < 1:
        raise ValueError("a budget needs at least one token")
    os.makedirs(directory, mode=0o700, exist_ok=True)
    with open(os.path.join(directory, "init.lock"), "a") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        config = os.path.join(directory, "capacity.json")
        if os.path.exists(config):
            with open(config) as existing:
                old = json.load(existing)
            if old != n:
                raise ValueError("budget capacity is immutable (%s, requested %s): %s" % (old, n, directory))
        for i in range(n):
            open(os.path.join(directory, "token-%03d" % i), "a").close()
        with open(config, "w") as out:
            json.dump(n, out)


def machine_directory():
    """One per-user budget across checkouts, runners and nightlies; never release.lock."""
    directory = os.environ.get("RICHOS_MACHINE_WORKERS") or os.path.join(
        os.path.expanduser("~"), ".richos-nightly", "worker-budget-v1")
    # The machine ceiling is independent of a run's smaller --capacity.
    init(directory, max(1, int((os.cpu_count() or 4) * 0.8)))
    return directory


def run_command(cmd, token, env=None):
    # The supervisor inherits the lease. If this wrapper is killed, admission cannot
    # reuse that slot until the supervisor has stopped the command's descendants.
    import proc_tree
    env = {**(env if env is not None else os.environ), "RICHOS_WORKER_SLOT_HELD": "1",
           "RICHOS_WORKER_BORROW_LOCK": token.path + ".child"}
    try:
        child = subprocess.Popen(proc_tree.command(cmd, owner=os.getpid()), env=env,
                                 pass_fds=tuple(token.fds), start_new_session=True)
        def stop(signum, _frame):
            child.send_signal(signum)
        previous = {sig: signal.signal(sig, stop) for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        try:
            rc = child.wait()
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)
        return rc if rc >= 0 else 128 - rc
    finally:
        token.release()


def lease_worker(directory, owner, ready, release, free):
    """Keep a bash 3.2 pool worker's lease until it finishes or its descendants are cleaned."""
    import proc_tree
    import uuid
    owner = int(owner)
    born = proc_tree.identity(owner)
    if born is None:
        return 125
    scope = uuid.uuid4().hex
    tracker = proc_tree.TrackedTree(owner, scope)
    budget = Budget(directory, int(os.environ.get("RICHOS_WORKER_TOKENS_RESERVED", "0")))
    interrupted = []
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda number, _frame: interrupted.append(number))
    if free != "-":
        free = os.environ.get("RICHOS_WORKER_BORROW_LOCK", free)
    token = None
    deadline = time.monotonic() + 1800
    while token is None:
        if interrupted or proc_tree.identity(owner) != born or time.monotonic() >= deadline:
            return 125
        token = budget._try_free(free if free != "-" else None) or budget.try_acquire()
        if token is None:
            time.sleep(POLL_SECONDS)
    try:
        with open(ready + ".borrow", "w") as out:
            out.write(token.path + ".child")
        with open(ready + ".new", "w") as out:
            out.write(scope)
        os.replace(ready + ".new", ready)
        while not os.path.exists(release) and not interrupted and proc_tree.identity(owner) == born:
            tracker.refresh()
            time.sleep(POLL_SECONDS)
        # The worker waits for us on normal completion. Exclude it from cleanup while
        # retaining its children, including children reparented after an abrupt death.
        class Owner:
            def poll(self):
                return None
        original = tracker.refresh
        def remaining(tags=False):
            return original(tags) - {owner}
        tracker.refresh = remaining
        left = proc_tree.finish_scope(Owner(), tracker)
        return 125 if left else 0
    finally:
        token.release()


def main(argv):
    if argv == ["directory"]:
        print(machine_directory())
        return 0
    if len(argv) == 6 and argv[0] == "lease":
        return lease_worker(*argv[1:])
    if len(argv) >= 3 and argv[:2] == ["machine", "--"]:
        if os.environ.get("RICHOS_WORKER_TOKENS") and os.environ.get("RICHOS_WORKER_SLOT_HELD") == "1":
            import proc_tree
            command = proc_tree.command(argv[2:], owner=os.getppid())
            os.execv(sys.executable, command)
        directory = machine_directory()
        token = Budget(directory, runner=True).acquire()
        env = {**os.environ, "RICHOS_MACHINE_WORKERS": directory,
               "RICHOS_WORKER_TOKENS": directory,
               "RICHOS_WORKER_TOKENS_TOOL": os.path.abspath(__file__),
               "RICHOS_WORKER_TOKENS_RESERVED": str(max(1, len(Budget(directory).files) // 4))}
        return run_command(argv[2:], token, env)
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
    return run_command(cmd, token)



if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
