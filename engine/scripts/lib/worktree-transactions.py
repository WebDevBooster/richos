#!/usr/bin/env python3
"""worktree-transactions.py — THE DURABLE STATE OF A TEAMMATE'S WORKTREES,
FROM SPAWN INTENT TO REMOVAL. One record per agent, keyed by what the platform
already gives us and nothing invented: `session_id`, `tool_use_id`, `agent_id`.

===========================================================================
WHY THIS FILE EXISTS — seven designs were rejected before it
===========================================================================
Every earlier lifecycle tried to DISCOVER, after the fact, whether a worktree's
owner might still return: from a lock, from a roster, from a name, from a
transcript, from process absence. Every one of those was either a guess
(names and branch shapes are reusable; absence is not death) or evidence the
land itself destroyed (the native lock). The CEO's ruling ended the question:

    The system should stop trying to discover whether the agent might
    return. It is forbidden to return.

So ownership is RECORDED at the only moment it is certain — the spawn — bound
to the platform's own agent id before the worker may write a byte, and the
whole bound set is terminalized at the first terminal ingress. Nothing here
searches for something with a similar name. Specification:
femcboost `docs/plans/worktree-real-fix-2026-09-03.md`.

===========================================================================
THE RECORD, ON DISK
===========================================================================
    <root>/<session_id>/intents/<tool_use_id>.json   spawn-intent  (PreToolUse[Agent])
    <root>/<session_id>/bound/<agent_id>.json        bound          (PostToolUse[Agent])
    <root>/<session_id>/starts/<agent_id>.json       start fact     (SubagentStart)
    <root>/<session_id>/<agent_id>.json              THE TRANSACTION (sealed -> terminal -> removed)
    <root>/<session_id>/<agent_id>.lock              flock — kernel-released, never stranded
    <root>/terminal/<agent_id>                       index: this agent id is terminal, forever
    <root>/terminal-names/<session_id>/<teammate>    index: this session's name is terminal

    <root> = $RICHOS_WORKTREE_TX_DIR, default ~/.claude/state/worktree-transactions

Every write is temp file -> fsync -> atomic rename -> directory fsync. A
transaction's member states advance one at a time, each persisted immediately
after the member operation, so recovery after a crash at ANY boundary is a
read of what exists on disk plus the ONE idempotent transition that follows.

===========================================================================
THE STATE MACHINE, PER MEMBER
===========================================================================
    bound -> ref_saved -> quarantined -> captured -> verified -> unregistered -> removed

    ref_saved     refs/richos/handoffs/<session_id>/<agent_id>/<branch> = HEAD
    quarantined   <path> renamed, same filesystem, to
                  <path>.richos-terminal-<session-id-prefix>-<agent_id>
    captured      raw bytes + index + provenance archived (the reconciler)
    verified      the archive re-read and every digest matched
    unregistered  git no longer lists the worktree
    removed       the quarantine directory is gone

Two terminal ingresses — SubagentStop (by agent id) and WorktreeRemove (by the
exact native path) — race for ONE compare-and-set claim on the transaction.
Exactly one wins; the loser resumes the already-started transaction
idempotently. Neither waits for the other and no ordering is assumed.

A member whose recovery finds BOTH the original and the quarantine present,
or whose provenance disagrees with git, is `failed`: refused, reported, and
COUNTED as dead-present. It is never resolved by looking for a similar name.

===========================================================================
WHAT IS NOT HERE, DELIBERATELY
===========================================================================
No liveness inference. No name lookup. No lead acceptance. No feature flag
that turns cleanup off. `TeammateIdle` and `TaskCompleted` are not read.
"""

import errno
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

MEMBER_STATES = ("bound", "ref_saved", "quarantined", "captured", "verified",
                 "unregistered", "removed")
TERMINAL_STATES = ("failed", "missing")

AGENT_ID_RE = re.compile(r"^[A-Za-z0-9_-]{6,64}$")
SAFE_SEGMENT_RE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")


# --------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------

