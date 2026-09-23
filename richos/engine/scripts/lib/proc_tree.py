#!/usr/bin/env python3
"""proc_tree.py — stop a process AND EVERYTHING IT STARTED, including what it started in a group
or session of its own and what was re-parented to init after its parent exited.

    proc_tree.py kill <pid> [--grace SECONDS]   exit 0 when nothing of the tree is left, 1 if
                                                something survived SIGKILL (named on stderr)
    proc_tree.py members <pid>                  the pids the kill would reach, one per line

    import: kill_tree(pid, grace=3.0) -> list of pids still alive afterwards (empty when clean)

WHY (2026-09-23). ci-shard.sh killed a unit at its deadline with `kill -TERM <pid>` and then
`kill -KILL <pid>`: the unit's shell died and its children did not. workspace-spec-fourteen.test.sh
was killed at 3600 s while its mutation harness (pid 97011) kept running under init for about an
hour and a half, spawning test processes and leaving fourteen `sleep 3600`s; it ignored SIGTERM,
and only a SIGKILL of the whole tree stopped it. A pid is the wrong unit to kill. The unit is:

  * every DESCENDANT of the pid, found by walking parent links in one `ps` snapshot taken BEFORE
    any signal is sent (once a parent dies its children are re-parented and the walk loses
    them), and
  * every PROCESS GROUP any of those belongs to, because a background child whose parent already
    exited (`sh -c 'sleep 3600 & echo $!'`) is no longer anyone's descendant but is still in
    its group — except the caller's own group, which is never sent a signal (it would kill the
    caller; a caller that needs its child's group killed starts the child in a group of its own).

Selection is by parentage and group of a pid the caller started, never by a name or a path.
SIGTERM first so EXIT traps run and sandboxes are removed, SIGKILL after the grace for anything
that ignored it, then a second snapshot of the same groups for anything spawned in between.
"""
import os
import signal
import subprocess
import sys
import time


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
    left = []
    for p in pids:
        try:
            os.kill(p, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            pass
        # A zombie is dead: it only waits for its parent to read its status.
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(p)], capture_output=True, text=True).stdout.strip()
        if state and not state.startswith("Z"):
            left.append(p)
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


def main(argv):
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
