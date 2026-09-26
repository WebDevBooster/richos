#!/usr/bin/env python3
"""Own test processes through normal completion, timeouts and caller death.

`run OWNER -- COMMAND` starts a separate supervisor. It registers the child before
allowing exec, retains birth identities and process groups and tags descendants with
an inherited random scope. It cleans on normal exit too. A killed caller leaves the
supervisor holding any inherited worker leases until cleanup finishes.

`kill PID` is the legacy snapshot-based fallback. It cannot recover a process which
already detached and was reparented before the snapshot. New runners use `run`.

This is cooperative supervision, not an OS container. macOS hides environment tags
on SIP-protected binaries, so tracked ancestry and groups remain necessary. A program
that immediately double-forks, creates a new session and strips its inherited scope
can escape discovery. Deliberate destruction of the supervisor itself also requires
an external OS boundary. Do not claim isolation against arbitrary untrusted programs.
"""
import os
import resource
import uuid
import signal
import subprocess
import sys
import time
import operator_fences


def snapshot():
    """{pid: (ppid, pgid)} for every process, from one `ps` call."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,pgid="], capture_output=True, text=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 3 and all(p.isdigit() for p in parts):
            pid, ppid, pgid = (int(p) for p in parts)
            table[pid] = (ppid, pgid)
    return table


def members(root, table=None):
    """(pids, groups): the root, its descendants, and the groups they are in (minus our own)."""
    table = table if table is not None else snapshot()
    children = {}
    for pid, (ppid, _pgid) in table.items():
        children.setdefault(ppid, []).append(pid)
    pids, stack = set(), [root]
    while stack:
        p = stack.pop()
        if p in pids:
            continue
        pids.add(p)
        stack.extend(children.get(p, []))
    own = os.getpgid(0)
    groups = {table[p][1] for p in pids if p in table} - {own, 0, 1}
    # Everything in those groups, including members re-parented to init before the snapshot.
    pids |= {pid for pid, (_pp, pg) in table.items() if pg in groups}
    pids.discard(os.getpid())
    return pids, groups


def _send(pids, groups, sig, table=None):
    """Each process gets the signal ONCE: through its group when its group is one of ours,
    directly otherwise. A second SIGTERM landing while a shell runs its EXIT trap (the first
    one's) kills it mid-trap, and the trap's cleanup is lost — measured, 1 run in 11 of
    mutation-focus.test.sh F1c before this was one signal per process."""
    table = table if table is not None else snapshot()
    for g in groups:
        try:
            os.killpg(g, sig)
        except (ProcessLookupError, PermissionError):
            pass
    for p in pids:
        if p in table and table[p][1] in groups:
            continue
        try:
            os.kill(p, sig)
        except (ProcessLookupError, PermissionError):
            pass


def _alive(pids):
    pids = set(pids)
    if not pids:
        return []
    # Unreadable native identities are common for other users' processes, not
    # an exceptional one-PID case. One status snapshot preserves zombie/exit
    # handling without spawning a ps child for every such process on every tick.
    result = subprocess.run(["ps", "-o", "pid=,stat=", "-p", ",".join(map(str, sorted(pids)))],
                            capture_output=True, text=True, timeout=10)
    if result.returncode not in (0, 1) or (result.returncode == 0 and not result.stdout.strip()):
        raise RuntimeError("cannot read owned process states")
    left = []
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2 or not fields[0].isdigit() or int(fields[0]) not in pids:
            raise RuntimeError("invalid process state snapshot")
        if not fields[1].startswith("Z"):
            left.append(int(fields[0]))
    return left


def kill_tree(root, grace=3.0):
    table = snapshot()
    pids, groups = members(root, table)
    if not pids:
        return []
    _send(pids, groups, signal.SIGTERM, table)
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline and _alive(pids):
        time.sleep(0.1)
    # Anything spawned since the first snapshot, in the same groups, goes too.
    later = snapshot()
    pids |= {pid for pid, (_pp, pg) in later.items() if pg in groups}
    pids.discard(os.getpid())
    _send(pids, groups, signal.SIGKILL, later)
    time.sleep(0.2)
    return _alive(pids)


SCOPE_ENV = "RICHOS_PROCESS_SCOPE"


def python_command():
    flags = (["-S"] if sys.flags.no_site else []) + (["-s"] if sys.flags.no_user_site else [])
    return [sys.executable, *flags]


def command(argv, owner=None, verification=None):
    """A separate supervisor survives the caller's SIGKILL and owns normal-exit cleanup too."""
    options = ["--verification", str(verification)] if verification else []
    return [*python_command(), os.path.abspath(__file__), "run", str(owner or os.getpid()), *options, "--", *map(str, argv)]


def identity(pid):
    row = operator_fences.proc(pid, precise=True)
    return row["start"] if row and not row["zombie"] else None


def process_rows():
    """Topology plus native birth generations, without a subprocess per identity.

    Keep unreadable rows in the topology so an owned process with an unknown
    generation causes a visible failure instead of disappearing from cleanup.
    """
    result = subprocess.run(["ps", "-ax", "-o", "pid=,ppid=,pgid="],
                            capture_output=True, text=True, timeout=10, check=True)
    table = {}
    unknown = set()
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 3 or not all(field.isdigit() for field in fields):
            continue
        pid, parent, group = map(int, fields)
        row = operator_fences.proc(pid, precise=True)
        if row and row["zombie"]:
            continue
        if row is None:
            # libproc can return ESRCH for an unreaped zombie while kill(pid, 0)
            # still succeeds. Batch the status check for all unreadable rows.
            unknown.add(pid)
        table[pid] = ((row["ppid"], row["pgid"], row["start"]) if row
                      else (parent, group, None))
    for pid in unknown - set(_alive(unknown)):
        del table[pid]
    return table


def scoped_members(scope):
    """Inherited random scope finds detached, reparented descendants. Never print environments."""
    result = subprocess.run(["ps", "-Eww" if sys.platform == "darwin" else "eww", "-ax", "-o", "uid=,pid=,command="],
                            capture_output=True, text=True, timeout=10)
    if result.returncode:
        raise RuntimeError("cannot inspect owned processes: ps failed")
    found = set()
    for line in result.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) != 3 or parts[0] != str(os.getuid()):
            continue
        for field in parts[2].split():
            if field.startswith(SCOPE_ENV + "=") and scope in field.split("=", 1)[1].split(":"):
                found.add(int(parts[1]))
    found.discard(os.getpid())
    return found