def tx_root():
    return ((os.environ.get("RICHOS_WORKTREE_TX_DIR") or "").strip()
            or os.path.join(os.path.expanduser("~"), ".claude", "state", "worktree-transactions"))


def capture_root():
    return ((os.environ.get("RICHOS_WORKTREE_CAPTURE_DIR") or "").strip()
            or os.path.join(os.path.expanduser("~"), ".claude", "state", "worktree-captures"))


def _seg(value, what):
    v = (value or "").strip()
    if not v or not SAFE_SEGMENT_RE.match(v) or v in (".", ".."):
        raise ValueError("%s is not a safe path segment: %r" % (what, value))
    return v


def session_dir(session_id):
    return os.path.join(tx_root(), _seg(session_id, "session_id"))


def intent_path(session_id, tool_use_id):
    return os.path.join(session_dir(session_id), "intents", _seg(tool_use_id, "tool_use_id") + ".json")


def bound_path(session_id, agent_id):
    return os.path.join(session_dir(session_id), "bound", _seg(agent_id, "agent_id") + ".json")


def start_path(session_id, agent_id):
    return os.path.join(session_dir(session_id), "starts", _seg(agent_id, "agent_id") + ".json")


def tx_path(session_id, agent_id):
    return os.path.join(session_dir(session_id), _seg(agent_id, "agent_id") + ".json")


def lock_path(session_id, agent_id):
    return os.path.join(session_dir(session_id), _seg(agent_id, "agent_id") + ".lock")


def terminal_index_path(agent_id):
    return os.path.join(tx_root(), "terminal", _seg(agent_id, "agent_id"))


def terminal_name_path(session_id, teammate):
    return os.path.join(tx_root(), "terminal-names", _seg(session_id, "session_id"), _seg(teammate, "teammate"))


def now_iso():
    return datetime.now(timezone.utc).isoformat()


# --------------------------------------------------------------------------
# durable writes
# --------------------------------------------------------------------------

def _fsync_dir(path):
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def atomic_write_json(path, obj):
    """temp file -> fsync -> rename -> directory fsync. Raises on failure."""
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = "%s.tmp.%d.%d" % (path, os.getpid(), int(time.time() * 1000000))
    data = json.dumps(obj, sort_keys=True, indent=1) + "\n"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    _fsync_dir(d)


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def touch_marker(path, content=""):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)
    _fsync_dir(d)


class tx_lock(object):
    """Process exclusion per (session, agent). Kernel-released on exit or
    crash — a stranded mkdir lock was finding 8 of the archiver review."""

    def __init__(self, session_id, agent_id, timeout=30.0):
        self.path = lock_path(session_id, agent_id)
        self.timeout = timeout
        self.fd = None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        deadline = time.time() + self.timeout
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError as e:
                if e.errno not in (errno.EAGAIN, errno.EACCES):
                    raise
                if time.time() >= deadline:
                    raise RuntimeError("could not lock %s within %ss" % (self.path, self.timeout))
                time.sleep(0.05)

    def __exit__(self, *exc):
        try:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
        finally:
            os.close(self.fd)
            self.fd = None
        return False


# --------------------------------------------------------------------------
# git helpers — small, exact, never guessing
# --------------------------------------------------------------------------

def norm_path(p):
    p = (p or "").strip().rstrip("/")
    if not p:
        return ""
    try:
        return os.path.realpath(p)
    except Exception:
        return p


def _git(cwd, *args, timeout=30):
    try:
        res = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True,
                             text=True, timeout=timeout)
    except Exception as e:
        return 1, "", str(e)
    return res.returncode, res.stdout, res.stderr


def worktree_toplevel(path):
    rc, out, _ = _git(path, "rev-parse", "--show-toplevel")
    return norm_path(out.strip()) if rc == 0 and out.strip() else ""


def main_checkout_of(path):
    """The FIRST `worktree` line of `git worktree list --porcelain` is the main
    working tree, wherever the query is run from."""
    rc, out, _ = _git(path, "worktree", "list", "--porcelain")
    if rc != 0:
        return ""
    for line in out.splitlines():
        if line.startswith("worktree "):
            return norm_path(line[len("worktree "):])
    return ""


