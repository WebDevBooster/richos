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
      done/<key>.json              an agent whose deletion completed
      ids/<agent_id>               platform agent id -> key
      repos.json                   every repository a record has named
      events.jsonl                 append-only history of every fact
      lock                         one flock for every mutation

WHAT IS RECORDED, AND BY WHOM (never inferred):
    registration   create-teammate-worktree.sh (cc/), PreToolUse[Agent],
                   PostToolUse[Agent] and SubagentStart (native)
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


class SpecError(Exception):
    """A refusal the page requires. The message is shown to the operator."""


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
    for sub in ("sessions", "agents", "done", "ids"):
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
    except (OSError, subprocess.TimeoutExpired) as e:
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
        if rec and (not session_id or str(rec.get("sessionId") or "") == session_id):
            return pid
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
           "continues": [], "lands_pending": [], "history": []}
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
    return w


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
    items = pending(sid, entity)
    blocking = [i for i in items if i["blocks_new_work"]]
    helps = set(continues + lands_pending)
    if blocking and not (helps & set(i["name"] for i in blocking)):
        raise SpecError(gate_message(blocking, "start new work", spawn=True))
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


def pending(me, entity="", scan=False, auto=True):
    """The finished work this session must land or discard (point 5), after
    landing automatically everything that already is landed (point 4)."""
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
        if auto:
            try:
                res = land(rec["key"], me, auto=True)
                if res.get("landed"):
                    continue
            except SpecError:
                pass
        items.append(_item(rec, why, cache, me))
    return items


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
              "       once every branch is in main and nothing is uncommitted)",
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

def uncommitted(path):
    """([uncommitted entries], [ignored entries the main checkout does not have])."""
    rc, out, err = git(path, "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignored")
    if rc != 0:
        raise SpecError("git status failed in %s: %s" % (path, err.strip()[:200]))
    dirty, ignored = [], []
    main = main_checkout(path)
    for ent in [e for e in out.split("\0") if e]:
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


def _require_clean(rec, doing, ignored_ok=""):
    problems = []
    for w in live_workspaces(rec):
        if w.get("path") and os.path.isdir(w["path"]):
            dirty, ignored = uncommitted(w["path"])
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
# branches an agent has (point 3: "any branch an agent created")
# ---------------------------------------------------------------------------

def _created_branches(w):
    """Branches CREATED in this workspace, read from git: a `checkout: moving
    from A to B` in the workspace's own HEAD reflog, at the second B's own
    reflog says it was created. Never guessed from a name."""
    if not w.get("path") or not os.path.isdir(w["path"]):
        return []
    rc, out, _ = git(w["path"], "reflog", "show", "--format=%gs\t%ct", "HEAD")
    if rc != 0:
        return []
    moved = {}
    for line in out.splitlines():
        m = re.match(r"^checkout: moving from .+ to (.+)\t(\d+)$", line)
        if m:
            moved.setdefault(m.group(1), []).append(int(m.group(2)))
    out_b = []
    main_branch = ""
    repo = w.get("repo") or main_checkout(w["path"])
    wl = worktree_list(repo) or []
    if wl:
        main_branch = wl[0]["branch"]
    for b, stamps in moved.items():
        if b in (w.get("branch"), main_branch) or b.startswith(CODEX_PREFIX):
            continue
        rc, o2, _ = git(repo, "reflog", "show", "--format=%gs\t%ct", "refs/heads/" + b)
        if rc != 0 or not o2.strip():
            continue
        first = o2.strip().splitlines()[-1]
        m = re.match(r"^branch: Created from .*\t(\d+)$", first)
        if m and any(abs(int(m.group(1)) - s) <= 2 for s in stamps):
            out_b.append(b)
    return out_b


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


def _workspace_branches(w):
    """Its own branch, plus every branch created in it (recorded before the
    directory was deleted, or read now while it exists)."""
    out = []
    extra = list(w.get("extra_branches") or [])
    if w.get("path") and os.path.isdir(w["path"]):
        extra += _created_branches(w)
    for b in [w.get("branch")] + extra:
        if b and b not in out:
            out.append(b)
    return out


def _branch_targets(chain):
    out = []
    for r in chain:
        for w in r.get("workspaces") or []:
            if w.get("branch_deleted_at"):
                continue
            for b in _workspace_branches(w):
                if (w.get("repo"), b) not in out:
                    out.append((w.get("repo"), b))
    return out


# ---------------------------------------------------------------------------
# points 4, 7, 9, 10, 13 — land, discard, delete, retry
# ---------------------------------------------------------------------------

