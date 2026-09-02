#!/usr/bin/env python3
"""worktree-ledger.py — THE DURABLE OWNERSHIP RECORD FOR TEAMMATE WORKTREES.

===========================================================================
WHY THIS FILE EXISTS — the defect four fixes did not touch
===========================================================================
A hand-rolled worktree (cross-repository work, `richos-wt/<name>`) takes no
git lock, so it carries no evidence about its own owner. To judge it, the
reaper read the owner's NATIVE isolation-worktree lock over in the session's
repository. That native worktree is deleted at land time. From that moment the
hand-rolled tree was PERMANENTLY undecidable — and correctly so, because
doctrine forbids inferring death from absence.

    Cleaning up one repository destroyed the only evidence that could ever
    clean up another.

Proven live on 2026-09-02: 29 worktrees in `richos`, 29 skipped, all
`owner-undecidable`, with the reaper declaring "no session transcript found
for entity '/Users/alex/ab/richos'" — a project directory that holds zero
transcripts and always will, because no session ever starts there.

Each earlier fix (one repo -> many, one path shape -> git truth, session-start
-> agent-finish trigger, a guard tightening) was correct and forward-only,
while the evidence it needed had already been destroyed behind it. This file
stops borrowing the harness's ephemeral lock as the record and makes RichOS
own the record instead.

===========================================================================
WHAT IS RECORDED, AND WHERE
===========================================================================
    ~/.claude/state/worktree-ledger.jsonl          (RICHOS_WORKTREE_LEDGER
                                                    overrides; tests point it
                                                    into a sandbox)

Append-only JSON lines. It lives OUTSIDE every repository and OUTSIDE the
session team directory on purpose: a repository can be cleaned, a session team
directory is per-session, and this record has to outlive both — that is its
entire job.

  registered   a worktree has an owner. Written at PostToolUse[Agent] by
               detect-nonnative-worktree.sh (beside the spawned-names append)
               and by scripts/create-teammate-worktree.sh (cross-repo). Carries
               teammate, agent_id, session_id, session_pid, pid_start, repo,
               worktree, branch, class (native|hand-rolled).
  terminated   a POSITIVE, WITNESSED termination of an agent: its native
               isolation worktree was observed registered-and-unlocked (or
               stale-locked by a dead pid) by the reaper, or the sanctioned
               remover removed it after its own NOT-ALIVE verdict. This is the
               evidence the land step used to destroy; it is now copied here
               the moment it is seen.
  finished     an ADVISORY per-agent lifecycle signal (TeammateIdle,
               TaskCompleted, SubagentStop), keyed to the worktree path when
               the payload carries one. Retained because it is per-agent
               where the lock is per-session — but see the next section for
               why it is not, by itself, a termination.

===========================================================================
THE JUDGMENT — and what is deliberately NOT a death signal
===========================================================================
For a hand-rolled worktree, the owner is resolved from the ledger first
(exact worktree path, then teammate name = branch or directory name), and
from a session transcript only as a fallback. Then, per registration:

    a `terminated` record exists for the agent ........... NOT-ALIVE (witnessed)
    native isolation worktree LOCKED by a running pid ..... ALIVE
    native isolation worktree registered, unlocked / stale  NOT-ALIVE (observed
                                                            now, and written to
                                                            the ledger so it
                                                            survives the land)
    native worktree ABSENT, session pid+start PROVABLY GONE  NOT-ALIVE. The pid
                                                            recorded at spawn no
                                                            longer exists, or
                                                            exists with a
                                                            different start time
                                                            (reused). Every
                                                            agent of a session
                                                            runs inside that one
                                                            process; when it is
                                                            gone, so are they.
                                                            This is the SAME
                                                            evidence class the
                                                            resolver already
                                                            accepts as a stale
                                                            lock — retained past
                                                            the lock's deletion.
    native worktree ABSENT, session pid still running ..... INDETERMINATE —
                                                            named as such, with
                                                            the pid, and it
                                                            becomes decidable
                                                            the moment that
                                                            session ends.
    no session identity on record, native absent .......... INDETERMINATE
    no registration and no transcript join at all ......... UNRESOLVED

Several registrations can match one name (the reuse guard is per-session,
names recur across sessions). ALL must be NOT-ALIVE for the tree's owner to
be NOT-ALIVE; one ALIVE wins over everything; otherwise INDETERMINATE.

`finished` records are NOT death. A teammate that went idle can be resumed by
a message (guard-resume-isolation.sh permits exactly that for an active
teammate), a completed task is task-grain not agent-grain, and SubagentStop
fires at the end of EVERY turn (agent-liveness.py measured 337 of them for six
agents). They are reported in the reason line so an operator sees them; they
never decide.

INDETERMINATE IS NEVER COLLAPSED. UNRESOLVED IS NEVER COLLAPSED. Absence is
never a termination signal.

===========================================================================
SESSION IDENTITY = pid + start time, never pid alone
===========================================================================
The lock line the harness writes names the host session's pid, and
agent-liveness.py measured that it is the same for every agent of the session.
A pid can be reused after the process dies, so a bare `kill -0` is not
identity. The ledger records `ps -o lstart=` for the pid at registration and
compares the same field later: same pid + same start = the same process;
anything else = that process is gone.
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

ALIVE = "ALIVE"
NOT_ALIVE = "NOT-ALIVE"
INDETERMINATE = "INDETERMINATE"
UNRESOLVED = "UNRESOLVED"

LOCK_PID_RE = re.compile(r"\(pid\s+(\d+)")
LOCK_START_RE = re.compile(r"\(pid\s+\d+\s+start\s+([^)]*)\)")
AGENT_ID_IN_RESPONSE_RE = re.compile(r"agentId:\s*([A-Za-z0-9_-]+)")

DEFAULT_PATH = os.path.join(os.path.expanduser("~"), ".claude", "state", "worktree-ledger.jsonl")


# --------------------------------------------------------------------------
# storage
# --------------------------------------------------------------------------

def ledger_path():
    return (os.environ.get("RICHOS_WORKTREE_LEDGER") or "").strip() or DEFAULT_PATH


def now_iso():
    return datetime.now(timezone.utc).isoformat()


def append(record, path=None):
    """Append one record. Returns True on success; never raises."""
    path = path or ledger_path()
    rec = dict(record)
    rec.setdefault("ts", now_iso())
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, sort_keys=True) + "\n")
        return True
    except Exception:
        return False


def read_all(path=None):
    path = path or ledger_path()
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if isinstance(d, dict):
                    out.append(d)
    except Exception:
        pass
    return out


# --------------------------------------------------------------------------
# process identity
# --------------------------------------------------------------------------

def _ws(s):
    return " ".join((s or "").split())


def pid_start(pid):
    """`ps -o lstart=` for a pid, whitespace-normalized, or "" if unreadable."""
    try:
        pid = int(pid)
    except Exception:
        return ""
    if pid <= 0:
        return ""
    try:
        res = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=5)
    except Exception:
        return ""
    if res.returncode != 0:
        return ""
    return _ws(res.stdout)


def _pid_running(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return None


def process_status(pid, recorded_start):
    """One of: alive, gone, reused, unknown.

    alive    the pid runs AND (no start was recorded OR the start matches)
    gone     no process has this pid
    reused   a process has this pid but with a different start time
    unknown  the pid is missing/unprobeable
    """
    if pid in (None, "", 0):
        return "unknown"
    try:
        pid = int(pid)
    except Exception:
        return "unknown"
    running = _pid_running(pid)
    if running is None:
        return "unknown"
    if not running:
        return "gone"
    cur = pid_start(pid)
    rec = _ws(recorded_start)
    if not cur:
        # It answered kill -0 but ps could not read it — do not guess.
        return "unknown"
    if not rec:
        return "alive"
    return "alive" if cur == rec else "reused"


def session_pid_from_env():
    """The host session pid: CLAUDE_PID when the harness exports it, else the
    nearest ancestor process named `claude`. Returns int or None."""
    v = (os.environ.get("CLAUDE_PID") or "").strip()
    if v.isdigit():
        return int(v)
    pid = os.getpid()
    for _ in range(12):
        try:
            res = subprocess.run(["ps", "-o", "ppid=,comm=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=5)
        except Exception:
            return None
        parts = res.stdout.split()
        if len(parts) < 2:
            return None
        ppid, comm = parts[0], parts[1]
        if os.path.basename(comm) == "claude":
            return pid
        if not ppid.isdigit() or int(ppid) <= 1:
            return None
        pid = int(ppid)
    return None


# --------------------------------------------------------------------------
# git helpers (small, local; the resolver owns the lock rule)
# --------------------------------------------------------------------------

def norm_path(p):
    p = (p or "").strip().rstrip("/")
    if not p:
        return ""
    try:
        return os.path.realpath(p)
    except Exception:
        return p


def worktree_entries(repo):
    """[(path, branch_or_"", lock_line_or_None)] for a repository, or None."""
    try:
        res = subprocess.run(["git", "-C", repo, "worktree", "list", "--porcelain"],
                             capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    if res.returncode != 0:
        return None
    out = []
    cur = None
    for line in res.stdout.splitlines():
        if line.startswith("worktree "):
            if cur:
                out.append(tuple(cur))
            cur = [line[len("worktree "):], "", None]
        elif cur is not None and line.startswith("branch refs/heads/"):
            cur[1] = line[len("branch refs/heads/"):]
        elif cur is not None and line.startswith("locked"):
            cur[2] = line
    if cur:
        out.append(tuple(cur))
    return out


def lock_identity(lock_line):
    """(pid, start) parsed from a harness lock line, or (None, "")."""
    if not lock_line:
        return None, ""
    m = LOCK_PID_RE.search(lock_line)
    pid = int(m.group(1)) if m else None
    m2 = LOCK_START_RE.search(lock_line)
    return pid, _ws(m2.group(1)) if m2 else ""


def agent_id_from_response(text):
    m = AGENT_ID_IN_RESPONSE_RE.search(text or "")
    return m.group(1) if m else ""


# --------------------------------------------------------------------------
# the resolver, borrowed — never re-implemented
# --------------------------------------------------------------------------

def _liveness_module():
    try:
        import importlib.util as ilu
        here = os.path.dirname(os.path.abspath(__file__))
        spec = ilu.spec_from_file_location(
            "agent_liveness_for_ledger", os.path.join(here, "agent-liveness.py"))
        mod = ilu.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


# --------------------------------------------------------------------------
# queries
# --------------------------------------------------------------------------

def registrations(records, worktree=None, names=(), repo=None):
    wt = norm_path(worktree) if worktree else ""
    names = {n for n in names if n}
    out = []
    for r in records:
        if r.get("event") != "registered":
            continue
        if wt and norm_path(r.get("worktree")) == wt:
            out.append(r)
            continue
        if names and (r.get("teammate") or "") in names:
            if repo and r.get("repo") and norm_path(r.get("repo")) != norm_path(repo) \
                    and r.get("class") == "hand-rolled":
                # A hand-rolled registration names the repository it lives in;
                # a same-name registration in a DIFFERENT repository is a
                # different worktree, not this one's owner.
                continue
            out.append(r)
    return out


def terminations(records, agent_id):
    if not agent_id:
        return []
    return [r for r in records
            if r.get("event") == "terminated" and (r.get("agent_id") or "") == agent_id]


def finished_signals(records, agent_id="", worktree=""):
    wt = norm_path(worktree) if worktree else ""
    out = []
    for r in records:
        if r.get("event") != "finished":
            continue
        if agent_id and (r.get("agent_id") or "") == agent_id:
            out.append(r)
        elif wt and norm_path(r.get("worktree") or r.get("cwd")) == wt:
            out.append(r)
    return out


def registered_branches(records, repo):
    rp = norm_path(repo)
    out = set()
    for r in records:
        if r.get("event") != "registered":
            continue
        if norm_path(r.get("repo")) == rp and r.get("branch"):
            out.add(r["branch"])
    return sorted(out)


# --------------------------------------------------------------------------
# the judgment
# --------------------------------------------------------------------------

def _judge_registration(reg, entity, records, mod, write, ledger):
    """(verdict, reason) for ONE registration. NOT-ALIVE only on positive
    evidence; absence lands in INDETERMINATE."""
    aid = (reg.get("agent_id") or "").strip()
    name = reg.get("teammate") or "?"
    sid = (reg.get("session_id") or "")[:8]

    # 1. a witnessed termination already on record
    term = terminations(records, aid)
    if term:
        t = term[-1]
        return NOT_ALIVE, ("witnessed termination on record for agent %s (%s): %s at %s"
                           % (aid, name, t.get("reason") or t.get("witness") or "?", t.get("ts")))

    # 2. the native lock, live, through the one resolver
    lock_entity = reg.get("repo") if reg.get("class") == "native" and reg.get("repo") else entity
    if aid and mod is not None and lock_entity:
        rec = mod.resolve(lock_entity, aid)
        v = rec.get("verdict")
        ev = rec.get("evidence") or {}
        if v == mod.ALIVE:
            return ALIVE, ("its isolation worktree %s is LOCKED by running pid %s"
                           % (ev.get("worktree_path"), ev.get("pid")))
        if v == mod.INDETERMINATE:
            return INDETERMINATE, rec.get("reason") or "liveness could not be resolved"
        if v == mod.NOT_ALIVE and ev.get("registered"):
            reason = rec.get("reason") or "isolation worktree registered and unlocked"
            if write:
                append({"event": "terminated", "agent_id": aid, "teammate": name,
                        "session_id": reg.get("session_id") or "",
                        "worktree": ev.get("worktree_path") or "",
                        "reason": reason, "witness": "reaper-observation"}, ledger)
            return NOT_ALIVE, "OBSERVED now: " + reason
        # NOT-ALIVE on ABSENCE: never accepted here. Fall through to the one
        # piece of evidence that outlives the lock — the session identity.

    # 3. session identity — the evidence the lock carried, retained
    pid = reg.get("session_pid")
    status = process_status(pid, reg.get("pid_start") or "")
    if status in ("gone", "reused"):
        return NOT_ALIVE, ("its host session pid %s (started %s) is %s — the process every "
                           "agent of session %s ran inside no longer exists"
                           % (pid, reg.get("pid_start") or "?", status, sid or "?"))
    if status == "alive":
        return INDETERMINATE, ("no native isolation worktree is registered for agent %s (%s) "
                               "while its session pid %s is still running; "
                               "decidable once that session ends (absence is not a termination "
                               "signal)" % (aid or "?", name, pid))
    return INDETERMINATE, ("no session identity on record for agent %s (%s) and its isolation "
                          "worktree is absent; absence is not a termination signal"
                          % (aid or "?", name))


def judge(entity, worktree, names, records, transcript_names=None, mod=None,
          write=True, ledger=None, repo=None):
    """The owner verdict for one hand-rolled worktree."""
    transcript_names = transcript_names or {}
    regs = registrations(records, worktree=worktree, names=names, repo=repo)
    source = "ledger" if regs else ""
    if not regs:
        for n in names:
            aid = transcript_names.get(n)
            if aid:
                regs.append({"event": "registered", "teammate": n, "agent_id": aid,
                             "class": "native", "repo": entity, "source": "transcript"})
                source = "transcript"
    if not regs:
        return {"verdict": UNRESOLVED, "agent_ids": [], "source": "",
                "reason": ("no ownership record: no ledger registration for this path or for "
                           "'%s', and no transcript joins that name to an agent"
                           % "/".join(n for n in names if n))}

    verdicts = []
    for reg in regs:
        v, why = _judge_registration(reg, entity, records, mod, write, ledger)
        verdicts.append((v, why, reg.get("agent_id") or ""))

    agent_ids = sorted({a for _v, _w, a in verdicts if a})
    advisory = []
    for aid in agent_ids:
        fs = finished_signals(records, agent_id=aid)
        if fs:
            advisory.append("%s: %d advisory finish signal(s), last %s at %s"
                            % (aid, len(fs), fs[-1].get("signal"), fs[-1].get("ts")))
    if worktree:
        fs = finished_signals(records, worktree=worktree)
        if fs:
            advisory.append("path: %d advisory finish signal(s)" % len(fs))

    if any(v == ALIVE for v, _w, _a in verdicts):
        v, why, _a = next(x for x in verdicts if x[0] == ALIVE)
        final, reason = ALIVE, why
    elif any(v == INDETERMINATE for v, _w, _a in verdicts):
        v, why, _a = next(x for x in verdicts if x[0] == INDETERMINATE)
        final, reason = INDETERMINATE, why
    else:
        final = NOT_ALIVE
        reason = "; ".join(w for _v, w, _a in verdicts)
    if len(regs) > 1:
        reason = "%d registrations match (%s); %s" % (len(regs), source, reason)
    if advisory:
        reason += " [advisory, never decisive: " + "; ".join(advisory) + "]"
    return {"verdict": final, "agent_ids": agent_ids, "source": source, "reason": reason}


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _cmd_record(args):
    rec = {"event": args.event}
    for key in ("teammate", "agent_id", "session_id", "repo", "worktree", "branch",
                "cls", "source", "signal", "reason", "witness", "cwd", "task_id"):
        val = getattr(args, key, None)
        if val not in (None, ""):
            rec["class" if key == "cls" else key] = val
    if args.session_pid not in (None, ""):
        try:
            rec["session_pid"] = int(args.session_pid)
        except ValueError:
            rec["session_pid"] = args.session_pid
    if args.pid_start:
        rec["pid_start"] = _ws(args.pid_start)
    elif args.session_pid not in (None, "") and args.pid_start_of_session:
        rec["pid_start"] = pid_start(args.session_pid)
    if args.lock_line:
        pid, start = lock_identity(args.lock_line)
        if pid and "session_pid" not in rec:
            rec["session_pid"] = pid
        if start and "pid_start" not in rec:
            rec["pid_start"] = start
        rec["lock_line"] = args.lock_line
    for kv in args.extra or []:
        if "=" in kv:
            k, v = kv.split("=", 1)
            rec[k] = v
    ok = append(rec, args.ledger)
    print(json.dumps(rec, sort_keys=True))
    return 0 if ok else 1


def _load_transcripts(paths, mod):
    names = {}
    if mod is None:
        return names
    for p in paths or []:
        try:
            for n, a in (mod.names_to_ids(p) or {}).items():
                names.setdefault(n, a)
        except Exception:
            continue
    return names


def _cmd_judge_batch(args):
    records = read_all(args.ledger)
    mod = _liveness_module()
    tnames = _load_transcripts(args.transcript, mod)
    write = not args.no_write
    for line in sys.stdin:
        line = line.rstrip("\n")
        if not line.strip():
            continue
        parts = line.split("\t")
        while len(parts) < 4:
            parts.append("")
        repo, path, branch, dirname = parts[:4]
        names = [n for n in (branch, dirname) if n]
        res = judge(args.entity, path, names, records, tnames, mod, write, args.ledger,
                    repo=repo or None)
        print("%s\t%s\t%s\t%s" % (path, res["verdict"], ",".join(res["agent_ids"]),
                                  res["reason"].replace("\t", " ").replace("\n", " ")))
    return 0


def _cmd_judge(args):
    records = read_all(args.ledger)
    mod = _liveness_module()
    tnames = _load_transcripts(args.transcript, mod)
    names = [n for n in ([args.name] + list(args.alias or [])) if n]
    res = judge(args.entity, args.worktree, names, records, tnames, mod,
                not args.no_write, args.ledger)
    if args.format == "json":
        print(json.dumps(res, indent=2, sort_keys=True))
    else:
        print("%s\t%s\t%s" % (res["verdict"], ",".join(res["agent_ids"]), res["reason"]))
    return 0


def _cmd_registrations(args):
    records = read_all(args.ledger)
    regs = registrations(records, worktree=args.worktree,
                         names=[n for n in [args.name] if n])
    for r in regs:
        print(json.dumps(r, sort_keys=True))
    return 0 if regs else 1


def _cmd_branches(args):
    records = read_all(args.ledger)
    for b in registered_branches(records, args.repo):
        print(b)
    return 0


def _cmd_pid_start(args):
    s = pid_start(args.pid)
    print(s)
    return 0 if s else 1


def _cmd_session_pid(_args):
    pid = session_pid_from_env()
    if pid is None:
        return 1
    print(pid)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="worktree-ledger.py")
    ap.add_argument("--ledger", default=None, help="ledger path (default: env / ~/.claude/state)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("path")

    p = sub.add_parser("record")
    p.add_argument("event", choices=("registered", "terminated", "finished"))
    for key in ("teammate", "agent-id", "session-id", "session-pid", "pid-start", "repo",
                "worktree", "branch", "source", "signal", "reason", "witness", "cwd",
                "task-id", "lock-line"):
        p.add_argument("--" + key, dest=key.replace("-", "_"), default="")
    p.add_argument("--class", dest="cls", default="", choices=("", "native", "hand-rolled"))
    p.add_argument("--pid-start-of-session", action="store_true",
                   help="fill pid_start from ps for --session-pid")
    p.add_argument("--extra", action="append", default=[], help="k=v")

    p = sub.add_parser("judge")
    p.add_argument("--entity", required=True)
    p.add_argument("--worktree", default="")
    p.add_argument("--name", default="")
    p.add_argument("--alias", action="append", default=[])
    p.add_argument("--transcript", action="append", default=[])
    p.add_argument("--no-write", action="store_true")
    p.add_argument("--format", choices=("json", "triple"), default="json")

    p = sub.add_parser("judge-batch")
    p.add_argument("--entity", required=True)
    p.add_argument("--transcript", action="append", default=[])
    p.add_argument("--no-write", action="store_true")

    p = sub.add_parser("registrations")
    p.add_argument("--worktree", default="")
    p.add_argument("--name", default="")

    p = sub.add_parser("branches")
    p.add_argument("--repo", required=True)

    p = sub.add_parser("pid-start")
    p.add_argument("pid")

    p = sub.add_parser("session-pid")

    args = ap.parse_args(argv)
    if args.cmd == "path":
        print(args.ledger or ledger_path())
        return 0
    return {
        "record": _cmd_record,
        "judge": _cmd_judge,
        "judge-batch": _cmd_judge_batch,
        "registrations": _cmd_registrations,
        "branches": _cmd_branches,
        "pid-start": _cmd_pid_start,
        "session-pid": _cmd_session_pid,
    }[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