def is_linked_worktree(path):
    rc1, common, _ = _git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")
    rc2, gitdir, _ = _git(path, "rev-parse", "--path-format=absolute", "--git-dir")
    if rc1 != 0 or rc2 != 0:
        return False
    return norm_path(common.strip()) != norm_path(gitdir.strip())


def registered_worktrees(repo):
    """{realpath: {"branch": ..., "head": ..., "locked": line|None, "prunable": bool}}"""
    rc, out, _ = _git(repo, "worktree", "list", "--porcelain")
    if rc != 0:
        return None
    entries = {}
    cur = None
    for line in out.splitlines():
        if line.startswith("worktree "):
            cur = {"branch": "", "head": "", "locked": None, "prunable": False}
            entries[norm_path(line[len("worktree "):])] = cur
        elif cur is None:
            continue
        elif line.startswith("branch refs/heads/"):
            cur["branch"] = line[len("branch refs/heads/"):]
        elif line.startswith("HEAD "):
            cur["head"] = line[len("HEAD "):].strip()
        elif line.startswith("locked"):
            cur["locked"] = line
        elif line.startswith("prunable"):
            cur["prunable"] = True
    return entries


def branch_of(path):
    rc, out, _ = _git(path, "symbolic-ref", "-q", "--short", "HEAD")
    return out.strip() if rc == 0 else ""


def head_of(path):
    rc, out, _ = _git(path, "rev-parse", "HEAD")
    return out.strip() if rc == 0 else ""


# --------------------------------------------------------------------------
# phase 2 — spawn intent
# --------------------------------------------------------------------------

def write_intent(session_id, tool_use_id, intent):
    """The complete exact member set a spawn PROPOSES. Authorizes nothing until
    an Agent result binds it to an agent id."""
    rec = dict(intent)
    rec.update({"record": "spawn-intent", "session_id": session_id,
                "tool_use_id": tool_use_id, "ts": now_iso()})
    atomic_write_json(intent_path(session_id, tool_use_id), rec)
    return rec


def read_intent(session_id, tool_use_id):
    return read_json(intent_path(session_id, tool_use_id))


# --------------------------------------------------------------------------
# phase 3 — bind the platform agent id to the intent
# --------------------------------------------------------------------------

def bind(session_id, tool_use_id, agent_id, source):
    """bound(session_id, tool_use_id, agent_id, exact members). Raises when
    there is no intent to bind — a binder that invents a member set is the
    best-effort registration this replaces."""
    if not AGENT_ID_RE.match(agent_id or ""):
        raise ValueError("not an agent id: %r" % (agent_id,))
    intent = read_intent(session_id, tool_use_id)
    if not intent:
        raise LookupError("no spawn-intent for session %s tool_use %s" % (session_id, tool_use_id))
    existing = read_json(bound_path(session_id, agent_id))
    if existing and existing.get("tool_use_id") not in (None, tool_use_id):
        raise RuntimeError("agent %s is already bound to tool_use %s, refusing to rebind to %s"
                           % (agent_id, existing.get("tool_use_id"), tool_use_id))
    rec = dict(intent)
    rec.update({"record": "bound", "agent_id": agent_id, "bound_ts": now_iso(),
                "bound_source": source})
    atomic_write_json(bound_path(session_id, agent_id), rec)
    return rec


def read_bound(session_id, agent_id):
    return read_json(bound_path(session_id, agent_id))


# --------------------------------------------------------------------------
# phase 4 — the start fact, and the seal
# --------------------------------------------------------------------------

def record_start(session_id, agent_id, cwd, agent_type="", transcript=""):
    rec = {"record": "start", "session_id": session_id, "agent_id": agent_id,
           "cwd": cwd or "", "cwd_real": norm_path(cwd) if cwd else "",
           "agent_type": agent_type or "", "agent_transcript_path": transcript or "",
           "ts": now_iso()}
    atomic_write_json(start_path(session_id, agent_id), rec)
    return rec


