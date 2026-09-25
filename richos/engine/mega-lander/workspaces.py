#!/usr/bin/env python3
"""workspaces.py — THE CEO'S WORKSPACE SPEC, AND NOTHING ELSE.

The only reference is docs/plans/worktree-spec-2026-09-11.md (fourteen
points). Every rule in this file names the point it implements. Nothing here
asks whether an agent is alive: an agent is FINISHED when a recorded fact says
so (point 11, point 12), and a workspace is deleted when its work is LANDED or
DISCARDED (points 4, 7) — by this file, and by nothing else in the engine.

THE TWO EVENTS (point 3)
    1. spawned   -> every workspace registered   (register_cc, register_spawn,
                                                   bind_agent, record_start)
    2. landed or discarded -> every workspace and branch deleted, as one
                                                  (land, discard; retry)

STATE — outside every repository and session, one JSON file per agent:
    $RICHOS_WORKSPACES_DIR, else $CLAUDE_CONFIG_DIR/state/workspaces,
    else ~/.claude/state/workspaces
      sessions/<session_id>.json   every session records itself (point 12)
      agents/<key>.json            one agent: its workspaces and its facts
      refs/<key>/<call>.json       the refs its repositories held at the START
                                   of ONE of its tool calls, keyed by that
                                   call's own id: its calls overlap, so there
                                   is one window per call and never one slot
                                   per agent (point 3)
      done/<key>.json              an agent whose deletion completed
      ids/<agent_id>               platform agent id -> key
      repos.json                   every repository a record has named
      integration.json             the branch each repository's work integrates
                                   on, RECORDED (point 14). Never inferred,
                                   never derived from what a checkout happens
                                   to be on, and never frozen onto an agent:
                                   the live record is the only answer, which is
                                   why a wrong one can always be corrected
      events.jsonl                 append-only history of every fact
      lock                         one flock for every mutation

WHAT IS RECORDED, AND BY WHOM (never inferred):
    registration   create-teammate-worktree.sh (cc/), PreToolUse[Agent],
                   PostToolUse[Agent] and SubagentStart (native)
    ref creation   the catch-all PreToolUse (barrier -> snapshot_refs) and the
                   catch-all PostToolUse (observe -> observe_created_refs):
                   a ref that appears BETWEEN the two halves of one of the
                   agent's own tool calls, and carries that agent's own
                   unlanded work, was created by it        (point 3, point 10)
    end of run     SubagentStop, and a successful TaskStop  (point 11)
                   a run the platform STOPPED gets neither: it is recorded in
                   the platform's own per-agent record beside the transcript
                   (`stoppedByUser`), which observe_platform_end reads (11)
    handed in      TaskCompleted                            (point 11, hole 7)
    pause/resume   a SendMessage carrying `pause-until: <what ends it>`, a later
                   message to a paused agent, or `workspaces.sh pause|resume`
    session end    SessionEnd, or the operating system saying the recorded
                   process is gone or is a different process  (point 12)
"""

import calendar
import errno
import fcntl
import glob
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time

SPEC = "docs/plans/worktree-spec-2026-09-11.md"
CC_PREFIX = "cc/"
CODEX_PREFIX = "codex/"
NATIVE_BRANCH_PREFIX = "worktree-agent-"
NATIVE_DIR_MARK = os.sep + os.path.join(".claude", "worktrees", "agent-")
AGENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,80}$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,80}$")

# Point 13: the retry schedule. The first retry is a minute out and each wait
# doubles, capped at an hour. The CEO hears about it only if it keeps failing:
# after RETRY_TELL_CEO_AFTER failed attempts the notice names him.
RETRY_BASE_SECONDS = float(os.environ.get("RICHOS_WORKSPACES_RETRY_BASE", "60"))
RETRY_CAP_SECONDS = 3600.0
RETRY_TELL_CEO_AFTER = int(os.environ.get("RICHOS_WORKSPACES_RETRY_TELL_CEO", "5"))
PROCESS_STOP_GRACE = float(os.environ.get("RICHOS_WORKSPACES_STOP_GRACE", "3"))
# How long a spawn takes to register what it created (see _younger_than_its_spawn).
SPAWN_WINDOW = float(os.environ.get("RICHOS_WORKSPACES_SPAWN_WINDOW", "120"))

# THE POINT-5 GATE RUNS INSIDE SOMEBODY ELSE'S TIMEOUT. The Stop hook that
# carries it is registered with 60 s and the spawn gate with 10 s
# (hooks/hooks.json), while the work grows with the pending backlog: every
# pending item re-walks its workspace's ignored files against the main
# checkout. The platform CANCELS a hook that reaches its timeout and DISCARDS
# its output, so an overrun gate lets the turn end, or the spawn through,
# having decided NOTHING and announced NOTHING — the one outcome point 5 calls
# impossible ("a guarantee, not a habit").
#
# These are not performance targets and nothing here was made faster. They buy
# one property: the gate's ANSWER never depends on finishing an unbounded scan.
# The direction makes that free — work that cannot be checked cannot be
# auto-landed, so it stays pending, and the safe answer is also the cheap one.
GATE_STOP_BUDGET = 20.0
GATE_SPAWN_BUDGET = 4.0


class SpecError(Exception):
    """A refusal the page requires. The message is shown to the operator."""


class Deadline(SpecError):
    """A gate ran out of the budget it has inside somebody else's hook timeout.
    It is a SpecError so every `except SpecError` that means "this item cannot
    be landed right now" already handles it: an item that could not be checked
    is an item that stays pending, which is the answer the page wants anyway."""


# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

def now():
    return time.time()


def iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now() if t is None else t))


def realpath(p):
    p = (p or "").strip()
    if not p:
        return ""
    return os.path.realpath(os.path.expanduser(p))


def state_dir():
    d = (os.environ.get("RICHOS_WORKSPACES_DIR") or "").strip()
    if d:
        return d
    base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() \
        or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "state", "workspaces")


def _p(*parts):
    return os.path.join(state_dir(), *parts)


def _ensure_dirs():
    for sub in ("sessions", "agents", "done", "ids", "refs"):
        os.makedirs(_p(sub), exist_ok=True)


def _key_segment(s):
    s = re.sub(r"[^A-Za-z0-9._-]+", "_", s or "")
    return s[:120] or "_"


def write_json(path, obj):
    """Durable write: temp file, fsync, rename, fsync the directory."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    try:
        fd = os.open(d, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError:
        pass


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, dict) else None
    except (OSError, ValueError):
        return None


class Lock(object):
    """One flock over every mutation. Kernel-released: never stranded.
    Re-entrant inside one process, so a nested caller never deadlocks on it."""

    _depth = 0
    _fd = None

    def __init__(self, timeout=30.0):
        self.timeout = timeout

    def __enter__(self):
        if Lock._depth:
            Lock._depth += 1
            return self
        _ensure_dirs()
        fd = os.open(_p("lock"), os.O_RDWR | os.O_CREAT, 0o600)
        deadline = now() + self.timeout
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as e:
                if e.errno not in (errno.EAGAIN, errno.EACCES):
                    os.close(fd)
                    raise
                if now() >= deadline:
                    os.close(fd)
                    raise SpecError("the workspace registry lock %s was not free within %.0fs"
                                    % (_p("lock"), self.timeout))
                time.sleep(0.05)
        Lock._fd = fd
        Lock._depth = 1
        return self

    def __exit__(self, *a):
        Lock._depth -= 1
        if Lock._depth == 0:
            try:
                fcntl.flock(Lock._fd, fcntl.LOCK_UN)
            finally:
                os.close(Lock._fd)
                Lock._fd = None


def event(what, **fields):
    """Append one fact to events.jsonl. The history, never the authority."""
    rec = {"ts": iso(), "event": what}
    rec.update(fields)
    try:
        _ensure_dirs()
        with open(_p("events.jsonl"), "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, sort_keys=True) + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# git — read from git, never assembled from path arithmetic
# ---------------------------------------------------------------------------

def _git_env():
    env = dict(os.environ)
    for k in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
        env.pop(k, None)
    env["LC_ALL"] = "C"
    return env


def git(repo, *args, **kw):
    try:
        r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True,
                           timeout=kw.get("timeout", 60), env=_git_env())
    except subprocess.TimeoutExpired as e:
        # 124, not 127: a caller running under a budget must be able to tell
        # "this did not finish in the time it had" from "git could not run".
        return 124, "", str(e)
    except OSError as e:
        return 127, "", str(e)
    return r.returncode, r.stdout, r.stderr


def main_checkout(path):
    """The repository's MAIN checkout: the first entry of git's own list."""
    path = realpath(path)
    if not path or not os.path.isdir(path):
        return ""
    rc, out, _ = git(path, "worktree", "list", "--porcelain")
    if rc != 0:
        return ""
    for line in out.splitlines():
        if line.startswith("worktree "):
            return realpath(line[len("worktree "):])
    return ""


def worktree_list(repo):
    """[{path, branch, head, detached, locked, prunable}] or None if unreadable."""
    rc, out, _ = git(repo, "worktree", "list", "--porcelain")
    if rc != 0:
        return None
    items, cur = [], None
    for line in out.splitlines() + [""]:
        if line.startswith("worktree "):
            cur = {"path": realpath(line[len("worktree "):]), "branch": "", "head": "",
                   "detached": False, "locked": False, "prunable": False}
        elif cur is None:
            continue
        elif line.startswith("branch refs/heads/"):
            cur["branch"] = line[len("branch refs/heads/"):]
        elif line.startswith("HEAD "):
            cur["head"] = line[5:].strip()
        elif line == "detached":
            cur["detached"] = True
        elif line.startswith("locked"):
            cur["locked"] = True
        elif line.startswith("prunable"):
            cur["prunable"] = True
        elif line == "" and cur is not None:
            items.append(cur)
            cur = None
    return items


def branch_tip(repo, branch):
    rc, out, _ = git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch)
    return out.strip() if rc == 0 else ""


def is_ancestor(repo, a, b):
    rc, _, _ = git(repo, "merge-base", "--is-ancestor", a, b)
    return rc == 0


def local_branches(repo, patterns):
    rc, out, _ = git(repo, "for-each-ref", "--format=%(refname:short)", *["refs/heads/" + p for p in patterns])
    if rc != 0:
        return None
    return [b for b in out.splitlines() if b.strip()]


def is_native_path(path):
    return NATIVE_DIR_MARK in (path or "")


def classify(path, branch):
    """'native', 'cc', 'codex' or '' (not the system's concern — point 1)."""
    if (branch or "").startswith(CODEX_PREFIX):
        return "codex"
    if is_native_path(path) or (branch or "").startswith(NATIVE_BRANCH_PREFIX):
        return "native"
    if (branch or "").startswith(CC_PREFIX):
        return "cc"
    return ""


# ---------------------------------------------------------------------------
# THE LAND LOCK'S HOME, AND THE APPEND-ONLY LAND RECORD BESIDE IT
# ---------------------------------------------------------------------------
# MOVED HERE FROM app.py ON 2026-09-17, AND THE LAYERING IS THE WHOLE REASON.
# `_restore_protected_refs` (far below) has to answer "whose land moved this
# ref?", and the answer is written by app.py's `integrate` — which imports THIS
# file as `W`. The import cannot go back the other way. So either the keying
# rule for the lock's path exists in two files, or it exists in the layer that
# already owns machine-wide state. Two copies of a keying rule is the defect
# class this subsystem keeps meeting: the copies agree until one is edited, and
# then two conversations take two locks while believing they share one — which
# is the exact before-state the land lock was written for (app.py, "TWO
# CONVERSATIONS, TWO LOCK FILES"). app.py now calls these four functions and
# declares no keying of its own.
#
# THE ONE CHANGE MADE WHILE MOVING: pathlib is gone. This module is imported by
# a PreToolUse and a PostToolUse hook on EVERY tool call of every agent, and it
# uses os.path throughout; these functions return strings for the same reason
# every other path in this file does.

def land_locks_dir():
    """The machine-wide home of the per-repository land locks and land records.

    Deliberately NOT `state_dir()` and NOT app.py's `state()`: those are the two
    partitions this lock exists to sit outside of. It is derived instead from
    `CLAUDE_CONFIG_DIR` (else `~/.claude`) — the same machine-wide home the
    workspace registry falls back to and the worktree ledger lives in — because
    the app neither sets nor removes that variable for the engine it launches:
    `EngineProfile::configure` strips every inherited `RICHOS_`/`LORO_`/`ECS_`/
    `GIT_` name and re-adds its own list, and `CLAUDE_CONFIG_DIR` is in neither
    (engine_profile.rs:156-210; the app reads it only to FIND the engine,
    setup.rs:146 and engine.rs:95). One value for every thread of one app, and
    for a terminal beside it.

    `RICHOS_LAND_LOCKS_DIR` overrides it for tests. That override cannot reach
    an app-launched engine at all, because the strip above removes it — and so
    that the property is CHECKED rather than argued from that, a home resolving
    inside either partition is REFUSED rather than used. A lock inside a
    partition is not a lock; it is the defect this function was written for,
    wearing the new name."""
    override = (os.environ.get("RICHOS_LAND_LOCKS_DIR") or "").strip()
    if override:
        base = realpath(override)
    else:
        home = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() \
            or os.path.join(os.path.expanduser("~"), ".claude")
        base = os.path.join(realpath(home), "state", "land-locks")
    if not os.path.isabs(base):
        raise ValueError("the land lock home must be an absolute path")
    for name in ("RICHOS_APP_STATE", "RICHOS_WORKSPACES_DIR"):
        partition = realpath(os.environ.get(name) or "")
        if not partition:
            continue
        if base == partition or base.startswith(partition.rstrip(os.sep) + os.sep):
            raise ValueError("the land lock cannot live inside a per-conversation partition (%s); "
                             "a lock two conversations cannot share serializes nothing" % name)
    os.makedirs(base, mode=0o700, exist_ok=True)
    if os.path.islink(base):
        raise ValueError("the land lock home cannot be redirected")
    return base


def canonical_repository(repo):
    """The identity of the ref store a land mutates, not the string it was
    reached by.

    `--git-common-dir`, made absolute and then realpath'd: two symlinked paths
    to one repository resolve to one value, and so do a repository and a linked
    worktree of it — which share a ref store and would otherwise race on the
    same branch through two different lock files. If git cannot answer (the
    path is gone, it is not a repository) the realpath of the given path is the
    key, so this never turns into a refusal `integrate` did not already make."""
    rc, out, _err = git(str(repo), "rev-parse", "--path-format=absolute", "--git-common-dir")
    common = out.strip() if rc == 0 else ""
    return os.path.realpath(os.path.expanduser(common or str(repo)))


def land_lock_path(repo):
    """One file per repository. The digest is the discriminator; the readable
    prefix is there so that an operator listing the directory sees repositories
    rather than hashes."""
    canonical = canonical_repository(repo)
    name = os.path.basename(canonical.rstrip("/"))
    if name in (".git", ""):
        name = os.path.basename(os.path.dirname(canonical.rstrip("/")))
    label = re.sub(r"[^A-Za-z0-9._-]+", "-", name).strip("-")[:48] or "repository"
    return os.path.join(land_locks_dir(),
                        "%s-%s.lock" % (label, hashlib.sha256(canonical.encode()).hexdigest()[:16]))


def read_land_lock(path):
    """The holder's record out of a lock file, or None for anything that is not
    a complete JSON object — `_write_land_lock` writes in place and a reader can
    catch a partial line."""
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.loads(handle.read(8192))
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


# A LAND RECORD IS APPENDED, NEVER OVERWRITTEN, and these are the bounds of the
# file that results. 500 lands into ONE repository is far beyond any window an
# agent's snapshot can still be open across (a snapshot belongs to a single tool
# call, or at the widest a single agent run), so the trim can only ever drop
# rows nothing will ask about. The line bound is the same 4000 the lock record
# carries, for the same reason: a bounded write cannot be half-read.
LAND_RECORD_KEEP = 500
LAND_RECORD_LINE = 4000


def land_record_path(repo):
    """The append-only history of lands in this repository, BESIDE its lock.

    A history and not a field on the lock, and that difference is the whole of
    attribution working versus saying "unknown". The lock file holds ONE
    record, rewritten in place by whoever takes the lock next
    (`_write_land_lock`), so of two lands in a row only the second survives —
    and an agent whose snapshot predates the FIRST one would see a move that
    nothing could name. Appending keeps both, and the match below is by COMMIT,
    so each land answers for exactly the move it made."""
    lock = land_lock_path(repo)
    return (lock[:-len(".lock")] if lock.endswith(".lock") else lock) + ".lands"


def append_land_record(repo, record):
    """Write one land into this repository's history. Append-only.

    `O_APPEND` and one bounded JSON line: every write lands at the end of the
    file, and the caller is holding this repository's land lock anyway, so the
    order is the order the lands happened in.

    A HISTORY IS NEVER WORTH FAILING A LAND FOR. Anything that goes wrong here
    returns "" and the land carries on: the cost of a missing row is that one
    later move is reported as unattributed, which is a worse message and never
    a wrong one."""
    try:
        path = land_record_path(repo)
        line = json.dumps(record, sort_keys=True)[:LAND_RECORD_LINE] + "\n"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, line.encode("utf-8"))
        finally:
            os.close(fd)
        _trim_land_records(path)
        return path
    except (OSError, ValueError, TypeError):
        return ""


def _trim_land_records(path):
    """Keep the newest LAND_RECORD_KEEP rows. Runs under the land lock, and
    replaces the file rather than truncating it, so a reader that opened the
    old inode still reads a whole file rather than a half of one."""
    try:
        with open(path, encoding="utf-8") as handle:
            lines = handle.readlines()
        if len(lines) <= LAND_RECORD_KEEP * 2:
            return
        tmp = "%s.tmp.%d" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.writelines(lines[-LAND_RECORD_KEEP:])
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except OSError:
        pass


def land_records(repo):
    """Every land recorded for this repository, oldest first.

    An empty list is NOT "no land happened": the terminal path lands with a
    hand-run `git merge` and writes nothing here. Telling those two apart is
    exactly what `land_by_another_conversation` needs, so absence is reported
    as absence and never as a land by nobody."""
    try:
        path = land_record_path(repo)
        with open(path, encoding="utf-8") as handle:
            raw = handle.readlines()[-(LAND_RECORD_KEEP * 2):]
    except (OSError, ValueError):
        return []
    out = []
    for line in raw:
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except ValueError:
            continue                    # a torn or foreign line names no land
        if isinstance(value, dict):
            out.append(value)
    return out


def this_conversation():
    """The conversation thread this engine was launched for, or "" in a
    terminal. Set by the app and stripped for anything else
    (engine_profile.rs:168-170), so it is the app's word rather than a guess."""
    return (os.environ.get("RICHOS_APP_THREAD") or "").strip()


def land_by_another_conversation(repo, branch, before, found):
    """WHOSE LAND MOVED THIS REF FORWARD? — the sentence to report, or None for
    silence. Consulted only where the caller has already established that a
    protected ref moved to a DESCENDANT: a fast-forward, nothing lost, the
    shape of an ordinary land.

    Until 2026-09-17 every one of those was silent. That is right for the
    lead's own land and wrong for another conversation's: the CEO runs two
    threads, their back ends share a repository, and the second one's land
    moves `main` under the first one's agents. Their snapshots, their bases and
    anything they recorded from the old tip are stale from that instant, with
    nothing saying so. The lock makes the two lands take turns; this makes the
    turn VISIBLE to the agent it happened under.

    SILENT WHEN THE HISTORY IS ABSENT. No file means land records are not in
    use for this repository at all, which is the terminal path — Rich's lands
    there are a hand-run `git merge` that writes no record, and those teammates
    are already told by guard-inflight-notify.sh at the push. Calling every one
    of those "unattributed" would put an alarm on the single most common write
    a recorded branch ever receives, which is how a report becomes wallpaper.

    SILENT FOR THIS CONVERSATION'S OWN LAND. A record carrying this engine's
    own `RICHOS_APP_THREAD` is this conversation landing its own work; its
    agents are the one party that already knows.

    IT NEVER CLAIMS MORE THAN THE RECORD CARRIES. A move no record names is
    reported as exactly that — a land the records do not name — and never as
    "another conversation", because a repository that keeps land records can
    still be merged into by a hand at a terminal."""
    try:
        records = land_records(repo)
        if not records:
            return None                 # land records are not in use here
        mine = this_conversation()
        for record in reversed(records):
            if record.get("branch") != branch or record.get("commit") != found:
                continue
            thread = str(record.get("thread_id") or "")
            if thread == mine:
                return None             # this conversation's own land
            return "landed by conversation %s at %s, %s -> %s" % (
                thread or "an unnamed thread", record.get("at") or "an unrecorded time",
                (before or "")[:12], (found or "")[:12])
        return ("moved forward by a land this repository's land records do not name, %s -> %s"
                % ((before or "")[:12], (found or "")[:12]))
    except (OSError, ValueError):
        return None


# ---------------------------------------------------------------------------
# point 12 — sessions record themselves; ended is read from the OS
# ---------------------------------------------------------------------------

def _ps_env():
    return dict(os.environ, LC_ALL="C", LANG="C", TZ="UTC0")


def process_start(pid):
    """('ok', '<lstart>') | ('gone', '') | ('unknown', why). Read from the OS.

    The start time is what makes the record more than a process number
    (point 12: "since those get reused")."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return "unknown", "no process number recorded"
    if pid <= 0:
        return "unknown", "no process number recorded"
    if not shutil.which("ps"):
        return "unknown", "ps is not available"
    try:
        r = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True,
                           text=True, timeout=10, env=_ps_env())
    except (OSError, subprocess.TimeoutExpired) as e:
        return "unknown", "ps could not run: %s" % e
    text = " ".join(r.stdout.split())
    if r.returncode == 0 and text:
        return "ok", text
    if r.returncode in (0, 1) and not text:
        return "gone", ""
    return "unknown", "ps exited %d: %s" % (r.returncode, r.stderr.strip()[:200])


def _ps_parent_and_comm(pid):
    try:
        r = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)], capture_output=True,
                           text=True, timeout=10, env=_ps_env())
    except (OSError, subprocess.TimeoutExpired):
        return None, ""
    parts = r.stdout.split(None, 1)
    if len(parts) < 2:
        return None, ""
    try:
        return int(parts[0]), parts[1].strip()
    except ValueError:
        return None, ""


def _platform_sessions_dir():
    return (os.environ.get("RICHOS_SESSIONS_DIR") or "").strip() or os.path.join(
        (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() or os.path.join(os.path.expanduser("~"), ".claude"),
        "sessions")


def session_pid(session_id=""):
    """The pid of the claude process that owns this hook or command.

    RICHOS_SESSION_PID overrides (tests, and a harness that exports it).
    Otherwise walk the process ancestry, from the operating system: the first
    ancestor that the platform's own session file names as this session, else
    the first ancestor whose command is `claude`."""
    v = (os.environ.get("RICHOS_SESSION_PID") or "").strip()
    if v.isdigit():
        return int(v)
    pid = os.getppid()
    named = None
    for _ in range(16):
        if pid is None or pid <= 1:
            break
        f = os.path.join(_platform_sessions_dir(), "%d.json" % pid)
        rec = read_json(f)
        if rec:
            if not session_id or str(rec.get("sessionId") or "") == session_id:
                return pid
            # The platform says this process is ANOTHER session. The payload's
            # session is therefore not the one running this code, and its
            # identity is not this process's to lend.
            return None
        ppid, comm = _ps_parent_and_comm(pid)
        if named is None and os.path.basename(comm) == "claude":
            named = pid
        pid = ppid
    return named


def session_path(session_id):
    return _p("sessions", _key_segment(session_id) + ".json")


def load_session(session_id):
    return read_json(session_path(session_id)) if session_id else None


def identity_for(session_id):
    """{pid, pid_start} of the process running this session, read from the OS."""
    pid = session_pid(session_id)
    if not pid:
        return None
    st, text = process_start(pid)
    if st != "ok":
        return None
    return {"pid": pid, "pid_start": text}


def worktree_session_reason(cwd, pid):
    """Point 3: nobody starts a session in its own workspace. Returns why, or ''."""
    top = ""
    if cwd and os.path.isdir(cwd):
        rc, out, _ = git(cwd, "rev-parse", "--show-toplevel")
        top = realpath(out.strip()) if rc == 0 else ""
    if top and (os.sep + os.path.join(".claude", "worktrees") + os.sep) in top + os.sep:
        return "the session's directory %s is a Claude Code workspace (claude --worktree)" % top
    if pid:
        try:
            r = subprocess.run(["ps", "-o", "args=", "-p", str(pid)], capture_output=True, text=True,
                               timeout=10, env=_ps_env())
            args = " " + r.stdout.strip() + " "
        except (OSError, subprocess.TimeoutExpired):
            args = ""
        if re.search(r"\s(--worktree|-w)(\s|=)", args) and "claude" in args:
            return "the session was started with claude --worktree / -w"
    return ""


def platform_session(session_id, pid=None):
    """The platform's OWN record of the claude process running `session_id`
    (<config>/sessions/<pid>.json), or None. Read, never written.

    It is written once, when the process starts, and its `cwd` is the directory
    the session was LAUNCHED in (Claude Code 2.1.280 writes `cwd: originalCwd`).
    That is the one fact point 3 asks about, and no hook payload carries it
    reliably: see session_start."""
    if not session_id:
        return None
    pids = []
    for p in (pid, None):
        if p is None:
            p = session_pid(session_id)
        try:
            p = int(p)
        except (TypeError, ValueError):
            continue
        if p > 0 and p not in pids:
            pids.append(p)
    for p in pids:
        rec = read_json(os.path.join(_platform_sessions_dir(), "%d.json" % p))
        if rec and str(rec.get("sessionId") or "") == session_id:
            return rec
    return None


# The SessionStart sources that mean a PROCESS was launched. The others
# (compact, clear) happen inside a running session, and one of them, compact,
# also fires for a SUBAGENT's compaction carrying the lead's session_id.
LAUNCH_SOURCES = ("", "startup", "resume", "fork")


def session_start(session_id, cwd, source="", agent_id=""):
    """Record a SessionStart. Returns (record, foreign).

    `foreign` is True when this SessionStart is NOT the lead's own: it must
    change nothing about the lead and give it no context.

    WHY THE PAYLOAD'S cwd IS NOT THE LEAD'S DIRECTORY. On 2026-09-22 at 23:10Z a
    subagent (isaac-opus-n1) compacted its context. Claude Code fires
    SessionStart(source=compact) for a subagent's compaction too, and 2.1.280
    builds that input WITHOUT the agent context: the LEAD's session_id, the
    SUBAGENT's worktree as cwd, no agent_id. This function used to take every
    SessionStart as the lead's, so it wrote the subagent's worktree onto the
    lead's record, point 3 flagged it FORBIDDEN, and every lead call was refused
    for the 33 minutes until the CEO exited, with ten agents at 100% CPU and
    nothing able to stop them.

    So the lead's directory is, in order: the platform's own record of the
    process (platform_session), else the first record, else a launch event's
    cwd. A later in-session SessionStart never moves it, and a SessionStart
    carrying an agent_id (a later platform version may send one) is never the
    lead's at all."""
    if not session_id:
        raise SpecError("no session id in the payload")
    source = (source or "").strip()
    payload_cwd = realpath(cwd)
    prev = load_session(session_id) or {}
    if agent_id:
        event("session-start-not-the-lead", session_id=session_id, agent_id=agent_id, source=source or None,
              cwd=payload_cwd or None)
        return prev, True
    ident = identity_for(session_id)
    pid = ident["pid"] if ident else prev.get("pid")
    plat = platform_session(session_id, pid)
    if plat and plat.get("cwd"):
        lead_cwd, basis = realpath(str(plat["cwd"])), "platform"
    elif prev.get("cwd"):
        lead_cwd, basis = prev["cwd"], prev.get("cwd_basis") or "recorded"
    else:
        lead_cwd, basis = payload_cwd, "first-record"
    foreign = bool(payload_cwd and lead_cwd and payload_cwd != lead_cwd and source not in LAUNCH_SOURCES)
    if foreign:
        event("session-start-not-the-lead", session_id=session_id, source=source or None,
              cwd=payload_cwd, lead_cwd=lead_cwd)
        return prev, True
    # A compact or clear with nothing before it cannot say whose directory it
    # carries, so it is recorded and never made the reason for a refusal.
    may_forbid = basis != "first-record" or source in LAUNCH_SOURCES
    rec = dict(prev)
    rec.update({"session_id": session_id, "cwd": lead_cwd, "cwd_basis": basis,
                "started_at": rec.get("started_at") or iso(),
                "repo": main_checkout(lead_cwd) if lead_cwd else ""})
    if ident:
        rec.update(ident)
    rec.pop("ended_at", None)
    rec.pop("end_reason", None)
    forbidden = worktree_session_reason(lead_cwd, pid) if may_forbid else ""
    if forbidden:
        rec["forbidden"] = forbidden
    else:
        rec.pop("forbidden", None)
    with Lock():
        write_json(session_path(session_id), rec)
        if rec.get("repo"):
            _remember_repo(rec["repo"])
    event("session-start", session_id=session_id, pid=rec.get("pid"), pid_start=rec.get("pid_start"),
          source=source or None, basis=basis, forbidden=forbidden or None)
    return rec, False


