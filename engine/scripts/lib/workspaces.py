#!/usr/bin/env python3
"""workspaces.py — THE CEO'S WORKSPACE SPEC, AND NOTHING ELSE.

The only reference is docs/plans/worktree-spec-2026-09-11.md (thirteen
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
    handed in      TaskCompleted                            (point 11, hole 7)
    pause/resume   a SendMessage carrying `pause-until: <what ends it>`, a later
                   message to a paused agent, or `workspaces.sh pause|resume`
    session end    SessionEnd, or the operating system saying the recorded
                   process is gone or is a different process  (point 12)
"""

import errno
import fcntl
import hashlib
import json
import os
import re
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


def record_session_start(session_id, cwd):
    if not session_id:
        raise SpecError("no session id in the payload")
    ident = identity_for(session_id)
    rec = load_session(session_id) or {}
    rec.update({"session_id": session_id, "cwd": realpath(cwd), "started_at": rec.get("started_at") or iso(),
                "repo": main_checkout(cwd) if cwd else ""})
    if ident:
        rec.update(ident)
    rec.pop("ended_at", None)
    rec.pop("end_reason", None)
    forbidden = worktree_session_reason(cwd, ident["pid"] if ident else None)
    if forbidden:
        rec["forbidden"] = forbidden
    with Lock():
        write_json(session_path(session_id), rec)
        if rec.get("repo"):
            _remember_repo(rec["repo"])
    event("session-start", session_id=session_id, pid=rec.get("pid"), pid_start=rec.get("pid_start"),
          forbidden=forbidden or None)
    return rec


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
# An agent registered before anything was recorded is bound to nothing, and
# falls back to its repository's current body of work — which is what makes the
# refusal HEAL (point 14's "the land then succeeds"). Nothing is inferred by
# that: the fallback reads a RECORDED branch, it just does not know which work
# the agent belongs to.

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
        return                       # nothing recorded yet: bound to nothing, heals later
    rec.setdefault("integration_work", {})
    rec["integration_work"].setdefault(main, wid)


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
    key = named_key(session_id, name)
    with Lock():
        rec = load_agent(key) or new_record(key, name=name, session_id=session_id)
        if rec.get("agent_id") or rec.get("disposition"):
            raise SpecError("agent %s already has a spawned registration in this session; names are "
                            "used once" % name)
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