def read_start(session_id, agent_id):
    return read_json(start_path(session_id, agent_id))


def load_tx(session_id, agent_id):
    try:
        return read_json(tx_path(session_id, agent_id))
    except ValueError:
        return None


def is_sealed(session_id, agent_id):
    tx = load_tx(session_id, agent_id)
    return bool(tx and tx.get("sealed"))


def _verify_native_member(cwd_real, agent_id):
    """The native isolation worktree, resolved from the SubagentStart cwd plus
    platform metadata and verified against git. Never invented from a name."""
    want_base = "agent-" + agent_id
    if os.path.basename(cwd_real) != want_base:
        return None, ("SubagentStart cwd %s is not the native isolation worktree agent-%s"
                      % (cwd_real, agent_id))
    if not os.path.isdir(cwd_real):
        return None, "SubagentStart cwd %s does not exist" % cwd_real
    top = worktree_toplevel(cwd_real)
    if top != cwd_real:
        return None, "SubagentStart cwd %s is not the top level of a git worktree (%s)" % (cwd_real, top or "?")
    if not is_linked_worktree(cwd_real):
        return None, "SubagentStart cwd %s is a main checkout, not a linked worktree" % cwd_real
    repo = main_checkout_of(cwd_real)
    reg = registered_worktrees(repo) if repo else None
    if not reg or cwd_real not in reg:
        return None, "git does not list %s as a worktree of %s" % (cwd_real, repo or "?")
    return {"class": "native", "repo": repo, "path": cwd_real,
            "branch": reg[cwd_real].get("branch") or branch_of(cwd_real),
            "head_at_seal": reg[cwd_real].get("head") or head_of(cwd_real),
            "state": "bound"}, ""


def _verify_external_member(m):
    """A prepared external member must STILL be what the prepared record said."""
    p = norm_path(m.get("path"))
    if not os.path.isdir(p):
        return None, "external member %s does not exist" % p
    if worktree_toplevel(p) != p:
        return None, "external member %s is not the top level of a git worktree" % p
    repo = main_checkout_of(p)
    if norm_path(m.get("repo")) != repo:
        return None, ("external member %s belongs to %s, not the prepared repository %s"
                      % (p, repo, m.get("repo")))
    br = branch_of(p)
    if (m.get("branch") or "") != br:
        return None, ("external member %s is on branch %r, not the prepared branch %r"
                      % (p, br, m.get("branch")))
    return {"class": "hand-rolled", "repo": repo, "path": p, "branch": br,
            "head_at_seal": head_of(p), "state": "bound"}, ""


def try_seal(session_id, agent_id):
    """(sealed, tx_or_reason). Transaction-locked. Both facts — the bound
    record from the parent's PostToolUse[Agent] and the start record from the
    worker's own SubagentStart — must exist; they may arrive in either order."""
    with tx_lock(session_id, agent_id):
        tx = load_tx(session_id, agent_id)
        if tx and tx.get("sealed"):
            return True, tx
        bound = read_bound(session_id, agent_id)
        start = read_start(session_id, agent_id)
        if not bound and not start:
            return False, "neither the bound record nor the start record exists for agent %s" % agent_id
        if not bound:
            return False, ("no bound record for agent %s (the parent's PostToolUse[Agent] has not bound "
                           "a spawn-intent to this agent id yet)" % agent_id)
        if not start:
            return False, "no start record for agent %s (SubagentStart has not fired for it yet)" % agent_id
        if start.get("agent_id") != agent_id or bound.get("agent_id") != agent_id:
            return False, "agent id mismatch between the bound record and the start record"

        members = []
        kind = bound.get("kind") or ""
        cwd_real = start.get("cwd_real") or norm_path(start.get("cwd"))
        if kind not in ("native", "native+external", "cwd", "main-checkout-run", "remote"):
            return False, "unknown spawn kind %r in the bound record" % kind
        if kind in ("native", "native+external"):
            nat, why = _verify_native_member(cwd_real, agent_id)
            if nat is None:
                return False, why
            members.append(nat)
        externals = bound.get("externals") or []
        if kind in ("cwd", "native+external"):
            if not externals:
                return False, "kind %s with no prepared external members" % kind
            if kind == "cwd":
                prepared_paths = {norm_path(e.get("path")) for e in externals}
                if cwd_real not in prepared_paths:
                    return False, ("SubagentStart cwd %s is not one of the prepared external members %s"
                                   % (cwd_real, sorted(prepared_paths)))
            for e in externals:
                ext, why = _verify_external_member(e)
                if ext is None:
                    return False, why
                members.append(ext)
        # main-checkout-run and remote: no local member is owned by this worker.

        tx = {
            "record": "transaction",
            "session_id": session_id,
            "agent_id": agent_id,
            "tool_use_id": bound.get("tool_use_id"),
            "teammate": bound.get("teammate") or "",
            "subagent_type": bound.get("subagent_type") or "",
            "kind": kind,
            "members": members,
            "sealed": True,
            "sealed_ts": now_iso(),
            "state": "sealed",
            "start_cwd": cwd_real,
            "terminal": None,
        }
        atomic_write_json(tx_path(session_id, agent_id), tx)
        return True, tx