def record_session_start(session_id, cwd, source="", agent_id=""):
    return session_start(session_id, cwd, source, agent_id)[0]


def forbidden_now(session_id, rec):
    """Point 3's verdict for the lead, RE-DERIVED rather than trusted.

    A stored flag is a claim with a date on it. The record 9cfd9fc9 was left
    with carried the wrong directory and FORBIDDEN, and nothing could ever
    correct it. So when a flag is stored, the platform's own launch record is
    asked again; where the two disagree the platform wins and the record is
    healed. Only a stored flag costs a lookup: the lead's ordinary call stays one
    file read."""
    stored = (rec or {}).get("forbidden") or ""
    if not stored:
        return ""
    plat = platform_session(session_id, rec.get("pid"))
    if not plat or not plat.get("cwd"):
        return stored
    lead_cwd = realpath(str(plat["cwd"]))
    reason = worktree_session_reason(lead_cwd, rec.get("pid"))
    if reason != stored:
        with Lock():
            cur = load_session(session_id) or dict(rec)
            cur["cwd"] = lead_cwd
            cur["cwd_basis"] = "platform"
            if reason:
                cur["forbidden"] = reason
            else:
                cur.pop("forbidden", None)
            write_json(session_path(session_id), cur)
        event("session-forbidden-rederived", session_id=session_id, was=stored, now=reason or None)
    return reason


def record_session_end(session_id, reason=""):
    with Lock():
        rec = load_session(session_id) or {"session_id": session_id}
        rec["ended_at"] = iso()
        rec["end_reason"] = reason or "SessionEnd"
        write_json(session_path(session_id), rec)
    event("session-end", session_id=session_id, reason=reason)


def session_state(session_id, fallback=None, cache=None):
    """('running'|'ended'|'unknown', why). Point 12, literally:
    ended when it recorded its end, or when its process no longer exists on
    this machine — read from the operating system, never guessed."""
    if cache is not None and session_id in cache:
        return cache[session_id]
    rec = load_session(session_id) if session_id else None
    ident = rec if (rec and rec.get("pid")) else (fallback or {})
    if rec and rec.get("ended_at"):
        out = ("ended", "session %s recorded its end at %s" % (session_id[:8], rec["ended_at"]))
    elif not ident.get("pid") or not ident.get("pid_start"):
        out = ("unknown", "session %s has no recorded process identity" % (session_id or "?")[:8])
    else:
        st, text = process_start(ident["pid"])
        if st == "gone":
            out = ("ended", "process %s of session %s no longer exists" % (ident["pid"], session_id[:8]))
        elif st == "ok" and text != ident["pid_start"]:
            out = ("ended", "process %s is no longer session %s's (started %s, recorded %s)"
                   % (ident["pid"], session_id[:8], text, ident["pid_start"]))
        elif st == "ok":
            out = ("running", "process %s of session %s runs" % (ident["pid"], session_id[:8]))
        else:
            out = ("unknown", text)
    if cache is not None:
        cache[session_id] = out
    return out


# ---------------------------------------------------------------------------
# records
# ---------------------------------------------------------------------------

def agent_path(key):
    return _p("agents", key + ".json")


def done_path(key):
    return _p("done", key + ".json")


def load_agent(key):
    return read_json(agent_path(key)) or read_json(done_path(key))


def save_agent(rec):
    write_json(agent_path(rec["key"]), rec)
    if rec.get("agent_id"):
        _write_id(rec["agent_id"], rec["key"])


def _write_id(agent_id, key):
    os.makedirs(_p("ids"), exist_ok=True)
    tmp = _p("ids", ".%s.%d" % (agent_id, os.getpid()))
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(key + "\n")
    os.replace(tmp, _p("ids", _key_segment(agent_id)))