class TrackedTree:
    """Retain birth identities before any parent exits, including protected macOS binaries.

    macOS hides environments of SIP-protected executables. Parent links and process
    groups complement inherited scope tags; no process names or executable paths grant ownership.
    """
    def __init__(self, root, scope):
        self.root, self.scope, self.known = root, scope, {}
        self.root_birth = identity(root)
        if self.root_birth is None:
            raise RuntimeError("cannot establish owned root generation: %s" % root)
        self.groups = {}
        self.empty_groups = set()
        self.refresh()

    def refresh(self, tags=False):
        table = process_rows()
        for pid in self.known:
            if pid in table and table[pid][2] is None:
                raise RuntimeError("owned process generation is unreadable: %s" % pid)
        owned = {pid for pid, birth in self.known.items() if pid in table and table[pid][2] == birth}
        if self.root in table and table[self.root][2] == self.root_birth:
            owned.add(self.root)
        # A short-lived shell may exit between samples while its background child
        # retains the original group. Keep that group until empty, rejecting a reused leader PID.
        empty = {g for g in self.groups if not any(row[1] == g for row in table.values())}
        self.groups = {g: birth for g, birth in self.groups.items()
                       if (g not in table or table[g][2] == birth)
                       and not (g in empty and g in self.empty_groups)}
        self.empty_groups = empty
        owned |= {p for p, row in table.items() if row[1] in self.groups}
        if tags:
            owned |= scoped_members(self.scope)
        while True:
            groups = {table[p][1] for p in owned if p in table} - {os.getpgrp(), 0, 1}
            more = {pid for pid, (parent, group, _) in table.items() if parent in owned or group in groups}
            if more <= owned:
                break
            owned |= more
        for pid in owned:
            if pid in table:
                if table[pid][2] is None:
                    raise RuntimeError("owned process generation is unreadable: %s" % pid)
                group = table[pid][1]
                if group in table and group not in (os.getpgrp(), 0, 1):
                    self.groups[group] = table[group][2]
        self.known = {pid: table[pid][2] for pid in owned if pid in table and pid != os.getpid()}
        return set(self.known)


def finish_scope(child, tracker, grace=8.0):
    """Re-scan while stopping so a TERM trap cannot fork an uncounted survivor."""
    deadline = time.monotonic() + grace
    killed_at = deadline + 3.0
    initial = True
    empty = False
    while True:
        child.poll()
        alive = set(_alive(tracker.refresh(tags=True)))
        if not alive:
            # Topology and native identities are two observations. A parent can
            # fork and exit between them. Confirm absence in a subsequent sample
            # before releasing the permits that cover its background child.
            if empty:
                return []
            empty = True
            time.sleep(0.05)
            continue
        empty = False
        hard = time.monotonic() >= deadline
        # Signal the original tree once. A shell's EXIT trap may start cleanup
        # commands during the grace period; terminating those immediately defeats
        # cooperative cleanup. Track them and kill any survivors at the deadline.
        for pid in alive if hard or initial else ():
            try:
                if identity(pid) == tracker.known.get(pid):
                    os.kill(pid, signal.SIGKILL if hard else signal.SIGTERM)
            except ProcessLookupError:
                pass
        initial = False
        if time.monotonic() >= killed_at:
            return sorted(alive)
        time.sleep(0.05)