# --------------------------------------------------------------------------
# terminalization — the compare-and-set claim
# --------------------------------------------------------------------------

def claim_terminal(session_id, agent_id, ingress, detail=""):
    """(won, tx). Exactly one caller wins the claim on a sealed transaction;
    every later caller gets (False, tx) and resumes idempotently. An unsealed
    or unknown agent is (False, None): nothing bound, nothing to terminalize."""
    with tx_lock(session_id, agent_id):
        tx = load_tx(session_id, agent_id)
        if not tx or not tx.get("sealed"):
            return False, None
        if tx.get("terminal"):
            return False, tx
        tx["terminal"] = {"ingress": ingress, "detail": detail, "ts": now_iso()}
        tx["state"] = "terminal"
        atomic_write_json(tx_path(session_id, agent_id), tx)
        # The two indexes the resume guard and the barrier read in O(1).
        touch_marker(terminal_index_path(agent_id), session_id + "\n")
        if tx.get("teammate"):
            try:
                touch_marker(terminal_name_path(session_id, tx["teammate"]), agent_id + "\n")
            except ValueError:
                pass
        return True, tx


def is_terminal_agent(agent_id):
    try:
        return os.path.isfile(terminal_index_path(agent_id))
    except ValueError:
        return False


def is_terminal_name(session_id, teammate):
    try:
        return os.path.isfile(terminal_name_path(session_id, teammate))
    except ValueError:
        return False


def find_by_native_path(session_id, path):
    """The agent id whose SEALED transaction in this session contains this
    exact native path as a member. Exact path only, never a name."""
    want = norm_path(path)
    if not want:
        return ""
    try:
        sd = session_dir(session_id)
    except ValueError:
        return ""
    try:
        names = os.listdir(sd)
    except OSError:
        return ""
    for n in names:
        if not n.endswith(".json"):
            continue
        tx = read_json(os.path.join(sd, n))
        if not tx or not tx.get("sealed"):
            continue
        for m in tx.get("members") or []:
            if m.get("class") == "native" and norm_path(m.get("path")) == want:
                return tx.get("agent_id") or ""
            # The quarantine name is also an exact identity of the same member.
            if norm_path(m.get("quarantine") or "") == want:
                return tx.get("agent_id") or ""
    return ""


def update_member(session_id, agent_id, index, **fields):
    """Persist ONE member transition. Called under tx_lock by the caller."""
    tx = load_tx(session_id, agent_id)
    if not tx:
        raise LookupError("no transaction for %s/%s" % (session_id, agent_id))
    m = tx["members"][index]
    m.update(fields)
    m["ts"] = now_iso()
    if all(x.get("state") == "removed" for x in tx["members"]):
        tx["state"] = "removed"
        tx["removed_ts"] = now_iso()
    atomic_write_json(tx_path(session_id, agent_id), tx)
    return tx


