#!/usr/bin/env python3
"""Hold an agent's running commands when it is paused; continue them on RESUME.

A pause is a message, and a message reaches an agent only at its next tool call,
so the command it is already running keeps the CPU until it ends. This module
makes the pause take effect at once: it suspends (SIGSTOP) exactly the processes
the paused agent owns and continues (SIGCONT) exactly those on RESUME. Nothing is
terminated, so nothing is lost. Measured on Claude Code 2.1.283: a suspended
foreground command that passes its Bash timeout is moved to the background, not
signaled, and finishes normally once continued.

OWNERSHIP IS CAPTURED AT SPAWN, BY THE PROCESS ITSELF. Every Bash call made by a
subagent is rewritten (shell-evidence.py calls capture()) to write its own `$$`
and `$PPID` into a record keyed by session, agent and tool call, and to export an
inherited owner tag. A process is owned only when it is alive, still has its
recorded parent and started between the hook and the record's write. A reused PID
fails that test. Names, paths and working directories never choose a process.

THE OWNED TREE is those shells, their descendants, the members of process groups
an owned process leads, and processes carrying this agent's own inherited tag
(detached and reparented children). Never pid 1, never the session process, never
this process or its ancestors. A proc_tree.py supervisor inside the tree IS held
with its check (it registers as a cpu_guard "session" root, which protects it from
cpu_guard's CPU kills, not from a pause): left running, it watched a frozen check
and its bounds expired (Sage's catch 2).

SHARED DAEMONS ARE LEFT RUNNING. A tagged process that was reparented to launchd
and leads its own session is a daemon the agent started for everyone (an adb
server, a Gradle daemon): other agents' work talks to it, so freezing it would
hold their work too. It is named in the report. (Sage's catch 5.)

THE TEST VM GUEST IS LEFT RUNNING. A walk that holds a guest slot (its holder
record is validated against the holder's start time) keeps running with
everything under it, and so does every recorded VM process and the run's login
keeper, which run.sh detaches (so neither is under the walk by parent link).
Freezing them would keep a shared slot locked for the whole pause and fail the
walk's own cleanup. The walk ends by itself and releases its slot; its boot,
push and cleanup steps are bounded (480, 120 and 120 s) but its scenario step is
not, and during a quota pause the guest keeps using the quota until it ends.
(Sage's catches 4 and 7.)

NOTHING STAYS FROZEN AFTER ITS LEAD. Every hold starts a watchdog, a detached
process outside every agent's tree. It releases the hold on its own when every
recorded session process is gone (a lead that crashed without SessionEnd: each
Bash shell is a session leader under `claude`, so the kernel never continues its
stopped group) or when the registry records the agent finished (a stop made from
the CEO's screen, which runs no hook). (Sage's catches 6 and 1.)

A PAUSED AGENT WAITS INSIDE ITS RUN. A background subagent that ends its turn
ends its run, and a later message starts a new run (Rich, brief addition 1). The
generated PAUSE therefore tells it to run `agent_hold.py wait`, which returns
RESUMED only once the hold is released; a held agent's new command waits anyway.

KNOWN LIMITS: held work keeps its file locks (the hold report lists the lock
files it has open: a Cargo target lock, a worker token, a git index lock), and a
command started before capture was installed has no record and is not held.
Timers inside held work keep counting unless they use proc_tree.HeldClock.
"""
import argparse
import calendar
import ctypes
import json
import os
import re
import shlex
import signal
import struct
import subprocess
import sys
import time

TAG = "RICHOS_AGENT_OWNER"
SESSION_TAG = "RICHOS_AGENT_SESSION"
ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
BIRTH_SLACK = 1.0          # `ps -o lstart` has one-second resolution
PRUNE_AFTER = 60.0         # a finished call's record is removed after this long
UNSTARTED_AFTER = 3600.0   # a call that never wrote its PID (refused, sandboxed)
STOP_ROUNDS = 10
SETTLE_SECONDS = 2.0
RELEASE_SCANS = 4
RELEASE_SCAN_GAP = 0.25
SLOT_FILES = ("guest.lock", "guest-2.lock")


# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------

def state_dir():
    d = (os.environ.get("RICHOS_AGENT_HOLD_DIR") or "").strip()
    if d:
        return d
    base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "state", "agent-hold")


def _shell_dir(session_id, agent_id):
    return os.path.join(state_dir(), "shells", session_id, agent_id)


def _held_path(session_id, agent_id):
    return os.path.join(state_dir(), "held", "%s__%s.json" % (session_id, agent_id))


def _write_json(path, value):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.%d.new" % (path, os.getpid())
    with open(tmp, "w") as out:
        json.dump(value, out, sort_keys=True)
    os.replace(tmp, path)


def _read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _valid_ids(*values):
    return all(isinstance(v, str) and ID.fullmatch(v) for v in values)


# ---------------------------------------------------------------------------
# capture: called by the PreToolUse[Bash] rewriter for a subagent's call
# ---------------------------------------------------------------------------

def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _prune(directory, now):
    """Remove records of calls that ended. Syscalls only: this runs on every Bash call."""
    try:
        names = os.listdir(directory)
    except OSError:
        return
    for name in names:
        if not name.endswith(".json"):
            continue
        stem = os.path.join(directory, name[:-5])
        try:
            age = now - os.stat(stem + ".json").st_mtime
        except OSError:
            continue
        pid = _read_pid(stem + ".pid")
        if pid is None:
            dead = age > UNSTARTED_AFTER
        else:
            dead = age > PRUNE_AFTER and not _alive(pid[0])
        if dead:
            for suffix in (".json", ".pid"):
                try:
                    os.unlink(stem + suffix)
                except OSError:
                    pass


def capture(payload):
    """The shell lines that record this call's ownership, or "" when it is not a subagent's call.

    The lines go after the caller's own prefix and before the command. They fork
    nothing: a builtin printf of the shell's own PID and parent, and an export.
    """
    if not isinstance(payload, dict) or payload.get("tool_name") != "Bash":
        return ""
    agent_id = payload.get("agent_id")
    session_id = payload.get("session_id")
    tool_use_id = payload.get("tool_use_id")
    if not _valid_ids(agent_id, session_id, tool_use_id):
        return ""
    directory = _shell_dir(session_id, agent_id)
    now = time.time()
    try:
        os.makedirs(directory, mode=0o700, exist_ok=True)
        _prune(directory, now)
        _write_json(os.path.join(directory, tool_use_id + ".json"),
                    {"at": now, "tool_use_id": tool_use_id, "cwd": str(payload.get("cwd") or "")})
    except OSError:
        return ""
    pid_path = os.path.join(directory, tool_use_id + ".pid")
    # A NEW command of a held agent waits, never refused: after recording itself the
    # shell suspends itself (builtin kill, no fork) before its command starts, and
    # release() continues it. The loop re-checks after every continue.
    return ("printf '%%s %%s\\n' \"$$\" \"$PPID\" > %s 2>/dev/null || :\nexport %s=%s %s=%s\n"
            "while [ -e %s ]; do kill -STOP $$; done\n"
            % (shlex.quote(pid_path), TAG, agent_id, SESSION_TAG, session_id,
               shlex.quote(_held_path(session_id, agent_id))))


# ---------------------------------------------------------------------------
# the process table
# ---------------------------------------------------------------------------

def _cpu_seconds(value):
    days, _, rest = value.partition("-")
    total = int(days) * 86400 if rest else 0
    for i, part in enumerate(reversed((rest or days).split(":"))):
        total += float(part) * 60 ** i
    return total