def supervise(owner, argv, deadline=None, timeout_marker=None, verification=None):
    # Enroll managed workloads even when invoked by Codex or a nightly without
    # Claude hooks. Fixtures copying just this helper keep working unchanged.
    guard_path = os.path.join(os.path.dirname(__file__), "cpu_guard.py")
    client = None
    if verification:
        import cpu_guard
        client = cpu_guard.VerificationClient(verification)
    elif os.path.isfile(guard_path) and not os.environ.get('RICHOS_VERIFICATION_OWNER'):
        import cpu_guard
        import pwd
        if (os.path.realpath(os.path.expanduser("~")) == pwd.getpwuid(os.getuid()).pw_dir
                and not os.environ.get("CLAUDE_CONFIG_DIR") and cpu_guard.healthy()):
            cpu_guard.register(os.getpid(), "managed " + os.path.basename(argv[0]), "session")
    owner_id = identity(owner)
    if owner_id is None:
        return 125
    scope = uuid.uuid4().hex
    inherited = os.environ.get(SCOPE_ENV, "")
    env = {**os.environ, SCOPE_ENV: (inherited + ":" if inherited else "") + scope}
    if client:
        env['RICHOS_VERIFICATION_OWNER'] = '%s:%s' % (client.pid, client.generation)
    interrupted = []
    def stop(signum, _frame):
        interrupted.append(signum)
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, stop)
    read_fd, write_fd = os.pipe()
    bootstrap = ("import os,sys,signal; fd=int(sys.argv[1]); ready=os.read(fd,1); os.close(fd); "
                 "ready == b'1' or sys.exit(125); "
                 "argv=sys.argv[2:];\n"
                 "for name in ('SIGPIPE','SIGXFZ','SIGXFSZ'):\n"
                 " if hasattr(signal,name): signal.signal(getattr(signal,name),signal.SIG_DFL)\n"
                 "try: os.execvpe(argv[0],argv,os.environ)\n"
                 "except OSError as e: print('could not start: '+str(e),file=sys.stderr); sys.exit(127)")
    try:
        child = subprocess.Popen([*python_command(), "-c", bootstrap, str(read_fd), *argv],
                                 env=env, start_new_session=True, pass_fds=(read_fd,))
    except OSError as exc:
        print("could not start: %s" % exc, file=sys.stderr)
        return 127
    os.close(read_fd)
    tracker = None
    rc = 125
    started = time.monotonic()
    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    try:
        tracker = TrackedTree(child.pid, scope)
        if client:
            client.start(child.pid)
        os.write(write_fd, b"1")
        os.close(write_fd)
        write_fd = None
        while child.poll() is None:
            tracker.refresh()
            if client:
                client.check_health()
            if interrupted or identity(owner) != owner_id:
                rc = 128 + interrupted[0] if interrupted else 125
                break
            if deadline is not None and time.monotonic() - started >= deadline:
                if timeout_marker:
                    with open(timeout_marker, "x"):
                        pass
                rc = 124
                break
            time.sleep(0.2)
        else:
            rc = child.returncode
    except BlockingIOError as exc:
        print('verification admission refused: %s' % exc, file=sys.stderr)
        rc = 75
    except (RuntimeError, ValueError, OSError) as exc:
        print('verification supervision failed: %s' % exc, file=sys.stderr)
        rc = 125
    finally:
        if write_fd is not None:
            os.close(write_fd)  # A child not yet enrolled exits without executing.
        left = finish_scope(child, tracker) if tracker else []
        if left:
            print("process cleanup failed; owned survivors: %s" % left, file=sys.stderr)
            rc = 125
        try:
            child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            rc = 125
        if client:
            after = resource.getrusage(resource.RUSAGE_CHILDREN)
            client.finish(rc if rc >= 0 else 128 - rc, left,
                          after.ru_utime + after.ru_stime - before.ru_utime - before.ru_stime)
    return rc if rc >= 0 else 128 - rc


def main(argv):
    if len(argv) >= 4 and argv[0] == "run" and "--" in argv:
        import argparse
        import math
        parser = argparse.ArgumentParser(prog="proc_tree.py run")
        parser.add_argument("owner", type=int)
        parser.add_argument("--deadline", type=float)
        parser.add_argument("--timeout-marker")
        parser.add_argument("--verification")
        split = argv.index("--")
        args = parser.parse_args(argv[1:split])
        if args.deadline is not None and (not math.isfinite(args.deadline) or args.deadline <= 0):
            parser.error("deadline must be finite and positive")
        try:
            return supervise(args.owner, argv[split + 1:], args.deadline, args.timeout_marker, args.verification)
        except (RuntimeError, ValueError, OSError) as exc:
            print('process supervision unavailable: %s' % exc, file=sys.stderr)
            return 125
    if len(argv) >= 2 and argv[0] in ("kill", "members") and argv[1].isdigit():
        root = int(argv[1])
        if argv[0] == "members":
            pids, _groups = members(root)
            print("\n".join(str(p) for p in sorted(pids)))
            return 0
        grace = 3.0
        if "--grace" in argv:
            grace = float(argv[argv.index("--grace") + 1])
        left = kill_tree(root, grace)
        if left:
            print("proc_tree.py: still alive after SIGKILL: %s" % " ".join(str(p) for p in left), file=sys.stderr)
            return 1
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
