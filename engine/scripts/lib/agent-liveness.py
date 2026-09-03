#!/usr/bin/env python3
"""agent-liveness.py — THE ONE IMPLEMENTATION OF "IS THIS AGENT ALIVE?".

===========================================================================
WHY THIS FILE EXISTS
===========================================================================
On 2026-08-31 at ~22:45 the orchestrator told the CEO that `zach-opus-g1` was
COMPLETED. It was not. The CEO's own screen showed it working, and its
isolation-worktree lock was held the entire time.

The correct signal was present and was DISCARDED. `git worktree list` said
`locked`. `remove-agent-worktree.sh` REFUSED the removal, for exactly the right
reason, and printed that a live agent's worktree is always locked. The lead
called the lock "residue" and quoted the `ListAgents` roster instead, which said
`completed`. The roster was stale. The lock was right. The CEO had to correct
his own assistant from a screenshot.

The project doctrine already said *liveness = the worktree lock* and *never
infer an agent is dead from filesystem inactivity; require a positive
termination signal*. What it did not anticipate is the INVERSE: a
positive-looking signal that is WRONG. A stale `completed` is more dangerous
than an absent status, because absence prompts a check and a false positive
does not.

And the correct logic already existed — inside remove-agent-worktree.sh, which
got today's case right. Nothing needed inventing. What was missing is that
nothing checked the lead's STATEMENTS against it. So the logic is extracted
here, and the remover CONSUMES this file rather than carrying a second copy:
two implementations of "alive" is how one of them ends up being the stale one.

===========================================================================
THE RULE, UNCHANGED FROM THE REMOVER (this is an extraction, not a redesign)
===========================================================================
An agent is ALIVE iff its NATIVE isolation worktree, registered in the ENTITY's
main checkout, is locked with a LIVE pid.

    absent / unregistered worktree ......... NOT-ALIVE
    registered but UNLOCKED ................ NOT-ALIVE
    locked, lock line carries no pid ....... NOT-ALIVE
    locked, pid parsed, pid is dead ........ NOT-ALIVE (stale lock)
    locked, pid parsed, pid is running ..... ALIVE
    git could not be queried ............... INDETERMINATE

INDETERMINATE IS A REAL OUTCOME AND IS NEVER COLLAPSED. The remover treats it
as "refuse" and the claim guard treats it as "say nothing", and those are
different responses to the same honest answer — which is the point of keeping
it. A resolver that only ever says yes or no has to guess, and a guess is what
produced the defect.

===========================================================================
WHAT THE PID IN THE LOCK ACTUALLY IS — MEASURED, NOT ASSUMED
===========================================================================
Read on this machine, 2026-08-31, from four concurrent agent worktrees in
/Users/alex/ab/femcboost/.git/worktrees/*/locked:

    claude agent agent-a86f3ce81f7d36390 (pid 94086 start Mon Aug 31 19:39:29 2026)
    claude agent agent-ac6e9e5cf51a66b24 (pid 94086 start Mon Aug 31 19:39:29 2026)

The pid is the HOST SESSION's pid, and it is THE SAME for every agent of that
session. So `kill -0 <pid>` does not distinguish one agent from another; it
distinguishes "the session that owns this lock is still running" from "this
lock was left behind by a session that is gone".

That is stated here rather than glossed because it bounds what this file can
prove. The LOCK'S PRESENCE is the per-agent signal; the pid check is the
stale-lock filter. A worktree whose agent finished but which has not yet been
reaped still reads ALIVE. That is why the claim guard built on this REPORTS
rather than BLOCKS — see guard-agent-state-claims.py, which carries the
measurement.

`pid_shared_with` is emitted in the JSON for exactly this reason: an operator
reading the evidence can see for himself that the pid is a session pid rather
than an agent pid, instead of taking this docstring's word for it.

===========================================================================
NAMING THE DISAGREEMENT IS HALF THE JOB
===========================================================================
The defect was not a missing answer. It was TWO answers and the wrong one
believed. So every verdict carries the other sources and says which of them
disagree:

  worktree-lock   AUTHORITATIVE. The only source that decides.
  roster          ~/.claude/teams/session-*/config.json members[].status.
                  This is the surface `ListAgents` reads. Advisory ONLY.
  worker-events   worker-events.jsonl, the SubagentStart/SubagentStop log.
                  MEASURED TRAP: `WorkerRunEnded` fires at the end of EVERY
                  subagent turn, not only at termination. On this machine one
                  session held 337 WorkerRunEnded records for 6 agents. A
                  reader who takes the last event as terminal will call a live
                  agent dead most of the time. Advisory ONLY, and labelled.

A source that says "terminal" over a held lock is not noise to be averaged in.
It is the exact signal that mattered on 2026-08-31, so it is reported by name.
"""