def snapshot():
    """{pid: row} for this user's processes: ppid, pgid, stat, cpu seconds, birth (epoch seconds)."""
    out = subprocess.run(["ps", "-ax", "-o", "pid=,ppid=,pgid=,uid=,stat=,time=,lstart="],
                         capture_output=True, text=True, timeout=10, check=True,
                         env={**os.environ, "LC_ALL": "C", "TZ": "UTC0"}).stdout
    uid = os.getuid()
    table = {}
    for line in out.splitlines():
        f = line.split(None, 6)
        if len(f) != 7 or not f[0].isdigit() or int(f[3]) != uid:
            continue
        try:
            birth = calendar.timegm(time.strptime(f[6].strip(), "%a %b %d %H:%M:%S %Y"))
            cpu = _cpu_seconds(f[5])
        except ValueError:
            continue
        table[int(f[0])] = {"ppid": int(f[1]), "pgid": int(f[2]), "stat": f[4], "cpu": cpu,
                            "birth": birth, "lstart": f[6].strip()}
    return table


def _read_pid(path):
    try:
        with open(path) as f:
            parts = f.read().split()
        return int(parts[0]), int(parts[1])
    except (OSError, ValueError, IndexError):
        return None


def owned_shells(session_id, agent_id, table):
    """[(pid, ppid, registered_at)] of this agent's recorded calls whose shell is still that shell."""
    directory = _shell_dir(session_id, agent_id)
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return []
    shells = []
    for name in names:
        if not name.endswith(".pid"):
            continue
        stem = os.path.join(directory, name[:-4])
        got = _read_pid(stem + ".pid")
        meta = _read_json(stem + ".json") or {}
        try:
            written = os.stat(stem + ".pid").st_mtime
        except OSError:
            continue
        if not got or not isinstance(meta.get("at"), (int, float)):
            continue
        pid, ppid = got
        row = table.get(pid)
        if not row or row["ppid"] != ppid:
            continue
        # Started after the hook ran and before it wrote its own record: that shell, not a reused PID.
        if not (int(meta["at"]) - BIRTH_SLACK <= row["birth"] <= written + BIRTH_SLACK):
            continue
        shells.append((pid, ppid, float(meta["at"])))
    return shells


def _environment(pid, _buf={}):
    """This process's environment strings, or None when the OS will not say. Never printed."""
    if sys.platform == "darwin":
        try:
            libc = _buf.get("libc") or ctypes.CDLL(None, use_errno=True)
            _buf["libc"] = libc
            if "buf" not in _buf:
                argmax = ctypes.c_int(0)
                size = ctypes.c_size_t(ctypes.sizeof(argmax))
                if libc.sysctl((ctypes.c_int * 2)(1, 8), 2, ctypes.byref(argmax), ctypes.byref(size), None, 0):
                    return None
                _buf["buf"] = ctypes.create_string_buffer(argmax.value)
            buf = _buf["buf"]
            size = ctypes.c_size_t(len(buf))
            # KERN_PROCARGS2: argc, exec path, padding, argv, then the environment.
            if libc.sysctl((ctypes.c_int * 3)(1, 49, pid), 3, buf, ctypes.byref(size), None, 0):
                return None
            raw = buf.raw[:size.value]
            argc = int.from_bytes(raw[:4], "little")
            rest = raw[4:]
            i = rest.index(b"\0")
            while i < len(rest) and rest[i] == 0:
                i += 1
            parts = rest[i:].split(b"\0")
            env = []
            for item in parts[argc:]:
                if not item:
                    break
                env.append(item)
            return env
        except (OSError, ValueError, AttributeError):
            return None
    try:
        with open("/proc/%d/environ" % pid, "rb") as f:
            return f.read().split(b"\0")
    except OSError:
        return None


def tagged(agent_id, table, since):
    """Processes carrying this agent's inherited tag, started no earlier than its first recorded call."""
    want = ("%s=%s" % (TAG, agent_id)).encode()
    hits = set()
    for pid, row in table.items():
        if row["birth"] < since - BIRTH_SLACK:
            continue
        env = _environment(pid)
        if env and want in env:
            hits.add(pid)
    return hits


