#!/usr/bin/env python3
"""Own a native provider group even if the desktop disappears without running Drop.

The desktop creates this process as its group leader. The provider inherits its
stdio unchanged. Parent death is observed from the OS, never from a timeout on
model activity. No persistent job or automatic restart is created.
"""
import os
import signal
import sys
import time


def main():
    if len(sys.argv) < 2 or os.getpgrp() != os.getpid():
        raise SystemExit("provider supervisor requires an executable and its own process group")
    parent = os.getppid()
    if parent <= 1:
        raise SystemExit("provider supervisor has no desktop owner")
    provider = os.fork()
    if provider == 0:
        os.environ["RICHOS_SESSION_PID"] = str(os.getpid())
        try:
            os.execvp(sys.argv[1], sys.argv[1:])
        except OSError as error:
            print(f"Provider could not start: {error}", file=sys.stderr, flush=True)
            os._exit(127)
    try:
        while os.getppid() == parent:
            ended, _ = os.waitpid(provider, os.WNOHANG)
            if ended:
                break
            time.sleep(0.1)
    finally:
        # This live group leader reserves the group identity. Include ourselves:
        # no detached watcher can later target a recycled PID or process group.
        os.killpg(os.getpid(), signal.SIGKILL)


# ---------------------------------------------------------------------------
# OPERATOR MODE ONLY: `--reap-descendants` (spec r3 (q) item 2, F5; Frank G8, G9)
# ---------------------------------------------------------------------------
# main() above is the product path, byte-identical and at the same lines as
# before this section existed (other files cite its line numbers). Nothing below
# runs unless the first argument is `--reap-descendants` (spec r3 N1).
#
# WHY. A tool shell of a Claude lead runs in its OWN session and process group
# (measured: shell pid = pgid, tty `??`), so the final `killpg` of this group
# never reaches it. With the flag, this supervisor reads the process table IN
# PROCESS once a second (libproc on macOS, /proc on Linux; never by spawning
# `ps`) and records every descendant of the provider as (pid, start time, pgid),
# and every process group a descendant belongs to. Those are processes its own
# child created: owned, never matched by name.
#
# WHEN THE PROVIDER MUST END (the desktop died, a SIGTERM arrived, or the
# provider exited by itself, G9): a final snapshot, SIGTERM to the provider, a
# wait of OPERATOR_REAP_GRACE seconds (default 5), then SIGKILL to every recorded
# group that still has a recorded member alive or whose leader still has its
# recorded start time, and to every recorded descendant still alive outside those
# groups, checked by start time so a recycled id is never signaled. It re-scans
# and repeats, at most three passes, then ends its own group exactly as main() does.
# Every kill, and anything found alive after the last pass, goes to the operator
# log (RICHOS_OPERATOR_REAP_LOG, else stderr).
#
# FOR THE HOST'S IDLE TEST (G8): with RICHOS_OPERATOR_REAP_STATE set, each
# snapshot writes {"outside_provider_group": [pid, ...]}: descendants alive
# OUTSIDE the provider's own group. Language servers, MCP servers and caffeinate
# share the provider's group and do not count; tool shells and background
# commands have their own groups and do.
#
# THE LIMIT, STATED: a process that detaches itself and starts children, all
# inside the second between two snapshots, can leave those children. A shared
# daemon a lead started (the `adb` server) is killed with that lead. A VM guest a
# lead started is killed mid-boot; its clone on disk is left for the scratch
# reaper (Frank §3).