import argparse
import json
import os
import re
import subprocess
import sys

ALIVE = "ALIVE"
NOT_ALIVE = "NOT-ALIVE"
INDETERMINATE = "INDETERMINATE"

# `agent-<id>` as the native isolation worktree names it.
AGENT_DIR_RE = re.compile(r"^agent-[A-Za-z0-9_]+$")
LOCK_PID_RE = re.compile(r"\(pid\s+(\d+)")
LOCK_AGENT_RE = re.compile(r"claude agent (agent-[A-Za-z0-9_]+)")

# Roster status values that CLAIM the agent is finished. Kept identical in
# spirit to guard-unresolved-claims.py's TERMINAL_STATUS: this is the set whose
# disagreement with a held lock is the 2026-08-31 defect.
TERMINAL_STATUS = {
    "shutdown", "shutdown_request", "shutdown_approved", "completed",
    "complete", "done", "terminated", "dead", "exited", "killed", "removed",
    "gone",
}


# --------------------------------------------------------------------------
# git
# --------------------------------------------------------------------------

def _worktree_entries(entity_root):
    """[(path, lock_line_or_None)] or raises RuntimeError.

    The parse is deliberately the same shape as the one remove-agent-worktree.sh
    used to carry inline, because this file replaced that copy and a behavioral
    difference here would be a silent change to the removal gate.
    """
    try:
        res = subprocess.run(
            ["git", "-C", entity_root, "worktree", "list", "--porcelain"],
            capture_output=True, text=True, timeout=20,
        )
    except Exception as e:
        raise RuntimeError("git worktree list failed: %s" % e)
    if res.returncode != 0:
        raise RuntimeError("git worktree list exited %d: %s"
                           % (res.returncode, (res.stderr or "").strip()[:200]))

    entries = []
    cur_path = None
    cur_locked = None
    for line in res.stdout.splitlines():
        if line.startswith("worktree "):
            if cur_path is not None:
                entries.append((cur_path, cur_locked))
            cur_path = line[len("worktree "):]
            cur_locked = None
        elif line.startswith("locked"):
            cur_locked = line
    if cur_path is not None:
        entries.append((cur_path, cur_locked))
    return entries


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Running, owned by somebody else. Alive.
        return True
    except Exception:
        return None


# --------------------------------------------------------------------------
# other sources -- advisory, reported, never decisive
# --------------------------------------------------------------------------

def teams_dir():
    return (os.environ.get("RICHOS_LIVENESS_TEAMS_DIR")
            or os.path.expanduser("~/.claude/teams"))


def _roster_says(agent_id):
    """What every session roster on this machine says about this agent id.

    Returns [] when no roster mentions it -- which is itself worth knowing, and
    is reported as such rather than silently read as "not alive".
    """
    out = []
    td = teams_dir()
    if not os.path.isdir(td):
        return out
    try:
        sessions = sorted(os.listdir(td))
    except OSError:
        return out
    for s in sessions:
        cfg = os.path.join(td, s, "config.json")
        try:
            with open(cfg, encoding="utf-8") as f:
                members = json.load(f).get("members") or []
        except Exception:
            continue
        for m in members:
            if not isinstance(m, dict):
                continue
            aid = str(m.get("agentId") or "")
            cwd = str(m.get("cwd") or "")
            if agent_id not in aid and not cwd.rstrip("/").endswith("/" + agent_id):
                continue
            out.append({
                "session": s,
                "name": m.get("name"),
                "agentType": m.get("agentType"),
                "status": str(m.get("status") or "") or None,
            })
    return out