def subtree(roots, table):
    """roots, their descendants and the members of every group one of them leads."""
    found = set(p for p in roots if p in table)
    while True:
        more = {p for p, r in table.items() if p not in found and (r["ppid"] in found or r["pgid"] in found)}
        if not more:
            return found
        found |= more


def _ancestors(table):
    """This process and its ancestors: the caller (a hook, the lead's shell) is never suspended."""
    keep, pid = set(), os.getpid()
    for _ in range(64):
        if pid <= 1 or pid in keep:
            break
        keep.add(pid)
        pid = table.get(pid, {}).get("ppid", os.getppid() if pid == os.getpid() else 0)
    return keep


def daemons(owned, shells, table):
    """Owned processes that daemonized: reparented to launchd and leading their own session.

    An adb server or a Gradle daemon started by this agent serves every agent's
    work; freezing it would hold theirs too. The agent's own recorded shells are
    never daemons, even after their session process died.
    """
    return {p for p in owned if p not in shells and table[p]["ppid"] == 1 and "s" in table[p]["stat"]}


def _recorded_pid(path, table, slack=5.0):
    """A pid a launcher wrote right after starting it (`echo $! > file`), still that process."""
    try:
        with open(path) as f:
            pid = int(f.read().strip())
        written = os.stat(path).st_mtime
    except (OSError, ValueError):
        return None
    return pid if pid in table and abs(table[pid]["birth"] - written) <= slack else None


def testvm_exclusions(table):
    """Roots the hold never freezes: validated guest-slot holders, recorded VM processes
    and each run's login keeper (both detached by run.sh, so not under the walk)."""
    root = os.environ.get("TESTVM_ROOT") or os.path.join(os.path.expanduser("~"), ".richos-testvm")
    roots, notes = set(), []
    for name in SLOT_FILES:
        rec = _read_json(os.path.join(root, name)) or {}
        pid, since = rec.get("pid"), rec.get("since")
        # The holder wrote its record after it started; a reused PID started later.
        if isinstance(pid, int) and isinstance(since, (int, float)) and pid in table \
                and table[pid]["birth"] <= since + BIRTH_SLACK:
            roots.add(pid)
            notes.append("test VM walk pid %d (slot %s) left running to its own end (its scenario step "
                         "has no time bound; a guest keeps using the quota until it ends)" % (pid, name))
    run = os.path.join(root, "run")
    try:
        guests = sorted(os.listdir(run))
    except OSError:
        guests = []
    for guest in guests:
        # run.sh writes `echo $! > vm.pid` and `> claude-keep.pid` right after each launch.
        for leaf, what in (("vm.pid", "test VM guest"), ("claude-keep.pid", "test VM login keeper")):
            pid = _recorded_pid(os.path.join(run, guest, leaf), table)
            if pid is not None:
                roots.add(pid)
                notes.append("%s pid %d (%s) left running" % (what, pid, guest))
    return roots, notes


LOCK_NAME = re.compile(r"(?:\.lock|-lock|/token-\d+)\Z")