def key_for_id(agent_id):
    try:
        with open(_p("ids", _key_segment(agent_id)), encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def all_agents(include_done=False):
    out = []
    dirs = ["agents"] + (["done"] if include_done else [])
    for sub in dirs:
        try:
            names = sorted(os.listdir(_p(sub)))
        except OSError:
            continue
        for n in names:
            if n.endswith(".json"):
                r = read_json(_p(sub, n))
                if r and r.get("key"):
                    out.append(r)
    return out


def named_key(session_id, name):
    return "%s--%s" % (_key_segment(session_id), _key_segment(name))


def new_record(key, **fields):
    rec = {"key": key, "name": "", "session_id": "", "agent_id": "", "workspaces": [],
           "registered_at": iso(), "end": None, "handed_in": None, "pause": None, "waiting": None,
           "disposition": None, "deletion": None, "orphan": False, "ceo_ordered": None,
           "continues": [], "lands_pending": [], "created_branches": [],
           "history": []}
    rec.update(fields)
    return rec


def _remember_repo(repo):
    repo = realpath(repo)
    if not repo:
        return
    path = _p("repos.json")
    cur = read_json(path) or {"repos": []}
    if repo not in cur["repos"]:
        cur["repos"].append(repo)
        write_json(path, cur)


def known_repos():
    return [r for r in (read_json(_p("repos.json")) or {}).get("repos", []) if os.path.isdir(r)]


# ---------------------------------------------------------------------------
# point 14 — the branch a body of work integrates on is RECORDED
# ---------------------------------------------------------------------------
#
# "Landed doesn't always mean landed on main. Landing means merged into the
#  branch this work integrates on. Usually that is main. When the work cannot
#  reach main yet — not reviewed, or not ready to install — it is that work's
#  dev branch. ... The branch a body of work integrates on is RECORDED when
#  that work starts, before its first agent is spawned. Nothing infers it and
#  nothing guesses it — without that record there is no fact to test a land
#  against, and 'landed' goes back to meaning whatever main happens to have."
#
# WHAT THIS REPLACED, AND WHY IT WAS WRONG. land() used to resolve each
# repository's target with `git rev-parse HEAD` in the main checkout, at the
# moment of the land. So "landed" meant "in whatever the main checkout has
# checked out just now" — which is not a fact about this work at all: it moves
# when Rich checks something else out, it is empty when the main checkout is
# detached, and it can NEVER answer yes for work that integrates on a dev
# branch, which is the case the page's fourteenth point exists for. Work merged
# onto its dev branch was reported "not landed yet" and its workspaces were left
# behind, against point 4.
#
# THE RECORD IS A FILE, PER REPOSITORY, AND THERE IS EXACTLY ONE WAY INTO IT:
#
#   `workspaces.sh integration --repo <r> --branch <b> --why '<this work>'`
#
# Rich records it when a body of work starts. It is the form the page asks for,
# and the only form that can name a dev branch: nothing in this file can know
# that this work is not allowed into main yet. It is read at land time, and a
# land in a repository with NO record REFUSES and names that command — refusing
# is the only answer that is not a guess.
#
# ===========================================================================
# THERE IS NO FLOOR, AND DELETING IT IS THE POINT — 2026-09-12
# ===========================================================================
# Until 2026-09-12 a "first-registration" floor read the main checkout's own
# current branch, wrote it down as though it were the recorded fact, and froze a
# copy of it onto every agent registered afterwards; `integration_target`
# preferred that frozen copy over the live record. It fired from
# `record_session_start` — earlier even than the comment above it claimed.
#
# IT WAS WORSE THAN THE REFUSAL IT REPLACED, and the comparison that shows it was
# reproduced independently by two reviewers:
#
#   with NO record at all      the land refuses, Rich records the branch, and
#                              the land then SUCCEEDS. The refusal HEALS.
#   with the floor's record    the wrong branch is frozen onto an agent already
#                              in flight. Recording the right branch afterwards
#                              cannot reach it, its land refuses FOREVER with
#                              "is not in main", its workspace is left behind,
#                              and point 5 is blocked — against point 14's own
#                              "'it cannot go to main yet' is never a reason for
#                              anything to be left behind".
#
# A derived value that cannot be corrected is not a floor; it is a wrong answer
# with the authority of a recorded one. "Nothing infers it and nothing guesses
# it" (point 14) is the whole sentence, so the derivation is gone, the
# `source: first-registration` record is gone, and the frozen per-agent copy is
# gone with them. THE LIVE RECORD IS THE ONLY ANSWER, and because it is the only
# answer it can always be corrected.
#
# ===========================================================================
# THE RECORD IS PER BODY OF WORK, NOT PER REPOSITORY — 2026-09-12
# ===========================================================================
# Point 14 says "the branch THIS WORK integrates on". The record had one slot
# per repository, read live at land time, and the code's own docstring called it
# "the branch each REPOSITORY's work integrates" — which is a different sentence
# and the wrong one.
#
# Point 5 permits a second body of work to start in a repository while the first
# one's agents are still running: it blocks new work only for FINISHED work that
# is neither landed nor discarded. With one slot per repository, recording the
# second body's branch — which point 14 requires Rich to do — MOVED THE FIRST
# BODY'S RUNNING AGENTS ONTO IT, retroactively. Their work was merged onto the
# branch they were spawned for, their land was then measured against a branch
# they had never heard of, it refused forever, and their workspaces were
# stranded. The superseded value went into a `history` list that nothing read.
#
# So a recording now names a BODY OF WORK: an id, its repository, and the branch
# it integrates on. Each repository has a CURRENT body of work, which is what a
# new agent binds to when it is registered, and that binding is by ID and never
# by value.
#
# THE INDIRECTION IS THE WHOLE DESIGN, and it is what the deleted floor got
# wrong. Freezing the BRANCH onto an agent gives an answer that cannot be
# corrected. Binding the WORK ID gives one that can: the work's branch stays
# live and correctable — correcting it corrects every agent bound to that work,
# in flight — while starting a DIFFERENT body of work creates a different id and
# cannot reach backwards into the first one.
#
#   `workspaces.sh integration --repo <r> --branch <b> --why '<this work>'`
#       starts a body of work (or re-states the current one, if the branch is
#       unchanged: recording the same branch twice is the same work).
#   `workspaces.sh integration --repo <r> --branch <b> --correct --why '<...>'`
#       CORRECTS the branch of the body of work that is current, keeping its id,
#       so every agent already bound to it moves with it.
#
# ===========================================================================
# THE SPAWN IS REFUSED, NOT THE LAND — 2026-09-12, round 7
# ===========================================================================
# Until round 7 an agent registered before anything was recorded was "bound to
# nothing, heals later": `integration_target` fell back to the repository's
# CURRENT body of work at land time. Both round-6 reviewers proved that is not
# a heal but a guess about WHICH body of work the agent belongs to
# (certification-sage-round6-2026-09-12.md §2, S1–S4;
# certification-frank-round6-2026-09-12.md §5): an agent bound to nothing was
# judged against whichever body of work happened to be current when it landed,
# so a second, unrelated recording made in between MOVED its land verdict,
# while a properly bound control agent was unmoved. "Nothing infers it and
# nothing guesses it" (point 14) is the whole sentence, and "current at land
# time" is an inference.
#
# So the page's own ordering is enforced where it says: "RECORDED when that
# work starts, BEFORE ITS FIRST AGENT IS SPAWNED." `register_cc` and
# `register_spawn` REFUSE when any repository the agent will work in has no
# current body of work, naming the recording command — point 3's shape, "if
# registration fails, the spawn does not happen". Every spawned agent is
# therefore bound at its spawn, and `integration_target` has no fallback: a
# chain bound to nothing refuses and names the command.
#
# The one kind of record that is never spawned through the guard — an
# UNREGISTERED workspace the point-3 sweep found (an orphan), or a native start
# the platform reported for a spawn no guard registered (provisional) — has no
# spawn at which to be refused. It binds at the first sweep after a body of
# work exists for its repository (`scan_unregistered`), and that binding is
# recorded on it by id and never moves afterwards; until then its land refuses
# and names the command. That is the only path left that reads "current", it
# is written down as a recorded fact the moment it is read, and it covers no
# agent this system spawned.

def _integration_path():
    return _p("integration.json")


def _norm_repo(repo):
    return main_checkout(repo) or realpath(repo)


def _integration_file():
    return read_json(_integration_path()) or {}


def _work_by_id(work_id):
    """The body of work with this id — including one that is no longer current,
    because that is precisely the one an agent in flight is still bound to."""
    if not work_id:
        return None
    return (_integration_file().get("works") or {}).get(work_id)


def integration_record(repo):
    """The recorded integration branch of a repository's CURRENT body of work, or
    None. Never inferred.

    An agent asks `integration_target`, which asks the work IT is bound to. This
    is the answer for a caller that has no agent — a consumer asking about the
    repository, or Rich asking what he last recorded."""
    return _work_by_id((_integration_file().get("current") or {}).get(_norm_repo(repo)))


def all_integration_records():
    """{repository: its current body of work} — one row per repository, the shape
    every reader of this already expects."""
    cur = _integration_file().get("current") or {}
    return dict((r, _work_by_id(w)) for r, w in cur.items() if _work_by_id(w))


def all_bodies_of_work():
    """Every body of work ever recorded, current or superseded. A superseded one
    is not history: an agent spawned for it is still bound to it and still lands
    against it, which is the whole reason this is keyed by work and not by
    repository."""
    return dict(_integration_file().get("works") or {})


def _new_work_id(cur, main):
    n = 1
    base = _key_segment(os.path.basename(main.rstrip("/")) or "repo")
    while "%s-%03d" % (base, n) in (cur.get("works") or {}):
        n += 1
    return "%s-%03d" % (base, n)


def _write_integration(main, branch, source, why="", by_session="", correct=False):
    with Lock():
        cur = _integration_file()
        cur.setdefault("works", {})
        cur.setdefault("current", {})
        prior_id = cur["current"].get(main)
        prior = cur["works"].get(prior_id) if prior_id else None
        if prior and prior.get("branch") == branch:
            return prior                     # the same body of work, re-stated
        if correct:
            if not prior:
                raise SpecError("there is no body of work recorded for %s to correct. Record one: "
                                "workspaces.sh integration --repo %s --branch %s --why '<this work>'"
                                % (main, main, branch))
            prior.setdefault("corrections", []).append(
                {"from": prior.get("branch"), "at": iso(), "why": why or "",
                 "by_session": by_session or ""})
            prior["branch"] = branch
            prior["recorded_at"] = iso()
            cur["works"][prior_id] = prior
            write_json(_integration_path(), cur)
            rec = prior
        else:
            wid = _new_work_id(cur, main)
            rec = {"id": wid, "repo": main, "branch": branch, "recorded_at": iso(),
                   "source": source, "why": why or "", "by_session": by_session or "",
                   "corrections": []}
            cur["works"][wid] = rec
            cur["current"][main] = wid
            write_json(_integration_path(), cur)
    event("integration-recorded", repo=main, branch=branch, source=source,
          work=rec.get("id"), corrected=bool(correct), why=why or None)
    return rec


def record_integration(repo, branch, why="", by_session="", correct=False):
    """Point 14, the form the page asks for: Rich records the branch this body of
    work integrates on, before its first agent is spawned.

    Without `correct`, this STARTS a body of work: a new id, which becomes the
    repository's current one, and which every agent registered afterwards binds
    to. Agents already bound to an earlier body of work are untouched — that is
    the failure this shape exists to end.

    With `correct`, the branch of the CURRENT body of work is changed in place,
    keeping its id, so every agent bound to it moves with it. That is the other
    half of point 14: a recorded fact must stay correctable, or the refusal it
    causes can never heal."""
    main = main_checkout(repo)
    if not main:
        raise SpecError("the repository %s could not be resolved from git" % repo)
    branch = (branch or "").strip()
    if not branch:
        raise SpecError("name the branch this work integrates on (point 14)")
    if branch.startswith(CC_PREFIX) or branch.startswith(NATIVE_BRANCH_PREFIX):
        raise SpecError("%s is an agent's own workspace branch. Finished work never waits on the "
                        "agent's own branch (point 14); an integration branch is main or this work's "
                        "dev branch." % branch)
    if not branch_tip(main, branch):
        raise SpecError("there is no branch %s in %s. The branch a body of work integrates on is "
                        "recorded before its first agent is spawned, so it exists by then (point 14)."
                        % (branch, main))
    return _write_integration(main, branch, "recorded", why, by_session, correct)


def _add_workspace(rec, kind, repo, path, branch, source):
    path = realpath(path) if path else ""
    for w in rec["workspaces"]:
        if (path and w.get("path") == path) or (not path and branch and w.get("branch") == branch):
            if branch and not w.get("branch"):
                w["branch"] = branch
            return w
    w = {"kind": kind, "repo": realpath(repo), "path": path, "branch": branch or "",
         "registered_at": iso(), "source": source, "deleted_at": None}
    rec["workspaces"].append(w)
    _remember_repo(repo)
    _bind_body_of_work(rec, repo)
    return w


def _bind_body_of_work(rec, repo):
    """WHICH BODY OF WORK THIS AGENT BELONGS TO IN THIS REPOSITORY (point 14).

    The agent is bound to the work's ID, never to its branch. The id is the one
    thing about a body of work that does not change, so binding it keeps the
    branch live and correctable for an agent in flight while making a SECOND
    body of work in the same repository unable to reach backwards into this one.
    A frozen branch would do neither; that is what the deleted floor did."""
    main = _norm_repo(repo)
    wid = (_integration_file().get("current") or {}).get(main)
    if not wid:
        return False                 # nothing recorded: a spawn is refused before this (point 14)
    rec.setdefault("integration_work", {})
    rec["integration_work"].setdefault(main, wid)
    return True


def _unrecorded_repos(repos):
    """The repositories among `repos` with NO current body of work recorded —
    the ones point 14 forbids spawning into. Deduplicated, in order.

    A PATH THAT IS NOT A GIT REPOSITORY IS NEVER ONE OF THEM, and that is not a
    convenience — it is the same rule the deleted floor was deleted for. Point
    14 records A BRANCH, `record_integration` refuses any path git cannot
    resolve ("the repository %s could not be resolved from git"), and a
    directory with no branches has no land to measure and nothing to record. So
    until this line existed, an entity root that was not a repository was
    refused EVERY spawn, forever, and the remedy the refusal printed could not
    be run:

        spawn  -> exit 2 "no branch is recorded as the one this work integrates
                  on in <dir> ... Record it, then spawn: workspaces.sh
                  integration --repo <dir> --branch <main|dev/...>"
        remedy -> exit 2 "the repository <dir> could not be resolved from git"

    That is the shape this file already rejects by name: "with NO record at all
    the refusal HEALS"; a refusal that cannot heal "is not a floor, it is a
    wrong answer with the authority of a recorded one". Every repository still
    needs its record, including the repository of every cc/ workspace — nothing
    about a real repository is relaxed here."""
    out, seen = [], set()
    for r in repos:
        main = main_checkout(r) if r else ""
        if not main or main in seen:
            continue
        seen.add(main)
        if not integration_record(main):
            out.append(main)
    return out


def _refuse_unrecorded(repos, what):
    """Point 14, at the spawn: "RECORDED when that work starts, before its first
    agent is spawned. Nothing infers it and nothing guesses it." Raises,
    naming the recording command, when any repository in `repos` has no
    current body of work."""
    missing = _unrecorded_repos(repos)
    if missing:
        raise SpecError("no branch is recorded as the one this work integrates on in %s, so %s is "
                        "refused. The branch a body of work integrates on is RECORDED when that work "
                        "starts, before its first agent is spawned; nothing infers it and nothing "
                        "guesses it (point 14). Record it, then spawn:\n    workspaces.sh integration "
                        "--repo %s --branch <main|dev/...> --why '<this body of work>'"
                        % (", ".join(missing), what, missing[0]))


def _drop_orphans_for(path):
    """A registration arriving for a workspace a scan had called unregistered
    wins: the scan's record is withdrawn (call under the lock)."""
    for r in all_agents():
        if r.get("orphan") and not r.get("disposition") and any(
                w.get("path") == path for w in live_workspaces(r)):
            os.unlink(agent_path(r["key"]))
            event("unregistered-withdrawn", key=r["key"], path=path)


def live_workspaces(rec):
    return [w for w in rec.get("workspaces") or [] if not w.get("deleted_at")]


# ---------------------------------------------------------------------------
# point 11 — what "finished" means
# ---------------------------------------------------------------------------

def finished_state(rec, cache=None):
    """(finished, paused, why). Built only from recorded facts (point 11) and
    from the operating system for session end (point 12). Nothing else."""
    if rec.get("disposition"):
        return True, False, "its work was %s" % rec["disposition"].get("kind")
    if rec.get("orphan"):
        return True, False, "it has no registration: finished work of an ended session (point 3)"
    if rec.get("creation_failed"):
        return True, False, "its workspace creation failed, so it was never spawned (point 3)"
    if rec.get("session_id"):
        st, why = session_state(rec["session_id"], rec.get("session_identity"), cache)
        if st == "ended":
            return True, False, "its session has ended: %s (point 12)" % why
    end = rec.get("end")
    if end:
        if end.get("signal") == "stopped":
            return True, False, "it was stopped (%s)" % end.get("detail", "")
        if rec.get("handed_in"):
            return True, False, "it ended after handing in its work (point 11)"
        pause = rec.get("pause")
        if pause and pause.get("at", 0) <= end.get("at", 0):
            return False, True, "paused until: %s" % (pause.get("until") or "(nothing named)")
        return True, False, "the platform recorded the end of its run (%s at %s)" % (
            end.get("signal"), iso(end.get("at")))
    if rec.get("pause"):
        return False, True, "paused until: %s" % (rec["pause"].get("until") or "(nothing named)")
    return False, False, "its run has not ended"


# ---------------------------------------------------------------------------
# points 1, 2, 3, 6 — registration
# ---------------------------------------------------------------------------

def _check_workspace_name(path, branch):
    kind = classify(path, branch)
    if kind == "codex":
        raise SpecError("%s is a codex/ workspace. codex/ is never touched, and an agent never works "
                        "inside one; it works from a copy in its own cc/ workspace (point 2)." % path)
    if kind == "":
        raise SpecError("%s is on branch %r. A non-native workspace must be named cc/; creating one "
                        "that is not is refused (points 1, 3)." % (path, branch))
    return kind


def register_cc(session_id, name, repo, path, branch, identity=None):
    """Point 3, event 1, for a cc/ workspace: registered BEFORE it exists.
    create-teammate-worktree.sh calls this first; if it raises, nothing is
    created and no spawn can name the workspace."""
    if not session_id:
        raise SpecError("no session id: a registration without one can never be matched to a spawn")
    if not NAME_RE.match(name or ""):
        raise SpecError("%r is not a usable agent name" % name)
    if not (branch or "").startswith(CC_PREFIX):
        raise SpecError("branch %r is not named cc/ (point 1)" % branch)
    repo = main_checkout(repo)
    if not repo:
        raise SpecError("the repository could not be resolved from git")
    ident = identity or identity_for(session_id)
    if not ident:
        raise SpecError("the session's process identity could not be read from the operating system, "
                        "so its end could never be told (point 12); registration refused")
    # Point 14: the workspace is the first half of the spawn (registered when it
    # is created, points 1 and 3), so the record has to exist before it too — a
    # registration made with nothing recorded would be a workspace bound to no
    # body of work, and its spawn would then be refused anyway, leaving a
    # registered, never-spawned workspace that point 5 cannot see until its
    # session ends. Refusing here leaves nothing behind at all.
    _refuse_unrecorded([repo], "creating %s's workspace" % name)
    key = named_key(session_id, name)
    with Lock():
        rec = load_agent(key) or new_record(key, name=name, session_id=session_id)
        # ONE WORKSPACE PER REPOSITORY PER NAME - AND THAT IS THE WHOLE RULE.
        #
        # This used to refuse ANY second registration under a name that had been
        # spawned, which reads as "names are used once" and is not the same
        # sentence: a name is used once for an AGENT, and point 10 says that one
        # agent's workspaces - "every workspace and branch it has" - go together.
        # On 2026-09-17 four teammates needed a workspace in a second repository
        # and this refusal sent every one of them to a SECOND NAME, which made
        # each a second agent landed separately; the CEO found the stray branch
        # of one (`cc/norm-opus-wireguide1`) himself.
        #
        # What must still be refused is unchanged, and is refused below by the
        # question it actually asks:
        #   - a second workspace in the SAME repository under one name (it would
        #     want the same cc/<name> branch; point 3's one registration);
        #   - a name whose agent is FINISHED (point 9: a finished agent never
        #     writes again, so it can have no use for a workspace) or whose work
        #     is already landed or discarded. That is where "names are used
        #     once" lives, and a reused name is still refused at the SPAWN by
        #     register_spawn.
        if rec.get("disposition"):
            raise SpecError("agent %s's work was already %s in this session; names are used once"
                            % (name, rec["disposition"].get("kind")))
        clash = [w for w in live_workspaces(rec)
                 if w.get("kind") == "cc" and realpath(w.get("repo") or "") == repo]
        if clash:
            raise SpecError("agent %s already has a workspace in %s (%s). One workspace per repository "
                            "per teammate: a second one in the same repository under the same name is "
                            "refused (point 3). Another REPOSITORY under this name is not - that is "
                            "what --repo <repo> --repo <repo> creates."
                            % (name, repo, clash[0].get("path") or clash[0].get("branch")))
        if rec.get("agent_id"):
            fin, _paused, why = finished_state(rec)
            if fin:
                raise SpecError("agent %s is finished (%s), so it gets no further workspace: a finished "
                                "agent never writes again (point 9), and its work is landed or "
                                "discarded (points 5, 7). For new work, spawn a fresh teammate - names "
                                "are used once." % (name, why))
        rec["session_identity"] = ident
        w = _add_workspace(rec, "cc", repo, path, branch, "create-teammate-worktree")
        w["created"] = False
        save_agent(rec)
    event("registered-cc", key=key, repo=repo, path=realpath(path), branch=branch)
    return rec


def confirm_cc(session_id, name, path, ok, why=""):
    key = named_key(session_id, name)
    with Lock():
        rec = load_agent(key)
        if not rec:
            raise SpecError("no registration for %s" % name)
        for w in rec["workspaces"]:
            if w.get("path") == realpath(path):
                w["created"] = bool(ok)
        if not ok:
            rec["creation_failed"] = {"at": now(), "why": why}
        save_agent(rec)
    event("cc-created" if ok else "cc-creation-failed", key=key, path=realpath(path), why=why)
    return rec


def prompt_lines(prompt, marker):
    out = []
    for line in (prompt or "").splitlines():
        m = re.match(r"^\s*%s:\s*(.+?)\s*$" % re.escape(marker), line)
        if m:
            out.append(m.group(1))
    return out


def _planned_workspaces(payload):
    """The cc/ workspaces a DRY evaluation's caller is ABOUT to create, read from
    `richos_spawn_check.planned`. Never read for a live call."""
    chk = payload.get("richos_spawn_check")
    if not isinstance(chk, dict):
        return []
    out = []
    for p in chk.get("planned") or []:
        if isinstance(p, dict) and p.get("path"):
            out.append({"path": realpath(str(p["path"])), "repo": str(p.get("repo") or ""),
                        "branch": str(p.get("branch") or "")})
    return out


def is_spawn_check(payload):
    """Is this a DRY evaluation? Only under BOTH halves, and the second half is
    what makes it structural rather than a promise:

      1. the caller asked for one (`richos_spawn_check` is present), and
      2. the platform minted NO `tool_use_id`.

    A live PreToolUse[Agent] call always carries a tool_use_id: `register_spawn`
    has refused every payload without one since it was written, and spawns
    happen, so a payload that lacks one was never going to be registered anyway.
    The marker therefore cannot turn a live spawn into an unregistered one - it
    can only describe a call that has not been made yet."""
    return bool(isinstance(payload.get("richos_spawn_check"), dict)
                and not str(payload.get("tool_use_id") or ""))


def _check_planned_workspace(p, name):
    """The dry equivalent of clause 7a for a workspace that does not exist yet.

    "Is it registered, created, and on its registered branch?" has no answer
    before it is created, and a check with no answer must not be waved through.
    So the question that IS answerable now is asked instead, and it is the same
    question one step earlier: does its repository resolve, is its name the
    teammate's cc/ name, is its path absent, is its branch free, and can it be
    created? Every one of those is what create-teammate-worktree.sh refuses on,
    evaluated before it has made anything."""
    path, repo, branch = p["path"], p["repo"], p["branch"]
    main = main_checkout(repo) if repo else ""
    if not main:
        raise SpecError("the repository of the planned workspace %s could not be resolved from git "
                        "(repo %r)" % (path, repo))
    if branch != CC_PREFIX + name:
        raise SpecError("the planned workspace %s would be on %r; a teammate's workspace is named %s%s "
                        "(point 1)" % (path, branch, CC_PREFIX, name))
    if os.path.lexists(path):
        raise SpecError("%s already exists, so it cannot be created for %s. Pick a fresh identifier, or "
                        "land/discard whatever owns it." % (path, name))
    if branch_tip(main, branch):
        raise SpecError("branch %s already exists in %s - a teammate name is used once; pick a fresh "
                        "identifier" % (branch, main))
    probe = os.path.dirname(path)
    while probe and probe != os.path.dirname(probe) and not os.path.isdir(probe):
        probe = os.path.dirname(probe)
    if not probe or not os.access(probe, os.W_OK):
        raise SpecError("%s cannot be created: %s is not writable" % (path, probe or "/"))
    return main


def register_spawn(payload, entity, dry=False):
    """PreToolUse[Agent], point 3: the registration a spawn needs. Raises
    SpecError -> the spawn does not happen. Returns the record.

    A DRY EVALUATION (`dry=True`, reached through the `check-spawn` verb) asks
    the same question about a payload that HAS NOT BEEN SENT YET. Every refusal
    below is evaluated by the same code; the only difference is that nothing is
    written - no record, no binding to a body of work, no event.

    WHY IT EXISTS. Until 2026-09-13 the only way to find out whether a spawn
    would be refused was to make it: the guards run at PreToolUse, so a brief
    with two problems cost two dispatches, and each cost a round trip in front
    of the CEO. A pre-flight that could not run this function had to fake a
    session_id and a tool_use_id, which this function correctly refuses - so the
    pre-flight carried a known false positive on its most important check,
    which is a defense that reports "on" while protecting nothing.

    IT CANNOT BE USED TO SKIP A REGISTRATION. See `is_spawn_check`: the dry path
    is reached only when the platform minted no tool_use_id, and a live call
    always has one."""
    sid = str(payload.get("session_id") or "")
    tuid = str(payload.get("tool_use_id") or "")
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    name = str(ti.get("name") or "")
    prompt = str(ti.get("prompt") or "")
    isolation = str(ti.get("isolation") or "")
    planned = _planned_workspaces(payload) if dry else []
    planned_by_path = dict((p["path"], p) for p in planned)
    if not sid or (not tuid and not dry):
        raise SpecError("the spawn payload carries no session_id/tool_use_id, so it cannot be registered")
    if not NAME_RE.match(name):
        raise SpecError("the spawn has no usable name, so it cannot be registered")
    cc_paths = [realpath(p) for p in prompt_lines(prompt, "cross-repo-worktree") if p]
    if ti.get("cwd"):
        cc_paths.append(realpath(str(ti.get("cwd"))))
    continues = [p.split()[0] for p in prompt_lines(prompt, "continues") if p.split()]
    lands_pending = [p.split()[0] for p in prompt_lines(prompt, "lands-pending") if p.split()]
    ceo_ordered = prompt_lines(prompt, "ceo-ordered")
    stray = [p["path"] for p in planned if p["path"] not in cc_paths]
    if stray:
        raise SpecError("the planned workspace %s is on no 'cross-repo-worktree:' line of the prompt, so "
                        "the spawn would never name it" % stray[0])

    # Point 5: new work is blocked while finished work is pending - except work
    # whose only purpose is getting that work landed (continues:/lands-pending:).
    report = {}
    items = pending(sid, entity, deadline=_gate_deadline(GATE_SPAWN_BUDGET), report=report)
    blocking = [i for i in items if i["blocks_new_work"]]
    helps = set(continues + lands_pending)
    if blocking and not (helps & set(value for i in blocking for value in (i["name"], i["key"]))):
        extra = ""
        if report.get("deferred"):
            extra = ("\n  (The gate answered inside its budget rather than overrunning this hook's "
                     "timeout: %s could not be checked for an automatic land, so it stays pending. "
                     "Land it by hand - `workspaces.sh land <name>` has no budget.)"
                     % ", ".join(sorted(set(report["deferred"]))))
        raise SpecError(gate_message(blocking, "start new work", spawn=True) + extra)
    continuation_keys = []
    for c in continues:
        match = [i for i in items if i["name"] == c or i["key"] == c]
        if not match:
            raise SpecError("continues: %s - there is no pending finished agent of that name to continue "
                            "(point 7)" % c)
        if len(match) != 1:
            raise SpecError("continues: %s is ambiguous; name its exact registered key" % c)
        continuation_keys.append(match[0]["key"])
        _require_clean(load_agent(match[0]["key"]), "continue it (its workspaces are deleted when the new "
                       "agent starts, point 7)")

    ident = identity_for(sid)
    if not ident:
        raise SpecError("the session's process identity could not be read from the operating system; "
                        "a registration that could never tell its session ended is refused (point 12)")
    key = named_key(sid, name)
    with Lock():
        rec = load_agent(key)
        if [p for p in cc_paths if p not in planned_by_path]:
            if not rec:
                raise SpecError("no registration exists for %s in this session. A cc/ workspace is "
                                "registered when it is created: use create-teammate-worktree.sh <repo> %s "
                                "(points 1, 3)." % (name, name))
        rec = rec or new_record(key, name=name, session_id=sid)
        if rec.get("agent_id") or rec.get("disposition"):
            raise SpecError("agent %s already ran in this session; names are used once" % name)
        known = dict((w.get("path"), w) for w in live_workspaces(rec) if w.get("kind") == "cc")
        planned_repos = []
        for p in cc_paths:
            if p in planned_by_path:
                planned_repos.append(_check_planned_workspace(planned_by_path[p], name))
                continue
            w = known.get(p)
            if not w:
                raise SpecError("%s was not registered for %s in this session (points 1, 3)" % (p, name))
            if not w.get("created") or not os.path.isdir(p):
                raise SpecError("%s is registered but was never created" % p)
            cur = ""
            for e in worktree_list(p) or []:
                if e["path"] == p:
                    cur = e["branch"]
            _check_workspace_name(p, cur)
            if cur != w.get("branch"):
                raise SpecError("%s is on %r, not the registered branch %r" % (p, cur, w.get("branch")))
        # Point 14: "RECORDED when that work starts, BEFORE ITS FIRST AGENT IS
        # SPAWNED. Nothing infers it and nothing guesses it." Every repository
        # this agent will work in - the entity, and the repository of every
        # cc/ workspace it names - must have a current body of work, and the
        # agent is BOUND to it here, by id, at the spawn. With no record the
        # spawn does not happen (point 3), and the refusal names the command.
        # This is what leaves `integration_target` no fallback to "current".
        # A PLANNED workspace's repository counts the same: its record has to
        # exist before the workspace is created (register_cc refuses without
        # one), so a dry evaluation that skipped it would report a pass for a
        # spawn whose very next step is refused.
        work_repos = ([main_checkout(entity) or realpath(entity)] if entity else []) \
            + [w.get("repo") for w in live_workspaces(rec) if w.get("repo")] \
            + [main_checkout(p) or realpath(p) for p in cc_paths if p not in planned_by_path] \
            + planned_repos
        _refuse_unrecorded(work_repos, "the spawn of %s" % name)
        if dry:
            return rec
        for r_ in work_repos:
            _bind_body_of_work(rec, r_)
        rec.update({"tool_use_id": tuid, "subagent_type": str(ti.get("subagent_type") or ""),
                    "isolation": isolation, "session_identity": ident,
                    "ceo_ordered": (ceo_ordered[0] if ceo_ordered else rec.get("ceo_ordered")),
                    "continues": continuation_keys,
                    "lands_pending": lands_pending, "entity": realpath(entity),
                    "spawned_at": iso()})
        rec.pop("creation_failed", None)
        save_agent(rec)
        if entity:
            _remember_repo(entity)
    event("registered-spawn", key=key, tool_use_id=tuid, cc=cc_paths, isolation=isolation,
          continues=continues, lands_pending=lands_pending)
    return rec


def withdraw_cc(session_id, name, why=""):
    """THE INVERSE OF `register_cc`, for a workspace whose spawn never happened.

    Point 3 is "if registration fails, the spawn does not happen", and its other
    half has never had a command: a workspace registered and created for a spawn
    that then could not be made is a registration for work that will not happen.
    Leaving it costs the name (names are used once) and leaves a directory and a
    branch behind for a land to puzzle over.

    IT REFUSES ANYTHING THAT EVER RAN. No agent_id, no tool_use_id, no
    spawned_at, no disposition - if any of those is set this is not an
    un-happened spawn, and `workspaces.sh land` or `discard` is the answer, not
    this. The record is then deleted rather than dispositioned: there is no work
    to account for, and the event log keeps the trace.

    THE DELETION IS `_delete`'s, NOT ITS OWN, and that is the whole design of
    this function rather than a detail. This first hand-rolled the sequence -
    remove_workspace, then delete_branch, in a loop - and it was correct on the
    day it was written. Hours later the container reaper landed, adding
    `stop_containers` inside `_delete` because an agent's container had outlived
    its agent and its worktree by six weeks. A hand-rolled copy would have
    quietly kept leaving those containers behind, and nothing would have said
    so. "Land, discard and the retry are the only code in the engine that
    deletes a workspace" is an invariant that holds only while every deleter
    goes through the same one; a fourth copy is how that stops being true.
    """
    key = named_key(session_id, name)
    rec = load_agent(key)
    if not rec:
        raise SpecError("there is no registration for %s in this session to withdraw" % name)
    for field, what in (("agent_id", "it ran"),
                        ("tool_use_id", "its spawn was registered"),
                        ("spawned_at", "its spawn was registered"),
                        ("disposition", "its work was already decided")):
        if rec.get(field):
            raise SpecError("%s is not an un-happened spawn (%s). Use `workspaces.sh land %s` or "
                            "`workspaces.sh discard %s` - this command withdraws only a registration "
                            "whose spawn never happened." % (name, what, name, name))
    ws = [w for w in live_workspaces(rec) if w.get("path")]
    paths = [w.get("path") for w in ws]
    _delete(rec, ws, branches=True, why="withdrawn: " + (why or "its spawn never happened"))
    fresh = load_agent(key) or rec
    if [w for w in live_workspaces(fresh) if w.get("path")] or fresh.get("deletion"):
        raise SpecError("%s could not be fully withdrawn: %s"
                        % (name, (fresh.get("deletion") or {}).get("last_error", "unknown")))
    with Lock():
        try:
            os.remove(agent_path(key))
        except OSError:
            pass
    event("withdrawn-cc", key=key, why=why, paths=paths)
    return {"withdrawn": paths}


def register_readonly(payload, entity):
    """Point 9: "The platform restarts finished agents (14 times observed). A
    restarted agent is refused every tool, so it cannot write anywhere,
    including after its workspace is gone."

    THE LOCK-OUT FINDS AN AGENT THROUGH ITS REGISTRATION, and a read-only type
    had none. READONLY_ALLOWLIST answers one question — does this agent need an
    isolated workspace? — and the spawn guard returned exit 0 on it before
    clause 7, so the type that needs no workspace also got no registration.
    barrier() then answered UNREGISTERED for it forever: it could never be
    found finished, so point 9 never fired for it once.

    That would be harmless if a read-only agent could not write. `Explore`'s
    allowlist is every tool EXCEPT Edit/Write/NotebookEdit, so IT CARRIES BASH:
    a restarted finished Explore can write anywhere a shell can, including
    after its workspace is gone. The exemption from isolation was never an
    exemption from the lock-out; it only looked like one.

    So a read-only spawn is registered here, with NO workspaces, and nothing
    else about it changes. It carries no name contract (a read-only spawn is
    not required to have a name, so the key is its tool_use_id), and it does
    not pass through point 5's new-work gate — that gate has never stopped an
    Explore spawn and widening it is not this fix. Because an agent that
    produced nothing counts as landed (point 7) and land() returns landed for
    an empty workspace list, it is landed the moment it finishes and never
    becomes pending work blocking the CEO's turn ends."""
    sid = str(payload.get("session_id") or "")
    tuid = str(payload.get("tool_use_id") or "")
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    if not sid or not tuid:
        raise SpecError("the spawn payload carries no session_id/tool_use_id, so it cannot be registered")
    name = str(ti.get("name") or "")
    if not NAME_RE.match(name):
        name = "readonly-" + _key_segment(tuid)[:40]
    ident = identity_for(sid)
    if not ident:
        raise SpecError("the session's process identity could not be read from the operating system; "
                        "a registration that could never tell its session ended is refused (point 12)")
    key = "%s--ro-%s" % (_key_segment(sid), _key_segment(tuid))
    with Lock():
        rec = load_agent(key)
        if rec and (rec.get("agent_id") or rec.get("disposition")):
            raise SpecError("this spawn is already registered as %s; a tool_use_id is used once" % key)
        rec = rec or new_record(key, name=name, session_id=sid)
        rec.update({"tool_use_id": tuid, "subagent_type": str(ti.get("subagent_type") or ""),
                    "isolation": str(ti.get("isolation") or ""), "session_identity": ident,
                    "readonly": True, "entity": realpath(entity), "spawned_at": iso()})
        save_agent(rec)
    event("registered-readonly", key=key, tool_use_id=tuid, subagent_type=rec.get("subagent_type"))
    return rec


def _is_key(s):
    return "--" in (s or "")


def _find_by_tool_use(session_id, tuid):
    for r in all_agents():
        if r.get("session_id") == session_id and r.get("tool_use_id") == tuid:
            return r
    return None


def _provisional_key(session_id, agent_id):
    return "%s--agent-%s" % (_key_segment(session_id), _key_segment(agent_id))


def _absorb_provisional(rec, prov_key):
    """The platform's own start and end for this agent — recorded against a
    PROVISIONAL record because nothing had bound its id to a registration yet —
    join the registration they belong to. Returns the provisional, or None.

    A provisional record that is still live has no facts of its own left after
    this and is removed, exactly as it always was. One that has already been
    DISPOSED OF (its native workspace landed on its own, which is what happens
    when the binding is missing for a whole run) is KEPT and stamped: it is the
    record of what the platform did, and deleting it to tidy up would delete the
    evidence that this reconciliation was needed."""
    prov = load_agent(prov_key)
    if not prov or prov.get("key") == rec.get("key"):
        return None
    for w in live_workspaces(prov):
        _add_workspace(rec, w["kind"], w["repo"], w["path"], w["branch"], w.get("source", ""))
    for f in ("started_at", "end", "handed_in"):
        if prov.get(f) and not rec.get(f):
            rec[f] = prov[f]
    if os.path.exists(agent_path(prov_key)):
        os.unlink(agent_path(prov_key))
    else:
        prov["absorbed_by"] = rec["key"]
        write_json(done_path(prov_key), prov)
    return prov


def bind_agent(session_id, tuid, agent_id, entity, name="", isolation=""):
    """PostToolUse[Agent]: the platform's agent id joins the registration, and
    the native workspace it created is registered (point 6).

    THE SPAWN WHOSE REGISTRATION WAS KILLED (2026-09-17). Point 3 says "if
    registration fails, the spawn does not happen", and the registration is
    written by the PreToolUse[Agent] guard — which the PLATFORM MAY KILL. On
    2026-09-17 at 10:57:48Z it did: `guard-worktree-isolation.sh` ran 10.027s
    against a 10s budget and the orchestrator's transcript records it as
    `hook_cancelled … timedOut: true`; two seconds later the same transcript
    records `Async agent launched successfully … agentId: a794a61d062e6d302`.
    A killed hook is not a refusal, so the spawn happened with no registration,
    and `sage-opus-nightly1`'s cc/ workspace could not be retired for hours —
    the ending point 11 requires "automatically and never by Rich noticing".
    The hook's budget is now larger than the longest wait inside it, but the
    platform decides when to kill a hook and no budget makes that impossible.

    So THIS call — the Post, which the platform delivers for a tool that
    actually ran, and which carries both the name the spawn used and the id it
    became — repairs the gap at the first moment it exists, seconds after the
    spawn rather than at the next land. It records what happened; it never
    certifies a spawn that was never checked, which is why the record says so."""
    if not AGENT_ID_RE.match(agent_id or ""):
        raise SpecError("not an agent id: %r" % agent_id)
    reconciled = ""
    with Lock():
        rec = _find_by_tool_use(session_id, tuid)
        if not rec and name and NAME_RE.match(name):
            cand = load_agent(named_key(session_id, name))
            if (cand and not cand.get("agent_id") and not cand.get("provisional")
                    and not cand.get("disposition") and not cand.get("orphan")):
                rec = cand
                reconciled = "PostToolUse[Agent]"
                rec["tool_use_id"] = rec.get("tool_use_id") or tuid
                rec["isolation"] = rec.get("isolation") or isolation
                rec["registration_reconciled"] = {
                    "at": now(), "agent_id": agent_id, "source": reconciled,
                    "why": "no registration carried this tool call, so the spawn's own "
                           "PreToolUse registration never ran; the platform's Post for the same "
                           "call names this session's registration for %r (point 3)" % name}
        if not rec:
            return None
        prov_key = _provisional_key(session_id, agent_id)
        rec["agent_id"] = agent_id
        if rec.get("isolation") == "worktree" and entity:
            main = main_checkout(entity) or realpath(entity)
            npath = os.path.join(main, ".claude", "worktrees", "agent-" + agent_id)
            _add_workspace(rec, "native", main, npath, NATIVE_BRANCH_PREFIX + agent_id, "PostToolUse[Agent]")
            _drop_orphans_for(realpath(npath))
        _absorb_provisional(rec, prov_key)
        save_agent(rec)
    event("bound", key=rec["key"], agent_id=agent_id, **({"reconciled": reconciled} if reconciled else {}))
    _on_start(rec)
    return rec


def record_start(session_id, agent_id, cwd, agent_type):
    """SubagentStart: the worker's own start. Registers its native workspace
    by the exact path the platform started it in (point 6)."""
    if not AGENT_ID_RE.match(agent_id or ""):
        return None
    top = ""
    if cwd and os.path.isdir(cwd):
        rc, out, _ = git(cwd, "rev-parse", "--show-toplevel")
        top = realpath(out.strip()) if rc == 0 else ""
    with Lock():
        key = key_for_id(agent_id)
        rec = load_agent(key) if key else None
        native = top if (top and is_native_path(top + os.sep) and top.endswith("agent-" + agent_id)) else ""
        if not rec:
            if not native:
                return None  # a helper with no workspace: nothing to register
            prov_key = "%s--agent-%s" % (_key_segment(session_id), _key_segment(agent_id))
            rec = read_json(agent_path(prov_key)) or new_record(prov_key, name="agent-" + agent_id,
                                                                  session_id=session_id, agent_id=agent_id,
                                                                  provisional=True)
            ident = identity_for(session_id)
            if ident:
                rec["session_identity"] = ident
        if native:
            branch = ""
            for e in worktree_list(native) or []:
                if e["path"] == native:
                    branch = e["branch"]
            _add_workspace(rec, "native", main_checkout(native), native, branch, "SubagentStart")
            _drop_orphans_for(native)
        rec["subagent_type"] = rec.get("subagent_type") or agent_type
        rec["started_at"] = rec.get("started_at") or iso()
        save_agent(rec)
    event("start", key=rec["key"], agent_id=agent_id, cwd=realpath(cwd))
    _on_start(rec)
    return rec


def _on_start(rec):
    """Point 7: when a continuing agent starts, the old agent's workspaces are
    deleted (its branches stay until the new agent's work lands)."""
    for old_key in rec.get("continues") or []:
        old = load_agent(old_key)
        if not old or (old.get("disposition") or {}).get("kind") == "continued":
            continue
        with Lock():
            old = load_agent(old_key)
            old["disposition"] = {"kind": "continued", "at": now(), "by": rec["key"]}
            save_agent(old)
        event("continued", key=old_key, by=rec["key"])
        _delete(old, [w for w in live_workspaces(old) if w.get("path")], branches=False,
                why="continued by %s (point 7)" % rec.get("name"))


# ---------------------------------------------------------------------------
# end of run, hand-in, pause (point 11)
# ---------------------------------------------------------------------------

def _record_for_agent(session_id, agent_id, name=""):
    key = key_for_id(agent_id) if agent_id else ""
    if key:
        return load_agent(key)
    if name and session_id:
        return load_agent(named_key(session_id, name))
    return None


def record_end(session_id, agent_id, signal_name, detail=""):
    """The platform's own end-of-run signal, recorded automatically."""
    with Lock():
        rec = _record_for_agent(session_id, agent_id)
        if not rec:
            return None
        if rec.get("disposition"):
            rec.setdefault("history", []).append({"at": iso(), "fact": "end after disposition", "signal": signal_name})
            save_agent(rec)
            return rec
        prev = rec.get("end")
        if prev and prev.get("signal") == "stopped" and signal_name != "stopped":
            return rec
        rec["end"] = {"at": now(), "signal": signal_name, "detail": detail}
        if signal_name == "stopped":
            rec["pause"] = None
        save_agent(rec)
    # The end-of-run signal carries the agent's id too, so it is the last
    # observation: a ref created in its LAST call is still its own, even if that
    # call's PostToolUse never arrived. It CONSUMES EVERY window still open —
    # calls overlap, so there can be more than one — and nothing that happens
    # after the run has ended is ever compared against them.
    observe_created_refs(rec, all_open=True)
    event("end", key=rec["key"], signal=signal_name, detail=detail)
    return rec


def _platform_projects_dir():
    return (os.environ.get("RICHOS_PROJECTS_DIR") or "").strip() or os.path.join(
        (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() or os.path.join(os.path.expanduser("~"), ".claude"),
        "projects")


def platform_agent_record(rec):
    """The platform's OWN per-agent record, which it writes beside the agent's
    transcript as <projects>/<project>/<session>/subagents/agent-<id>.meta.json
    and updates at the moment a run ends. Read, never written."""
    aid = (rec.get("agent_id") or "").strip()
    if not AGENT_ID_RE.match(aid):
        return None
    leaf = os.path.join("subagents", "agent-%s.meta.json" % aid)
    base = _platform_projects_dir()
    pats = []
    sid = (rec.get("session_id") or "").strip()
    if sid and "/" not in sid:
        pats.append(os.path.join(base, "*", sid, leaf))
    pats.append(os.path.join(base, "*", "*", leaf))
    for pat in pats:
        for p in sorted(glob.glob(pat)):
            d = read_json(p)
            if d is not None:
                return d
    return None


def platform_agent_records(session_id):
    """Every per-agent record the platform wrote for THIS session, as
    (agent_id, record). Read, never written. The platform writes one for each
    agent it actually launched, and it carries the NAME the spawn used and the
    TOOL CALL it came from — which is the binding the registry would otherwise
    have to guess at."""
    sid = (session_id or "").strip()
    if not sid or "/" in sid:
        return []
    out = []
    seen = set()
    for p in sorted(glob.glob(os.path.join(_platform_projects_dir(), "*", sid,
                                           "subagents", "agent-*.meta.json"))):
        aid = os.path.basename(p)[len("agent-"):-len(".meta.json")]
        if aid in seen or not AGENT_ID_RE.match(aid):
            continue
        d = read_json(p)
        if isinstance(d, dict):
            seen.add(aid)
            out.append((aid, d))
    return out


def platform_agent_transcript(rec):
    """The agent's own JSONL, beside the per-agent record the platform writes.

    <projects>/<project>/<session>/subagents/agent-<id>.jsonl — the same
    directory platform_agent_record reads, and the same file the session's
    scratch `tasks/<id>.output` is a symlink to. Read, never written."""
    aid = (rec.get("agent_id") or "").strip()
    if not AGENT_ID_RE.match(aid):
        return ""
    leaf = os.path.join("subagents", "agent-%s.jsonl" % aid)
    base = _platform_projects_dir()
    sid = (rec.get("session_id") or "").strip()
    pats = []
    if sid and "/" not in sid:
        pats.append(os.path.join(base, "*", sid, leaf))
    pats.append(os.path.join(base, "*", "*", leaf))
    for pat in pats:
        for p in sorted(glob.glob(pat)):
            if os.path.isfile(p):
                return p
    return ""


def qa_throwaway_lines(ref, me=""):
    """What a QA teammate's walk wrote from scratch, said at its land.

    The CEO, 2026-09-20: "what else must be done to ensure the QA toolkit
    actually gets used?" The spawn carries the toolkit's index in; this is the
    other end — the land says what the walk wrote instead of reaching for it.
    111 helper scripts across eight walks is the baseline it measures against,
    and a number nobody ever reads is the same as no number.

    INFORMATION, NEVER A REFUSAL. A walk that genuinely needed a one-off is not
    a defect, and a land that refused over a count would be waived the first
    time it was right — which is how a guard dies. It never raises either: a
    counter that could break the deleter it hangs off would be a worse defect
    than the one it reports.

    NEVER SILENT. A transcript it cannot find is said so, with where it looked.
    A count that is absent because nothing looked reads exactly like a clean
    walk, and those are opposite facts."""
    out = []
    try:
        here = os.path.join(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))), "scripts", "lib")
        # Both modules carry a hyphen in their filename, so they are loaded by
        # path rather than imported by name — the same reason spawn.py has its
        # own _load. ONE definition of "is this a QA type" (qa-toolkit.py, off
        # QA_TOOLKIT_AGENTS) and ONE definition of what counts as a throwaway
        # (qa-throwaways.py); this file restates neither.
        qa_toolkit = _import_path("qa_toolkit", os.path.join(here, "qa-toolkit.py"))
        throwaways = _import_path("qa_throwaways", os.path.join(here, "qa-throwaways.py"))
        rec = _resolve(ref, me)
        stype = (rec.get("subagent_type") or "").strip()
        if not qa_toolkit.is_qa_type(stype):
            return []
        path = platform_agent_transcript(rec)
        if not path:
            return ["qa toolkit:  no transcript found for %s under %s — the count of "
                    "helper scripts this walk wrote was NOT taken"
                    % (rec.get("name") or ref, _platform_projects_dir())]
        events, rows = throwaways.scan(path)
        scripts, toolkit = throwaways.classify(events)
        n = len(scripts)
        if n:
            out.append("qa toolkit:  %d helper script%s written from scratch in this walk "
                       "(%s):" % (n, "" if n == 1 else "s", os.path.basename(path)))
            for s in sorted(scripts, key=lambda s: s["rows"][0])[:12]:
                out.append("               %s" % os.path.basename(s["path"]))
            if n > 12:
                out.append("               ... and %d more — "
                           "scripts/qa-throwaways.sh %s" % (n - 12, path))
        else:
            out.append("qa toolkit:  0 helper scripts written from scratch in this walk")
        if toolkit:
            out.append("               %d added to the committed toolkit, which is the "
                       "wanted behavior" % len(toolkit))
    except Exception as e:                                   # never break a land
        out = ["qa toolkit:  the count could not be taken (%s)" % str(e)[:160]]
    return out


def _import_path(name, path):
    import importlib.util
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# POINT 11's UNTIDY ENDINGS. "That covers every ending: it handed in its work,
# crashed, was cut off by a limit, OR WAS STOPPED." The tidy ending arrives as
# a hook: the LAST SubagentStop of a run carries the agent's own bound id, and
# record_end takes it. A STOPPED agent's run never reaches that point, so no
# SubagentStop is ever delivered for it — measured on this machine on
# 2026-09-13: of 24 runs the platform flagged stoppedByUser in 14 days, 23 had
# no terminal SubagentStop at all, and the two the CEO stopped that day
# (reed-opus-fr1/fr2, killed 18:24:21Z and 18:26:28Z with
# "[Request interrupted by user]" as the last line of each transcript) have
# ZERO rows in worktree-ledger.jsonl, which worker-ended-handoff.sh appends to
# on every SubagentStop and on nothing else. They were marked finished BY HAND
# at 22:56:32Z, four and a half hours later, which is exactly what point 11
# forbids ("automatically and never by Rich noticing").
#
# The signal does exist. The platform records the stop ITSELF, in the agent's
# own record, within 0-5 s of the last transcript row (measured across all 20
# flagged runs that still have transcripts). Reading a recorded terminal fact
# is not a liveness question: nothing here asks whether a process is alive, and
# a running agent never carries the flag.
PLATFORM_ENDINGS = (
    ("stoppedByUser", "stopped", "the platform recorded stoppedByUser: the run was stopped (point 11)"),
)