def _worker_events_say(agent_id):
    """Last lifecycle event for this agent id, plus the count, plus the trap.

    `WorkerRunEnded` fires on EVERY SubagentStop, which is every turn the agent
    takes -- not its termination. So the last event being `run_ended` means
    almost nothing on its own, and this dict says so in `terminal_looking`
    rather than letting a caller infer it.
    """
    td = teams_dir()
    last = None
    n = 0
    if not os.path.isdir(td):
        return None
    try:
        sessions = sorted(os.listdir(td))
    except OSError:
        return None
    for s in sessions:
        p = os.path.join(td, s, "worker-events.jsonl")
        try:
            with open(p, encoding="utf-8") as f:
                for line in f:
                    if agent_id not in line:
                        continue
                    try:
                        d = json.loads(line)
                    except Exception:
                        continue
                    if str(d.get("agent_id") or "") != agent_id:
                        continue
                    n += 1
                    last = d
        except Exception:
            continue
    if last is None:
        return None
    ev = str(last.get("event") or "")
    return {
        "last_event": ev,
        "last_timestamp": last.get("timestamp"),
        "events_seen": n,
        "agent_type": last.get("agent_type") or None,
        "terminal_looking": ev in ("WorkerRunEnded", "WorkerEnded"),
        "caveat": ("WorkerRunEnded fires at the end of EVERY subagent turn, "
                   "not only at termination -- it is not a termination signal"),
    }


# --------------------------------------------------------------------------
# name -> agent id, from the orchestrator's own transcript
# --------------------------------------------------------------------------

def agent_spawns(transcript_path, limit_bytes=64 * 1024 * 1024):
    """[(tool_use_id, name_or_"", agent_id)] — every Agent call in a session
    transcript that the harness answered with an agent id.

    THE MAPPING IS NOT ON DISK ANYWHERE ELSE, and this is why the guard cannot
    work from `spawned-names.log` alone. Verified on a real transcript
    (session 042f3850, 2026-08-31):

      * the assistant record carries a tool_use named `Agent` whose input has
        the teammate's `name` ("zach-opus-g1") and a tool_use `id`
      * the following user record carries a tool_result with the SAME
        tool_use_id, and a `toolUseResult` object holding `agentId`

    So the join is on tool_use_id and it is exact. Nothing here guesses. This
    is THE ONE parser of that join; names_to_ids() and tool_use_ids_to_agent_ids()
    are two views of its output, and a third consumer must be a third view,
    never a third parser.
    """
    out = []
    if not transcript_path or not os.path.isfile(transcript_path):
        return out
    pending = {}     # tool_use_id -> name ("" when the spawn carried none)
    try:
        size = os.path.getsize(transcript_path)
    except OSError:
        return out
    try:
        with open(transcript_path, encoding="utf-8", errors="replace") as f:
            if size > limit_bytes:
                f.seek(size - limit_bytes)
                f.readline()
            for line in f:
                if '"Agent"' not in line and '"agentId"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                msg = d.get("message") or {}
                content = msg.get("content")
                if isinstance(content, list):
                    for c in content:
                        if not isinstance(c, dict):
                            continue
                        if c.get("type") == "tool_use" and c.get("name") == "Agent":
                            inp = c.get("input") or {}
                            nm = inp.get("name")
                            if c.get("id"):
                                pending[c["id"]] = nm.strip() if isinstance(nm, str) else ""
                        elif c.get("type") == "tool_result" and c.get("tool_use_id"):
                            tur = d.get("toolUseResult")
                            if isinstance(tur, dict) and tur.get("agentId"):
                                tuid = c["tool_use_id"]
                                if tuid in pending:
                                    out.append((tuid, pending[tuid], str(tur["agentId"])))
    except Exception:
        return out
    return out


def names_to_ids(transcript_path, limit_bytes=64 * 1024 * 1024):
    """{'zach-opus-g1': 'a86f3ce81f7d36390', ...} from a session transcript.

    A name that cannot be joined is simply absent from the result -- the caller
    then has no agent to check, which is the honest answer rather than a
    role-prefix match that would be ambiguous the moment two teammates of the
    same role run at once (three did, on the day of the defect).
    """
    out = {}
    for _tuid, nm, aid in agent_spawns(transcript_path, limit_bytes):
        if nm:
            out[nm] = aid
    return out