def lock_files(pids):
    """{path: [pid, ...]}: lock files the held processes have open. Reported, never acted on.

    Held work keeps every lock it holds (Sage's catch 5): a Cargo target lock, a
    machine worker token, a git index lock. Nothing but ending the work can drop
    another process's lock, so the lead is told which ones a pause is keeping.
    Read through libproc (no lsof); any failure reports nothing.
    """
    if sys.platform != "darwin":
        return {}
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    except OSError:
        return {}
    found = {}
    for pid in sorted(pids):
        try:
            size = libproc.proc_pidinfo(pid, 1, 0, None, 0)          # PROC_PIDLISTFDS
            if size <= 0:
                continue
            buf = ctypes.create_string_buffer(size)
            size = libproc.proc_pidinfo(pid, 1, 0, buf, size)
            for i in range(max(0, size) // 8):                       # struct proc_fdinfo
                fd, kind = struct.unpack_from("iI", buf.raw, i * 8)
                if kind != 1:                                        # PROX_FDTYPE_VNODE
                    continue
                info = ctypes.create_string_buffer(1200)             # vnode_fdinfowithpath
                if libproc.proc_pidfdinfo(pid, fd, 2, info, 1200) <= 0:
                    continue
                path = info.raw[176:1200].split(b"\0", 1)[0].decode("utf-8", "replace")
                if path and LOCK_NAME.search(path):
                    found.setdefault(path, []).append(pid)
        except (OSError, ValueError, struct.error):
            continue
    return found


def owned_tree(session_id, agent_id, table):
    """(owned pids, excluded pids, protected pids, notes, shell parents)."""
    shells = owned_shells(session_id, agent_id, table)
    if not shells:
        return set(), set(), set(), [], {}
    parents = {ppid: table[ppid]["birth"] for _p, ppid, _a in shells if ppid in table}
    since = min(at for _p, _pp, at in shells)
    owned = subtree([p for p, _pp, _a in shells] + sorted(tagged(agent_id, table, since)), table)
    protected = {1} | set(parents) | _ancestors(table)
    owned -= protected
    vm_roots, vm_notes = testvm_exclusions(table)
    excluded = subtree(vm_roots, table) & owned
    notes = vm_notes if excluded else []
    shared = daemons(owned - excluded, {p for p, _pp, _a in shells}, table)
    if shared:
        excluded |= subtree(shared, table) & owned
        notes.append("shared daemon(s) it started left running for other agents' work: pid %s"
                     % ", ".join(map(str, sorted(shared))))
    return owned, excluded, protected, notes, parents


# ---------------------------------------------------------------------------
# hold and release
# ---------------------------------------------------------------------------

def hold(session_id, agent_id, name="", sample=0.5, session_pid=None):
    """Suspend the agent's owned processes and make its new commands wait.

    The record is written FIRST, even for an idle agent: from that moment every new
    Bash call of this agent suspends itself before its command starts. Then its
    running processes are suspended. `session_pid` (the lead's session process) lets
    release_orphans() tell a dead session from a live one when no shell recorded it.
    Returns the measured result; never raises on process races.
    """
    if not _valid_ids(session_id, agent_id):
        return {"ok": False, "why": "no valid session and agent id recorded", "held": {}}
    t0 = time.monotonic()
    path = _held_path(session_id, agent_id)
    previous = _read_json(path) or {}
    held = {int(k): v for k, v in (previous.get("held") or {}).items()}
    parents = dict(previous.get("parents") or {})
    excluded, notes = set(), []
    table = snapshot()
    if isinstance(session_pid, int) and session_pid in table:
        parents[str(session_pid)] = table[session_pid]["birth"]
    at = previous.get("at") or time.time()
    _write_json(path, {"session_id": session_id, "agent_id": agent_id, "name": name, "at": at,
                       "held": {str(p): b for p, b in held.items()}, "parents": parents})
    for _round in range(STOP_ROUNDS):
        owned, excluded, _protected, notes, found_parents = owned_tree(session_id, agent_id, table)
        parents.update({str(k): v for k, v in found_parents.items()})
        targets = sorted((owned - excluded) - {p for p in held if held[p] == table.get(p, {}).get("birth")})
        if not targets:
            break
        for pid in targets:
            try:
                os.kill(pid, signal.SIGSTOP)
                held[pid] = table[pid]["birth"]
            except (ProcessLookupError, PermissionError):
                pass
        # A process forked between the snapshot and the signal is caught by the next round.
        table = snapshot()
    held = {p: b for p, b in held.items() if table.get(p, {}).get("birth") == b}
    deadline = time.monotonic() + SETTLE_SECONDS
    running = sorted(p for p in held if not table[p]["stat"].startswith("T"))
    while running and time.monotonic() < deadline:
        time.sleep(0.05)
        table = snapshot()
        running = sorted(p for p in held if p in table and not table[p]["stat"].startswith("T"))
    stopped_seconds = time.monotonic() - t0
    before = {p: table[p]["cpu"] for p in held if p in table}
    cpu_advance = None
    if held and sample > 0:
        time.sleep(sample)
        after = snapshot()
        cpu_advance = round(sum(max(0.0, after[p]["cpu"] - c) for p, c in before.items() if p in after), 2)
    locks = lock_files(held)
    result = {"ok": not running, "session_id": session_id, "agent_id": agent_id, "name": name,
              "at": at, "held": {str(p): b for p, b in sorted(held.items())},
              "not_stopped": running, "excluded": sorted(excluded), "notes": notes, "parents": parents,
              "stopped_seconds": round(stopped_seconds, 3), "sample_seconds": sample,
              "cpu_during_sample": cpu_advance, "locks": sorted(locks),
              "watchdog": previous.get("watchdog")}
    _write_json(path, result)
    # The record exists before the watchdog starts, so its first look finds it.
    result["watchdog"] = ensure_watchdog(session_id, agent_id, result.get("watchdog"))
    _write_json(path, result)
    return result


# ---------------------------------------------------------------------------
# the watchdog: no hold outlives its lead (Sage's catch 6) or its agent (catch 1)
# ---------------------------------------------------------------------------

def _watch_seconds():
    try:
        return max(0.2, float(os.environ.get("RICHOS_AGENT_HOLD_WATCH_SECONDS") or 5))
    except ValueError:
        return 5.0


def ensure_watchdog(session_id, agent_id, current=None):
    """{pid, birth} of this hold's watchdog, started unless the recorded one still runs.

    Detached (its own session, reparented to launchd once the hook exits) and
    without this agent's tags, so no hold ever freezes it.
    """
    if isinstance(current, dict) and isinstance(current.get("pid"), int):
        row = snapshot().get(current["pid"])
        if row and row["birth"] == current.get("birth"):
            return current
    env = {k: v for k, v in os.environ.items() if k not in (TAG, SESSION_TAG)}
    env["RICHOS_AGENT_HOLD_DIR"] = state_dir()
    try:
        p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "watch",
                              "--session", session_id, "--agent", agent_id],
                             env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    except OSError:
        return None
    row = None
    for _ in range(20):
        row = snapshot().get(p.pid)
        if row:
            break
        time.sleep(0.05)
    return {"pid": p.pid, "birth": row["birth"] if row else None}