def observe_platform_end(rec):
    """Point 11: an ending the platform recorded in its own per-agent record,
    for which it delivers no hook, makes the agent finished — automatically,
    at the next moment anything asks."""
    if not rec or rec.get("end") or rec.get("disposition") or rec.get("orphan"):
        return rec
    d = platform_agent_record(rec)
    if not d:
        return rec
    for field, signal_name, why in PLATFORM_ENDINGS:
        if not d.get(field):
            continue
        with Lock():
            fresh = load_agent(rec["key"]) or rec
            if fresh.get("end") or fresh.get("disposition"):
                return fresh
            fresh["end"] = {"at": now(), "signal": signal_name, "detail": why, "source": field}
            fresh["pause"] = None
            save_agent(fresh)
        observe_created_refs(fresh, all_open=True)
        event("end", key=fresh["key"], signal=signal_name, detail=why, source=field)
        return fresh
    return rec


# POINT 3'S REGISTRATION, WHEN THE HOOK THAT WRITES IT WAS KILLED. The spawn is
# registered at PreToolUse[Agent] and bound at PostToolUse[Agent]; both are
# hooks, and a hook the platform kills still lets the tool run. Measured
# 2026-09-17 on this machine: `guard-worktree-isolation.sh` was killed at
# 10.027s against its 10s budget (orchestrator transcript, `hook_cancelled …
# timedOut: true`, tool_use_id toolu_01C3dCBDwFksv5tBHramMDch) and the agent
# launched anyway. The registry was then left with a NAMED record holding a cc/
# workspace and no agent id — `started_at` None, `end` None — beside a
# PROVISIONAL record holding the platform's own SubagentStart (10:57:50Z) and
# SubagentStop (11:13:58Z) for the very same run. `land` refused the finished
# work with "its run has not ended", and the only ways left to retire it were
# the ones point 11 forbids ("automatically and never by Rich noticing").
#
# The facts were never missing — only the JOIN between them was, and the
# platform records that join itself, in the same per-agent file
# `observe_platform_end` already reads: `{"name": "sage-opus-nightly1",
# "toolUseId": "toolu_01C3…", "agentType": "sage"}`. So the registry adopts it,
# at the next moment anything asks, exactly as it adopts `stoppedByUser`.
#
# WHAT THIS IS NOT. It does not certify a spawn: the guard's checks never ran
# for that call and cannot be run after the fact, so the adoption is recorded on
# the record (`registration_reconciled`) and in the event log, where a reader
# sees that this registration was repaired rather than made. It never invents an
# ending either — a registration with no provisional twin adopts an id and stays
# unfinished, because nothing has recorded that its run ended.
def observe_platform_binding(rec):
    """Point 3 + point 11: the agent a registration became, taken from the
    platform's own record of the spawn when nothing bound it at the time."""
    if not rec or rec.get("agent_id") or rec.get("provisional") or rec.get("orphan"):
        return rec
    if rec.get("disposition"):
        return rec
    sid = str(rec.get("session_id") or "")
    name = str(rec.get("name") or "")
    if not sid or not NAME_RE.match(name):
        return rec
    tuid = str(rec.get("tool_use_id") or "")
    hits = [(aid, d) for aid, d in platform_agent_records(sid)
            if (str(d.get("toolUseId") or "") == tuid if tuid
                else str(d.get("name") or "") == name)]
    # Nothing recorded, or more than one record answering to it: a reconciliation
    # is an adoption of a recorded fact, never a choice between candidates.
    if len(hits) != 1:
        return rec
    aid, meta = hits[0]
    if not tuid and str(meta.get("name") or "") != name:
        return rec
    prov_key = _provisional_key(sid, aid)
    bound_to = key_for_id(aid)
    if bound_to and bound_to not in (rec["key"], prov_key):
        return rec              # that id already belongs to another registration
    with Lock():
        fresh = load_agent(rec["key"]) or rec
        if fresh.get("agent_id") or fresh.get("disposition"):
            return fresh
        fresh["agent_id"] = aid
        fresh["tool_use_id"] = fresh.get("tool_use_id") or str(meta.get("toolUseId") or "")
        fresh["subagent_type"] = fresh.get("subagent_type") or str(meta.get("agentType") or "")
        prov = _absorb_provisional(fresh, prov_key)
        fresh["registration_reconciled"] = {
            "at": now(), "agent_id": aid, "source": "platform-record",
            "adopted": prov_key if prov else "",
            "why": "the spawn was never bound to an agent id; the platform's own record of this "
                   "session names %s as the agent spawned for %r (point 3)" % (aid, name)}
        save_agent(fresh)
    event("reconciled", key=fresh["key"], agent_id=aid, source="platform-record",
          adopted=prov_key if prov else "", tool_use_id=fresh.get("tool_use_id") or "")
    _on_start(fresh)
    return fresh


def record_handed_in(session_id, agent_id="", name=""):
    with Lock():
        rec = _record_for_agent(session_id, agent_id, name)
        if not rec:
            return None
        rec["handed_in"] = now()
        save_agent(rec)
    event("handed-in", key=rec["key"])
    return rec


def _resolve(ref, session_id=""):
    """A record by key, by agent id, or by name (this session first, then any
    pending item this session may handle), with any binding and any ending the
    platform has recorded for it since taken (points 3, 11)."""
    return observe_platform_end(observe_platform_binding(_resolve_record(ref, session_id)))


def _resolve_record(ref, session_id=""):
    if not ref:
        raise SpecError("name an agent")
    r = load_agent(ref)
    if r:
        return r
    k = key_for_id(ref)
    if k:
        return load_agent(k)
    if session_id:
        r = load_agent(named_key(session_id, ref))
        if r:
            return r
    hits = [a for a in all_agents() if a.get("name") == ref]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        raise SpecError("no registered agent %r" % ref)
    raise SpecError("%r names %d agents; use a key: %s" % (ref, len(hits), ", ".join(h["key"] for h in hits)))


def pause(ref, until, session_id=""):
    with Lock():
        rec = _resolve(ref, session_id)
        fin, _p_, why = finished_state(rec)
        if fin:
            raise SpecError("%s is already finished (%s); a finished agent is not paused" % (rec["name"], why))
        rec["pause"] = {"at": now(), "until": (until or "").strip()}
        save_agent(rec)
    event("pause", key=rec["key"], until=until)
    return rec


def resume(ref, session_id=""):
    with Lock():
        rec = _resolve(ref, session_id)
        fin, paused_, why = finished_state(rec)
        if fin:
            raise SpecError("%s is finished (%s); it cannot be resumed. Land or discard it, or continue "
                            "its work with a new agent (point 7)." % (rec["name"], why))
        if not paused_:
            return rec
        rec.setdefault("history", []).append({"at": iso(), "fact": "resumed", "pause": rec.get("pause"),
                                              "end": rec.get("end")})
        rec["pause"] = None
        rec["end"] = None
        rec["handed_in"] = None
        save_agent(rec)
    event("resume", key=rec["key"])
    return rec


def stop(ref, why, session_id=""):
    """Point 11: a pause whose work is no longer wanted ends by stopping it."""
    with Lock():
        rec = _resolve(ref, session_id)
        rec["end"] = {"at": now(), "signal": "stopped", "detail": why or "stopped by Rich"}
        rec["pause"] = None
        save_agent(rec)
    observe_created_refs(rec, all_open=True)
    event("end", key=rec["key"], signal="stopped", detail=why)
    return rec


def wait(ref, kind, on, todo="", session_id=""):
    """Point 5's allowances for ending a turn, recorded by Rich."""
    if kind not in ("started", "outside", "ceo-discard"):
        raise SpecError("unknown wait kind %r" % kind)
    if not (on or "").strip():
        raise SpecError("say what it is waiting on")
    if kind in ("outside", "ceo-discard") and not (todo or "").strip():
        raise SpecError("an item waiting on something outside Rich's reach goes on the CEO's TODO list; "
                        "pass --todo with where it is (point 5)")
    with Lock():
        rec = _resolve(ref, session_id)
        if kind == "ceo-discard" and not rec.get("ceo_ordered"):
            raise SpecError("%s was not recorded as ordered by the CEO, so its discard does not need his word"
                            % rec["name"])
        rec["waiting"] = {"kind": kind, "on": on.strip(), "todo": (todo or "").strip(), "at": now()}
        save_agent(rec)
    event("wait", key=rec["key"], kind=kind, on=on, todo=todo)
    return rec


# ---------------------------------------------------------------------------
# point 5 — the pending list, and who handles which item (point 12)
# ---------------------------------------------------------------------------

def scan_unregistered(repos):
    """Point 3, hole 6: a cc/ or native workspace with no registration, and any
    such branch, is finished work of an ended session. codex/ and every other
    name is not the system's concern (points 1, 2) and is never listed."""
    paths, branches = set(), set()
    # Point 14: a record that was never spawned through the guard — an orphan
    # this sweep made, or a provisional native start no spawn registered — had
    # no spawn at which to be refused for a missing record. It binds to its
    # repository's body of work at the first sweep after one exists, recorded
    # on it by id, once; until then its land refuses and names the command.
    for r in all_agents():
        if not (r.get("orphan") or r.get("provisional")) or r.get("disposition"):
            continue
        repos = sorted(set(w.get("repo") for w in live_workspaces(r) if w.get("repo")))
        bound = r.get("integration_work") or {}
        if all(_norm_repo(x) in bound for x in repos):
            continue
        with Lock():
            fresh = load_agent(r["key"])
            if not fresh or fresh.get("disposition"):
                continue
            changed = False
            for x in repos:
                if _norm_repo(x) not in (fresh.get("integration_work") or {}) and _bind_body_of_work(fresh, x):
                    changed = True
            if changed:
                save_agent(fresh)
                event("bound-at-sweep", key=fresh["key"], work=fresh.get("integration_work"))
    for r in all_agents(include_done=True):
        for w in r.get("workspaces") or []:
            if w.get("path") and not w.get("deleted_at"):
                paths.add(w["path"])
            if w.get("branch") and not w.get("branch_deleted_at"):
                branches.add((w.get("repo"), w["branch"]))
        # A ref already attributed to an agent (point 3) is that agent's work,
        # not unregistered work of an ended session: it is landed or discarded
        # with the agent that made it.
        for pair in r.get("created_branches") or []:
            if len(pair) >= 2:
                branches.add((pair[0], pair[1]))
    found = []
    for repo in repos:
        repo = main_checkout(repo)
        if not repo:
            continue
        wl = worktree_list(repo)
        if wl is None:
            continue
        attached = set()
        for e in wl[1:]:
            kind = classify(e["path"], e["branch"])
            if e["branch"]:
                attached.add(e["branch"])
            if kind not in ("cc", "native"):
                continue
            if e["path"] in paths or (repo, e["branch"]) in branches:
                continue
            if _younger_than_its_spawn(repo, e["path"]):
                continue
            found.append((repo, e["path"], e["branch"], kind))
        for b in local_branches(repo, ["cc/", NATIVE_BRANCH_PREFIX + "*"]) or []:
            if b in attached or (repo, b) in branches or b.startswith(CODEX_PREFIX):
                continue
            found.append((repo, "", b, classify("", b)))
    made = []
    for repo, path, branch, kind in found:
        key = "orphan--" + hashlib.sha1(("%s\0%s\0%s" % (repo, path, branch)).encode()).hexdigest()[:16]
        with Lock():
            prior = load_agent(key)
            if prior and not prior.get("disposition"):
                continue
            if prior:
                key = "%s-%d" % (key, int(now()))
            rec = new_record(key, name="orphan-" + os.path.basename(path or branch.replace("/", "-")),
                             orphan=True)
            _add_workspace(rec, kind, repo, path, branch, "unregistered")
            save_agent(rec)
        event("unregistered", key=key, repo=repo, path=path, branch=branch)
        made.append(key)
    return made


def _younger_than_its_spawn(repo, path):
    """A workspace git registered less than SPAWN_WINDOW seconds ago is inside
    the spawn that created it: points 3 and 6 register it *at* that spawn
    (PreToolUse, SubagentStart, PostToolUse), and a scan that raced them would
    call a workspace unregistered while its registration is being written.
    This reads the age of git's own registration of it — it says nothing
    about whether any agent is alive, and after the window the rule is the
    page's: no registration means finished work of an ended session."""
    admin = _admin_dir_for(repo, path)
    try:
        # `commondir` is written once, when git creates the workspace, and never
        # again — unlike the directory itself, whose time moves with every commit.
        return bool(admin) and (now() - os.stat(os.path.join(admin, "commondir")).st_mtime) < SPAWN_WINDOW
    except OSError:
        return False


def _claimable(rec, me, cache):
    """Point 12: each running session handles only the agents it started; the
    next session handles an ended session's. An unregistered workspace is an
    ended session's (point 3)."""
    owner = rec.get("session_id")
    if owner == me:
        return True
    if owner and not rec.get("orphan"):
        st, _ = session_state(owner, rec.get("session_identity"), cache)
        if st != "ended":
            return False
    claim = rec.get("claimed_by")
    if claim and claim != me:
        st, _ = session_state(claim, None, cache)
        if st != "ended":
            return False
    return True


def pending(me, entity="", scan=False, auto=True, deadline=None, report=None):
    """The finished work this session must land or discard (point 5), after
    landing automatically everything that already is landed (point 4).

    With a deadline, the AUTO-LAND is what gets dropped when the budget runs
    out — never the list. An item that could not be checked stays pending and
    keeps blocking, which is the safe answer; the names of the items that were
    not checked go into `report` so the gate can say so rather than go quiet."""
    cache = {}
    if scan:
        repos = set(known_repos())
        if entity:
            repos.add(main_checkout(entity) or realpath(entity))
        scan_unregistered(sorted(r for r in repos if r))
    items = []
    for rec in all_agents():
        if rec.get("disposition"):
            continue
        # Point 11: an ending the platform recorded itself and gave no hook for
        # (a stopped agent) becomes finished HERE, before anything asks whether
        # it is, so the list below is the list the page describes. Point 3's
        # half of the same sentence comes first: a registration whose spawn was
        # never bound to an agent — because the hook that binds it was killed —
        # takes the platform's own binding here too, or the ending below would
        # be looked for on a record that can never have one.
        rec = observe_platform_binding(rec)
        rec = observe_platform_end(rec)
        fin, paused_, why = finished_state(rec, cache)
        if not fin:
            if paused_ and rec.get("session_id") == me and not (rec.get("pause") or {}).get("until"):
                items.append(_item(rec, "paused with nothing named that ends it (point 11)", cache, me))
            continue
        if not _claimable(rec, me, cache):
            continue
        if rec.get("session_id") != me and rec.get("claimed_by") != me:
            with Lock():
                fresh = load_agent(rec["key"])
                if fresh and not fresh.get("disposition"):
                    fresh["claimed_by"] = me
                    save_agent(fresh)
                    rec = fresh
        if auto and not _past(deadline):
            try:
                res = land(rec["key"], me, auto=True, deadline=deadline)
                if res.get("landed"):
                    continue
            except Deadline:
                _deferred(report, rec)
            except SpecError:
                pass
        elif auto:
            _deferred(report, rec)
        items.append(_item(rec, why, cache, me))
    return items


def _deferred(report, rec):
    if report is not None:
        report.setdefault("deferred", []).append(rec.get("name") or rec["key"])


def _land_under_way(rec, kind):
    """(under_way, why): CEO ruling §77. Finished work whose land is under way
    does not block new agents. Under way needs BOTH of these, and nothing else.

    1. THE RECORD. The item waits on something Rich has started to get it
       landed: `kind == "started"` (`workspaces.sh wait <name> --started '...'`,
       or a live `lands-pending:`/`continues:` agent). No other wait counts:
       the CEO's word and something outside Rich's reach are not a land.
    2. THE GIT FACT. Every branch of the chain and every live workspace HEAD
       is already contained in the branch this work integrates on, the
       recorded ref point 14 says every consumer asks about, at its LOCAL tip.
       That is "merged locally", the observable half of §77's "merged locally
       or with its checks running": Rich's land recipe merges first and runs
       its checks on the merged tree, so checks running is a state of merged
       work. A record with no merge behind it is a promise, not a land, and it
       keeps blocking exactly as it did before §77.

    The way back is built in: a land whose checks fail is rewound, the branch
    stops being contained, and the item blocks new work again. Any failure to
    read git answers "not under way", which is the safe answer."""
    if kind != "started":
        return False, "no land has been recorded as started"
    chain = _chain(rec)
    targets, proved = {}, 0
    try:
        refs = []
        for r in chain:
            for w in live_workspaces(r):
                if w.get("path") and os.path.isdir(w["path"]):
                    rc, out, _ = git(w["path"], "rev-parse", "HEAD")
                    if rc != 0:
                        return False, "the HEAD of %s cannot be read" % w["path"]
                    refs.append((w.get("repo"), out.strip(), w["path"]))
        for repo, b in _branch_targets(chain):
            t = branch_tip(repo, b)
            if t:
                refs.append((repo, t, b))
        for repo, sha, label in refs:
            if repo not in targets:
                targets[repo] = integration_target(chain, repo)
            branch, tip, why_not = targets[repo]
            if why_not:
                return False, why_not
            if not is_ancestor(repo, sha, tip):
                return False, "%s is not merged into %s yet" % (label, branch)
            proved += 1
    except (OSError, SpecError, subprocess.SubprocessError) as exc:
        return False, "its merge state cannot be read: %s" % exc
    if not proved:
        return False, "no branch or workspace is left to prove the merge against"
    return True, "recorded as started and merged locally"


def _item(rec, why, cache, me):
    waiting = rec.get("waiting") or {}
    helpers = [a for a in all_agents() if rec["name"] in (a.get("lands_pending") or [])
               or rec["key"] in (a.get("continues") or [])]
    started = [a for a in helpers if not finished_state(a, cache)[0]]
    kind = waiting.get("kind", "")
    if not kind and started:
        kind, waiting = "started", {"on": "agent %s is working to land it" % started[0].get("name")}
    # POINT 5, BOTH SENTENCES AT ONCE, AS AMENDED BY CEO RULING §77.
    # "that one item then waits on him, is on his TODO list, and blocks nothing
    # else" governs the OTHER pending items and the turn; "New work stays
    # blocked either way" governs new work, and its own parenthesis names this
    # very case ("the CEO's word"). Until round 8 this read
    # `kind != "ceo-discard"` — Rich's inverted paraphrase of the page, built
    # into the library in round 7 (brief-audit-sage-round8 §3: with one item
    # waiting on his word an unrelated spawn returned rc=0). Round 8 therefore
    # made EVERY pending item block new work, and that stays the rule for every
    # kind of wait: the CEO's word, something outside Rich's reach, and
    # finished work nobody has started landing. Nothing may be forgotten.
    #
    # THE ONE EXCEPTION IS THE CEO'S OWN AMENDMENT, NOT A RELAXATION TO UNDO.
    # richos-hq/wiki/ceo-decisions.md §77 (2026-09-22, his word "go", after
    # five agents were refused for about 35 minutes behind one land whose
    # checks were queued): "Finished work whose land is under way (merged
    # locally or with its checks running, and recorded as such) no longer
    # blocks new agents." `_land_under_way` is that sentence and needs BOTH
    # halves: the record (a `started` wait) and the git fact (merged locally).
    # Do not "fix" this back to `True`: that restores the freeze he ruled out.
    # `blocks_turn_end` is untouched by §77.
    under_way = _land_under_way(rec, kind)[0]
    return {"key": rec["key"], "name": rec.get("name") or rec["key"], "why": why,
            "waiting": kind, "waiting_on": waiting.get("on", ""),
            "land_under_way": under_way,
            "blocks_new_work": not under_way,
            "blocks_turn_end": kind not in ("ceo-discard", "started", "outside"),
            "workspaces": [(w.get("path") or "(branch only)", w.get("branch")) for w in live_workspaces(rec)]}


def gate_message(items, what, spawn=False):
    lines = ["=== Finished work is not landed or discarded: you cannot %s (point 5) ===" % what,
             "  Spec: %s. Land or discard every item first:" % SPEC]
    for i in items:
        w = ("  [waiting: %s — %s]" % (i["waiting"], i["waiting_on"])) if i["waiting"] else ""
        lines.append("   - %s: %s%s" % (i["name"], i["why"], w))
        for p, b in i["workspaces"][:4]:
            lines.append("       %s  %s" % (p, b or ""))
    lines += ["  How: merge its branch, then  workspaces.sh land <name>   (it also lands on its own",
              "       once every branch is in the branch this work integrates on and nothing is",
              "       uncommitted — `workspaces.sh integration` says which branch that is (point 14))",
              "       or  workspaces.sh discard <name> --reason '...' (--ceo-word '...' | --not-ceo-ordered '...')",
              "       or spawn the work that lands it, naming it:  lands-pending: <name>  /  continues: <name>"]
    if spawn:
        lines += ["  A land UNDER WAY does not block new work (CEO ruling §77): once its branch is merged",
                  "       locally, record it:  workspaces.sh wait <name> --started '<checks running on the merge>'"]
    if not spawn:
        lines += ["  Allowed while it waits (point 5): answer the CEO naming this work, or record",
                  "       workspaces.sh wait <name> --started '...'  |  --outside '...' --todo '<CEO TODO ref>'",
                  "       |  --ceo '<the question you asked him>' --todo '<CEO TODO ref>'"]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# point 8 — nothing uncommitted lands
# ---------------------------------------------------------------------------

def _past(deadline):
    return deadline is not None and now() >= deadline


def _gate_deadline(default_seconds):
    v = (os.environ.get("RICHOS_WORKSPACES_GATE_BUDGET") or "").strip()
    try:
        secs = float(v) if v else float(default_seconds)
    except ValueError:
        secs = float(default_seconds)
    return now() + max(0.0, secs)


def uncommitted(path, deadline=None):
    """([uncommitted entries], [ignored entries the main checkout does not have]).

    THIS IS THE UNBOUNDED PART, and it is unbounded by nature: it walks every
    ignored entry of a workspace and compares it against the main checkout. Run
    with a deadline it raises Deadline rather than overrunning it — including
    inside `git status` itself, which is one subprocess that cannot be
    interrupted, so it is given only the time that is left."""
    if _past(deadline):
        raise Deadline("the gate's budget ran out before %s could be checked for uncommitted work" % path)
    kw = {}
    if deadline is not None:
        kw["timeout"] = max(1.0, min(60.0, deadline - now()))
    rc, out, err = git(path, "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignored", **kw)
    if rc == 124:
        raise Deadline("`git status --ignored` in %s did not finish inside the gate's budget" % path)
    if rc != 0:
        raise SpecError("git status failed in %s: %s" % (path, err.strip()[:200]))
    dirty, ignored = [], []
    main = main_checkout(path)
    for n, ent in enumerate([e for e in out.split("\0") if e]):
        if deadline is not None and (n & 63) == 0 and _past(deadline):
            raise Deadline("the gate's budget ran out while walking the ignored entries of %s" % path)
        code, rel = ent[:2], ent[3:]
        if code == "!!":
            other = os.path.join(main, rel.rstrip("/")) if main else ""
            mine = os.path.join(path, rel.rstrip("/"))
            if other and os.path.isdir(mine) and not os.path.islink(mine) and os.path.isdir(other):
                # AN IGNORED DIRECTORY IS COMPARED BY CONTENT, NEVER SKIPPED BY
                # NAME. `git status --ignored` reports a wholly ignored directory
                # as ONE entry, so until round 7 a directory the main checkout
                # also had was `continue`d here with nothing inside it looked
                # at — and every main checkout and most cc/ workspaces on this
                # machine carry `.claude/`, so that was the ordinary case. A
                # nested repository with unlanded commits under an ignored
                # `vendor/`, and a `.claude/notes/needed.txt`, were neither
                # refused nor preserved: the land proceeded and deleted them
                # (lifecycle-failure-record-2026-09-10.md §3b.2, the one real
                # way to lose work; certification-frank-round6-2026-09-12.md
                # §2.1). Point 8: "Deletion therefore never loses anything that
                # was meant to land." So every file under it is compared, and
                # the ones the main checkout does not have, or has differently,
                # are named by path.
                for sub in _ignored_dir_diff(mine, other, rel.rstrip("/"), deadline):
                    ignored.append(sub)
                continue
            if other and os.path.isfile(mine) and os.path.isfile(other) and _same_file(mine, other):
                continue
            ignored.append(rel)
        else:
            dirty.append(ent)
    return dirty, ignored


def _ignored_dir_diff(mine, other, rel, deadline=None):
    """Every entry under the ignored directory `mine` that the main checkout's
    `other` lacks or has with different bytes, as paths relative to the
    workspace. Symlinks are compared by target and never followed; a nested
    repository's `.git` is walked like anything else, so a commit that exists
    only in the workspace's copy shows up as an object file the main checkout
    does not have. Bounded by the gate's deadline like the rest of the walk."""
    out = []
    n = 0
    for root, dirs, files in os.walk(mine, followlinks=False):
        dirs.sort()
        for name in sorted(files) + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
            n += 1
            if deadline is not None and (n & 63) == 0 and _past(deadline):
                raise Deadline("the gate's budget ran out while comparing the ignored directory %s" % rel)
            a = os.path.join(root, name)
            b = os.path.join(other, os.path.relpath(a, mine))
            sub = os.path.join(rel, os.path.relpath(a, mine))
            if os.path.islink(a):
                try:
                    same = os.path.islink(b) and os.readlink(a) == os.readlink(b)
                except OSError:
                    same = False
            else:
                same = os.path.isfile(b) and not os.path.islink(b) and _same_file(a, b)
            if not same:
                out.append(sub)
        # a symlinked directory is compared above as a link and never descended
        dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
    return out


def _same_file(a, b):
    try:
        if os.path.getsize(a) != os.path.getsize(b):
            return False
        with open(a, "rb") as fa, open(b, "rb") as fb:
            return hashlib.sha1(fa.read()).digest() == hashlib.sha1(fb.read()).digest()
    except OSError:
        return False


def _landed_residue(rec, w, deadline=None):
    """Accept partial-removal leftovers only when their content is still preserved."""
    path = w["path"]
    main = main_checkout(w.get("repo") or "")
    entries = worktree_list(main) if main else None
    if entries is None:
        return False
    if any(e["path"] == path for e in entries):
        return None  # Still a worktree: use Git's normal cleanliness check.
    _branch, tip, why = integration_target([rec], w.get("repo"))
    if why:
        return False
    rc, tree, _err = git(main, "ls-tree", "-rz", tip)
    if rc:
        return False
    tracked = {}
    for item in tree.split("\0"):
        if item:
            info, name = item.split("\t", 1)
            mode, kind, oid = info.split()
            if kind == "blob":
                tracked[name] = (mode, oid)
    pointer = os.path.join(path, ".git")
    try:
        if os.path.lexists(pointer):
            if not os.path.isfile(pointer) or os.path.islink(pointer):
                return False
            with open(pointer, encoding="utf-8") as f:
                text = f.read().strip()
            common = _common_dir(main)
            if not text.startswith("gitdir:") or not common or not realpath(text[7:].strip()).startswith(
                    os.path.join(common, "worktrees") + os.sep):
                return False
        def unreadable(error):
            raise error
        for root, dirs, files in os.walk(path, followlinks=False, onerror=unreadable):
            for name in files + [d for d in dirs if os.path.islink(os.path.join(root, d))]:
                if _past(deadline):
                    raise Deadline("the gate's budget ran out while checking partial cleanup")
                source = os.path.join(root, name)
                if source == pointer:
                    continue
                relative = os.path.relpath(source, path)
                target = os.path.join(main, relative)
                mode, oid = tracked.get(relative, ("", ""))
                if os.path.islink(source):
                    if os.path.islink(target) and os.readlink(source) == os.readlink(target):
                        continue
                    rc, content, _err = git(main, "cat-file", "blob", oid) if mode == "120000" else (1, "", "")
                    if rc or os.readlink(source) != content:
                        return False
                elif os.path.isfile(source):
                    executable = bool(os.stat(source).st_mode & 0o111)
                    if (os.path.isfile(target) and not os.path.islink(target) and _same_file(source, target)
                            and executable == bool(os.stat(target).st_mode & 0o111)):
                        continue
                    if mode != ("100755" if executable else "100644"):
                        return False
                    rc, actual, _err = git(main, "hash-object", "--no-filters", "--", source)
                    if rc or actual.strip() != oid:
                        return False
                else:
                    return False
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
    except (OSError, UnicodeError):
        return False
    return True