def tool_use_ids_to_agent_ids(transcript_path, limit_bytes=64 * 1024 * 1024):
    """{'toolu_01...': 'a86f3ce81f7d36390', ...} — the join keyed the way the
    worktree lifecycle keys it: by the exact tool_use_id the PreToolUse[Agent]
    spawn-intent was written under (worktree-transactions.py). Exact, and
    name-free: a spawn with no name still binds."""
    out = {}
    for tuid, _nm, aid in agent_spawns(transcript_path, limit_bytes):
        out[tuid] = aid
    return out


# --------------------------------------------------------------------------
# the resolution
# --------------------------------------------------------------------------

def _normalize(target):
    """A bare id, an `agent-<id>`, or a worktree path -> (agent_dirname, path_hint)."""
    t = (target or "").strip().rstrip("/")
    if not t:
        return None, None
    if "/" in t:
        return os.path.basename(t), t
    if t.startswith("agent-"):
        return t, None
    return "agent-" + t, None


def resolve(entity_root, target):
    """One authoritative verdict, with its evidence and its disagreements."""
    agent_dir, path_hint = _normalize(target)
    rec = {
        "target": target,
        "agent_dir": agent_dir,
        "agent_id": agent_dir[len("agent-"):] if agent_dir else None,
        "entity_root": entity_root,
        "verdict": INDETERMINATE,
        "reason": "",
        "evidence": {},
        "sources": {},
        "disagreements": [],
    }
    if not agent_dir:
        rec["reason"] = "no agent id or worktree path given"
        return rec

    try:
        entries = _worktree_entries(entity_root)
    except RuntimeError as e:
        rec["verdict"] = INDETERMINATE
        rec["reason"] = str(e)
        rec["evidence"] = {"git_query": "failed"}
        return rec

    match = None
    for path, locked in entries:
        base = path.rstrip("/").split("/")[-1]
        if base == agent_dir or (locked and agent_dir in locked) or (
                path_hint and path.rstrip("/") == path_hint):
            match = (path, locked)
            break

    ev = rec["evidence"]
    ev["registered"] = match is not None
    if match is None:
        ev["worktree_path"] = path_hint
        ev["present_on_disk"] = bool(path_hint and os.path.isdir(path_hint))
        ev["locked"] = False
        rec["verdict"] = NOT_ALIVE
        rec["reason"] = ("no registered entity worktree for %s in %s "
                         "(absent/unregistered)" % (agent_dir, entity_root))
        _attach_sources(rec)
        return rec

    path, locked = match
    ev["worktree_path"] = path
    ev["present_on_disk"] = os.path.isdir(path)
    ev["locked"] = bool(locked)
    ev["lock_line"] = locked

    if not locked:
        rec["verdict"] = NOT_ALIVE
        rec["reason"] = ("entity worktree %s is present but UNLOCKED -- a live "
                         "agent isolation worktree is always locked" % path)
        _attach_sources(rec)
        return rec

    m = LOCK_PID_RE.search(locked)
    if not m:
        rec["verdict"] = NOT_ALIVE
        rec["reason"] = ("entity worktree %s is locked but the lock line carries "
                         "no pid (%r)" % (path, locked))
        _attach_sources(rec)
        return rec

    pid = int(m.group(1))
    ev["pid"] = pid
    shared = sum(1 for _p, _l in entries
                 if _l and LOCK_PID_RE.search(_l)
                 and int(LOCK_PID_RE.search(_l).group(1)) == pid)
    # See the module docstring: the lock pid is the HOST SESSION pid, so this is
    # routinely > 1 and that is not an anomaly. It is emitted so an operator can
    # see the pid is not per-agent instead of assuming it is.
    ev["pid_shared_with"] = shared - 1
    alive = _pid_alive(pid)
    ev["pid_alive"] = alive

    if alive is None:
        rec["verdict"] = INDETERMINATE
        rec["reason"] = ("worktree %s is locked by pid %d and that pid could not "
                         "be probed" % (path, pid))
    elif alive:
        rec["verdict"] = ALIVE
        rec["reason"] = ("isolation worktree %s is LOCKED and the locking pid %d "
                         "is running" % (path, pid))
    else:
        rec["verdict"] = NOT_ALIVE
        rec["reason"] = ("entity worktree %s carries a STALE lock (pid %d is "
                         "dead)" % (path, pid))
    _attach_sources(rec)
    return rec