def _registry_finished(rec):
    """True when the workspace registry records this agent finished (stopped, disposed of,
    its session ended). A stop made from the CEO's screen runs no hook; this sees it."""
    name = rec.get("name") or ""
    if not ID.fullmatch(name or "-"):
        return False
    # RICHOS_AGENT_HOLD_REGISTRY: a declared test seam naming a workspaces.py stand-in.
    ws = (os.environ.get("RICHOS_AGENT_HOLD_REGISTRY") or "").strip() or os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "mega-lander", "workspaces.py")
    if not os.path.isfile(ws):
        return False
    try:
        out = subprocess.run([sys.executable, ws, "--session", rec["session_id"], "recipient", "--name", name],
                             capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return out.split("\t", 1)[0].strip() == "finished"


def watch(session_id, agent_id, registry_every=6):
    """Poll until this hold is released by anyone; release it ourselves when every
    recorded session process is gone or the registry records the agent finished."""
    polls = 0
    path = _held_path(session_id, agent_id)
    while True:
        rec = _read_json(path)
        if not rec:
            return 0
        parents = rec.get("parents") or {}
        if parents:
            table = snapshot()
            if not any(table.get(int(p), {}).get("birth") == b for p, b in parents.items()):
                _log("watchdog released %s: its session process is gone" % (rec.get("name") or agent_id))
                release(session_id, agent_id)
                return 0
        polls += 1
        if polls % registry_every == 0 and _registry_finished(rec):
            _log("watchdog released %s: the registry records it finished" % (rec.get("name") or agent_id))
            release(session_id, agent_id)
            return 0
        time.sleep(_watch_seconds())


def _log(line):
    try:
        os.makedirs(state_dir(), mode=0o700, exist_ok=True)
        with open(os.path.join(state_dir(), "watchdog.log"), "a") as out:
            out.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), line))
    except OSError:
        pass


