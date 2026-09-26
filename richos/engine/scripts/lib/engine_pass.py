#!/usr/bin/env python3
"""Bounded large-plan serialization with main-checkout admission priority.

The threshold is 20 units, not the full inventory. The inherited kernel-held
slot serializes large plans without changing their coverage obligations.
This helper alone is neither a CPU quota nor universal execution enforcement.
"""
import argparse
import fcntl
import json
import os
import signal
import subprocess
import sys
import time

FULL_PASS_UNITS = 20
MAIN_WAIT = 3600
TEAMMATE_WAIT = 1800
POLL_SECONDS = float(os.environ.get("RICHOS_ENGINE_PASS_POLL") or 2.0)   # a suite seam; never tuned
REPORT_EVERY = 60
REFUSED = 75
NEEDED = 10


def directory():
    """The machine's one slot. RICHOS_ENGINE_PASS_DIR is for suites, never for a real run."""
    path = os.environ.get("RICHOS_ENGINE_PASS_DIR")
    if not path:
        if sys.platform == "darwin":
            if not os.path.ismount("/Volumes/E1TB"):
                raise RuntimeError("connect /Volumes/E1TB before starting a large verification plan")
            path = "/Volumes/E1TB/state/richos/engine-pass-v1"
        else:
            path = os.path.join(os.path.expanduser("~"), ".richos-nightly", "engine-pass-v1")
    os.makedirs(path, mode=0o700, exist_ok=True)
    return path


def needs_slot(count):
    return int(count) >= FULL_PASS_UNITS


def _ps_rows():
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,lstart="], capture_output=True, text=True,
                         env={**os.environ, "LC_ALL": "C", "TZ": "UTC0"}, timeout=10)
    rows = {}
    for line in out.stdout.splitlines():
        f = line.split(None, 2)
        if len(f) == 3 and f[0].isdigit() and f[1].isdigit():
            rows[int(f[0])] = (int(f[1]), f[2].strip())
    return rows


def birth(pid, rows=None):
    rows = rows if rows is not None else _ps_rows()
    row = rows.get(int(pid))
    return row[1] if row else None


def _locked(path):
    """True when another open file description holds `path` exclusively. Takes nothing."""
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def holder():
    """The recorded holder, only while the slot is actually held."""
    d = directory()
    if not _locked(os.path.join(d, "slot.lock")):
        return None
    try:
        with open(os.path.join(d, "holder.json")) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"label": "unknown (the slot is held and no holder record was readable)"}


def held_by_ancestor(pid=None):
    """True when the slot is held by this process or one of its ancestors (same PID AND the same
    start time, so a reused PID never counts)."""
    rec = holder()
    if not rec or "pid" not in rec:
        return False
    rows = _ps_rows()
    if birth(rec["pid"], rows) != rec.get("birth"):
        return False
    pid = os.getpid() if pid is None else int(pid)
    seen = set()
    while pid and pid not in seen:
        if pid == rec["pid"]:
            return True
        seen.add(pid)
        row = rows.get(pid)
        if not row:
            return False
        pid = row[0]
    return False