def register_spawn(payload, entity):
    """PreToolUse[Agent], point 3: the registration a spawn needs. Raises
    SpecError -> the spawn does not happen. Returns the record."""
    sid = str(payload.get("session_id") or "")
    tuid = str(payload.get("tool_use_id") or "")
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    name = str(ti.get("name") or "")
    prompt = str(ti.get("prompt") or "")
    isolation = str(ti.get("isolation") or "")
    if not sid or not tuid:
        raise SpecError("the spawn payload carries no session_id/tool_use_id, so it cannot be registered")
    if not NAME_RE.match(name):
        raise SpecError("the spawn has no usable name, so it cannot be registered")
    cc_paths = [realpath(p.split()[0]) for p in prompt_lines(prompt, "cross-repo-worktree") if p.split()]
    if ti.get("cwd"):
        cc_paths.append(realpath(str(ti.get("cwd"))))
    continues = [p.split()[0] for p in prompt_lines(prompt, "continues") if p.split()]
    lands_pending = [p.split()[0] for p in prompt_lines(prompt, "lands-pending") if p.split()]
    ceo_ordered = prompt_lines(prompt, "ceo-ordered")

    # Point 5: new work is blocked while finished work is pending — except work
    # whose only purpose is getting that work landed (continues:/lands-pending:).
    report = {}
    items = pending(sid, entity, deadline=_gate_deadline(GATE_SPAWN_BUDGET), report=report)
    blocking = [i for i in items if i["blocks_new_work"]]
    helps = set(continues + lands_pending)
    if blocking and not (helps & set(i["name"] for i in blocking)):
        extra = ""
        if report.get("deferred"):
            extra = ("\n  (The gate answered inside its budget rather than overrunning this hook's "
                     "timeout: %s could not be checked for an automatic land, so it stays pending. "
                     "Land it by hand — `workspaces.sh land <name>` has no budget.)"
                     % ", ".join(sorted(set(report["deferred"]))))
        raise SpecError(gate_message(blocking, "start new work", spawn=True) + extra)
    for c in continues:
        match = [i for i in items if i["name"] == c]
        if not match:
            raise SpecError("continues: %s — there is no pending finished agent of that name to continue "
                            "(point 7)" % c)
        _require_clean(load_agent(match[0]["key"]), "continue it (its workspaces are deleted when the new "
                       "agent starts, point 7)")

    ident = identity_for(sid)
    if not ident:
        raise SpecError("the session's process identity could not be read from the operating system; "
                        "a registration that could never tell its session ended is refused (point 12)")
    key = named_key(sid, name)
    with Lock():
        rec = load_agent(key)
        if cc_paths:
            if not rec:
                raise SpecError("no registration exists for %s in this session. A cc/ workspace is "
                                "registered when it is created: use create-teammate-worktree.sh <repo> %s "
                                "(points 1, 3)." % (name, name))
        rec = rec or new_record(key, name=name, session_id=sid)
        if rec.get("agent_id") or rec.get("disposition"):
            raise SpecError("agent %s already ran in this session; names are used once" % name)
        known = dict((w.get("path"), w) for w in live_workspaces(rec) if w.get("kind") == "cc")
        for p in cc_paths:
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
        rec.update({"tool_use_id": tuid, "subagent_type": str(ti.get("subagent_type") or ""),
                    "isolation": isolation, "session_identity": ident,
                    "ceo_ordered": (ceo_ordered[0] if ceo_ordered else rec.get("ceo_ordered")),
                    "continues": [named_key(sid, c) if not _is_key(c) else c for c in continues],
                    "lands_pending": lands_pending, "entity": realpath(entity),
                    "spawned_at": iso()})
        rec.pop("creation_failed", None)
        save_agent(rec)
        if entity:
            _remember_repo(entity)
    event("registered-spawn", key=key, tool_use_id=tuid, cc=cc_paths, isolation=isolation,
          continues=continues, lands_pending=lands_pending)
    return rec


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