def _process_table():
    """{pid: (ppid, pgid, start_seconds)} for every process we can read."""
    if sys.platform == "darwin":
        import ctypes

        class Info(ctypes.Structure):
            _fields_ = [("a", ctypes.c_uint32 * 3), ("pid", ctypes.c_uint32), ("ppid", ctypes.c_uint32),
                        ("b", ctypes.c_uint32 * 7), ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32),
                        ("nfiles", ctypes.c_uint32), ("pgid", ctypes.c_uint32), ("c", ctypes.c_uint32 * 3),
                        ("nice", ctypes.c_int32), ("start", ctypes.c_uint64), ("ustart", ctypes.c_uint64)]
        lib = _process_table.lib = getattr(_process_table, "lib", None) or ctypes.CDLL("/usr/lib/libproc.dylib")
        count = lib.proc_listallpids(None, 0)
        pids = (ctypes.c_int * (count + 256))()
        n = lib.proc_listallpids(pids, ctypes.sizeof(pids))
        table, info = {}, Info()
        for pid in pids[:max(0, n)]:
            if pid <= 0:
                continue
            if lib.proc_pidinfo(pid, 3, ctypes.c_uint64(0), ctypes.byref(info), ctypes.sizeof(info)) == 136:
                if int(info.a[1]) != 5:          # pbi_status SZOMB: a zombie is already dead
                    table[pid] = (int(info.ppid), int(info.pgid), int(info.start))
        return table
    table = {}
    try:
        with open("/proc/stat") as fh:
            btime = next(int(l.split()[1]) for l in fh if l.startswith("btime "))
    except (OSError, StopIteration, ValueError):
        btime = 0
    ticks = os.sysconf("SC_CLK_TCK")
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % name) as fh:
                raw = fh.read()
            rest = raw[raw.rindex(")") + 2:].split()
            if rest[0] != "Z":
                table[int(name)] = (int(rest[1]), int(rest[2]), btime + int(rest[19]) // ticks)
        except (OSError, ValueError, IndexError):
            continue
    return table


class Record(object):
    """Everything the provider has ever had below it, with birth identities."""

    def __init__(self, provider, own_group):
        self.provider = provider
        self.own_group = own_group
        self.procs = {}           # pid -> (start, pgid)
        self.groups = {}          # pgid -> leader start (or None when the leader was never seen)

    def snapshot(self, table=None):
        table = _process_table() if table is None else table
        children = {}
        for pid, (ppid, _pg, _st) in table.items():
            children.setdefault(ppid, []).append(pid)
        roots = [self.provider] + list(self.procs)
        stack = [p for p in roots if p in table]
        seen = set()
        while stack:
            pid = stack.pop()
            if pid in seen:
                continue
            seen.add(pid)
            ppid, pgid, start = table[pid]
            known = self.procs.get(pid)
            if known and known[0] != start:
                continue                      # a recycled id: not ours
            if pid != self.provider or not known:
                self.procs[pid] = (start, pgid)
            if pgid not in (self.own_group, 0, 1):
                leader = table.get(pgid)
                self.groups.setdefault(pgid, leader[2] if leader and leader[1] == pgid else None)
            stack.extend(children.get(pid, []))
        # Everything in a recorded group, including members reparented to launchd,
        # but only for a group PROVEN still ours by a live recorded member or by its
        # leader's recorded start. A group id recycled by an unrelated process is
        # never adopted, so it is never signaled either.
        ours = self.live_groups(table)
        for pid, (_ppid, pgid, start) in table.items():
            if pgid in ours and pid not in self.procs:
                self.procs[pid] = (start, pgid)
        return table

    def live_groups(self, table):
        ours = set()
        for pgid, leader_start in self.groups.items():
            if leader_start is not None and pgid in table and table[pgid][2] == leader_start:
                ours.add(pgid)
                continue
            if any(pg == pgid and pid in table and table[pid][2] == start
                   for pid, (start, pg) in self.procs.items()):
                ours.add(pgid)
        return ours

    def outside_provider_group(self, table):
        """G8: descendants still alive OUTSIDE the provider's own group. Language
        servers, MCP servers and caffeinate share the provider's group and do not
        count; tool shells and background commands have their own groups and do."""
        return sorted(pid for pid, (start, pgid) in self.procs.items()
                      if pgid != self.own_group and pid != self.provider and pid in table and table[pid][2] == start)


def _log(line):
    path = (os.environ.get("RICHOS_OPERATOR_REAP_LOG") or "").strip()
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    text = "%s provider-supervisor[%d]: %s\n" % (stamp, os.getpid(), line)
    try:
        if path:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(text)
        else:
            sys.stderr.write(text)
            sys.stderr.flush()
    except OSError:
        pass


def _write_state(record, table):
    path = (os.environ.get("RICHOS_OPERATOR_REAP_STATE") or "").strip()
    if not path:
        return
    try:
        import json
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"provider": record.provider, "own_group": record.own_group, "at": time.time(),
                       "outside_provider_group": record.outside_provider_group(table)}, fh)
        os.replace(tmp, path)
    except OSError:
        pass