# ---------------------------------------------------------------------------
# wait: a paused agent stays inside its run (Rich, brief addition 1)
# ---------------------------------------------------------------------------

WAIT_SECONDS = 540     # under the Bash tool's 600 s limit, so the call returns and is repeated


def wait_resume(max_seconds=WAIT_SECONDS, poll=2.0, out=sys.stdout):
    """Returns once this agent's hold is released, printing RESUMED; at the bound it
    prints STILL WAITING so the agent runs it again. Never ends anything."""
    agent, session = os.environ.get(TAG, ""), os.environ.get(SESSION_TAG, "")
    if not _valid_ids(session, agent):
        out.write("PAUSE-WAIT: this shell carries no agent identity (%s, %s), so there is no hold to wait "
                  "for. Only a subagent's Bash call carries it.\n" % (TAG, SESSION_TAG))
        return 2
    deadline = time.monotonic() + max_seconds
    path = _held_path(session, agent)
    while os.path.exists(path):
        if time.monotonic() >= deadline:
            out.write("STILL WAITING at %s: run this same command again, with the Bash timeout 600000.\n"
                      % time.strftime("%H:%M:%SZ", time.gmtime()))
            return 0
        time.sleep(poll)
    out.write("RESUMED at %s: carry on from where you were.\n"
              % time.strftime("%H:%M:%SZ", time.gmtime()))
    return 0


def release(session_id, agent_id):
    """Continue exactly the processes this agent's hold suspended, each re-checked by start time."""
    if not _valid_ids(session_id, agent_id):
        return {"ok": False, "why": "no valid session and agent id recorded", "continued": [], "gone": []}
    path = _held_path(session_id, agent_id)
    rec = _read_json(path)
    if not rec:
        return {"ok": True, "continued": [], "gone": [], "why": "nothing was held"}
    t0 = time.monotonic()
    # Removed FIRST, so no new command suspends itself after the scans below.
    try:
        os.unlink(path)
    except OSError:
        pass
    table = snapshot()
    continued, gone, waited = [], [], []
    for key, birth in sorted((rec.get("held") or {}).items(), key=lambda kv: int(kv[0])):
        pid = int(key)
        if table.get(pid, {}).get("birth") != birth:
            gone.append(pid)
            continue
        try:
            os.kill(pid, signal.SIGCONT)
            continued.append(pid)
        except ProcessLookupError:
            gone.append(pid)
    # New commands that suspended themselves while held: this agent's own recorded
    # shells, registered after the hold began, in state T. Scanned more than once
    # so a shell that read the record just before its removal is not left behind.
    since = float(rec.get("at") or 0) - BIRTH_SLACK
    for scan in range(RELEASE_SCANS):
        if scan:
            time.sleep(RELEASE_SCAN_GAP)
            table = snapshot()
        for pid, _ppid, at in owned_shells(rec["session_id"], rec["agent_id"], table):
            if at >= since and pid not in continued and table[pid]["stat"].startswith("T"):
                try:
                    os.kill(pid, signal.SIGCONT)
                    continued.append(pid)
                    waited.append(pid)
                except ProcessLookupError:
                    pass
    return {"ok": True, "continued": continued, "gone": gone, "waited": waited, "name": rec.get("name", ""),
            "held_seconds": round(time.time() - float(rec.get("at") or time.time()), 1),
            "continued_seconds": round(time.monotonic() - t0, 3)}


def records():
    directory = os.path.join(state_dir(), "held")
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return []
    return [r for r in (_read_json(os.path.join(directory, n)) for n in names if n.endswith(".json")) if r]