def bind_agent(session_id, tuid, agent_id, entity):
    """PostToolUse[Agent]: the platform's agent id joins the registration, and
    the native workspace it created is registered (point 6)."""
    if not AGENT_ID_RE.match(agent_id or ""):
        raise SpecError("not an agent id: %r" % agent_id)
    with Lock():
        rec = _find_by_tool_use(session_id, tuid)
        if not rec:
            return None
        prov_key = "%s--agent-%s" % (_key_segment(session_id), _key_segment(agent_id))
        prov = read_json(agent_path(prov_key))
        rec["agent_id"] = agent_id
        if rec.get("isolation") == "worktree" and entity:
            main = main_checkout(entity) or realpath(entity)
            npath = os.path.join(main, ".claude", "worktrees", "agent-" + agent_id)
            _add_workspace(rec, "native", main, npath, NATIVE_BRANCH_PREFIX + agent_id, "PostToolUse[Agent]")
            _drop_orphans_for(realpath(npath))
        if prov:
            for w in live_workspaces(prov):
                _add_workspace(rec, w["kind"], w["repo"], w["path"], w["branch"], w.get("source", ""))
            for f in ("started_at", "end", "handed_in"):
                if prov.get(f) and not rec.get(f):
                    rec[f] = prov[f]
            os.unlink(agent_path(prov_key))
        save_agent(rec)
    event("bound", key=rec["key"], agent_id=agent_id)
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
    pending item this session may handle)."""
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


def _item(rec, why, cache, me):
    waiting = rec.get("waiting") or {}
    helpers = [a for a in all_agents() if rec["name"] in (a.get("lands_pending") or [])
               or rec["key"] in (a.get("continues") or [])]
    started = [a for a in helpers if not finished_state(a, cache)[0]]
    kind = waiting.get("kind", "")
    if not kind and started:
        kind, waiting = "started", {"on": "agent %s is working to land it" % started[0].get("name")}
    return {"key": rec["key"], "name": rec.get("name") or rec["key"], "why": why,
            "waiting": kind, "waiting_on": waiting.get("on", ""),
            "blocks_new_work": kind != "ceo-discard",
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
            if other and os.path.isdir(mine) and os.path.isdir(other):
                continue
            if other and os.path.isfile(mine) and os.path.isfile(other) and _same_file(mine, other):
                continue
            ignored.append(rel)
        else:
            dirty.append(ent)
    return dirty, ignored


def _same_file(a, b):
    try:
        if os.path.getsize(a) != os.path.getsize(b):
            return False
        with open(a, "rb") as fa, open(b, "rb") as fb:
            return hashlib.sha1(fa.read()).digest() == hashlib.sha1(fb.read()).digest()
    except OSError:
        return False


def _require_clean(rec, doing, ignored_ok="", deadline=None):
    problems = []
    for w in live_workspaces(rec):
        if w.get("path") and os.path.isdir(w["path"]):
            dirty, ignored = uncommitted(w["path"], deadline)
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
        for repo in _repos_of(rec):
            refs = _local_refs(repo)
            if refs is None:
                continue                 # unreadable: no snapshot, so no candidates
            snap[repo] = sorted(refs)
        row = {"key": rec["key"], "call": call or "", "at": now(), "repos": snap}
        write_json(_slot_path(rec["key"], call), row)
        # The same fact, kept where consuming a window cannot remove it. It is
        # what stops a window leaked by a refused call from widening the
        # end-of-run comparison to the whole run (see `_before_set`).
        write_json(_latest_path(rec["key"]), row)
        _evict_old_slots(rec["key"])
        return snap
    except (OSError, ValueError):
        return {}


def _take_snapshots(key, call="", all_open=False):
    """CONSUME this call's window — or, at the end of the run, every open one —
    and return what was in it. Consumed whatever the outcome: one creation is
    attributed once, and a Post whose own Pre never ran attributes nothing."""
    if all_open:
        paths = _open_slots(key)
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
        paths = [p] if os.path.exists(p) else _open_slots(key)[:1]
    else:
        paths = [p for p in _open_slots(key) if os.path.basename(p).startswith("u.")][:1] \
            or _open_slots(key)[:1]
    priors = []
    for p in paths:
        prior = read_json(p)
        try:
            os.unlink(p)
        except OSError:
            pass
        if prior and isinstance(prior.get("repos"), dict):
            priors.append(prior)
    return priors


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


def observe_created_refs(rec, call="", all_open=False):
    """THE SECOND HALF OF THE PAIR (point 3): the refs this agent created during
    the tool call that is now ending, recorded against it. Returns what it added.

    `call` names WHICH of the agent's open windows this is the far end of, so
    two of its own calls open at once no longer clobber each other. `all_open`
    is the end of the run: every window still open is the last observation.

    The window is CONSUMED here, whatever the outcome: one creation is
    attributed once.

    IT DOES NOT NEED AN INTEGRATION BRANCH TO BE RECORDED. The record is a
    filter on what is at stake, never a gate on whether the observation happens
    at all — attribution is made once and never again, so a missing record used
    to mean "attributed to nobody, permanently"."""
    # READ BEFORE CONSUMING. The last snapshot has to be in hand before the
    # windows are thrown away, or the end-of-run pass is judged against the
    # leaked window alone -- which is the widening this whole change ends.
    latest = read_json(_latest_path(rec["key"]))
    priors = _take_snapshots(rec["key"], call, all_open)
    if all_open:
        _drop_snapshots(rec["key"])
    if not priors:
        return []
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
    return observe_created_refs(rec, str(payload.get("tool_use_id") or ""))


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

    A chain bound to nothing (registered before anything was recorded) falls
    back to the repository's current body of work. That is what makes the
    refusal HEAL — Rich records the branch and the same land then succeeds —
    and it infers nothing: the branch it reads is a recorded one."""
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
        return {"landed": True, "already": rec["disposition"]["kind"]}
    chain = _chain(rec)
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
    for r in chain:
        with Lock():
            fresh = load_agent(r["key"])
            fresh["disposition"] = {"kind": "landed", "at": now(), "auto": bool(auto), "by_session": me,
                                    "ignored_not_needed": ignored_ok or None, "as_part_of": rec["key"]}
            save_agent(fresh)
        event("landed", key=r["key"], auto=bool(auto), as_part_of=rec["key"])
    _delete_chain(chain, "landed")
    return {"landed": True}


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