def bound_members(session_id, agent_id):
    """The AUTHORITATIVE member list for a destructive caller: the sealed
    transaction's members, or nothing. There is no fallback."""
    tx = load_tx(session_id, agent_id)
    if not tx or not tx.get("sealed"):
        return []
    return list(tx.get("members") or [])


def quarantine_name(path, session_id, agent_id):
    return "%s.richos-terminal-%s-%s" % (path.rstrip("/"), session_id[:8], agent_id)


def backup_ref(session_id, agent_id, branch):
    return "refs/richos/handoffs/%s/%s/%s" % (session_id, agent_id, branch or "detached")


# --------------------------------------------------------------------------
# the two transitions the terminal ingress performs synchronously
# --------------------------------------------------------------------------

def save_ref(session_id, agent_id, index):
    """bound -> ref_saved. Idempotent: the HEAD is read from whichever of the
    original or the quarantine exists."""
    tx = load_tx(session_id, agent_id)
    m = tx["members"][index]
    if m.get("state") != "bound":
        return tx
    orig = m["path"]
    quar = m.get("quarantine") or quarantine_name(orig, session_id, agent_id)
    src = orig if os.path.isdir(orig) else (quar if os.path.isdir(quar) else "")
    if not src:
        return update_member(session_id, agent_id, index, state="missing",
                             error="neither %s nor %s exists" % (orig, quar))
    head = head_of(src)
    if not head:
        return update_member(session_id, agent_id, index, state="failed",
                             error="could not read HEAD of %s" % src)
    ref = backup_ref(session_id, agent_id, m.get("branch"))
    rc, _, err = _git(m["repo"], "update-ref", ref, head)
    if rc != 0:
        return update_member(session_id, agent_id, index, state="failed",
                             error="update-ref %s failed: %s" % (ref, err.strip()[:200]))
    return update_member(session_id, agent_id, index, state="ref_saved",
                         backup_ref=ref, head=head, quarantine=quar)


def quarantine(session_id, agent_id, index):
    """ref_saved -> quarantined. A same-filesystem atomic rename beside the
    original. Both present -> failed; neither -> missing; never a search."""
    tx = load_tx(session_id, agent_id)
    m = tx["members"][index]
    if m.get("state") != "ref_saved":
        return tx
    orig = m["path"]
    quar = m.get("quarantine") or quarantine_name(orig, session_id, agent_id)
    o, q = os.path.isdir(orig), os.path.isdir(quar)
    if o and q:
        return update_member(session_id, agent_id, index, state="failed",
                             error="both %s and %s exist; refusing to choose" % (orig, quar))
    if not o and not q:
        return update_member(session_id, agent_id, index, state="missing",
                             error="neither %s nor %s exists" % (orig, quar))
    if o:
        try:
            os.rename(orig, quar)
        except OSError as e:
            return update_member(session_id, agent_id, index, state="failed",
                                 error="rename %s -> %s failed: %s" % (orig, quar, e))
        _fsync_dir(os.path.dirname(orig))
    # RE-POINT GIT AT THE QUARANTINE. After a raw rename the repository's
    # registration still names the ORIGINAL path and is "prunable"; the
    # harness's own cleanup (or anyone's `git worktree prune`) would then
    # delete the admin directory the quarantine's `.git` file points at, and
    # every later git read of the quarantine (index, status, HEAD) would fail.
    # `git worktree repair <new path>` rewrites the admin pointer to the
    # quarantine (measured: rc 0, "repair: gitdir incorrect" is its normal
    # output), so the registration is valid again and the branch stays
    # checked out here — which also makes the harness's `branch -D` refuse.
    _git(m["repo"], "worktree", "repair", quar)
    return update_member(session_id, agent_id, index, state="quarantined", quarantine=quar)