def _require_clean(rec, doing, ignored_ok="", deadline=None):
    problems = []
    for w in live_workspaces(rec):
        if w.get("path") and os.path.isdir(w["path"]):
            residue = None
            if rec.get("landing_cleanup_started") or (
                    (rec.get("disposition") or {}).get("kind") == "landed" and rec.get("deletion")):
                residue = _landed_residue(rec, w, deadline)
                if residue is False:
                    raise SpecError("partial cleanup at %s cannot verify all remaining files are preserved; kept" % w["path"])
            dirty, ignored = ([], []) if residue else uncommitted(w["path"], deadline)
            if dirty:
                problems.append("%s has %d uncommitted entr%s (%s)" % (
                    w["path"], len(dirty), "y" if len(dirty) == 1 else "ies", ", ".join(dirty[:5])))
            if ignored and not ignored_ok:
                problems.append("%s has %d ignored entr%s the main checkout does not have (%s)" % (
                    w["path"], len(ignored), "y" if len(ignored) == 1 else "ies", ", ".join(ignored[:5])))
    if problems:
        raise SpecError("cannot %s — nothing uncommitted is ever landed (point 8):\n    %s\n  Commit what it "
                        "left to its branch, or discard it. If the ignored files are not needed, say so: "
                        "--ignored-not-needed '<why>'." % (doing, "\n    ".join(problems)))


# ---------------------------------------------------------------------------
# point 3 — "any branch an agent created": ATTRIBUTION BY RECORDED CREATION
# ---------------------------------------------------------------------------
#
# A ref an agent created is the agent's, however it was made and whether or not
# it is checked out. A ref that already existed is never the agent's, however
# long the agent holds it. So the fact that decides is CREATION, and it is
# recorded at the moment it happens, against the agent's id.
#
# THREE EARLIER ANSWERS WERE WRONG, EACH IN ITS OWN DIRECTION, AND ALL THREE ARE
# WORTH KEEPING WRITTEN DOWN.
#
# THE REFLOG. git writes `branch: Created from <X>` identically whoever ran the
# command and wherever they ran it, and writes NOTHING to a workspace's HEAD
# reflog for a plain `git branch`. It missed the agent's own branch and handed it
# Rich's rescue copy: wrong in both directions at once.
#
# A WINDOW OVER THE WHOLE REPOSITORY, BETWEEN TWO OF THE AGENT'S TOOL CALLS.
# Every ref that appeared anywhere in the repository in that window was called
# that agent's. TWO AGENTS IN ONE REPOSITORY IS THE NORMAL CASE, and reproduced
# on this machine agent A's record held `cc/zach-opus-b1` and
# `worktree-agent-azachopusb10000` — B's, both of them. A's land was refused
# because B's branch was not in main, and `discard(A)` DELETED B's branch.
#
# POSSESSION: a branch git reports checked out at one of the agent's own
# registered workspace paths, sampled at its tool calls. That fixed the window
# and left three holes, which are one defect — it answers WHERE a ref is, and
# the question is WHO MADE IT:
#   the stray        `git branch spare` checks nothing out, so it was never
#                    attributed and was left behind (against point 10, "none is
#                    left behind").
#   the side branch  an agent that commits on a branch and switches away leaves
#                    work that nothing attributes: land() reported SUCCESS,
#                    pending() listed nothing, and the work was in no
#                    integration branch (against points 5 and 8).
#   the borrowed     a PRE-EXISTING branch the agent merely checked out became
#     branch         the agent's, and a discard deleted it with `git branch -D`
#                    (against point 8, in the destructive direction).
#
# ===========================================================================
# THE PAIR OF EVENTS, WHICH IS WHAT MAKES CREATION OBSERVABLE
# ===========================================================================
# The platform gives a tool call two halves, and both carry the agent's id:
# PreToolUse and PostToolUse. A ref that is absent at the first and present at
# the second appeared DURING that agent's own tool call. There is a catch-all
# PreToolUse (the lock-out, which calls snapshot_refs); the catch-all PostToolUse
# in hooks/hooks.json is the other half, and until 2026-09-12 it did not exist —
# which is why creation could not be recorded and possession was the only fact
# left to read.
#
# The pair is per tool call, not per agent-lifetime, and that matters: the
# window is the duration of ONE call, so it is measured in seconds rather than
# in the minutes between two calls.
#
# ===========================================================================
# ONE WINDOW PER TOOL CALL, KEYED BY THE CALL — NOT ONE SLOT PER AGENT
# ===========================================================================
# Until 2026-09-12 the snapshot was written to ONE path per agent,
# `refs/<key>.json`, and the first PostToolUse to arrive consumed it. AN AGENT'S
# OWN CALLS OVERLAP: this project's own agent instructions require independent
# calls to be issued in one block, and a backgrounded Bash call was measured
# returning 4.0 s before its process finished. Pre(A) Pre(B) Post(A) Post(B)
# therefore lost a whole window — B's snapshot overwrote A's, Post(A) consumed
# what was left, and Post(B) had nothing to compare against. A ref created in
# call B was attributed to NOBODY, and a side branch created that way took real
# commits with it: land() reported LANDED, pending() listed nothing, and the
# commit was in no integration branch (reproduced by two reviewers at 84e12d32,
# against points 5, 8 and 10).
#
# THE PLATFORM GIVES EACH CALL ITS OWN ID and both halves carry it: `tool_use_id`
# is the same string at PreToolUse and at PostToolUse of one call — the spawn
# registration has relied on exactly that pairing since it was written
# (register_spawn stores it at the Pre; bind_agent looks it up at the Post). So
# the snapshot is keyed by the CALL, in a directory per agent, and a Post
# consumes ITS OWN call's window and no other. Overlapping calls of one agent can
# no longer clobber each other, and a Post whose Pre never ran (a guard refused
# it) still attributes nothing, exactly as before.
#
# WHEN NO CALL ID IS PRESENT — a caller driving these entry points directly —
# the only pairing available is arrival order, so an unkeyed snapshot is written
# under its own name and a Post consumes the OLDEST unkeyed one. That is still
# one window per call; it is merely paired by order rather than by name. A Pre
# and a Post that DISAGREE about whether there is an id find nothing to consume
# and attribute nothing, which is the safe direction: under-attribution leaves a
# stray, and the land refuses while that stray carries anything unlanded.
#
# The open windows of one agent are bounded (_MAX_OPEN_CALLS): a PreToolUse that
# a guard then REFUSES leaves a snapshot no Post will ever consume, so the oldest
# are evicted rather than accumulating. Every open window is consumed at the
# agent's end of run, which is the last observation (record_end, stop).
#
# ===========================================================================
# TIME ALONE IS STILL A GUESS, SO IT IS NEVER THE WHOLE TEST
# ===========================================================================
# Other things happen while an agent's tool call runs: Rich cuts a branch, a
# second agent is spawned, a human commits in a worktree of his own. "It
# appeared while this agent was working" is co-occurrence, and the closing
# section of the page allows no guessing. So a candidate must ALSO carry THIS
# AGENT'S OWN UNLANDED WORK, which is a fact about the agent and not about the
# clock. Four filters, each one load-bearing and each one with its own mutant:
#
#   1. NEW      absent from the snapshot this agent's own PreToolUse took, and
#               present now. codex/ is never a candidate at all (point 2).
#   2. NOBODY   not a ref recorded on another agent's record — its workspace
#      ELSE'S   branch or a ref it is already recorded as having created — and
#               not the branch the main checkout itself holds.
#   3. AT       its tip is NOT already contained in the branch this work
#      STAKE    integrates on (point 14). A ref that is entirely landed carries
#               nothing, so attributing it decides nothing; leaving it is a
#               stray, and the page's own bound on the cost of that is below.
#   4. THIS     its tip is on one line of history with a commit of this agent's
#      AGENT'S  OWN that is itself not yet in the integration branch — equal to
#      WORK     it, or one is an ancestor of the other. "Its own" means every
#               commit its own workspaces have pointed at: their branch tips,
#               their current HEADs and their own private HEAD reflogs. An agent
#               that has produced no unlanded commit of its own in that
#               repository is attributed NOTHING, which is what keeps a second
#               agent's refs, and a human's, out of its record.
#
# WHEN, still: only at a moment the platform vouches for with this agent's id,
# and only while the agent is not finished. A finished agent's restarted call is
# refused before it gets here (point 9), and its open snapshot is thrown away, so
# a branch Rich cuts in the workspace afterwards to rescue the work stays his.
#
# THE ONE THING THIS STILL CANNOT TELL APART, named rather than papered over: a
# ref Rich cuts, DURING one of the agent's own tool calls, AT that agent's own
# unlanded tip. git keeps no record of where a ref was created, so `git branch
# spare` inside the workspace and `git branch rich/copy <the agent's tip>` in the
# main checkout are the same event seen from outside. It is decided for the
# agent, because the agent's stray is the case the page names ("any branch an
# agent created") and because the cost is bounded in both directions: a land
# refuses while such a ref carries anything not in the integration branch, so the
# only one a land can delete is one already fully landed, and a discard records
# every tip it deletes. Rich does not rescue a running agent's work — he rescues
# a finished one's, which is outside every window by construction.
#
# Cost, per tool call: one `git for-each-ref` per repository the agent has a
# workspace in (one or two) at each half, plus one small write. The registry lock
# and the scan of other agents' records are touched only when a ref that is not
# already accounted for is actually sitting there, which is rare.

# A REFUSED PreToolUse LEAKS A WINDOW, AND THAT IS THE WHOLE OF ITEM 2.
# -------------------------------------------------------------------------
# The barrier runs at PreToolUse and writes this call's window. If ANOTHER
# PreToolUse hook then refuses the call, the tool never runs and no PostToolUse
# ever arrives: the window stays open for the rest of the agent's run. Two
# things used to go wrong with it, and they need different answers.
#
#   THE WIDENING (fixed in `_before_set`). The end-of-run pass consumed every
#   open window and INTERSECTED their before-sets, so "the widest one decides".
#   One window leaked at minute one turned the last comparison of the run into
#   "everything that appeared during this agent's entire run" — and a branch
#   RICH cut between two of the agent's calls was then attributed to the agent
#   and destroyed by its discard. The answer is the opposite operation: the
#   before-sets are UNIONED, and the most recent snapshot this agent ever took
#   is always part of that union even when its own call already consumed it.
#   A leaked window can then only ever NARROW what is attributed, never widen
#   it, which is the safe direction: an unattributed stray is a branch left
#   behind and named by the point-3 sweep, while an over-attributed one is
#   somebody else's work deleted.
#
#   THE EVICTION, MEASURED AND LEFT ALONE. The cap evicts the OLDEST window by
#   position, so a burst of refused calls opened while a live call is in flight
#   evicts the LIVE one. That looks like a second bug and it was going to be
#   fixed here. It was measured instead, and it is not one: once the
#   before-sets are UNIONED, a window opened before the ref still decides, and
#   after a burst of refusals there is always one of those still open. Both an
#   age-based cap and the unpaired-Post fallback below rescue the case
#   independently, and neither can be told from the other by any scenario --
#   so the age-based cap was an unproven claim and is not here. What actually
#   rescues it is the fallback, which has its own case and its own mutant.
_MAX_OPEN_CALLS = 64
# What the last observation of this process FOUND about the protected refs (see
# _restore_protected_refs): rows of (action, repo, branch, snapshot_tip, found,
# why), action "RESTORED" (a deleted ref put back), "MOVED" (seen, reported,
# left exactly where it was) or "LANDED" (another conversation's land, named
# from the land record and announced to the thread it moved under). The CLI
# prints them after the CREATED rows so the observe hook can announce them.
PROTECTED_REF_FINDINGS = []
# What each action is called ON THE AGENT'S OWN RECORD. Three actions, three
# sentences, and the third is not a variation of the second: "another
# conversation landed" is news about somebody else's finished work, while
# "moved" is an unexplained write on a protected ref.
_PROTECTED_REF_FACTS = {
    "RESTORED": "protected ref restored",
    "MOVED": "protected ref moved (reported, not restored)",
    "LANDED": "another conversation landed on this branch",
}


def _refs_dir(key):
    return _p("refs", _key_segment(key))


def _latest_path(key):
    """The most recent snapshot this agent took, kept AFTER its own window is
    consumed. It is never attributed from on its own; it only joins the union
    that decides what counts as new (see `_before_set`)."""
    return os.path.join(_refs_dir(key), "latest.json")


def _slot_path(key, call):
    """The window of ONE tool call. Keyed by the platform's own call id when the
    payload carries one; otherwise a unique, time-ordered unkeyed slot."""
    if call:
        return os.path.join(_refs_dir(key), "c." + _key_segment(call) + ".json")
    return os.path.join(_refs_dir(key), "u.%020d.%s.json" % (time.time_ns(), os.urandom(4).hex()))


def _open_slots(key):
    """Every open window of this agent, oldest first. Unkeyed slots sort
    chronologically by construction; keyed ones are looked up by name.

    `latest.json` is NOT a window: it is the running record of the last
    snapshot taken, and consuming it would attribute a call twice."""
    try:
        names = sorted(n for n in os.listdir(_refs_dir(key))
                       if n.endswith(".json") and n != "latest.json")
    except OSError:
        return []
    return [os.path.join(_refs_dir(key), n) for n in names]


def _evict_old_slots(key):
    """A refused PreToolUse leaves a window no Post will consume. Keep the cap."""
    slots = _open_slots(key)
    if len(slots) <= _MAX_OPEN_CALLS:
        return
    try:
        slots.sort(key=os.path.getmtime)
    except OSError:
        pass
    for p in slots[:len(slots) - _MAX_OPEN_CALLS]:
        try:
            os.unlink(p)
        except OSError:
            pass


def _local_refs(repo):
    """{branch: tip} for every local branch, read from git. None if unreadable."""
    rc, out, _ = git(repo, "for-each-ref", "--format=%(objectname) %(refname:short)", "refs/heads")
    if rc != 0:
        return None
    refs = {}
    for line in out.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].strip():
            refs[parts[1].strip()] = parts[0].strip()
    return refs


def _repos_of(rec):
    """The repositories this agent has a live workspace in, from its record."""
    out = []
    for w in live_workspaces(rec):
        repo = w.get("repo")
        if repo and repo not in out and os.path.isdir(repo):
            out.append(repo)
    return out


def snapshot_refs(rec, call=""):
    """THE FIRST HALF OF THE PAIR (point 3): what its repositories held when
    THIS tool call started. Called from barrier(), so it runs at a moment the
    platform vouches for with this agent's id, and never for a finished one.

    `call` is the platform's own id for this tool call, and it KEYS the window:
    two of the agent's own calls open at once keep two windows, and neither can
    clobber the other.

    A snapshot lost to a crash costs one window of attribution, and
    under-attribution loses nothing — so this never fails a tool call."""
    try:
        snap = {}
        tips = {}
        for repo in _repos_of(rec):
            refs = _local_refs(repo)
            if refs is None:
                continue                 # unreadable: no snapshot, so no candidates
            snap[repo] = sorted(refs)
            # THE PROTECTED REFS' TIPS (round 8, items 2 and 3): a RECORDED
            # integration branch and every codex/ ref. What is compared at the
            # other half of the pair is not only which refs EXIST but where
            # these point, so a move by any verb — named or not, from the
            # agent's own worktree or the main checkout — can be restored.
            tips[repo] = _protected_tips(repo, refs)
        row = {"key": rec["key"], "call": call or "", "at": now(), "repos": snap, "tips": tips}
        write_json(_slot_path(rec["key"], call), row)
        # The same fact, kept where consuming a window cannot remove it. It is
        # what stops a window leaked by a refused call from widening the
        # end-of-run comparison to the whole run (see `_before_set`).
        write_json(_latest_path(rec["key"]), row)
        _evict_old_slots(rec["key"])
        return snap
    except (OSError, ValueError):
        return {}


def _protected_names(repo):
    """The branch names protected IN THIS REPOSITORY: a RECORDED integration
    branch of a body of work recorded FOR THIS REPOSITORY (any body of work,
    superseded ones included). A codex/ ref is protected by its prefix in every
    repository and is not in here.

    KEYED BY (REPOSITORY, BRANCH), NEVER BY NAME ALONE. Until 2026-09-14 this
    gathered every recorded branch of every body of work and matched on the NAME,
    so `main` recorded for femcboost made `refs/heads/main` protected — and
    restorable — in richos and richos-hq too (three bodies of work on this
    machine, all three integrating on `main`). The repository a body of work was
    recorded for is written on the record; nothing has to be inferred."""
    names = set()
    try:
        key = _norm_repo(repo)
        for w in all_bodies_of_work().values():
            if not (w or {}).get("branch"):
                continue
            if realpath(w.get("repo") or "") != key:
                continue
            names.add(w["branch"])
    except (OSError, ValueError):
        pass
    return names


def _is_protected(repo_names, b):
    return b.startswith(CODEX_PREFIX) or b in repo_names


def _protected_tips(repo, refs):
    """{branch: tip} for every ref of `refs` that is protected in THIS repository:
    a recorded integration branch of a body of work recorded for it, or a codex/
    ref."""
    recorded = _protected_names(repo)
    return {b: sha for b, sha in refs.items() if _is_protected(recorded, b)}


def _recreate_deleted_ref(repo, branch, tip, who):
    """THE ONLY REF WRITE THIS CHECK MAKES, and it is create-only.

    The empty old value means "the ref must not exist at the time of the update"
    (git refuses with `cannot lock ref ... reference already exists`, measured on
    git 2.52.0), so this can re-create a protected ref that was DELETED and can
    do nothing else: it cannot move a ref, cannot clobber one somebody re-created
    between the deletion and this call, and cannot oscillate with another agent's
    check, because repeating it is refused rather than repeated. It is therefore
    incapable of dropping a commit.

    The `-m` is not decoration. Until 2026-09-14 this call site passed none, and
    the three writes it made to refs/heads/main landed in the reflog with an
    EMPTY message — which is why a day was spent working out who had moved main
    (docs/verification/ref-write-forensics-2026-09-14.md). An automated system
    writing a ref anonymously is indefensible and the message is free.

    UNDER THE OPERATOR FENCE (spec r3 e2, Frank G3). Git deletes a branch's
    reflog together with the branch, so the fence cannot recognize this restore
    from the reflog. When the repository's fence is on, a one-line RESTORE INTENT
    is written first, into the lease home the fence reads (baked into its
    launcher, never this process's environment): the ref, the value, and this
    process's pid and start time. The fence passes the creation of a missing
    `main` only when the new value equals the intent's and the intent's process
    is an ancestor of the Git call. It is removed afterwards. With the fence off,
    or absent, nothing is written and this function is what it always was.

    Returns git's own (rc, out, err)."""
    msg = "richos engine: protected ref restored after it was deleted during %s's tool call" % who
    intent = _fence_restore_intent(repo, branch, tip)
    try:
        return git(repo, "update-ref", "-m", msg, "--no-deref", "refs/heads/" + branch, tip, "")
    finally:
        if intent:
            try:
                os.unlink(intent)
            except OSError:
                pass


def _fence_restore_intent(repo, branch, tip):
    """Write the G3 restore intent when `repo`'s operator fence is on; return its
    path, or '' when nothing was written. Never raises."""
    try:
        rc, out, _ = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
        if rc != 0:
            return ""
        launcher = os.path.join(out.strip(), "hooks", "reference-transaction")
        with open(launcher, encoding="utf-8") as fh:
            text = fh.read(65536)
        if "richos-operator-fence-launcher" not in text:
            return ""
        conf = dict(re.findall(r'(?m)^OPERATOR_FENCES_([A-Z_]+)="([^"]*)"\s*$', text))
        if conf.get("STATE") != "on" or not conf.get("HOME") or not conf.get("KEY"):
            return ""
        st, started = process_start(os.getpid())
        if st != "ok":
            return ""
        epoch = calendar.timegm(time.strptime(" ".join(started.split()), "%a %b %d %H:%M:%S %Y"))
        path = os.path.join(conf["HOME"], "restore-intents", conf["KEY"] + ".json")
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(json.dumps({"ref": "refs/heads/" + branch, "value": tip, "pid": os.getpid(),
                                 "start": epoch, "at": iso()}) + "\n")
        os.replace(tmp, path)
        return path
    except (OSError, ValueError, OverflowError):
        return ""


def _restore_protected_refs(rec, priors, latest):
    """ITEMS 2 AND 3 OF ROUND 8, THE EFFECTS CHECK. A protected ref — a RECORDED
    integration branch of THIS repository, or any codex/ ref — that is gone or
    has moved since the snapshot this agent's call started with is REPORTED,
    whatever verb moved it: a named one the Bash guard missed, an unnamed one
    (`checkout <it>` then `commit`/`reset`/`merge`/`rebase`, the doorway class
    no verb list can close — brief-audit-frank-round8 §2), from the agent's own
    worktree or from the main checkout, or a non-git write.

    A MOVE IS NEVER PUT BACK. THE CHECK REPORTS IT AND LEAVES THE REF ALONE.
    From 2026-09-14, and the reason is measured, not argued. Until then a move
    was "restored" with `git update-ref --no-deref refs/heads/<b> <snapshot
    tip>`, and on 2026-09-13/14 that line moved `refs/heads/main` in
    /Users/alex/ab/richos three times, twice within twelve seconds in opposite
    directions, while Rich was landing (docs/verification/
    ref-write-forensics-2026-09-14.md, events 3, 4, 5; reproduced from nothing by
    docs/verification/protected-ref-oscillation-2026-09-14-logs/repro.py).

      * THE SHAPE CANNOT IDENTIFY THE WRITER. This check infers who moved the
        ref from the shape of the result, and Rich's ordinary land has the same
        shape as the abuse it hunts — a land is the most common write the
        recorded branch ever receives. The old docstring conceded this for "Rich
        rewinding the branch"; the reproduction shows it fires on his plain
        `git merge` of the very agent whose window is open.
      * ITS OWN WRITE WAS AN INPUT TO ITSELF. Every restore manufactured the
        non-descendant condition that made the NEXT agent's check fire, so two
        agents holding different snapshots alternated for as long as both kept
        making tool calls. A report is not an input to the check, so the loop
        cannot exist.
      * A "RESTORE" OF A MOVE IS AN ASSIGNMENT IN EITHER DIRECTION, and it drops
        every commit made between the snapshot and the write. `--mode
        destruction` of the reproduction loses a merge Rich had just made.
      * THE SNAPSHOT IT WOULD RESTORE TO IS NOBODY'S DECISION: the oldest still-
        open window of ONE agent, which can be minutes stale, and which a second
        running agent does not share.

    A DELETION IS STILL RESTORED, AND ONLY A DELETION. A deleted protected ref
    is unambiguous — point 2 says a codex/ branch is never deleted without the
    CEO's express word, and nothing in the spec deletes the branch a body of
    work integrates on while an agent is running — and re-creating it is
    information-preserving: the objects are still there and the ref goes back to
    the tip it held. The write is CREATE-ONLY and carries a reflog message:

        git update-ref -m <msg> --no-deref refs/heads/<b> <snapshot tip> ""

    The empty old value means "the ref must not exist" (git refuses with
    `reference already exists` otherwise, measured on git 2.52.0), so it can
    never clobber a ref somebody re-created in between, can never move one, and
    cannot oscillate: re-creating a ref that is already there is refused rather
    than repeated. `-m` is free, and its absence is what cost a day of
    forensics.

    NOT REPORTED: the lead's legitimate move. Rich lands FINISHED agents' work
    onto the recorded branch while other agents run, so a move to a DESCENDANT
    of the snapshot tip carrying none of THIS agent's own unlanded work is his
    and is passed over in silence. Reported: the ref is DELETED (and restored);
    or it moved to a tip that is not a descendant (a rewind, a force-move, a
    symref); or it moved to a descendant carrying this agent's own unlanded
    commits (it committed or merged onto it — which is ALSO what Rich's land of
    that same agent looks like, and is now reported rather than undone).

    AND, FROM 2026-09-17, THE ONE DESCENDANT THAT IS NOT HIS. The CEO runs two
    conversation threads whose back ends share a repository; their lands take
    one machine-wide lock per repository, so they never collide — but the
    second one's land moves the recorded branch UNDER the first one's running
    agents, and until now that was the silent case above, indistinguishable
    from the lead's own land. It is no longer inferred from the shape: app.py's
    `integrate` appends a land record naming the conversation that landed, and
    `land_by_another_conversation` reads it. A land by THIS conversation stays
    silent; one by another conversation is reported, with its thread, its time
    and its two tips; and where a repository keeps land records at all, a
    fast-forward that no record names is reported as exactly that. A repository
    with NO land records is the terminal path, and it stays silent as before —
    Rich's hand-run `git merge` writes no record, and those teammates are told
    by guard-inflight-notify.sh at the push instead.

    Returns [(action, repo, branch, snapshot_tip, found_tip_or_"", why)], with
    action "RESTORED" (a deletion put back), "MOVED" (seen, reported, left
    alone) or "LANDED" (another conversation's land, announced to this one).

    THE OWN-WORK RULE APPLIES ONLY INSIDE A WINDOW. A descendant that carries
    the agent's own unlanded commits is evidence of the AGENT's move only while
    one of its calls is open — the doorway commit happens inside a call. With no
    window open (the end of the run, compared against the last snapshot, which
    may be minutes old) the same shape is what Rich's fast-forward of the
    agent's OWN branch onto the recorded one looks like, made after the agent's
    last call and before its end signal; measured undoing exactly that in
    certification-sage-runner-round case R8 on 2026-09-13, and the land then
    refused. So outside a window only a deletion or a non-descendant move is
    reported."""
    findings = []
    try:
        ordered = sorted([p for p in priors if isinstance(p.get("tips"), dict)], key=lambda p: p.get("at", 0))
        for repo in _repos_of(rec):
            before = {}
            windowed = set()
            for prior in ordered:                       # oldest first: the earliest tip is the reference
                for b, sha in (prior["tips"].get(repo) or {}).items():
                    before.setdefault(b, sha)
                    windowed.add(b)
            if latest and isinstance(latest.get("tips"), dict):
                for b, sha in (latest["tips"].get(repo) or {}).items():
                    before.setdefault(b, sha)
            if not before:
                continue
            refs = _local_refs(repo)
            if refs is None:
                continue
            # (REPOSITORY, BRANCH) KEYING IS APPLIED HERE TOO, not only where the
            # snapshot is taken: a window opened before 2026-09-14 recorded the
            # name `main` for every repository at once, and those windows are
            # still on disk when this lands.
            protected = _protected_names(repo)
            own = None
            for b, old in sorted(before.items()):
                if not _is_protected(protected, b):
                    continue
                cur = refs.get(b)
                if cur == old:
                    continue
                action = "MOVED"
                if cur is None:
                    why = "deleted"
                elif not is_ancestor(repo, old, cur):
                    why = "moved to %s, which does not descend from %s (a rewind, a force-move or a symref)" % (cur[:12], old[:12])
                elif b not in windowed:
                    landed = land_by_another_conversation(repo, b, old, cur)
                    if not landed:
                        continue                        # no call open: a descendant is the lead's land, whatever it carries
                    action, why = "LANDED", landed      # except when the land record names another conversation
                else:
                    if own is None:
                        # The agent's own unlanded tips are measured against the
                        # recorded branch's SNAPSHOT tip, never the tip read now:
                        # after a doorway commit the branch's current tip IS the
                        # agent's commit, and subtracting it would call the move
                        # the lead's.
                        _branch, target, _why_not = integration_target([rec], repo)
                        base = before.get(_branch, target) if _branch else target
                        own = _own_unlanded_tips(rec, repo, refs, base)
                    if any(t == cur or is_ancestor(repo, t, cur) for t in own):
                        why = "moved to %s, which carries this agent's own unlanded work (it committed or merged onto it)" % cur[:12]
                    else:
                        landed = land_by_another_conversation(repo, b, old, cur)
                        if not landed:
                            continue                    # a descendant carrying none of the agent's work: the lead's land
                        action, why = "LANDED", landed  # except when the land record names another conversation
                if cur is not None:
                    if action == "LANDED":
                        # ANOTHER CONVERSATION'S LAND, REPORTED TO THE THREAD IT
                        # MOVED UNDER. Nothing was lost and nothing is changed
                        # here either: a fast-forward is announced, not judged.
                        # It is deliberately NOT one of the classes
                        # scripts/lib/protected-ref-moves.py reads — that
                        # reader's whole question is "were commits lost", and
                        # the answer here is no.
                        findings.append((action, repo, b, old, cur, why))
                        PROTECTED_REF_FINDINGS.append((action, repo, b, old, cur, why))
                        event("protected-ref-landed-elsewhere", key=rec["key"], repo=repo, branch=b,
                              tip=old, found=cur, why=why,
                              action="reported: another conversation's land, nothing was changed")
                        continue
                    # A MOVE IS REPORTED AND LEFT ALONE. See the docstring: the
                    # shape cannot tell Rich's land from an agent's doorway, and
                    # the write this used to make was destructive, self-
                    # triggering, and aimed at a tip no one decided on.
                    findings.append(("MOVED", repo, b, old, cur, why))
                    PROTECTED_REF_FINDINGS.append(("MOVED", repo, b, old, cur, why))
                    event("protected-ref-moved", key=rec["key"], repo=repo, branch=b, tip=old,
                          found=cur, why=why, action="reported: the engine does not move a ref back")
                    continue
                # A DELETION, AND ONLY A DELETION, IS PUT BACK — by the
                # create-only, attributed write above, which cannot clobber, move
                # or oscillate.
                rc, _o, err = _recreate_deleted_ref(repo, b, old, rec.get("name") or rec["key"])
                if rc != 0:
                    event("protected-ref-restore-failed", key=rec["key"], repo=repo, branch=b, tip=old, err=err.strip()[:300])
                    continue
                findings.append(("RESTORED", repo, b, old, "", why))
                PROTECTED_REF_FINDINGS.append(("RESTORED", repo, b, old, "", why))
                event("protected-ref-restored", key=rec["key"], repo=repo, branch=b, tip=old, found=cur, why=why)
        if findings:
            with Lock():
                fresh = load_agent(rec["key"])
                if fresh:
                    fresh.setdefault("history", []).extend(
                        {"at": iso(), "fact": _PROTECTED_REF_FACTS[a],
                         "repo": r, "branch": b, "tip": o, "found": c, "why": w}
                        for a, r, b, o, c, w in findings)
                    save_agent(fresh)
    except (OSError, ValueError, SpecError):
        pass
    return findings