def _delete_chain(chain, why):
    allw = [(r, w) for r in chain for w in live_workspaces(r) if w.get("path")]
    stopped = stop_processes([w["path"] for _r, w in allw])
    for r in chain:
        _delete(r, [w for w in live_workspaces(r) if w.get("path")], branches=True, why=why,
                processes=stopped)


def _delete(rec, workspaces, branches, why, processes=None):
    """Points 9, 10, 13: stop every process, then delete every workspace (and
    branch) as one; whatever fails is retried automatically."""
    if processes is None:
        processes = stop_processes([w["path"] for w in workspaces])
    failures = []
    if processes.get("survivors"):
        failures.append("processes still running in its workspaces: %s" % processes["survivors"])
    else:
        for w in workspaces:
            # Point 3: the branches the agent created are its branches too, and
            # they are recorded (observe_created_refs) rather than read back out of
            # the directory here — the record survives the directory.
            ok, err = remove_workspace(w)
            if ok:
                w["deleted_at"] = iso()
            else:
                failures.append(err)
    if branches:
        for repo, b in _branch_targets([rec]):
            ok, err = delete_branch(repo, b)
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
    if b.startswith(CODEX_PREFIX):
        return False, "branch %s is codex/; never touched (point 2)" % b
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

def barrier(payload):
    """Verdict for guard-sealed-worktree.sh: (kind, detail).
    FINISHED        a finished agent: refused every tool (point 9)
    FORBIDDEN       the lead of a claude --worktree session (point 3)
    REGISTERED      a registered, unfinished worker (paused included)
    UNREGISTERED    a worker with no registration (point 3)
    LEAD            the lead's own call"""
    sid = str(payload.get("session_id") or "")
    aid = str(payload.get("agent_id") or "")
    if not aid:
        s = load_session(sid) if sid else None
        if s and s.get("forbidden"):
            return "FORBIDDEN", s["forbidden"]
        return "LEAD", ""
    key = key_for_id(aid)
    rec = load_agent(key) if key else None
    if not rec:
        return "UNREGISTERED", "agent %s has no registration" % aid
    fin, _paused, why = finished_state(rec)
    if fin:
        return "FINISHED", "agent %s (%s) is finished: %s" % (aid, rec.get("name"), why)
    # This call carries the agent's id, so it is a moment the platform vouches
    # for. Record what its repositories hold NOW; the catch-all PostToolUse
    # compares, and a ref that appeared in between was created by this agent
    # (point 3, "any branch an agent created"). It runs only for an UNFINISHED
    # agent: a ref Rich cuts after the run has ended, to rescue the work, is his
    # and is never a candidate at all.
    snapshot_refs(rec, str(payload.get("tool_use_id") or ""))
    return "REGISTERED", rec.get("name") or ""