def is_main_checkout(path):
    try:
        out = subprocess.run(["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-dir",
                              "--git-common-dir"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    lines = out.stdout.split()
    return out.returncode == 0 and len(lines) == 2 and os.path.realpath(lines[0]) == os.path.realpath(lines[1])


def _branch(path):
    try:
        out = subprocess.run(["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip() or "?"
    except (OSError, subprocess.TimeoutExpired):
        return "?"


def describe(rec):
    if not rec:
        return "nobody"
    if "pid" not in rec:
        return rec.get("label", "unknown")
    age = time.time() - rec.get("started", time.time())
    return "%s (pid %s, %s, %s, %s units, for %.0f s)" % (
        rec.get("label"), rec.get("pid"), "LAND RUN, main checkout" if rec.get("main") else
        "checkout %s" % rec.get("checkout"), "branch %s" % rec.get("branch"), rec.get("count"), age)


class Refused(Exception):
    def __init__(self, waited, rec, count, units, main):
        self.waited, self.rec, self.count, self.units, self.main = waited, rec, count, list(units), main
        super().__init__(self.message())

    def message(self):
        lines = ["engine-pass: REFUSED after %.0f s. The machine's one full-engine-pass slot is held by %s."
                 % (self.waited, describe(self.rec)),
                 "  This run selected %d engine unit(s); %d or more is a full pass, and only one runs on "
                 "this Mac at a time. NOTHING WAS RUN." % (self.count, FULL_PASS_UNITS)]
        if self.main:
            lines.append("  Run it again when that pass ends (engine_pass.py status shows it).")
        else:
            lines.append("  From a teammate's worktree the full pass is the lead's, at land. Verify what you wrote "
                         "with `bash scripts/ci-shard.sh --only-units <unit>` on the units covering it.")
        if self.units:
            lines.append("  The units this run selected:")
            lines.extend("    " + u for u in self.units)
        return "\n".join(lines)


class Slot:
    def __init__(self, fd, waited):
        self.fd, self.waited = fd, waited

    def release(self):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            finally:
                os.close(self.fd)
                self.fd = None


class Admission:
    """Main-checkout waiters hold shared priority; background admission needs exclusive.

    The guard spans the actual permit attempt, closing the check-then-acquire race.
    No queue age can override an integration waiter. Borrowing a caller's already
    held permit remains possible, so nested work can release occupied capacity.
    """
    def __init__(self, root, checkout):
        self.root = os.path.join(root, "admission")
        os.makedirs(self.root, mode=0o700, exist_ok=True)
        self.main = is_main_checkout(checkout)
        self.fd = None
        self.since = None
        self.marker = os.path.join(self.root, "wait-%s-%s.json" % (os.getpid(), id(self)))

    def begin(self):
        if self.fd is not None:
            return True
        fd = os.open(os.path.join(self.root, "priority.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, (fcntl.LOCK_SH if self.main else fcntl.LOCK_EX) | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return False
        self.fd = fd
        if self.since is None:
            self.since = time.monotonic()
            with open(self.marker, "w") as out:
                json.dump({"pid": os.getpid(), "birth": birth(os.getpid()),
                           "main": self.main, "since": time.time()}, out)
        return True

    def attempted(self, acquired):
        # Keep integration intent while its permit is occupied. Background work
        # holds priority only during its attempt, never while queued.
        if acquired or not self.main:
            self.close()

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        try:
            os.unlink(self.marker)
        except FileNotFoundError:
            pass
        self.since = None


def acquire(count, label, checkout, units=(), wait=None, out=None):
    """Wait for the slot, bounded and reported; return a Slot or raise Refused."""
    out = out or sys.stderr
    d = directory()
    main = is_main_checkout(checkout)
    wait = (MAIN_WAIT if main else TEAMMATE_WAIT) if wait is None else float(wait)
    slot = os.open(os.path.join(d, "slot.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    priority = os.path.join(d, "priority.lock")
    prio_fd = None
    if main:
        prio_fd = os.open(priority, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(prio_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:      # another land run already waits first; take turns after it
            os.close(prio_fd)
            prio_fd = None
    marker = os.path.join(d, "wait-%d.json" % os.getpid())
    start = time.monotonic()
    next_report = start
    try:
        while True:
            if main or not _locked(priority):
                try:
                    fcntl.flock(slot, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    pass
            now = time.monotonic()
            if now - start >= wait:
                os.close(slot)
                raise Refused(now - start, holder(), count, units, main)
            if now >= next_report:
                if next_report == start:
                    with open(marker, "w") as fh:
                        json.dump({"pid": os.getpid(), "label": label, "checkout": checkout, "main": main,
                                   "count": count, "since": time.time()}, fh)
                print("engine-pass: waiting %.0f s of at most %.0f s for the one-full-engine-pass slot "
                      "(%d units); held by %s%s" % (now - start, wait, count, describe(holder()),
                                                    "" if main or not _locked(priority)
                                                    else "; a land run is waiting and goes first"),
                      file=out, flush=True)
                next_report += REPORT_EVERY
            time.sleep(POLL_SECONDS)
    finally:
        if prio_fd is not None:
            os.close(prio_fd)
        try:
            os.remove(marker)
        except OSError:
            pass
    rec = {"pid": os.getpid(), "birth": birth(os.getpid()), "label": label, "checkout": checkout,
           "branch": _branch(checkout), "main": main, "count": count, "started": time.time()}
    tmp = os.path.join(d, "holder.json.%d" % os.getpid())
    with open(tmp, "w") as fh:
        json.dump(rec, fh)
    os.replace(tmp, os.path.join(d, "holder.json"))
    waited = time.monotonic() - start
    print("engine-pass: this run holds the machine's one full-engine-pass slot (%d units%s)"
          % (count, ", after waiting %.0f s" % waited if waited >= 1 else ""), file=out, flush=True)
    return Slot(slot, waited)


def status():
    d = directory()
    waiting = []
    for name in sorted(os.listdir(d)):
        if name.startswith("wait-") and name.endswith(".json"):
            try:
                with open(os.path.join(d, name)) as fh:
                    rec = json.load(fh)
                os.kill(int(rec["pid"]), 0)
                waiting.append(rec)
            except (OSError, ValueError, KeyError):
                continue
    return {"threshold": FULL_PASS_UNITS, "holder": holder(), "waiting": waiting,
            "land_run_waiting": _locked(os.path.join(d, "priority.lock"))}


def hold(argv):
    p = argparse.ArgumentParser(prog="engine_pass.py hold")
    p.add_argument("--count", type=int, required=True)
    p.add_argument("--units", default="")
    p.add_argument("--label", required=True)
    p.add_argument("--checkout", required=True)
    p.add_argument("--wait", type=float)
    if "--" not in argv:
        p.error("hold needs -- CMD...")
    split = argv.index("--")
    a = p.parse_args(argv[:split])
    cmd = argv[split + 1:]
    if not cmd:
        p.error("hold needs a command after --")
    units = [u for u in a.units.split(",") if u]
    try:
        slot = acquire(a.count, a.label, a.checkout, units, a.wait)
    except Refused as r:
        print(r.message(), file=sys.stderr, flush=True)
        return REFUSED
    try:
        # The command inherits the lock's descriptor, so the slot stays held for as long as the
        # pass runs even if this wrapper is killed first; it frees when the last holder exits.
        child = subprocess.Popen(cmd, pass_fds=(slot.fd,))
        def forward(signum, _frame):
            child.send_signal(signum)
        previous = {s: signal.signal(s, forward) for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        try:
            rc = child.wait()
        finally:
            for s, h in previous.items():
                signal.signal(s, h)
        return rc if rc >= 0 else 128 - rc
    finally:
        slot.release()


def main(argv):
    if argv == ["threshold"]:
        print(FULL_PASS_UNITS)
        return 0
    if len(argv) == 2 and argv[0] == "needed" and argv[1].isdigit():
        return NEEDED if needs_slot(int(argv[1])) and not held_by_ancestor() else 0
    if argv == ["held"]:
        return 0 if held_by_ancestor() else 1
    if argv == ["status"]:
        print(json.dumps(status(), indent=1))
        return 0
    if argv[:1] == ["hold"]:
        return hold(argv[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