def terminalize(session_id, agent_id, first_path=None):
    """ONE MEMBER AT A TIME, the named native path first: save its ref,
    quarantine it, persist — and only then touch the next member.

    The path the ingress named (a WorktreeRemove's exact native path) ranks
    first, else the native member, then every external member. Called by the
    winner AND the loser: every step is idempotent on the persisted state.

    WHY PER-MEMBER AND NOT TWO PASSES (review 2026-09-03, blocker 1): the
    WorktreeRemove hook has a 20-second budget and any git subprocess may take
    up to its 30-second timeout. Two passes — save every ref, THEN quarantine
    every member — put an external repository's `rev-parse`/`update-ref`
    BEFORE the native rename. A stalled external repository then exhausted
    the hook budget with the native path still at its original name, and
    Claude Code deleted that path, with every unstaged and untracked byte in
    it, on the strength of a hook that had merely run out of time. The
    native member is the one the platform is about to destroy, so nothing
    from any other repository runs until it is renamed and its transition is
    on disk. worktree-transactions.test.sh T51 stalls an external repository
    past a simulated hook kill and asserts the native quarantine survived."""
    tx = load_tx(session_id, agent_id)
    if not tx or not tx.get("terminal"):
        return tx
    order = list(range(len(tx["members"])))
    first = norm_path(first_path) if first_path else ""

    def rank(i):
        m = tx["members"][i]
        if first and norm_path(m.get("path")) == first:
            return 0
        return 1 if m.get("class") == "native" else 2

    order.sort(key=rank)
    with tx_lock(session_id, agent_id):
        for i in order:
            save_ref(session_id, agent_id, i)
            quarantine(session_id, agent_id, i)
        return load_tx(session_id, agent_id)


# --------------------------------------------------------------------------
# inventory
# --------------------------------------------------------------------------

def iter_transactions():
    root = tx_root()
    try:
        sessions = sorted(os.listdir(root))
    except OSError:
        return
    for s in sessions:
        sd = os.path.join(root, s)
        if not os.path.isdir(sd) or s in ("terminal", "terminal-names"):
            continue
        try:
            names = sorted(os.listdir(sd))
        except OSError:
            continue
        for n in names:
            if n.endswith(".json"):
                tx = read_json(os.path.join(sd, n))
                if tx and tx.get("record") == "transaction":
                    yield tx


def member_present(m):
    return os.path.isdir(m.get("path") or "") or os.path.isdir(m.get("quarantine") or "")


def metrics():
    """The definition of done. No dead directory is omitted from the
    denominator: a failed member with a directory present is counted."""
    out = {"transactions": 0, "sealed_live": 0, "terminal": 0, "removed": 0,
           "terminal_members": 0, "terminal_members_present": 0,
           "pending_retry": 0, "failed": 0, "failed_present": 0}
    for tx in iter_transactions():
        out["transactions"] += 1
        if not tx.get("terminal"):
            out["sealed_live"] += 1
            continue
        out["terminal"] += 1
        if tx.get("state") == "removed":
            out["removed"] += 1
        for m in tx.get("members") or []:
            out["terminal_members"] += 1
            present = member_present(m)
            st = m.get("state")
            if present:
                out["terminal_members_present"] += 1
            if st in TERMINAL_STATES:
                out["failed"] += 1
                if present:
                    out["failed_present"] += 1
            elif st != "removed":
                out["pending_retry"] += 1
    return out


# --------------------------------------------------------------------------
# CLI — thin; every hook drives the module through it or by import
# --------------------------------------------------------------------------