def recipient_state(session_id, name):
    rec = load_agent(named_key(session_id, name)) if session_id and name else None
    if not rec:
        return "unregistered", ""
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
        if not isinstance(d, dict) or d.get("type") != "user" or d.get("isMeta"):
            continue
        msg = d.get("message") or {}
        content = msg.get("content")
        texts = []
        if isinstance(content, str):
            texts = [content]
        elif isinstance(content, list):
            if any(isinstance(c, dict) and c.get("type") == "tool_result" for c in content):
                continue
            texts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text"]
        text = "\n".join(texts).strip()
        if not text:
            continue
        if re.match(r"^<(task-notification|teammate-message|system-reminder|local-command|command-name)", text) \
                or "<task-notification>" in text:
            return False
        return True
    return False


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


def gate_stop(payload, entity):
    """(allowed, message). Point 5: Rich cannot end his turn while finished
    work is neither landed nor discarded, except as the page allows."""
    sid = str(payload.get("session_id") or "")
    if not sid:
        return True, ""
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
        rec = record_session_start(sid, str(payload.get("cwd") or entity or ""))
        if rec.get("forbidden"):
            notices.append("THIS SESSION IS NOT ALLOWED: %s. Nobody starts a session in its own workspace in "
                           "RichOS (point 3). Every tool but reading is refused." % rec["forbidden"])
        retry_due()
        items = pending(sid, entity, scan=True)
        if items:
            ctx = ("A SESSION THAT STARTS WITH FINISHED WORK LANDS OR DISCARDS IT FIRST (point 5).\n"
                   + gate_message(items, "start new work"))
    elif ev == "SessionEnd":
        record_session_end(sid, str(payload.get("reason") or "SessionEnd"))
    elif ev == "SubagentStart":
        record_start(sid, str(payload.get("agent_id") or ""), str(payload.get("cwd") or ""),
                     str(payload.get("agent_type") or ""))
    elif ev == "SubagentStop":
        record_end(sid, str(payload.get("agent_id") or ""), "SubagentStop")
    elif ev == "TaskCompleted":
        record_handed_in(sid, str(payload.get("agent_id") or payload.get("agentId") or ""),
                         str(payload.get("teammate_name") or payload.get("teammateName") or ""))
    elif ev == "PostToolUse":
        tool = str(payload.get("tool_name") or "")
        ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
        if tool == "Agent":
            aid = _agent_id_from_response(payload.get("tool_response"))
            if aid:
                bind_agent(sid, str(payload.get("tool_use_id") or ""), aid, entity)
        elif tool == "TaskStop":
            aid = _taskstop_id(payload.get("tool_response"))
            if aid:
                record_end(sid, aid, "stopped", "TaskStop")
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
        print("PENDING  %s  %s%s" % (i["name"], i["why"],
                                     ("  [waiting %s: %s]" % (i["waiting"], i["waiting_on"])) if i["waiting"] else ""))
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
    for n in ("hook", "gate-stop", "register-spawn", "register-readonly", "barrier",
              "observe-refs"):
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
                     "observe-refs"):
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
                if a.cmd in ("register-spawn", "register-readonly"):
                    sys.stderr.write("the spawn payload is unparseable; it cannot be registered\n")
                    return 2
                return 0
            if not entity and payload.get("cwd"):
                entity = main_checkout(str(payload["cwd"]))
            if a.cmd == "observe-refs":
                for repo, b in observe(payload):
                    print("CREATED\t%s\t%s" % (repo, b))
                return 0
            if a.cmd == "barrier":
                k, d = barrier(payload)
                print("%s\t%s" % (k, d.replace("\t", " ").replace("\n", " ")))
                return 0
            if a.cmd == "register-spawn":
                rec = register_spawn(payload, entity)
                print("REGISTERED\t%s" % rec["key"])
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
            land(a.agent, me, ignored_ok=a.ignored_not_needed)
            print("landed: %s — every workspace and branch deleted (or retrying)" % a.agent)
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