def _take_snapshots(key, call="", all_open=False, background=False):
    """CONSUME this call's window — or, at the end of the run, every open one —
    and return what was in it. Consumed whatever the outcome: one creation is
    attributed once, and a Post whose own Pre never ran attributes nothing.

    A BACKGROUNDED CALL'S WINDOW STAYS OPEN (round 8, item 8). When the Post
    says the call was issued with `run_in_background` — the platform's own
    stamped field, never the text of the command — the call's process is, by
    the platform's own word, still running after this Post. Its window is
    read and compared now, then written BACK marked `background`, and every
    later observation of this agent (the next call's Post, an unkeyed Post,
    the end of the run) consumes the background windows as well as its own.
    That is what lets a ref the backgrounded process creates AFTER its call's
    Post — measured on this machine: a Bash call returned 3 s before its
    process finished (certification-frank-recorded-attribution-2026-09-12-
    probe.py) — be judged against the window the process actually belongs to.
    Returns (priors, background_priors): the two are judged apart, because a
    background window must NOT be unioned with a later snapshot that already
    contains what its process created (see `observe_created_refs`)."""
    own = []
    if all_open:
        own = _open_slots(key)
    elif call:
        p = _slot_path(key, call)
        # A POST WHOSE OWN WINDOW IS NOT THERE STILL ENDS SOME CALL OF THIS
        # AGENT. The platform does not always carry `tool_use_id` on both
        # halves, and a Pre keyed / Post unkeyed pair (or the reverse) used to
        # find nothing at either end: the ref created inside that call was
        # attributed to nobody until the end of the run, and after the run
        # ended, to nobody at all. So an unpaired Post falls back to the OLDEST
        # open window, which is the one least likely to have another Post
        # coming.
        own = [p] if os.path.exists(p) else [q for q in _open_slots(key) if not _is_background(q)][:1]
    else:
        own = [p for p in _open_slots(key) if os.path.basename(p).startswith("u.") and not _is_background(p)][:1] \
            or [q for q in _open_slots(key) if not _is_background(q)][:1]
    bg = [q for q in _open_slots(key) if _is_background(q) and q not in own]
    priors, bg_priors = [], []
    for p in own:
        prior = read_json(p)
        if prior and isinstance(prior.get("repos"), dict):
            if prior.get("background"):
                bg_priors.append(prior)
            else:
                priors.append(prior)
        if background and not all_open and prior and isinstance(prior.get("repos"), dict):
            prior["background"] = True                  # the process outlives the call: keep the window
            write_json(p, prior)
            continue
        try:
            os.unlink(p)
        except OSError:
            pass
    for p in bg:
        prior = read_json(p)
        try:
            os.unlink(p)
        except OSError:
            pass
        if prior and isinstance(prior.get("repos"), dict):
            bg_priors.append(prior)
    return priors, bg_priors


def _is_background(slot_path):
    prior = read_json(slot_path)
    return bool(prior and prior.get("background"))


def _before_set(priors, latest, repo):
    """WHAT ALREADY EXISTED WHEN ANY OF THIS AGENT'S OPEN CALLS STARTED — the
    UNION of their before-sets, plus the most recent snapshot it ever took.

    It used to be the INTERSECTION, described as "the widest one decides". With
    one window leaked by a refused call, the widest one was the start of the
    run, so the end-of-run comparison asked "what appeared while this agent
    existed" instead of "what changed during this call", and a branch Rich cut
    between two of the agent's calls came back as the agent's.

    The union is the other direction and it is the safe one. A ref that already
    existed when ANY call of this agent started was not created by that call,
    and with windows overlapping there is no way to say which call made it. The
    cost is under-attribution in one narrow shape — a ref created during a call
    that is still open when an even later call starts, and whose own Post never
    arrives — and under-attribution leaves a branch behind for the point-3
    sweep to name, while over-attribution deletes somebody else's work.

    `latest` joins the union even after its own window was consumed, because
    that is exactly the fact a leaked window is missing: the run got as far as
    THAT call, so anything already present then is not the leaked call's doing.
    It never adds attribution of its own — it only ever removes some."""
    before = None
    for prior in priors:
        if repo in (prior.get("repos") or {}):
            b = set(prior["repos"][repo] or [])
            before = b if before is None else (before | b)
    if latest and repo in (latest.get("repos") or {}):
        b = set(latest["repos"][repo] or [])
        before = b if before is None else (before | b)
    return before


def _drop_snapshots(key):
    """Every open window of this agent, thrown away unconsumed."""
    for p in _open_slots(key):
        try:
            os.unlink(p)
        except OSError:
            pass
    try:
        os.unlink(_latest_path(key))
    except OSError:
        pass
    try:
        os.rmdir(_refs_dir(key))
    except OSError:
        pass
    try:
        os.unlink(_p("refs", key + ".json"))      # the pre-2026-09-12 single slot
    except OSError:
        pass


def _refs_recorded_elsewhere(exclude_key):
    """Every (repo, branch) recorded on some OTHER agent's record: its
    workspaces' own branches and the refs it is recorded as having created.
    Filter 2, and the hard guarantee for the shape that broke on 2026-09-11."""
    out = set()
    for r in all_agents(include_done=True):
        if r.get("key") == exclude_key:
            continue
        for w in r.get("workspaces") or []:
            if w.get("branch"):
                out.add((w.get("repo"), w["branch"]))
        for pair in r.get("created_branches") or []:
            if len(pair) >= 2:
                out.add((pair[0], pair[1]))
    return out


# A reflog subject says whether this workspace MADE the commit its HEAD moved
# to, or merely visited one that already existed. "checkout: moving from X to Y"
# is a visit; "commit: ...", "merge ...", "rebase ...", "cherry-pick ...",
# "revert ...", "am ..." and "pull ..." all produce the commit they land on.
# Counting visits is how a ref Rich cut at a commit the agent only BORROWED
# became the agent's: the agent checked that commit out for one call and its
# reflog then swore the commit was its own work.
_MADE_HERE = ("commit", "merge", "rebase", "cherry-pick", "revert", "am", "pull")


def _made_here(subject):
    head = (subject or "").split(":")[0].strip().lower()
    return head.split(" ")[0] in _MADE_HERE if head else False


def _own_unlanded_tips(rec, repo, refs, target):
    """EVERY COMMIT THIS AGENT'S OWN WORKSPACES IN `repo` HAVE POINTED AT, less
    the ones already in the branch this work integrates on. Filter 4's other
    half: an agent with none of these has produced nothing of its own here, and
    is attributed nothing.

    Four sources, all facts about the agent's own workspaces or its own record:
    its workspace branches' tips, its workspaces' current HEADs, its workspaces'
    own HEAD REFLOGS, and the refs it is already recorded as having created.

    THE REFLOG HERE IS THE PER-WORKSPACE ONE, AND IT IS NOT THE REFLOG THAT WAS
    REJECTED. What was rejected is `logs/refs/heads/<name>`, the BRANCH's reflog:
    git writes `branch: Created from <X>` into it identically whoever ran the
    command and wherever they ran it, so it says nothing about who made the ref.
    `$GIT_DIR/logs/HEAD` of a workspace is a different file with a different
    property — it is PRIVATE TO THAT WORKSPACE, it is written when that
    workspace's HEAD moves, and it is deleted with it.

    IT IS WHAT CLOSES THE SIDE BRANCH INSIDE ONE TOOL CALL. An agent that runs
    `git checkout -b sidework && <commit> && git checkout <its own branch>` in a
    single call is back on its own empty branch by the time anything looks: its
    branch tip and its current HEAD are both the integration tip, so without the
    reflog it has no unlanded work of its own and the commit on `sidework` is
    attributed to nobody — which is exactly the hole where land() reported
    success and the work was in no integration branch (points 5, 8). Its HEAD
    reflog still carries the commit it made, so the side branch is on one line of
    history with something of its own, and the land is held until that branch is
    merged or discarded."""
    tips = set()
    bases = set()
    for w in live_workspaces(rec):
        if w.get("repo") != repo:
            continue
        if w.get("branch") and refs.get(w["branch"]):
            tips.add(refs[w["branch"]])
        if not w.get("path") or not os.path.isdir(w["path"]):
            continue
        rc, out, _ = git(w["path"], "rev-parse", "HEAD")
        if rc == 0 and out.strip():
            tips.add(out.strip())
        rc, out, _ = git(w["path"], "reflog", "show", "--format=%H%x09%gs", "HEAD")
        if rc == 0:
            lines = [l for l in out.splitlines() if l.strip()]
            for line in lines:
                sha, _tab, subject = line.partition("\t")
                sha = sha.strip()
                if not sha:
                    continue
                if _made_here(subject):
                    tips.add(sha)
            if lines:
                # The OLDEST entry is where this workspace started — the commit
                # git put its HEAD on when the workspace was created. It is a
                # fact about the agent's own workspace, recorded by git, and it
                # is the floor used when point 14's record does not exist yet.
                oldest = lines[-1].partition("\t")[0].strip()
                if oldest:
                    bases.add(oldest)
    for pair in rec.get("created_branches") or []:
        if len(pair) >= 2 and pair[0] == repo and refs.get(pair[1]):
            tips.add(refs[pair[1]])
    if not target:
        # NOTHING IS RECORDED FOR THIS REPOSITORY YET (point 14 not yet done),
        # so "less the ones already in the integration branch" has no branch to
        # subtract. The floor is then each workspace's OWN starting commit: work
        # that was already there when the agent's workspace was created is not
        # the agent's, whatever any record says. Without this floor the base
        # commit itself counts as the agent's work, every ref in the repository
        # descends from it, and every ref is "on this agent's line of work" —
        # which is how a ref cut at a tip the agent only BORROWED became the
        # agent's the moment attribution stopped waiting for the record.
        if not bases:
            return set(t for t in tips if t)
        return set(t for t in tips
                   if t and not any(is_ancestor(repo, t, b) for b in bases))
    return set(t for t in tips if t and not is_ancestor(repo, t, target))


def observe_created_refs(rec, call="", all_open=False, background=False):
    """THE SECOND HALF OF THE PAIR (point 3): the refs this agent created during
    the tool call that is now ending, recorded against it. Returns what it added.

    `call` names WHICH of the agent's open windows this is the far end of, so
    two of its own calls open at once no longer clobber each other. `all_open`
    is the end of the run: every window still open is the last observation.
    `background` says the platform stamped this call `run_in_background`: its
    window is compared now and kept open for the process that outlives it
    (`_take_snapshots`).

    The window is CONSUMED here, whatever the outcome: one creation is
    attributed once. A background window is the one exception, and it is
    consumed by the next observation of this agent, judged against ITS OWN
    before-set: a later snapshot already holds what its process created, so
    the union rule would call that ref old, and it is not.

    IT DOES NOT NEED AN INTEGRATION BRANCH TO BE RECORDED. The record is a
    filter on what is at stake, never a gate on whether the observation happens
    at all — attribution is made once and never again, so a missing record used
    to mean "attributed to nobody, permanently"."""
    # READ BEFORE CONSUMING. The last snapshot has to be in hand before the
    # windows are thrown away, or the end-of-run pass is judged against the
    # leaked window alone -- which is the widening this whole change ends.
    latest = read_json(_latest_path(rec["key"]))
    priors, bg_priors = _take_snapshots(rec["key"], call, all_open, background)
    if all_open:
        _drop_snapshots(rec["key"])
    # The effects check runs FIRST, on the snapshots as taken: a protected ref
    # the call DELETED is put back, and one it MOVED is reported and left where
    # it is (it never moves a ref back — see _restore_protected_refs), before
    # anything is attributed.
    _restore_protected_refs(rec, priors + bg_priors, latest)
    added = []
    if bg_priors:
        # THE BACKGROUND WINDOWS, JUDGED APART: against their own before-sets,
        # never unioned with `latest` — the next call's snapshot was taken
        # while the backgrounded process was still running, so it already
        # holds what that process created, and the union would call it old.
        # The four filters still apply (own unlanded work, not somebody
        # else's, at stake), which is what keeps a second agent's refs out.
        added += _attribute_new_refs(rec, bg_priors, None)
    # THE END OF THE RUN COMPARES ONCE MORE AGAINST THE LAST SNAPSHOT, WHETHER
    # OR NOT A WINDOW IS STILL OPEN (round 8, item 8). A backgrounded process
    # outlives its tool call — measured on this machine: a Bash call returned
    # 3 s before its process finished (certification-frank-recorded-attribution
    # -2026-09-12-probe.py, cases outside-stray / outside-side) — so a ref it
    # creates appears AFTER that call's PostToolUse consumed the window. The
    # end signal used to observe only windows still open, so with the last
    # window consumed `priors` was empty and the ref was compared against
    # nothing: attributed to nobody, land() reported success, the ref was left
    # behind (esc-20260912T225456Z-d34bf4e6, the one RED probe of round 7).
    # `latest` is the snapshot the run got as far as; anything present in it
    # was not created after it, and the four filters below still apply, so
    # this widens nothing but the moment of the last comparison. Points 3, 9.
    if all_open and latest and isinstance(latest.get("repos"), dict):
        priors.append(latest)
    if not priors:
        return added
    return added + _attribute_new_refs(rec, priors, latest)


def _attribute_new_refs(rec, priors, latest):
    """THE FOUR FILTERS, over the union of the before-sets in `priors` (plus
    `latest`, see `_before_set`): what is new, not somebody else's, at stake,
    and on this agent's own line of work is recorded against it. Returns what
    it added. Shared by the end of a call (observe_created_refs), the end of
    the run, and the start of a call with nothing in flight (snapshot_refs)."""
    try:
        mine = []
        repos = _repos_of(rec)
        seen_repos = sorted(set(r for prior in priors for r in prior["repos"]))
        for repo in seen_repos:
            if repo not in repos:
                continue
            # A ref is NEW when it did not exist at the start of ANY of this
            # agent's open calls (`_before_set` says why that is a union and not
            # an intersection).
            before = _before_set(priors, latest, repo)
            if before is None:
                continue
            refs = _local_refs(repo)
            if refs is None:
                continue                              # unreadable: observe nothing
            fresh_refs = [b for b in sorted(refs) if b not in before
                          and not b.startswith(CODEX_PREFIX)]
            if not fresh_refs:
                continue
            # ATTRIBUTION DOES NOT WAIT FOR THE RECORD, AND THIS IS ITEM 1.
            # It used to: with no integration branch recorded, this gave up on
            # the whole observation and wrote an `attribution-skipped` event
            # that had one producer and NO CONSUMER. Attribution happens once,
            # at the end of a tool call, so "skipped" meant attributed to NOBODY
            # PERMANENTLY -- recording the branch afterwards unblocked the land
            # and never went back for what was skipped, and `land()` then
            # reported success over a commit that had reached no integration
            # branch. The control that recorded the branch first held, so the
            # cause was the ORDER, and the fix is to take the order out: the
            # target is now only ever a FILTER here, never a precondition.
            #
            # With no target the judgment is deliberately wider -- the two tests
            # it can make no longer run, so a ref that is already fully merged
            # is attributed where it would otherwise have been skipped. That is
            # the right way round. An over-attributed ref is still measured at
            # land time, where a ref already in the integration branch simply
            # passes and a ref that is not REFUSES the land by name. A ref
            # attributed to nobody is measured nowhere, ever.
            _branch, target, _why_not = integration_target([rec], repo)
            wl = worktree_list(repo) or []
            held_by_main = (wl[0].get("branch") or "") if wl else ""
            elsewhere = _refs_recorded_elsewhere(rec["key"])
            own_branches = set(w.get("branch") for w in live_workspaces(rec)
                               if w.get("repo") == repo)
            own = _own_unlanded_tips(rec, repo, refs, target)
            if not own:
                continue     # it has produced nothing of its own here (filter 4)
            for b in fresh_refs:
                if b == held_by_main or b in own_branches or (repo, b) in elsewhere:
                    continue
                tip = refs[b]
                if target and is_ancestor(repo, tip, target):
                    continue                          # entirely landed: nothing at stake
                if not any(t == tip or is_ancestor(repo, t, tip) or is_ancestor(repo, tip, t)
                           for t in own):
                    continue                          # not on this agent's line of work
                if (repo, b) not in mine:
                    mine.append((repo, b))
        if not mine:
            return []
        with Lock():
            fresh = load_agent(rec["key"])
            if not fresh:
                return []
            have = [tuple(x) for x in (fresh.get("created_branches") or [])]
            own_ws = set((w.get("repo"), w.get("branch")) for w in fresh.get("workspaces") or [])
            add = [x for x in mine if x not in have and x not in own_ws]
            if not add:
                return []
            fresh["created_branches"] = [list(x) for x in have + add]
            save_agent(fresh)
        event("branch-created", key=rec["key"], branches=[list(x) for x in add])
        return add
    except (OSError, ValueError, SpecError):
        return []


def observe(payload):
    """The catch-all PostToolUse's half of the pair (point 3). A payload with no
    agent_id is the lead's own call and can never be an agent's creation; a
    finished agent observes nothing and its open snapshot is thrown away (point
    9), so a ref Rich cuts to rescue the work afterwards stays his."""
    aid = str(payload.get("agent_id") or "")
    if not aid:
        return []
    key = key_for_id(aid)
    rec = load_agent(key) if key else None
    if not rec:
        return []
    if finished_state(rec)[0]:
        _drop_snapshots(rec["key"])
        return []
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    background = str(payload.get("tool_name") or "") == "Bash" and bool(ti.get("run_in_background"))
    return observe_created_refs(rec, str(payload.get("tool_use_id") or ""), background=background)


def _chain(rec):
    """The agent plus every agent whose work it continues (point 7)."""
    out, seen, todo = [], set(), [rec]
    while todo:
        r = todo.pop()
        if r["key"] in seen:
            continue
        seen.add(r["key"])
        out.append(r)
        for k in r.get("continues") or []:
            o = load_agent(k)
            if o:
                todo.append(o)
    return out


def _branch_targets(chain):
    """Every branch this work has: each workspace's own, plus every branch this
    agent is RECORDED as having created (created_branches). The record is what
    survives the workspace directory being deleted.

    A WORKSPACE CONTRIBUTES EXACTLY ONE BRANCH — ITS OWN — AND `branch_deleted_at`
    IS WHY THAT MATTERS. Until 2026-09-12 a workspace record could also carry an
    `extra_branches` list, which `_workspace_branches` folded in here. NOTHING
    EVER WROTE THAT FIELD: every reader (this function, the prune in `_delete`,
    the done-check) read a list that was always empty, so all three were dead
    code wearing the shape of a rule. It was also the one path in the file where
    a failed deletion could never be retried (point 13): the `branch_deleted_at`
    skip is per WORKSPACE, so the moment the workspace's own branch was deleted
    its extras dropped out of the target list — a retry could not name what it
    had failed to delete. Deleting the field deleted that path with it; nothing
    is skipped here now except a branch whose deletion has already succeeded."""
    out = []
    for r in chain:
        for w in r.get("workspaces") or []:
            if w.get("branch_deleted_at") or not w.get("branch"):
                continue
            if (w.get("repo"), w["branch"]) not in out:
                out.append((w.get("repo"), w["branch"]))
        for pair in r.get("created_branches") or []:
            t = (pair[0], pair[1])
            if t not in out:
                out.append(t)
    return out


# ---------------------------------------------------------------------------
# points 4, 7, 9, 10, 13 — land, discard, delete, retry
# ---------------------------------------------------------------------------

def integration_target(chain, repo):
    """(branch, tip, why_not) — the ref a land is proved against (point 14).

    THE ONE ANSWER. "Every part of the system that needs to know whether work
    has landed asks the same question: is it in the branch recorded for this
    work? None of them is allowed its own answer, and none of them assumes
    main." This function is that question. A consumer with no agent in hand asks
    `integration_for(repo)`, which is this with an empty chain.

    The branch comes from the body of work THIS CHAIN IS BOUND TO, and nowhere
    else. Nothing is inferred, no branch is frozen onto an agent, and nothing
    falls back to whatever the main checkout happens to have checked out: a land
    that cannot name its target REFUSES and names the command that records it.

    `chain` is the unit of work, and it is now a real input rather than a
    courtesy: a second body of work started in the same repository — which point
    5 permits while this one's agents are still running — must not move this
    chain's target. Each agent carries the work ID it was registered under; the
    branch is read live from that work, so a CORRECTION still reaches an agent
    in flight and a DIFFERENT body of work never does.

    THERE IS NO FALLBACK TO "CURRENT" FOR A CHAIN. A spawned agent is bound at
    its spawn or the spawn is refused (register_spawn, point 14), and an
    unregistered or provisional record binds at the first sweep after a body
    of work exists (scan_unregistered). A chain that is still bound to nothing
    REFUSES and names the command — reading the repository's current body of
    work at land time would be a guess about which work the agent belongs to,
    and both round-6 reviewers reproduced that guess moving a land verdict.
    Only a caller with NO chain (`integration_for`, a consumer asking about the
    repository itself) reads the current record, because that is the question
    it is asking."""
    repo = realpath(repo or "")
    if not repo or not os.path.isdir(repo):
        return "", "", "its repository %s cannot be read" % repo
    main_key = _norm_repo(repo)
    work = None
    for r in chain or []:
        wid = (r.get("integration_work") or {}).get(main_key)
        if wid:
            work = _work_by_id(wid)
            if work:
                break
    if work is None and chain:
        return "", "", ("%s is bound to no body of work in %s: it was registered while none was "
                        "recorded, and nothing guesses which one it belongs to (point 14). A spawned "
                        "agent is refused before this can happen; an unregistered workspace binds at "
                        "the next sweep once a branch is recorded: workspaces.sh integration --repo %s "
                        "--branch <main|dev/...> --why '<this body of work>'. Otherwise discard it "
                        "(point 7)." % (", ".join(r.get("name") or r.get("key") for r in chain), repo, repo))
    if work is None:
        work = integration_record(repo)
    branch = (work or {}).get("branch") or ""
    if not branch:
        return "", "", ("no branch is recorded for %s as the one this work integrates on. The branch a "
                        "body of work integrates on is RECORDED when that work starts (point 14); "
                        "nothing infers it. Record it: workspaces.sh integration --repo %s --branch "
                        "<main|dev/...> --why '<this body of work>'" % (repo, repo))
    main = main_checkout(repo) or repo
    tip = branch_tip(main, branch)
    if not tip:
        return branch, "", ("the recorded integration branch %s (body of work %s) does not exist in %s "
                            "any more. Correct the branch this work integrates on (point 14): "
                            "workspaces.sh integration --repo %s --branch <main|dev/...> --correct"
                            % (branch, (work or {}).get("id") or "?", repo, repo))
    return branch, tip, ""


def integration_for(repo):
    """(branch, tip, why_not) for a caller that has no agent in hand — the single
    answer every consumer asks instead of keeping its own.

    A SECOND CORRECT COPY IS STILL A SECOND ANSWER. Consumers that need to know
    whether work has landed — `completion-proof.py`, `land-completeness.py`,
    `land-residue-gate.py`, `unlanded-branches.py`, `guard-ci-red-lands.sh`,
    `guard-unresolved-claims.py`, `guard-idle-land.py`, `inflight.py` — call
    this. Where nothing is recorded it returns a `why_not` that NAMES THE
    RECORDING COMMAND, and the consumer abstains on it. None of them assumes
    main (point 14)."""
    return integration_target([], repo)


def land(ref, me="", auto=False, ignored_ok="", deadline=None):
    """Point 4: landed means every workspace and branch is deleted. Landed is
    proved from git: every branch tip (and every workspace HEAD) is already in
    the branch this work INTEGRATES ON, which is the branch recorded when the
    work started — usually main, and its dev branch when it cannot reach main
    yet (point 14). An agent that produced nothing is landed (point 7)."""
    rec = _resolve(ref, me)
    fin, _pz, why = finished_state(rec)
    if not fin:
        raise SpecError("%s is not finished (%s); only finished work is landed" % (rec["name"], why))
    if rec.get("disposition") and rec["disposition"].get("kind") != "continued":
        kind = rec["disposition"]["kind"]
        if kind == "landed":
            # An explicit retry must finish failed deletion, not certify the
            # earlier eligibility receipt as completed cleanup. The canonical
            # deletion path rechecks landing after writers stop.
            chain = _chain(rec)
            clean = _delete_chain(chain, "landed")
            fresh = load_agent(rec["key"]) or {}
            return {"landed": (fresh.get("disposition") or {}).get("kind") == "landed",
                    "already": kind, "cleanup_pending": not clean}
        return {"landed": True, "already": kind}
    chain = _chain(rec)
    # Shutdown can flush files or create commits. Prove landing only after it.
    paths = [w["path"] for r in chain for w in live_workspaces(r) if w.get("path")]
    stopped = stop_processes(paths)
    if stopped.get("survivors"):
        raise SpecError("cannot land %s: workspace processes are still running: %s" %
                        (rec["name"], stopped["survivors"]))
    containers = stop_containers(paths)
    if containers.get("failed"):
        raise SpecError("cannot land %s: workspace containers could not be stopped" % rec["name"])
    _require_landed(rec, chain, ignored_ok, deadline)
    for r in chain:
        with Lock():
            fresh = load_agent(r["key"])
            fresh["disposition"] = {"kind": "landed", "at": now(), "auto": bool(auto), "by_session": me,
                                    "ignored_not_needed": ignored_ok or None, "as_part_of": rec["key"]}
            save_agent(fresh)
        event("landed", key=r["key"], auto=bool(auto), as_part_of=rec["key"])
    clean = _delete_chain(chain, "landed", processes=stopped)
    if not clean:
        if not (load_agent(rec["key"]) or {}).get("disposition"):
            raise SpecError("landing eligibility changed during cleanup; the work was preserved")
    return {"landed": True, **({"cleanup_pending": True} if not clean else {})}


def _require_landed(rec, chain, ignored_ok="", deadline=None):
    """Read current work after writers stop, including on a deletion retry."""
    for r in chain:
        _require_clean(r, "land %s" % r["name"], ignored_ok, deadline)
    missing = []
    targets = {}

    def _target(repo):
        """The RECORDED integration ref of this repository (point 14) — resolved
        once per land, never from a HEAD read at land time."""
        if repo not in targets:
            targets[repo] = integration_target(chain, repo)
        return targets[repo]

    for r in chain:
        for w in r.get("workspaces") or []:
            repo = w.get("repo")
            branch, tip, why_not = _target(repo)
            if why_not:
                missing.append("%s: %s" % (w.get("path") or w.get("branch"), why_not))
                continue
            if not w.get("deleted_at") and w.get("path") and os.path.isdir(w["path"]):
                rc, out, _ = git(w["path"], "rev-parse", "HEAD")
                if rc == 0 and not is_ancestor(repo, out.strip(), tip):
                    missing.append("HEAD of %s (%s) is not in %s of %s at %s"
                                   % (w["path"], out.strip()[:12], branch, repo, tip[:12]))
    for repo, b in _branch_targets(chain):
        if _past(deadline):
            raise Deadline("the gate's budget ran out before %s's branches could be proved to be in the "
                           "branch this work integrates on" % rec["name"])
        branch, tip, why_not = _target(repo)
        if why_not:
            missing.append("branch %s: %s" % (b, why_not))
            continue
        t = branch_tip(repo, b)
        if t and not is_ancestor(repo, t, tip):
            missing.append("%s (%s) is not in %s of %s at %s" % (b, t[:12], branch, repo, tip[:12]))
    if missing:
        raise SpecError("%s is not landed yet: %s. Merge it onto the branch this work integrates on, "
                        "then land it; or discard it (point 7)." % (rec["name"], "; ".join(missing)))