def _grace():
    try:
        return max(0.0, float(os.environ.get("OPERATOR_REAP_GRACE") or 5))
    except ValueError:
        return 5.0


def reap(record, provider_running):
    """The sequence of (q) item 2. Returns the pids found alive after the last pass."""
    table = record.snapshot() if provider_running else _process_table()
    if provider_running:
        try:
            os.kill(record.provider, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + _grace()
        while time.monotonic() < deadline:
            try:
                ended, _ = os.waitpid(record.provider, os.WNOHANG)
            except ChildProcessError:
                ended = record.provider
            if ended:
                break
            time.sleep(0.05)
    killed = []
    for _pass in range(3):
        table = _process_table()
        record.snapshot(table)
        # A group is signaled only while a recorded member is alive with its
        # recorded start, or its leader is: a group with neither is never hit.
        targets = [("group", pgid) for pgid in sorted(record.live_groups(table))]
        in_groups = {pg for _k, pg in targets}
        for pid, (start, pgid) in sorted(record.procs.items()):
            if pid == os.getpid() or pgid in in_groups or pgid == record.own_group:
                continue
            if pid in table and table[pid][2] == start:
                targets.append(("pid", pid))
        if not targets:
            break
        for kind, ident in targets:
            try:
                (os.killpg if kind == "group" else os.kill)(ident, signal.SIGKILL)
                killed.append("%s %d" % (kind, ident))
            except (ProcessLookupError, PermissionError):
                pass
        time.sleep(0.1)
    try:
        os.waitpid(record.provider, os.WNOHANG)
    except ChildProcessError:
        pass
    table = _process_table()
    left = sorted(pid for pid, (start, pgid) in record.procs.items()
                  if pid in table and table[pid][2] == start and pgid != record.own_group and pid != os.getpid())
    if killed:
        _log("killed %s" % ", ".join(killed))
    if left:
        _log("ALIVE after the last pass: %s" % ", ".join(str(p) for p in left))
    return left


def operator_main(parent, argv):
    terminate = []
    signal.signal(signal.SIGTERM, lambda *_a: terminate.append(True))
    provider = os.fork()
    if provider == 0:
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.environ["RICHOS_SESSION_PID"] = str(os.getpid())
        try:
            os.execvp(argv[0], argv)
        except OSError as error:
            print(f"Provider could not start: {error}", file=sys.stderr, flush=True)
            os._exit(127)
    record = Record(provider, os.getpgrp())
    running = True
    try:
        tick = 0
        while os.getppid() == parent and not terminate:
            ended, _ = os.waitpid(provider, os.WNOHANG)
            if ended:
                running = False           # G9: reap from the last snapshot
                break
            if tick % 10 == 0:
                try:
                    table = record.snapshot()
                    _write_state(record, table)
                except Exception as error:   # noqa: BLE001  never let a read end the watch
                    _log("process table read failed: %s" % error)
            tick += 1
            time.sleep(0.1)
        cause = "the provider exited" if not running else ("SIGTERM" if terminate else "the owner died")
        _log("ending: %s" % cause)
        reap(record, running)
    finally:
        os.killpg(os.getpid(), signal.SIGKILL)


def _entry():
    if len(sys.argv) > 1 and sys.argv[1] == "--reap-descendants":
        argv = sys.argv[2:]
        if not argv or os.getpgrp() != os.getpid():
            raise SystemExit("provider supervisor requires an executable and its own process group")
        parent = os.getppid()
        if parent <= 1:
            raise SystemExit("provider supervisor has no desktop owner")
        return operator_main(parent, argv)
    return main()


if __name__ == "__main__":
    _entry()