def release_session(session_id):
    """Every hold of this session, released: a session that ends never leaves work frozen."""
    return [release(r["session_id"], r["agent_id"]) for r in records() if r.get("session_id") == session_id]


def release_orphans():
    """Holds whose session process is gone (recorded parent absent, or a different process now)."""
    table = snapshot()
    out = []
    for r in records():
        parents = r.get("parents") or {}
        if parents and not any(table.get(int(p), {}).get("birth") == b for p, b in parents.items()):
            out.append(release(r["session_id"], r["agent_id"]))
    return out


def describe_hold(result):
    name = result.get("name") or result.get("agent_id") or "the agent"
    if result.get("ok") is False and result.get("why"):
        return "HOLD %s: NOT held (%s); its running work was not suspended." % (name, result["why"])
    if not result.get("held"):
        return ("HOLD %s: no running command of it is recorded, so nothing was suspended (idle, or started "
                "before ownership capture was installed). Its new commands wait until RESUME." % name)
    line = "HOLD %s: %d process(es) suspended in %.2f s" % (name, len(result["held"]), result["stopped_seconds"])
    if result.get("cpu_during_sample") is not None:
        line += "; CPU used by them over the next %.1f s: %.2f s" % (result["sample_seconds"], result["cpu_during_sample"])
    if result.get("not_stopped"):
        line += "; NOT confirmed stopped: %s" % ", ".join(map(str, result["not_stopped"]))
    for note in result.get("notes") or []:
        line += "; " + note
    if result.get("locks"):
        line += ("; they keep these locks until RESUME, so work elsewhere that needs one waits: %s"
                 % ", ".join(result["locks"][:6]) + (" and %d more" % (len(result["locks"]) - 6)
                                                     if len(result["locks"]) > 6 else ""))
    if not result.get("watchdog"):
        line += "; its watchdog did NOT start, so only a SessionStart releases it if the lead dies"
    return line + ". They, and any new command it starts, continue on RESUME."


def describe_release(result):
    name = result.get("name") or "the agent"
    if result.get("why") == "nothing was held":
        return ""
    line = "RELEASE %s: %d process(es) continued after %.0f s held" % (
        name, len(result["continued"]), result.get("held_seconds") or 0)
    if result.get("waited"):
        line += ", including %d new command(s) that waited" % len(result["waited"])
    if result.get("gone"):
        line += "; %d had already ended" % len(result["gone"])
    return line + "."


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    for cmd in ("hold", "release", "watch"):
        s = sub.add_parser(cmd)
        s.add_argument("--session", required=True)
        s.add_argument("--agent", required=True, help="the agent id recorded by the registry")
        s.add_argument("--name", default="")
    sub.add_parser("status")
    sub.add_parser("capture", help="print the ownership lines for a hook payload on stdin")
    w = sub.add_parser("wait", help="a paused agent's own call: returns RESUMED once its hold is released")
    w.add_argument("--max-seconds", type=float, default=WAIT_SECONDS)
    a = p.parse_args(argv)
    if a.cmd == "wait":
        return wait_resume(a.max_seconds)
    if a.cmd == "watch":
        return watch(a.session, a.agent)
    if a.cmd == "hold":
        r = hold(a.session, a.agent, a.name)
        print(json.dumps(r, sort_keys=True))
        return 0 if r.get("ok") else 1
    if a.cmd == "release":
        r = release(a.session, a.agent)
        print(json.dumps(r, sort_keys=True))
        return 0 if r.get("ok") else 1
    if a.cmd == "status":
        for r in records():
            print("%s (%s): %d held since %s" % (r.get("name") or r.get("agent_id"), r.get("session_id"),
                                                 len(r.get("held") or {}),
                                                 time.strftime("%H:%M:%SZ", time.gmtime(r.get("at") or 0))))
        return 0
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 2
    sys.stdout.write(capture(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