def _attach_sources(rec):
    """The advisory surfaces, and every place they contradict the lock."""
    aid = rec.get("agent_id") or ""
    if not aid:
        return
    roster = _roster_says(aid)
    events = _worker_events_say(aid)
    rec["sources"] = {
        "worktree-lock": {
            "authoritative": True,
            "says": rec["verdict"],
            "detail": rec["reason"],
        },
        "roster": {
            "authoritative": False,
            "entries": roster,
            "detail": ("~/.claude/teams/*/config.json -- the surface ListAgents "
                       "reads. Advisory: it is not refreshed from the lock."),
        },
        "worker-events": {
            "authoritative": False,
            "entry": events,
            "detail": ("worker-events.jsonl. Advisory: WorkerRunEnded fires at "
                       "every subagent turn end, not only at termination."),
        },
    }

    dis = rec["disagreements"]
    if rec["verdict"] == ALIVE:
        for r in roster:
            st = (r.get("status") or "").lower()
            if st in TERMINAL_STATUS:
                dis.append(
                    "roster (session %s) says status=%r for %s while the lock is "
                    "HELD -- this is the 2026-08-31 shape: believe the lock."
                    % (r["session"], r.get("status"), r.get("name") or aid))
        if events and events.get("terminal_looking"):
            dis.append(
                "worker-events last record is %s (%s) while the lock is HELD. "
                "That event fires at every turn end, so it is not a termination "
                "signal -- believe the lock."
                % (events["last_event"], events.get("last_timestamp")))
    if rec["verdict"] == NOT_ALIVE and roster:
        for r in roster:
            st = (r.get("status") or "").lower()
            if st and st not in TERMINAL_STATUS:
                dis.append(
                    "roster (session %s) says status=%r for %s while the lock is "
                    "NOT held. The lock decides; the roster is stale in the other "
                    "direction." % (r["session"], r.get("status"), r.get("name") or aid))


def enumerate_all(entity_root):
    """Every agent worktree registered in the entity -- the sweep the lead owes
    himself before saying anything about an agent's state."""
    try:
        entries = _worktree_entries(entity_root)
    except RuntimeError as e:
        return [{"target": None, "verdict": INDETERMINATE, "reason": str(e),
                 "entity_root": entity_root, "evidence": {}, "sources": {},
                 "disagreements": []}]
    out = []
    for path, locked in entries:
        base = path.rstrip("/").split("/")[-1]
        if not AGENT_DIR_RE.match(base):
            if not (locked and LOCK_AGENT_RE.search(locked)):
                continue
            base = LOCK_AGENT_RE.search(locked).group(1)
        out.append(resolve(entity_root, path if base == path.rstrip("/").split("/")[-1] else base))
    return out


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _triple(rec):
    """The line format remove-agent-worktree.sh consumes.

    THREE FIELDS, TAB SEPARATED, one line:
        ALIVE\t<pid>\t<worktree-path>
        NOT-ALIVE\t<reason>\t<worktree-path or empty>
        INDETERMINATE\t<reason>\t
    """
    v = rec["verdict"]
    if v == ALIVE:
        return "%s\t%s\t%s" % (ALIVE, rec["evidence"].get("pid", ""),
                               rec["evidence"].get("worktree_path", ""))
    reason = (rec.get("reason") or "").replace("\t", " ").replace("\n", " ")
    if v == NOT_ALIVE:
        return "%s\t%s\t%s" % (NOT_ALIVE, reason,
                               rec["evidence"].get("worktree_path") or "")
    return "%s\t%s\t" % (INDETERMINATE, reason)


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--entity", required=True)
    ap.add_argument("--owner", default=None,
                    help="agent id, agent-<id>, or a worktree path")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--transcript", default=None,
                    help="a session transcript; attaches teammate NAMES to ids")
    ap.add_argument("--format", choices=("triple", "json"), default="json")
    args = ap.parse_args(argv)

    if args.all or not args.owner:
        recs = enumerate_all(args.entity)
    else:
        recs = [resolve(args.entity, args.owner)]

    if args.transcript:
        n2i = names_to_ids(args.transcript)
        i2n = {}
        for n, i in n2i.items():
            i2n.setdefault(i, []).append(n)
        for r in recs:
            r["names"] = sorted(i2n.get(r.get("agent_id") or "", []))

    if args.format == "triple":
        for r in recs:
            print(_triple(r))
        return 0
    print(json.dumps(recs if (args.all or not args.owner) else recs[0], indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