def land(ref, me="", auto=False, ignored_ok=""):
    """Point 4: landed means every workspace and branch is deleted. Landed is
    proved from git: every branch tip (and every workspace HEAD) is already in
    the main checkout's HEAD. An agent that produced nothing is landed (point 7)."""
    rec = _resolve(ref, me)
    fin, _pz, why = finished_state(rec)
    if not fin:
        raise SpecError("%s is not finished (%s); only finished work is landed" % (rec["name"], why))
    if rec.get("disposition") and rec["disposition"].get("kind") != "continued":
        return {"landed": True, "already": rec["disposition"]["kind"]}
    chain = _chain(rec)
    for r in chain:
        _require_clean(r, "land %s" % r["name"], ignored_ok)
    missing = []
    heads = {}
    for r in chain:
        for w in r.get("workspaces") or []:
            repo = w.get("repo")
            if repo not in heads:
                heads[repo] = git(repo, "rev-parse", "HEAD")[1].strip() if repo and os.path.isdir(repo) else ""
            head = heads[repo]
            if not head:
                missing.append("%s: its repository %s cannot be read" % (w.get("path") or w.get("branch"), repo))
                continue
            tips = []
            if not w.get("deleted_at") and w.get("path") and os.path.isdir(w["path"]):
                rc, out, _ = git(w["path"], "rev-parse", "HEAD")
                if rc == 0:
                    tips.append(("HEAD of " + w["path"], out.strip()))
            if not w.get("branch_deleted_at"):
                for rb in _workspace_branches(w):
                    t = branch_tip(repo, rb)
                    if t:
                        tips.append((rb, t))
            for label, t in tips:
                if not is_ancestor(repo, t, head):
                    missing.append("%s (%s) is not in %s at %s" % (label, t[:12], repo, head[:12]))
    if missing:
        raise SpecError("%s is not landed yet: %s. Merge it, then land it; or discard it (point 7)."
                        % (rec["name"], "; ".join(missing)))
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
            # Point 3: the branches created in it are its branches too. Read
            # them while the directory still exists; they are deleted with it.
            w["extra_branches"] = _workspace_branches(w)[1:]
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
                    if w.get("repo") == repo and b in _workspace_branches(w) and w.get("branch") == b:
                        w["branch_deleted_at"] = iso()
                        if not w.get("path"):
                            w["deleted_at"] = iso()
                    elif w.get("repo") == repo and b in (w.get("extra_branches") or []):
                        w["extra_branches"] = [x for x in w["extra_branches"] if x != b]
            else:
                failures.append(err)
    with Lock():
        fresh = load_agent(rec["key"]) or rec
        fresh["workspaces"] = rec["workspaces"]
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
        if done and all(w.get("deleted_at") and (w.get("branch_deleted_at") or not w.get("branch"))
                        and not w.get("extra_branches") for w in fresh["workspaces"]):
            write_json(done_path(fresh["key"]), fresh)
            os.unlink(agent_path(fresh["key"]))
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


def gate_stop(payload, entity):
    """(allowed, message). Point 5: Rich cannot end his turn while finished
    work is neither landed nor discarded, except as the page allows."""
    sid = str(payload.get("session_id") or "")
    if not sid:
        return True, ""
    retry_due()
    items = pending(sid, entity, scan=True)
    loud = keeps_failing()
    notes = []
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
        return True, "\n".join(notes)
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
    x = sub.add_parser("register-cc")
    for f in ("--name", "--repo", "--path", "--branch"):
        x.add_argument(f, required=True)
    x = sub.add_parser("confirm-cc")
    x.add_argument("--name", required=True)
    x.add_argument("--path", required=True)
    x.add_argument("--failed", default="")
    for n in ("hook", "gate-stop", "register-spawn", "barrier"):
        sub.add_parser(n)
    x = sub.add_parser("recipient")
    x.add_argument("--name", required=True)
    a = ap.parse_args(argv)
    if not a.cmd:
        ap.print_help()
        return 2
    entity = a.entity or os.environ.get("RICHOS_ENTITY_ROOT_RESOLVED", "")
    try:
        if a.cmd in ("hook", "gate-stop", "register-spawn", "barrier"):
            raw = sys.stdin.read()
            try:
                payload = json.loads(raw)
            except ValueError:
                payload = None
            if not isinstance(payload, dict):
                if a.cmd == "barrier":
                    print("ERROR\tthe payload is unparseable")
                    return 0
                if a.cmd == "register-spawn":
                    sys.stderr.write("the spawn payload is unparseable; it cannot be registered\n")
                    return 2
                return 0
            if not entity and payload.get("cwd"):
                entity = main_checkout(str(payload["cwd"]))
            if a.cmd == "barrier":
                k, d = barrier(payload)
                print("%s\t%s" % (k, d.replace("\t", " ").replace("\n", " ")))
                return 0
            if a.cmd == "register-spawn":
                rec = register_spawn(payload, entity)
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