def discard(ref, reason, ceo_word="", not_ceo_ordered="", me=""):
    """Point 7: work that must not go into main is discarded — every workspace
    and branch deleted, with the reason recorded. Work the CEO ordered is never
    discarded without his word."""
    if len((reason or "").strip()) < 10:
        raise SpecError("a discard records its reason (point 7): give one")
    rec = _resolve(ref, me)
    fin, _pz, why = finished_state(rec)
    if not fin:
        raise SpecError("%s is not finished (%s). Stop it first; a running agent is not discarded."
                        % (rec["name"], why))
    chain = _chain(rec)
    ordered = [r for r in chain if r.get("ceo_ordered")]
    if ordered and not (ceo_word or "").strip():
        raise SpecError("%s is work the CEO ordered (%s). It is never discarded without his word: ask him, "
                        "then pass --ceo-word '<his words>' (point 7)."
                        % (rec["name"], ordered[0]["ceo_ordered"]))
    if not ordered and not (ceo_word or "").strip() and len((not_ceo_ordered or "").strip()) < 10:
        raise SpecError("say whether the CEO ordered this work: --ceo-word '<his words>' or "
                        "--not-ceo-ordered '<why it was not his order>' (point 7)")
    tips = {}
    for repo, b in _branch_targets(chain):
        t = branch_tip(repo, b)
        if t:
            tips["%s:%s" % (repo, b)] = t
    for r in chain:
        with Lock():
            fresh = load_agent(r["key"])
            fresh["disposition"] = {"kind": "discarded", "at": now(), "reason": reason.strip(),
                                    "ceo_word": ceo_word or None, "not_ceo_ordered": not_ceo_ordered or None,
                                    "tips": tips, "by_session": me, "as_part_of": rec["key"]}
            save_agent(fresh)
        event("discarded", key=r["key"], reason=reason, tips=tips, as_part_of=rec["key"])
    _delete_chain(chain, "discarded")
    return {"discarded": True, "tips": tips}


def _delete_chain(chain, why, processes=None):
    allw = [(r, w) for r in chain for w in live_workspaces(r) if w.get("path")]
    stopped = processes if processes is not None else stop_processes([w["path"] for _r, w in allw])
    complete = True
    for r in chain:
        if not _delete(r, [w for w in live_workspaces(r) if w.get("path")], branches=True, why=why,
                       processes=stopped):
            complete = False
            if why == "landed" and not (load_agent(r["key"]) or {}).get("disposition"):
                return False
    return complete


def _delete(rec, workspaces, branches, why, processes=None):
    """Points 9, 10, 13: stop every process, then delete every workspace (and
    branch) as one; whatever fails is retried automatically."""
    if processes is None:
        processes = stop_processes([w["path"] for w in workspaces])
    failures = []
    if processes.get("survivors"):
        failures.append("processes still running in its workspaces: %s" % processes["survivors"])
    else:
        # Containers first, directories second: a workspace's containers are
        # part of it, and stop_containers never raises, so this cannot cost a
        # deletion that would otherwise have succeeded. See stop_containers.
        containers = stop_containers([w["path"] for w in workspaces])
        # §54 addendum 4, and it sits here rather than beside stop_processes
        # for the same reason containers do: it never raises and it never
        # blocks the deletion, so it cannot cost a land that would otherwise
        # have worked. A window that will not close is recorded for the alert,
        # not made into a reason to keep a landed worktree on disk.
        stop_test_instances([w["path"] for w in workspaces])
        current = load_agent(rec["key"]) or rec
        disposition = current.get("disposition") or {}
        if disposition.get("kind") == "landed":
            owner = load_agent(disposition.get("as_part_of") or rec["key"]) or current
            chain = _chain(owner)
            try:
                if containers.get("failed"):
                    raise SpecError("workspace containers could not be stopped")
                _require_landed(owner, chain, disposition.get("ignored_not_needed") or "")
            except SpecError as e:
                # Eligibility expired. Return surviving work to the pending gate,
                # instead of retrying a forced deletion under an old verdict.
                with Lock():
                    for member in chain:
                        if not os.path.exists(agent_path(member["key"])):
                            continue
                        fresh = load_agent(member["key"])
                        if (fresh.get("disposition") or {}).get("kind") == "landed":
                            if fresh.get("deletion"):
                                fresh["landing_cleanup_started"] = True
                            fresh["disposition"] = None
                            fresh["deletion"] = None
                            fresh.setdefault("history", []).append({"at": iso(),
                                "fact": "landing eligibility changed", "why": str(e)})
                            save_agent(fresh)
                event("landing-reopened", key=rec["key"], why=str(e))
                return False

        for w in workspaces:
            # Point 3: the branches the agent created are its branches too, and
            # they are recorded (observe_created_refs) rather than read back out of
            # the directory here — the record survives the directory.
            ok, err = remove_workspace(w)
            if ok:
                w["deleted_at"] = iso()
            else:
                failures.append(err)
    untouched = []
    if branches and not processes.get("survivors"):
        for repo, b in _branch_targets([rec]):
            ok, err = delete_branch(repo, b)
            if ok is None:
                # POINT 2, AT THE DELETER: a codex/ ref on this agent's record —
                # it can only get there by hand or by a defect, since
                # observe_created_refs never attributes one — is aimed at and
                # REFUSED by delete_branch, and the refusal is not a failed
                # deletion to retry until the CEO is told: it is the page's own
                # answer. The ref is dropped from the record with the fact
                # written down, and the agent's own deletion completes.
                untouched.append({"at": iso(), "fact": "codex/ untouched", "repo": repo, "branch": b, "why": err})
                rec["created_branches"] = [p for p in (rec.get("created_branches") or [])
                                           if (p[0], p[1]) != (repo, b)]
                for w in rec["workspaces"]:
                    if w.get("repo") == repo and w.get("branch") == b and not w.get("path"):
                        w["deleted_at"] = iso()
                event("codex-untouched", key=rec["key"], repo=repo, branch=b)
                continue
            if ok:
                for w in rec["workspaces"]:
                    if w.get("repo") == repo and w.get("branch") == b:
                        w["branch_deleted_at"] = iso()
                        if not w.get("path"):
                            w["deleted_at"] = iso()
                rec["created_branches"] = [p for p in (rec.get("created_branches") or [])
                                           if (p[0], p[1]) != (repo, b)]
            else:
                failures.append(err)
    with Lock():
        fresh = load_agent(rec["key"]) or rec
        fresh["workspaces"] = rec["workspaces"]
        fresh["created_branches"] = rec.get("created_branches") or []
        if untouched:
            fresh.setdefault("history", []).extend(untouched)
        if failures:
            d = fresh.get("deletion") or {"attempts": 0, "first_failed_at": now()}
            d["attempts"] = d.get("attempts", 0) + 1
            d["last_error"] = "; ".join(failures)[:2000]
            d["next_at"] = now() + min(RETRY_CAP_SECONDS, RETRY_BASE_SECONDS * (2 ** (d["attempts"] - 1)))
            d["branches"] = bool(branches)
            fresh["deletion"] = d
        else:
            fresh["deletion"] = None
        save_agent(fresh)
        done = not failures and fresh.get("disposition") and fresh["disposition"].get("kind") != "continued"
        if done and not fresh["created_branches"] \
                and all(w.get("deleted_at") and (w.get("branch_deleted_at") or not w.get("branch"))
                        for w in fresh["workspaces"]):
            write_json(done_path(fresh["key"]), fresh)
            os.unlink(agent_path(fresh["key"]))
            _drop_snapshots(fresh["key"])
    event("deleted" if not failures else "deletion-failed", key=rec["key"], why=why,
          failures=failures or None, stopped=processes.get("stopped") or None)
    return not failures


def retry_due(budget=5.0):
    """Point 13: a failed deletion is retried with no one's involvement."""
    t0 = now()
    out = []
    for rec in all_agents():
        d = rec.get("deletion")
        if not d or d.get("next_at", 0) > now():
            continue
        if now() - t0 > budget:
            break
        targets = [w for w in live_workspaces(rec) if w.get("path")]
        ok = _delete(rec, targets, branches=d.get("branches", True), why="retry %d" % (d.get("attempts", 0) + 1))
        out.append((rec["key"], ok))
    return out


def keeps_failing():
    return [r for r in all_agents() if (r.get("deletion") or {}).get("attempts", 0) >= RETRY_TELL_CEO_AFTER]


def remove_workspace(w):
    path, repo = w.get("path"), w.get("repo")
    main = main_checkout(repo) if repo and os.path.isdir(repo) else ""
    if not main:
        return False, "%s: its repository %s cannot be read" % (path, repo)
    wl = worktree_list(main) or []
    entry = None
    for e in wl:
        if e["path"] == path:
            entry = e
    if entry and wl and entry is wl[0]:
        return False, "%s is the main checkout of %s and is never deleted" % (path, main)
    if entry and entry["branch"].startswith(CODEX_PREFIX):
        return False, "%s is now on %s; codex/ is never touched (point 2)" % (path, entry["branch"])
    if os.path.lexists(path):
        if entry is None:
            # Git no longer lists it. Delete it only if it is provably this
            # repository's workspace (its .git file points into this
            # repository's worktrees/), or the residue of a deletion that git
            # began (no .git left at all) — never a repository of its own.
            gitfile = os.path.join(path, ".git")
            if os.path.isdir(gitfile):
                return False, "%s is a repository of its own, not a workspace of %s; not deleted" % (path, main)
            if os.path.isfile(gitfile):
                with open(gitfile, encoding="utf-8", errors="replace") as f:
                    pointer = f.read()
                common = _common_dir(main)
                if not common or (os.path.join(common, "worktrees") + os.sep) not in realpath(
                        pointer.replace("gitdir:", "").strip()) + os.sep:
                    return False, "%s is not a workspace of %s; not deleted" % (path, main)
            shutil.rmtree(path, ignore_errors=True)
        else:
            rc, _o, err = git(main, "worktree", "remove", "--force", "--force", path, timeout=300)
            if rc != 0 and os.path.lexists(path):
                return False, "git worktree remove %s failed: %s" % (path, err.strip()[:300])
    # A registration whose directory is gone: remove exactly its own admin entry.
    wl = worktree_list(main) or []
    if any(e["path"] == path for e in wl):
        admin = _admin_dir_for(main, path)
        if admin:
            shutil.rmtree(admin, ignore_errors=True)
    if os.path.lexists(path):
        return False, "%s still exists after deletion" % path
    if any(e["path"] == path for e in (worktree_list(main) or [])):
        return False, "%s is still registered with git after deletion" % path
    return True, ""


def _common_dir(main):
    rc, out, _ = git(main, "rev-parse", "--path-format=absolute", "--git-common-dir")
    return realpath(out.strip()) if rc == 0 else ""


def _admin_dir_for(main, path):
    common = _common_dir(main)
    base = os.path.join(common, "worktrees") if common else ""
    if not base or not os.path.isdir(base):
        return ""
    for n in os.listdir(base):
        g = os.path.join(base, n, "gitdir")
        try:
            with open(g, encoding="utf-8") as f:
                target = f.read().strip()
        except OSError:
            continue
        if realpath(os.path.dirname(target)) == path or realpath(target) == os.path.join(path, ".git"):
            return os.path.join(base, n)
    return ""


def delete_branch(repo, b):
    """(True, "") deleted or already gone; (False, why) failed, retried later
    (point 13); (None, why) REFUSED BY THE PAGE — a codex/ branch is never
    touched (point 2), and that is an answer, not a failure to retry."""
    if b.startswith(CODEX_PREFIX):
        return None, "branch %s is codex/; never touched (point 2)" % b
    main = main_checkout(repo)
    wl = worktree_list(main) or []
    if not wl:
        return False, "%s: repository %s cannot be read" % (b, repo)
    if wl[0]["branch"] == b:
        return False, "branch %s is the main checkout's branch; never deleted" % b
    if not branch_tip(main, b):
        return True, ""
    holders = [e["path"] for e in wl if e["branch"] == b]
    if holders:
        return False, "branch %s is still checked out at %s" % (b, holders[0])
    rc, _o, err = git(main, "branch", "-D", b)
    if rc != 0 or branch_tip(main, b):
        return False, "git branch -D %s failed: %s" % (b, err.strip()[:300])
    return True, ""


# ---------------------------------------------------------------------------
# point 9 — every process it started is stopped before deletion
# ---------------------------------------------------------------------------

def _process_cwds():
    """{pid: cwd} for every process the OS will show us."""
    out = {}
    if os.path.isdir("/proc/self"):
        for n in os.listdir("/proc"):
            if n.isdigit():
                try:
                    out[int(n)] = os.readlink("/proc/%s/cwd" % n)
                except OSError:
                    continue
        return out
    if shutil.which("lsof"):
        try:
            r = subprocess.run(["lsof", "-a", "-d", "cwd", "-F", "pn", "-w"], capture_output=True, text=True,
                               timeout=60, env=_ps_env())
        except (OSError, subprocess.TimeoutExpired):
            return out
        pid = None
        for line in r.stdout.splitlines():
            if line.startswith("p"):
                try:
                    pid = int(line[1:])
                except ValueError:
                    pid = None
            elif line.startswith("n") and pid:
                out[pid] = line[1:]
    return out


def _process_args():
    try:
        r = subprocess.run(["ps", "-axo", "pid=,args="], capture_output=True, text=True, timeout=30, env=_ps_env())
    except (OSError, subprocess.TimeoutExpired):
        return {}
    out = {}
    for line in r.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            out[int(parts[0])] = parts[1]
    return out


def _protected_pids():
    """This process, its ancestors and every claude process: never stopped."""
    keep = set()
    pid = os.getpid()
    for _ in range(64):
        if not pid or pid <= 1:
            break
        keep.add(pid)
        pid, _c = _ps_parent_and_comm(pid)
    for p, a in _process_args().items():
        if os.path.basename((a.split() or [""])[0]) == "claude":
            keep.add(p)
    return keep


def processes_in(paths):
    paths = [realpath(p) for p in paths if p]
    if not paths:
        return []
    keep = _protected_pids()
    hits = set()
    for pid, cwd in _process_cwds().items():
        c = realpath(cwd)
        if any(c == p or c.startswith(p + os.sep) for p in paths):
            hits.add(pid)
    for pid, args in _process_args().items():
        if any((" " + p + os.sep) in (" " + args + os.sep) or (" " + p + " ") in (" " + args + " ")
               or args.endswith(" " + p) for p in paths):
            hits.add(pid)
    return sorted(h for h in hits if h not in keep)


def stop_processes(paths):
    pids = processes_in(paths)
    if not pids:
        return {"stopped": [], "survivors": []}
    for p in pids:
        try:
            os.kill(p, signal.SIGTERM)
        except OSError:
            pass
    deadline = now() + PROCESS_STOP_GRACE
    alive = list(pids)
    while alive and now() < deadline:
        time.sleep(0.1)
        alive = [p for p in alive if _alive(p)]
    for p in alive:
        try:
            os.kill(p, signal.SIGKILL)
        except OSError:
            pass
    time.sleep(0.2)
    survivors = [p for p in alive if _alive(p)]
    event("processes-stopped", pids=pids, survivors=survivors or None)
    return {"stopped": pids, "survivors": survivors}


def stop_test_instances(paths):
    """§54 ADDENDUM 4: a test instance of the app still running after its agent
    has finished is uncollected garbage, and the land step collects it.

    CEO, 2026-09-18, verbatim: "Ray had left the test app window open. Test app
    windows must always close/quit when testing is finished. Same hygiene as
    with any other garbage." The candidate-.7 walk ended with the QA instance
    still on his screen after the handoff.

    WHY stop_processes DOES NOT ALREADY DO THIS, measured rather than assumed.
    stop_processes matches a process by its cwd or by its workspace path
    appearing in argv. A test instance launched the way this engine launches
    one has NEITHER: scripts/lib/gui-launch.sh runs it `cd /` with `env -i`, so
    its cwd is `/`, and the candidate-.7 instance's argv was the relative
    `./RichOS.app/Contents/MacOS/richos-tauri`, which names no absolute path at
    all. Both tests miss it, which is exactly how it survived its own land.

    WHAT IS IN SCOPE HERE, AND WHAT IS DELIBERATELY NOT. This collects
    instances rooted under the paths being deleted -- the landing agent's own
    workspaces -- and nothing else. It does NOT sweep every scratch root on the
    machine, because a live peer agent's test instance is rooted under a scratch
    root too, and quitting a running colleague's app mid-test would be a new
    defect wearing this fix's clothes. The machine-wide arm belongs to the
    reaper, which knows which sessions are still alive; here we only know about
    this agent.

    A SURVIVOR DOES NOT BLOCK THE WORKSPACE DELETION, and that is on purpose. A
    window that will not close is not a reason to keep a landed worktree on
    disk; the two failures are unrelated. It is made DURABLE instead, so the
    §54 alert names it at session start and every turn end until it is gone.
    Never raises: tidying up must not be able to break the deleter it hangs off.
    """
    try:
        here = os.path.join(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))), "scripts", "lib")
        if here not in sys.path:
            sys.path.insert(0, here)
        import appinstances
        own = [p for p in paths if p]
        if not own:
            return {}
        # include_declared=False: ONLY this agent's workspaces. See the RootSet
        # docstring -- with the declared roots in scope this call would quit a
        # live peer's test instance.
        res = appinstances.collect_and_record(
            roots=appinstances.RootSet(extra=own, include_declared=False))
    except Exception as e:
        event("test-instances-uncollected", why=str(e)[:200], paths=paths or None)
        return {}
    if res.get("collected") or res.get("survivors") or res.get("undecided"):
        event("test-instances-collected",
              collected=[d["pid"] for d in res.get("collected") or []] or None,
              survivors=[d["pid"] for d in res.get("survivors") or []] or None,
              undecided=[d["pid"] for d in res.get("undecided") or []] or None)
    collect_test_devices(departing=paths)
    return res


def collect_test_devices(departing=(), budget=None):
    """§54 FOR SIMULATORS AND EMULATORS (scripts/lib/testdevices.py). On
    2026-09-22 three iOS simulators booted by killed test runs outlived their
    agents and the session. Collected here machine-wide, because each device is
    removed only when its owner is PROVEN gone (a registered pid, the pid its
    name carries, or a recorded checkout that no longer exists), so a live
    peer's device is never touched. `departing` are the workspaces this land is
    deleting: a device keyed to one of them goes with it. Never raises."""
    try:
        here = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts", "lib")
        if here not in sys.path:
            sys.path.insert(0, here)
        import testdevices
        res = testdevices.collect(apply=True, departing=[p for p in departing or () if p],
                                  deadline=(now() + budget) if budget else None)
    except Exception as e:
        event("test-devices-uncollected", why=str(e)[:200])
        try:
            from testdevice_alerts import record_failure
            record_failure("collector unavailable: %s" % e)
        except Exception as alert_error:
            sys.stderr.write("TEST DEVICE CLEANUP FAILED; alert state could not be written: %s\n" % alert_error)
        return {}
    # A shut-down device nothing proves the owner of is reported by the
    # collector itself; repeating it in the history at every land is noise.
    running = [d["id"] for d in res.get("undecided") or [] if d.get("state") != "Shutdown"]
    if res.get("notes"):
        event("test-devices-uncollected", why="; ".join(res["notes"])[:400])
    if res.get("collected") or res.get("survivors") or running or res.get("deferred"):
        event("test-devices-collected",
              collected=[d["id"] for d in res.get("collected") or []] or None,
              survivors=[d["id"] for d in res.get("survivors") or []] or None,
              undecided=running or None,
              deferred=[d["id"] for d in res.get("deferred") or []] or None)
    return res


def stop_containers(paths):
    """POINT 9'S OTHER HALF: the containers a workspace declared go with it.

    "reap PROCESSES, not just directories" was written after a detached child
    outlived both its agent and its worktree. A container is that same defect
    wearing a different hat, and nothing was reaping them:
    `agent-af36c9abcc76937ab-redis-1` — an agent id — sat on the founder's
    machine for six weeks after its agent ended.

    The whole mechanism, and the argument for every refusal in it, is in
    scripts/lib/containers.py. Two properties matter to THIS caller, and both
    are that file's job to keep: it NEVER raises, and it never removes a
    container that is not DECLARED by one of these paths. A machine with no
    Docker, or a daemon that is down, lands work exactly as it did before this
    function existed.
    """
    try:
        here = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts", "lib")
        if here not in sys.path:
            sys.path.insert(0, here)
        import containers
        # ending=True: these workspaces are being deleted right now, so their
        # own liveness must not protect them from their own deletion. Every
        # other live workspace keeps its protection. See reap_for_workspaces.
        res = containers.reap_for_workspaces(paths, ending=True)
    except Exception as e:
        # Tidying up must never be able to break the deleter it is attached to.
        event("containers-unreaped", why=str(e)[:200], paths=paths or None)
        return {}
    if res.get("removed") or res.get("failed") or res.get("kept"):
        event("containers-reaped", removed=[r["name"] for r in res.get("removed") or []] or None,
              failed=[r["name"] for r in res.get("failed") or []] or None,
              kept=[r["name"] for r in res.get("kept") or []] or None)
    return res


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        r = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, timeout=5)
        return r.returncode == 0 and "Z" not in r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return True


# ---------------------------------------------------------------------------
# point 9 — the lock-out, and point 3 — no worktree sessions
# ---------------------------------------------------------------------------

RECOVERY_SCRIPTS = ("stop.sh", "stop-work-ack.sh")


def engine_root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def stop_command():
    return os.path.join(engine_root(), "scripts", "stop.sh")


def _one_plain_command(cmd):
    """True when `cmd` is ONE simple command: no operator, redirection,
    substitution or expansion anywhere a shell would act on it. Single quotes
    make everything literal; inside double quotes `$` and a backquote still
    act, so they are refused there too."""
    q = None
    i = 0
    while i < len(cmd):
        c = cmd[i]
        if q == "'":
            if c == "'":
                q = None
        elif q == '"':
            if c == '"':
                q = None
            elif c == "\\":
                i += 1
            elif c in "$`":
                return False
        elif c in "'\"":
            q = c
        elif c == "\\":
            i += 1
        elif c in ";&|<>()$`\n\r":
            return False
        i += 1
    return q is None


def lead_recovery_call(payload):
    """The name of the stop this lead call is, or "".

    POINT 3 NEVER TAKES AWAY THE STOP. A refused lead that cannot stop its
    agents is how 2026-09-22 went: ten agents at 100% CPU for 33 minutes, the
    lead refused TaskStop, SendMessage and every command, and the CEO stopping
    them from his own screen. So a refused lead may still stop agents: TaskStop,
    and the engine's own stop.sh / stop-work-ack.sh (which write only the ack
    TaskStop's guard asks for), called as ONE plain command resolving to THIS
    engine's copy. Nothing may ride along with it."""
    tool = str(payload.get("tool_name") or "")
    if tool == "TaskStop":
        return "TaskStop"
    if tool != "Bash":
        return ""
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    cmd = str(ti.get("command") or "").strip()
    if not cmd or not _one_plain_command(cmd):
        return ""
    try:
        toks = shlex.split(cmd)
    except ValueError:
        return ""
    if toks and toks[0] in ("bash", "/bin/bash"):
        toks = toks[1:]
    if not toks:
        return ""
    p = os.path.expanduser(toks[0])
    if not os.path.isabs(p):
        base = str(payload.get("cwd") or "")
        if not base:
            return ""
        p = os.path.join(base, p)
    rp = realpath(p)
    for name in RECOVERY_SCRIPTS:
        if rp == realpath(os.path.join(engine_root(), "scripts", name)):
            return name
    return ""


def barrier(payload):
    """Verdict for guard-sealed-worktree.sh: (kind, detail).
    FINISHED        a finished agent: refused every tool (point 9)
    FORBIDDEN       the lead of a claude --worktree session (point 3)
    RECOVERY        that lead stopping its agents: never refused
    REGISTERED      a registered, unfinished worker (paused included)
    UNREGISTERED    a worker with no registration (point 3)
    LEAD            the lead's own call"""
    sid = str(payload.get("session_id") or "")
    aid = str(payload.get("agent_id") or "")
    if not aid:
        s = load_session(sid) if sid else None
        if s and s.get("forbidden"):
            why = forbidden_now(sid, s)
            if why:
                stop = lead_recovery_call(payload)
                if stop:
                    return "RECOVERY", "%s stops agents, which a refused lead may always do (%s)" % (stop, why)
                return "FORBIDDEN", why
        return "LEAD", ""
    key = key_for_id(aid)
    rec = load_agent(key) if key else None
    if not rec:
        return "UNREGISTERED", "agent %s has no registration" % aid
    # POINT 9 MEETS POINT 11'S FOURTH ENDING. "The platform restarts finished
    # agents. A restarted agent is refused every tool." A STOPPED agent's
    # restart can be the FIRST thing that happens after the kill — before any
    # gate or command has looked at it — so the lock-out asks the platform's
    # own record here too, rather than waiting to be told.
    rec = observe_platform_end(rec)
    fin, _paused, why = finished_state(rec)
    if fin:
        return "FINISHED", "agent %s (%s) is finished: %s" % (aid, rec.get("name"), why)
    # POINT 2, AT THE TOOL: "An agent never works inside a codex/ workspace."
    # The Bash guard refuses a command run there; the only hook that sees a
    # Write, Edit, MultiEdit or NotebookEdit is this one, and until round 8 an
    # agent's Edit with a file_path inside a codex/ workspace passed
    # (brief-audit-sage-round8 §4, measured with a registered agent). Whether
    # the path IS inside a codex/ workspace is read from git on disk — the
    # branch its worktree has checked out — never from the path's spelling.
    tool = str(payload.get("tool_name") or "")
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
        fp = str(ti.get("file_path") or ti.get("notebook_path") or "")
        cx = _codex_workspace_of(fp)
        if cx:
            return "CODEX", "agent %s (%s) is writing %s inside the codex/ workspace %s" % (
                aid, rec.get("name"), fp, cx)
    # This call carries the agent's id, so it is a moment the platform vouches
    # for. Record what its repositories hold NOW; the catch-all PostToolUse
    # compares, and a ref that appeared in between was created by this agent
    # (point 3, "any branch an agent created"). It runs only for an UNFINISHED
    # agent: a ref Rich cuts after the run has ended, to rescue the work, is his
    # and is never a candidate at all.
    snapshot_refs(rec, str(payload.get("tool_use_id") or ""))
    return "REGISTERED", rec.get("name") or ""


def _codex_workspace_of(path):
    """The top level of the codex/ workspace `path` lies in, or "". Read from
    git: the nearest existing ancestor's toplevel, and the branch git lists
    for that worktree."""
    p = realpath(path)
    if not p:
        return ""
    d = p if os.path.isdir(p) else os.path.dirname(p)
    while d and not os.path.isdir(d):
        d = os.path.dirname(d)
    if not d or d == os.sep:
        return ""
    rc, out, _ = git(d, "rev-parse", "--show-toplevel")
    if rc != 0:
        return ""
    top = realpath(out.strip())
    for e in worktree_list(top) or []:
        if e["path"] == top and (e.get("branch") or "").startswith(CODEX_PREFIX):
            return top
    return ""


def recipient_state(session_id, name):
    rec = load_agent(named_key(session_id, name)) if session_id and name else None
    if not rec:
        return "unregistered", ""
    # A STOPPED agent is finished (point 11), so a message to it would restart
    # an agent that can do nothing — which is what guard-resume-isolation.sh
    # refuses. It asks this function, so this function asks the platform's own
    # record rather than waiting for a signal a stopped run never sends.
    rec = observe_platform_end(rec)
    fin, paused_, why = finished_state(rec)
    return ("finished" if fin else ("paused" if paused_ else "active")), why


# ---------------------------------------------------------------------------
# the Stop gate (point 5)
# ---------------------------------------------------------------------------

def _turn_started_by_person(transcript):
    """True when the turn now ending began with a message from a person — the
    CEO — rather than a platform notification. Read from the transcript."""
    try:
        size = os.path.getsize(transcript)
        with open(transcript, "rb") as f:
            f.seek(max(0, size - 4 * 1024 * 1024))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except (OSError, TypeError):
        return False
    for line in reversed(lines):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if not isinstance(d, dict) or d.get("type") != "user":
            continue
        verdict = _row_is_a_persons(d)
        if verdict is None:
            continue                     # this row starts no turn: the row before it does
        return verdict
    return False