def _main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="worktree-transactions.py")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("root")

    p = sub.add_parser("intent", help="write a spawn-intent (JSON on stdin)")
    p.add_argument("--session-id", required=True)
    p.add_argument("--tool-use-id", required=True)

    p = sub.add_parser("bind")
    p.add_argument("--session-id", required=True)
    p.add_argument("--tool-use-id", required=True)
    p.add_argument("--agent-id", required=True)
    p.add_argument("--source", default="cli")

    p = sub.add_parser("start")
    p.add_argument("--session-id", required=True)
    p.add_argument("--agent-id", required=True)
    p.add_argument("--cwd", required=True)
    p.add_argument("--agent-type", default="")
    p.add_argument("--transcript", default="")

    p = sub.add_parser("seal")
    p.add_argument("--session-id", required=True)
    p.add_argument("--agent-id", required=True)

    p = sub.add_parser("sealed")
    p.add_argument("--session-id", required=True)
    p.add_argument("--agent-id", required=True)

    p = sub.add_parser("claim")
    p.add_argument("--session-id", required=True)
    p.add_argument("--agent-id", required=True)
    p.add_argument("--ingress", required=True)
    p.add_argument("--detail", default="")
    p.add_argument("--first-path", default="")

    p = sub.add_parser("terminal-agent")
    p.add_argument("--agent-id", required=True)

    p = sub.add_parser("terminal-name")
    p.add_argument("--session-id", required=True)
    p.add_argument("--teammate", required=True)

    p = sub.add_parser("by-native-path")
    p.add_argument("--session-id", required=True)
    p.add_argument("--path", required=True)

    p = sub.add_parser("show")
    p.add_argument("--session-id", required=True)
    p.add_argument("--agent-id", required=True)

    p = sub.add_parser("members")
    p.add_argument("--session-id", required=True)
    p.add_argument("--agent-id", required=True)

    p = sub.add_parser("metrics")
    p = sub.add_parser("list")

    a = ap.parse_args(argv)
    if a.cmd == "root":
        print(tx_root()); return 0
    if a.cmd == "intent":
        rec = write_intent(a.session_id, a.tool_use_id, json.load(sys.stdin))
        print(json.dumps(rec, sort_keys=True)); return 0
    if a.cmd == "bind":
        rec = bind(a.session_id, a.tool_use_id, a.agent_id, a.source)
        print(json.dumps(rec, sort_keys=True)); return 0
    if a.cmd == "start":
        rec = record_start(a.session_id, a.agent_id, a.cwd, a.agent_type, a.transcript)
        print(json.dumps(rec, sort_keys=True)); return 0
    if a.cmd == "seal":
        ok, res = try_seal(a.session_id, a.agent_id)
        print(json.dumps(res if ok else {"sealed": False, "reason": res}, sort_keys=True))
        return 0 if ok else 1
    if a.cmd == "sealed":
        return 0 if is_sealed(a.session_id, a.agent_id) else 1
    if a.cmd == "claim":
        won, tx = claim_terminal(a.session_id, a.agent_id, a.ingress, a.detail)
        if tx is None:
            print(json.dumps({"claimed": False, "reason": "no sealed transaction"})); return 3
        tx = terminalize(a.session_id, a.agent_id, a.first_path or None)
        print(json.dumps({"claimed": won, "transaction": tx}, sort_keys=True))
        return 0 if won else 2
    if a.cmd == "terminal-agent":
        return 0 if is_terminal_agent(a.agent_id) else 1
    if a.cmd == "terminal-name":
        return 0 if is_terminal_name(a.session_id, a.teammate) else 1
    if a.cmd == "by-native-path":
        aid = find_by_native_path(a.session_id, a.path)
        print(aid); return 0 if aid else 1
    if a.cmd == "show":
        tx = load_tx(a.session_id, a.agent_id)
        print(json.dumps(tx, sort_keys=True, indent=1)); return 0 if tx else 1
    if a.cmd == "members":
        for m in bound_members(a.session_id, a.agent_id):
            print("%s\t%s\t%s\t%s\t%s" % (m.get("class"), m.get("repo"), m.get("path"),
                                          m.get("branch"), m.get("state")))
        return 0
    if a.cmd == "metrics":
        print(json.dumps(metrics(), sort_keys=True)); return 0
    if a.cmd == "list":
        for tx in iter_transactions():
            print("%s\t%s\t%s\t%s\t%s" % (tx.get("session_id"), tx.get("agent_id"), tx.get("teammate"),
                                          tx.get("state"), ",".join(m.get("state") or "" for m in tx.get("members") or [])))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