def _row_is_a_persons(d):
    """None — this row starts no turn (a tool result, hook feedback, a
    compaction summary, image metadata: skip to the row before it);
    True — a person's turn, the CEO's; False — the platform's, a peer's, a
    notification's.

    DECIDED ON THE FIELDS THE PLATFORM STAMPS, NEVER ON THE SHAPE OF THE TEXT
    (round 8, item 4). Until round 8 this was a deny-list of five tag names over
    the text (`<task-notification`, `<teammate-message`, ...), so any shape the
    platform had not been listed for read as a person — and the transcripts on
    this machine already held one: 68 non-meta peer-message rows beginning
    `Another Claude session sent a message:` (v2.1.229–2.1.267, origin absent)
    passed the deny-list and spent the CEO's allowance. A textual ALLOW-list is
    wrong the other way: the CEO's own `[Image #5] …` turns (11 rows, origin
    human, promptSource typed/queued) begin with a bracket.

    Measured over every persisted transcript on this machine on 2026-09-13
    (2,591 files; 4,675 main-session user text rows; the census script and its
    output are in docs/verification/round8-fixes-2026-09-13-logs/): a row a
    person typed carries `origin.kind == "human"` (1,861 typed + 52 queued + 24
    suggestion_accepted + 92 through the SDK, all versions 2.1.217–2.1.269); the
    RichOS app's prompts through the `sdk-cli` entrypoint carry NO origin and
    `promptSource: sdk` (670 rows, v2.1.250–2.1.267 — an origin-only rule
    rejects every one of them); a notification carries `origin.kind ==
    "task-notification"` and `promptSource: system` (1,320 rows); a peer's
    message carries `origin.kind == "peer"` with `isMeta` (53 rows); hook
    feedback, image metadata and local-command caveats are `isMeta` with no
    origin (283 rows, none starts a turn); a compaction summary is
    `isCompactSummary` (8 rows, none starts a turn); and every main-session row
    with NO origin and NO promptSource is the platform's — `<command-name>`,
    `<local-command-stdout>`, `[Request interrupted by user]`, the 68 old-shape
    peer rows — 212 rows, not one of them a person's words. Both sides are
    asserted from those shapes in the fourteen (C5.15, C5.16)."""
    msg = d.get("message") or {}
    content = msg.get("content")
    texts = []
    if isinstance(content, str):
        texts = [content]
    elif isinstance(content, list):
        if any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
            return None
        texts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
    text = "\n".join(texts).strip()
    origin = d.get("origin")
    kind = origin.get("kind") if isinstance(origin, dict) else None
    if d.get("isMeta") or d.get("isCompactSummary"):
        # A meta row with a stamped non-human origin (a peer's message, the
        # coordinator's) starts a turn that is not his. A meta row with no
        # origin (hook feedback, image metadata, a caveat, a summary) is part of
        # another row's turn: the row before it decides.
        if kind and kind != "human":
            return False
        return None
    if not text and not isinstance(origin, dict):
        return None
    if d.get("queueSkipAttachments") or d.get("promptSource") == "system":
        return False
    if isinstance(origin, dict):
        return kind == "human"
    return d.get("promptSource") in ("typed", "queued", "sdk", "suggestion_accepted")


def _allowance_state(rec, item):
    """WHAT THE ONE ALLOWANCE WAS SPENT ON — the item's decision-relevant state.

    Point 5 allows a reply that names the pending work, and the page binds that
    allowance in its own parenthesis: "(the reply names the pending work, WHICH
    IS HANDLED RIGHT AFTER)". Naming it is not handling it, so the allowance is
    spent per item and returns only when the item has MOVED. This is the
    fingerprint of "moved": the reason it is pending, what it is recorded as
    waiting on, the workspaces it still has, and the tip of every branch it
    still has. Rich committing what the agent left to its branch, or merging
    it, or recording what it waits on, all change it; a second turn that only
    says the name again does not.

    It is bounded by the ITEM's own branches — one rev-parse each — never by a
    scan of anything (see the gate's budget)."""
    tips = []
    for repo, b in sorted(_branch_targets([rec])):
        tips.append("%s\t%s\t%s" % (repo, b, branch_tip(repo, b)))
    return hashlib.sha1(json.dumps([
        item["why"], item["waiting"], item["waiting_on"],
        sorted((p or "", b or "") for p, b in item["workspaces"]),
        (rec.get("disposition") or {}).get("kind", ""),
        sorted(rec.get("lands_pending") or []),
        sorted(rec.get("continues") or []),
        tips,
    ], sort_keys=True).encode("utf-8")).hexdigest()


def _allowance_spent_message(spent):
    lines = ["=== That reply has already used its one allowance (point 5) ===",
             "  Spec: %s — \"the reply names the pending work, which is HANDLED RIGHT AFTER\"." % SPEC,
             "  Naming it a second time is not handling it. These items were named in an earlier",
             "  reply and have not moved since — same reason, same workspaces, same branch tips:"]
    for i, prev in spent:
        lines.append("   - %s: named at %s; %s" % (i["name"], iso(prev.get("at")), i["why"]))
    lines += ["  The allowance returns the moment the item MOVES: commit what it left to its branch,",
              "  merge it, record what it waits on, start the work that lands it, or discard it.",
              "  Handling it is the only way past this."]
    return "\n".join(lines)


def refused_session_text(why):
    return ("THIS SESSION IS NOT ALLOWED: %s. Nobody starts a session in its own workspace in RichOS "
            "(point 3); every tool but reading and stopping agents is refused, and retrying cannot succeed. "
            "To stop its agents, first prepare the acknowledgement with "
            "%s <name> [<name> ...] --ceo-word '<his words>', then make the printed TaskStop calls. Tell the CEO once that the session "
            "must be restarted from the repository's main checkout, and end the turn."
            % (why, stop_command()))


def _refused_session_notice(sid, why):
    """The Stop gate's answer for a refused session: said ONCE, never a hold.

    2026-09-22, 23:31-23:43Z: this gate refused the lead's turn end 42 times,
    each time demanding a `workspaces.sh wait` that the lock-out refused, and
    each refusal produced one more "still blocked" reply. A session that can do
    nothing but stop agents cannot land anything, so holding its turn only
    makes it spin; the finished work waits for the next session, whose start
    names it first (point 5)."""
    with Lock():
        rec = load_session(sid) or {}
        if rec.get("refused_notice") == why:
            return ""
        rec["refused_notice"] = why
        write_json(session_path(sid), rec)
    event("refused-session-told", session_id=sid)
    return refused_session_text(why)


def gate_stop(payload, entity):
    """(allowed, message). Point 5: Rich cannot end his turn while finished
    work is neither landed nor discarded, except as the page allows."""
    sid = str(payload.get("session_id") or "")
    if not sid:
        return True, ""
    s = load_session(sid)
    if s and s.get("forbidden"):
        why = forbidden_now(sid, s)
        if why:
            return True, _refused_session_notice(sid, why)
    retry_due()
    report = {}
    items = pending(sid, entity, scan=True, deadline=_gate_deadline(GATE_STOP_BUDGET), report=report)
    loud = keeps_failing()
    notes = []
    if report.get("deferred"):
        notes.append("NOTE: the gate answered inside its budget rather than overrunning the hook's "
                     "timeout, which the platform would have canceled, discarding this answer. "
                     "%d item(s) were not checked for an automatic land this turn and STAY PENDING: %s. "
                     "That is the safe answer, not a missing one. `workspaces.sh land <name>` run by "
                     "hand has no budget."
                     % (len(report["deferred"]), ", ".join(sorted(set(report["deferred"])))))
    for r in loud:
        d = r["deletion"]
        notes.append("TELL THE CEO: deleting %s has failed %d times since %s: %s" % (
            r.get("name"), d.get("attempts"), iso(d.get("first_failed_at")), d.get("last_error")))
    blocking = [i for i in items if i["blocks_turn_end"]]
    if not blocking:
        msg = "\n".join(notes)
        if items:
            msg = (msg + "\n" if msg else "") + "Pending finished work (waiting, recorded): " + \
                ", ".join("%s [%s: %s]" % (i["name"], i["waiting"], i["waiting_on"]) for i in items)
        return True, msg
    last = str(payload.get("last_assistant_message") or "")
    if last and _turn_started_by_person(str(payload.get("transcript_path") or "")) \
            and all(i["name"] in last for i in blocking):
        # THE ALLOWANCE IS CONSUMED. It used to be unlimited: ten consecutive
        # turns whose reply merely contained each item's name all ended, and
        # nothing anywhere made the work get handled afterwards. The page's own
        # parenthesis binds it, so it is spent per item and returns only when
        # that item's state has changed (_allowance_state).
        spent, state = [], {}
        for i in blocking:
            rec = load_agent(i["key"])
            if not rec:
                continue
            state[i["key"]] = _allowance_state(rec, i)
            prev = rec.get("answer_allowance") or {}
            if prev.get("state") == state[i["key"]]:
                spent.append((i, prev))
        if not spent:
            for i in blocking:
                if i["key"] not in state:
                    continue
                with Lock():
                    rec = load_agent(i["key"])
                    if not rec:
                        continue
                    rec["answer_allowance"] = {"at": now(), "state": state[i["key"]], "session": sid}
                    save_agent(rec)
                event("answer-allowance-used", key=i["key"])
            return True, "\n".join(notes)
        return False, _allowance_spent_message(spent) + "\n" + \
            gate_message(blocking, "end your turn") + ("\n" + "\n".join(notes) if notes else "")
    return False, gate_message(blocking, "end your turn") + ("\n" + "\n".join(notes) if notes else "")


# ---------------------------------------------------------------------------
# the lifecycle hook: facts, never a refusal
# ---------------------------------------------------------------------------

def _taskstop_id(resp, depth=0):
    if depth > 3:
        return ""
    if isinstance(resp, str):
        try:
            return _taskstop_id(json.loads(resp), depth + 1)
        except ValueError:
            return ""
    if isinstance(resp, list):
        for c in resp:
            v = _taskstop_id(c, depth + 1)
            if v:
                return v
        return ""
    if isinstance(resp, dict):
        if resp.get("is_error") or resp.get("error") or resp.get("success") is False:
            return ""
        tid = resp.get("task_id")
        if isinstance(tid, str) and AGENT_ID_RE.match(tid):
            return tid
        if resp.get("type") == "text" and isinstance(resp.get("text"), str):
            return _taskstop_id(resp["text"], depth + 1)
    return ""


def _agent_id_from_response(resp):
    if isinstance(resp, dict):
        v = str(resp.get("agentId") or "").strip()
        if AGENT_ID_RE.match(v):
            return v
    text = json.dumps(resp) if not isinstance(resp, str) else resp
    m = re.search(r"agentId:\s*([A-Za-z0-9_-]+)", text or "")
    return m.group(1) if m else ""


def lifecycle(payload, entity):
    """Records the facts the page names. Returns (context_text, notices)."""
    ev = str(payload.get("hook_event_name") or "")
    sid = str(payload.get("session_id") or "")
    notices = []
    ctx = ""
    if ev == "SessionStart":
        rec, foreign = session_start(sid, str(payload.get("cwd") or entity or ""),
                                     str(payload.get("source") or ""), str(payload.get("agent_id") or ""))
        if foreign:
            # A subagent's compaction: nothing about the lead changes, and the
            # lead's gate is no business of an agent that cannot land anything.
            return "", []
        if rec.get("forbidden"):
            notices.append(refused_session_text(rec["forbidden"]))
        if str(payload.get("source") or "") in LAUNCH_SOURCES:
            # A session that STARTS is the first moment after a killed run
            # that anything is listening: 2026-09-22's three simulators were
            # still booted when the next session began. Bounded, because this
            # runs inside the hook's timeout; what is not reached is collected
            # by the next land or sweep.
            collect_test_devices(budget=8.0)
        retry_due()
        items = pending(sid, entity, scan=True)
        if items:
            ctx = ("A SESSION THAT STARTS WITH FINISHED WORK LANDS OR DISCARDS IT FIRST (point 5).\n"
                   + gate_message(items, "start new work"))
    elif ev == "SessionEnd":
        record_session_end(sid, str(payload.get("reason") or "SessionEnd"))
        collect_test_devices(budget=8.0)
    elif ev == "SubagentStart":
        record_start(sid, str(payload.get("agent_id") or ""), str(payload.get("cwd") or ""),
                     str(payload.get("agent_type") or ""))
    elif ev == "SubagentStop":
        record_end(sid, str(payload.get("agent_id") or ""), "SubagentStop")
        collect_test_devices(budget=8.0)
    elif ev == "TaskCompleted":
        record_handed_in(sid, str(payload.get("agent_id") or payload.get("agentId") or ""),
                         str(payload.get("teammate_name") or payload.get("teammateName") or ""))
    elif ev == "PostToolUse":
        tool = str(payload.get("tool_name") or "")
        ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
        if tool == "Agent":
            aid = _agent_id_from_response(payload.get("tool_response"))
            if aid:
                # The name and isolation of the call the platform actually ran:
                # the repair path in bind_agent needs them when no registration
                # carries this tool call (its PreToolUse was killed).
                bind_agent(sid, str(payload.get("tool_use_id") or ""), aid, entity,
                           name=str(ti.get("name") or ""), isolation=str(ti.get("isolation") or ""))
        elif tool == "TaskStop":
            aid = _taskstop_id(payload.get("tool_response"))
            if aid:
                record_end(sid, aid, "stopped", "TaskStop")
                collect_test_devices(budget=8.0)
        elif tool == "SendMessage":
            to = str(ti.get("to") or "")
            msg = ti.get("message")
            text = msg if isinstance(msg, str) else ""
            if to and NAME_RE.match(to):
                rec = load_agent(named_key(sid, to))
                if rec:
                    until = prompt_lines(text, "pause-until")
                    if prompt_lines(text, "pause-until") or re.search(r"(?m)^\s*pause-until:\s*$", text):
                        try:
                            pause(rec["key"], until[0] if until else "", sid)
                        except SpecError as e:
                            notices.append(str(e))
                    else:
                        st = finished_state(rec)
                        if st[1]:
                            resume(rec["key"], sid)
        elif tool == "Bash":
            cmd = str(ti.get("command") or "")
            if re.search(r"\bgit\b.*\b(merge|pull|rebase|cherry-pick)\b", cmd):
                retry_due()
                pending(sid, entity, scan=False)
    if ev in ("SubagentStop", "SubagentStart", "TaskCompleted"):
        retry_due(budget=2.0)
    return ctx, notices


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def current_session():
    """The session a CLI call runs in: the recorded session whose process is
    this command's ancestor (point 12's record, read against the OS)."""
    v = (os.environ.get("RICHOS_SESSION_ID") or "").strip()
    if v:
        return v
    pid = session_pid()
    if not pid:
        return ""
    st, text = process_start(pid)
    try:
        names = os.listdir(_p("sessions"))
    except OSError:
        names = []
    for n in names:
        r = read_json(_p("sessions", n))
        if r and r.get("pid") == pid and r.get("pid_start") == text:
            return r.get("session_id") or ""
    rec = read_json(os.path.join(_platform_sessions_dir(), "%d.json" % pid))
    return str((rec or {}).get("sessionId") or "")


def _print_status(me, entity):
    items = pending(me, entity, scan=True)
    print("session: %s" % (me or "(none)"))
    for repo in sorted(all_integration_records()):
        r = all_integration_records()[repo]
        print("integrates on: %s  %s  (%s)" % (r.get("branch"), repo, r.get("source")))
    if not items:
        print("pending: none")
    for i in items:
        print("PENDING  %s  %s%s%s" % (i["name"], i["why"],
                                       ("  [waiting %s: %s]" % (i["waiting"], i["waiting_on"])) if i["waiting"] else "",
                                       "  [land under way: does not block new work, §77]"
                                       if i.get("land_under_way") else ""))
        for p, b in i["workspaces"]:
            print("           %s  %s" % (p, b or ""))
    for r in all_agents():
        if r.get("disposition") or any(i["key"] == r["key"] for i in items):
            if r.get("deletion"):
                d = r["deletion"]
                print("RETRYING %s  deletion attempt %d failed: %s" % (r.get("name"), d.get("attempts"),
                                                                     d.get("last_error")))
            continue
        fin, paused_, why = finished_state(r)
        print("%-8s %s  %s" % ("PAUSED" if paused_ else ("FINISHED" if fin else "WORKING"), r.get("name"), why))
    return 0


def sweep_scratch_after_land():
    """Reclaim the landed agent's scratch, right here, while somebody is looking.

    A LAND IS THE MOMENT THE GARBAGE BECOMES GARBAGE. The agent has finished, its
    workspace is gone, and every temporary directory its harnesses made is now
    owned by nothing. Waiting up to six hours for the scheduled sweep means the
    next agent starts on a disk carrying the last one's leavings — and on
    2026-09-17 one agent's leavings were 105.3 GB.

    NEVER FATAL, AND NEVER NOISY ON SUCCESS. The land has already happened and
    printed its result by the time this runs; a sweeper that raised here would
    turn a completed land into a traceback and leave the operator unsure whether
    the land took. So every failure is one line on stderr and nothing else, and a
    sweep that reclaims nothing says nothing at all.

    It calls scripts/scratch-sweep.sh — the app-facing entry point, whose whole
    contract is "safe to call constantly, safe to call concurrently, one line of
    JSON" — rather than the reaper directly. That gets the flock for free, so a
    land that overlaps the launchd job or an app-triggered sweep collapses into
    one instead of two runs measuring a tree the other is deleting.
    """
    sweep = os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "scripts", "scratch-sweep.sh")
    if not os.access(sweep, os.X_OK):
        return
    try:
        r = subprocess.run(["bash", sweep], capture_output=True, text=True,
                           timeout=600)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print("scratch sweep after land could not run: %s" % exc, file=sys.stderr)
        return
    line = (r.stdout or "").strip().splitlines()
    if not line:
        return
    try:
        rep = json.loads(line[-1])
    except ValueError:
        return
    # SPEAK ONLY WHEN THERE IS SOMETHING TO SAY. A land already prints a lot, and
    # a line about zero bytes on every land is the kind of noise that gets the
    # informative lines skipped too.
    if rep.get("failures"):
        print("SCRATCH SWEEP: %d deletion(s) FAILED after this land — %s"
              % (rep["failures"], rep.get("reason") or ""), file=sys.stderr)
        print("  The CEO's rule (ceo-decisions §54): if the clean-up fails, it is"
              " deleted BY HAND. scripts/disk-watchdog.sh --status names the paths.",
              file=sys.stderr)
    elif rep.get("freed_bytes"):
        print("scratch swept: %s reclaimed (%s entr%s)"
              % (rep.get("freed_human") or rep["freed_bytes"],
                 rep.get("swept") or 0,
                 "y" if rep.get("swept") == 1 else "ies"))


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="workspaces.sh", description="the CEO's workspace spec (%s)" % SPEC)
    ap.add_argument("--session", default="")
    ap.add_argument("--entity", default="")
    sub = ap.add_subparsers(dest="cmd")
    sub.add_parser("status")
    x = sub.add_parser("land")
    x.add_argument("agent")
    x.add_argument("--ignored-not-needed", default="")
    x = sub.add_parser("discard")
    x.add_argument("agent")
    x.add_argument("--reason", required=True)
    x.add_argument("--ceo-word", default="")
    x.add_argument("--not-ceo-ordered", default="")
    x = sub.add_parser("pause")
    x.add_argument("agent")
    x.add_argument("--until", required=True)
    x = sub.add_parser("resume")
    x.add_argument("agent")
    x = sub.add_parser("stop")
    x.add_argument("agent")
    x.add_argument("--why", default="its work is no longer wanted")
    x = sub.add_parser("wait")
    x.add_argument("agent")
    g = x.add_mutually_exclusive_group(required=True)
    g.add_argument("--started")
    g.add_argument("--outside")
    g.add_argument("--ceo")
    x.add_argument("--todo", default="")
    sub.add_parser("retry")
    x = sub.add_parser("integration-branch")
    x.add_argument("--repo", default="")
    x = sub.add_parser("integration")
    x.add_argument("--repo", default="")
    x.add_argument("--branch", default="")
    x.add_argument("--why", default="")
    x.add_argument("--correct", action="store_true",
                   help="change the branch of the body of work that is CURRENT, keeping its "
                        "id, so every agent already bound to it moves with it. Without this, "
                        "a recording STARTS a new body of work and reaches no running agent.")
    x.add_argument("--all", action="store_true",
                   help="list every body of work, superseded ones included — a superseded "
                        "one is what an agent spawned for it still lands against")
    x = sub.add_parser("register-cc")
    for f in ("--name", "--repo", "--path", "--branch"):
        x.add_argument(f, required=True)
    x = sub.add_parser("confirm-cc")
    x.add_argument("--name", required=True)
    x.add_argument("--path", required=True)
    x.add_argument("--failed", default="")
    x = sub.add_parser("withdraw-cc",
                       help="withdraw a registration whose spawn NEVER HAPPENED: delete its cc/ "
                            "workspaces and branches and remove the record, so the name is free "
                            "again. Refuses anything that ran (point 3's other half).")
    x.add_argument("--name", required=True)
    x.add_argument("--why", default="")
    for n in ("hook", "gate-stop", "register-spawn", "register-readonly", "barrier",
              "observe-refs", "check-spawn"):
        sub.add_parser(n)
    x = sub.add_parser("recipient")
    x.add_argument("--name", required=True)
    a = ap.parse_args(argv)
    if not a.cmd:
        ap.print_help()
        return 2
    entity = a.entity or os.environ.get("RICHOS_ENTITY_ROOT_RESOLVED", "")
    try:
        if a.cmd in ("hook", "gate-stop", "register-spawn", "register-readonly", "barrier",
                     "observe-refs", "check-spawn"):
            raw = sys.stdin.read()
            try:
                payload = json.loads(raw)
            except ValueError:
                payload = None
            if not isinstance(payload, dict):
                if a.cmd == "barrier":
                    print("ERROR\tthe payload is unparseable")
                    return 0
                if a.cmd == "observe-refs":
                    return 0
                if a.cmd in ("register-spawn", "register-readonly", "check-spawn"):
                    sys.stderr.write("the spawn payload is unparseable; it cannot be registered\n")
                    return 2
                return 0
            if not entity and payload.get("cwd"):
                entity = main_checkout(str(payload["cwd"]))
            if a.cmd == "observe-refs":
                for repo, b in observe(payload):
                    print("CREATED\t%s\t%s" % (repo, b))
                for r in PROTECTED_REF_FINDINGS:
                    print("%s\t%s\t%s\t%s\t%s\t%s" % r)
                return 0
            if a.cmd == "barrier":
                k, d = barrier(payload)
                print("%s\t%s" % (k, d.replace("\t", " ").replace("\n", " ")))
                return 0
            if a.cmd == "register-spawn":
                rec = register_spawn(payload, entity)
                print("REGISTERED\t%s" % rec["key"])
                return 0
            if a.cmd == "check-spawn":
                # THE DRY EVALUATION. Same refusals, nothing written. It refuses
                # a payload that is NOT a dry one rather than evaluating it,
                # because a caller that reached here with a live tool_use_id
                # wanted `register-spawn` and would otherwise be told its spawn
                # was fine while no registration was written for it.
                if not is_spawn_check(payload):
                    sys.stderr.write("check-spawn evaluates a spawn that has not been made: the payload "
                                     "must carry richos_spawn_check and no tool_use_id. This one carries "
                                     "a tool_use_id, so it is a live call - use register-spawn.\n")
                    return 2
                register_spawn(payload, entity, dry=True)
                print("WOULD-REGISTER\t%s"
                      % named_key(str(payload.get("session_id") or ""),
                                  str((payload.get("tool_input") or {}).get("name") or "")))
                return 0
            if a.cmd == "register-readonly":
                rec = register_readonly(payload, entity)
                print("REGISTERED\t%s" % rec["key"])
                return 0
            if a.cmd == "gate-stop":
                ok, msg = gate_stop(payload, entity)
                if not ok:
                    sys.stderr.write(msg + "\n")
                    return 2
                if msg:
                    print(json.dumps({"systemMessage": msg}))
                return 0
            ctx, notices = lifecycle(payload, entity)
            out = {}
            if ctx and payload.get("hook_event_name") == "SessionStart":
                out["hookSpecificOutput"] = {"hookEventName": "SessionStart", "additionalContext": ctx}
            if notices:
                out["systemMessage"] = "\n".join(notices)
            if out:
                print(json.dumps(out))
            return 0
        me = a.session or current_session()
        if a.cmd == "status":
            return _print_status(me, entity)
        if a.cmd == "land":
            # Taken BEFORE the land: the record is read for the agent's type and
            # its transcript, and a land that ends in a deletion retry must not
            # cost the count. The transcript itself lives in the platform's
            # projects directory and no workspace deletion touches it.
            qa_lines = qa_throwaway_lines(a.agent, me)
            land(a.agent, me, ignored_ok=a.ignored_not_needed)
            print("landed: %s — every workspace and branch deleted (or retrying)" % a.agent)
            for _l in qa_lines:
                print(_l)
            sweep_scratch_after_land()
        elif a.cmd == "discard":
            r = discard(a.agent, a.reason, a.ceo_word, a.not_ceo_ordered, me)
            print("discarded: %s — tips recorded: %s" % (a.agent, json.dumps(r["tips"])))
        elif a.cmd == "pause":
            pause(a.agent, a.until, me)
            print("paused: %s until %s" % (a.agent, a.until))
        elif a.cmd == "resume":
            resume(a.agent, me)
            print("resumed: %s" % a.agent)
        elif a.cmd == "stop":
            stop(a.agent, a.why, me)
            print("stopped: %s (finished)" % a.agent)
        elif a.cmd == "wait":
            kind, on = ("started", a.started) if a.started else (("outside", a.outside) if a.outside else ("ceo-discard", a.ceo))
            wait(a.agent, kind, on, a.todo, me)
            print("recorded: %s waits (%s) on %s" % (a.agent, kind, on))
        elif a.cmd == "integration-branch":
            # THE ONE ANSWER, FOR A SHELL CONSUMER. "Every part of the system
            # that needs to know whether work has landed asks the same
            # question... None of them is allowed its own answer, and none of
            # them assumes main" (point 14). Exit 0 and the branch on stdout, or
            # exit 3 and the reason on stderr -- 3 means ABSTAIN, not failure:
            # the caller must not fall back to main, it must say it cannot
            # answer and name the command below.
            branch, tip, why_not = integration_for(a.repo or entity)
            if why_not:
                print(why_not, file=sys.stderr)
                return 3
            print("%s\t%s" % (branch, tip))
        elif a.cmd == "integration":
            if a.branch:
                r = record_integration(a.repo or entity, a.branch, a.why, me, a.correct)
                print("%s: %s integrates on %s (body of work %s)"
                      % ("corrected" if a.correct else "recorded", r["repo"], r["branch"], r["id"]))
            elif a.all:
                works = all_bodies_of_work()
                cur = set((_integration_file().get("current") or {}).values())
                if not works:
                    print("no body of work has an integration branch recorded (point 14)")
                for wid in sorted(works):
                    w = works[wid]
                    print("%s\t%s\t%s\t%s\t%s\t%s"
                          % (wid, "current" if wid in cur else "superseded", w.get("repo"),
                             w.get("branch"), w.get("recorded_at"), w.get("why") or ""))
                    for c in w.get("corrections") or []:
                        print("\t  corrected from %s at %s: %s"
                              % (c.get("from"), c.get("at"), c.get("why") or ""))
            else:
                recs = all_integration_records()
                if a.repo:
                    one = integration_record(a.repo)
                    recs = {one["repo"]: one} if one else {}
                if not recs:
                    print("no integration branch is recorded (point 14)")
                for repo in sorted(recs):
                    r = recs[repo]
                    print("%s\t%s\t%s\t%s\t%s" % (repo, r.get("branch"), r.get("source"),
                                                    r.get("recorded_at"), r.get("id") or ""))
        elif a.cmd == "retry":
            for k, ok in retry_due(budget=60.0):
                print("%s %s" % ("deleted" if ok else "still failing", k))
        elif a.cmd == "register-cc":
            register_cc(me, a.name, a.repo, a.path, a.branch)
            print("registered")
        elif a.cmd == "withdraw-cc":
            r = withdraw_cc(me, a.name, a.why)
            print("withdrawn: %s - %s" % (a.name, ", ".join(r["withdrawn"]) or "nothing was created"))
        elif a.cmd == "confirm-cc":
            confirm_cc(me, a.name, a.path, not a.failed, a.failed)
            print("confirmed" if not a.failed else "recorded failure")
        elif a.cmd == "recipient":
            st, why = recipient_state(me, a.name)
            print("%s\t%s" % (st, why))
        return 0
    except SpecError as e:
        sys.stderr.write("workspaces: REFUSED — %s\n" % e)
        # The Stop gate's exit 2 means "block the turn"; a refusal inside it
        # is an evaluation failure, which the gate reports and never blocks on.
        return 4 if a.cmd == "gate-stop" else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
