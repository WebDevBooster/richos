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

The terminal ingresses — SubagentStop (by its OWN agent id, never a cwd),
WorktreeRemove (by the exact native path), a successful TaskStop (by the
task id its RESULT returned) and the reconciler's NativeMemberGone (the
sealed native member verified absent or unregistered) — race for ONE
compare-and-set claim on the transaction. Exactly one wins; every later
one resumes the already-started transaction idempotently. None waits for
another and no ordering is assumed.

NO MEMBER STATE WAITS FOR A PERSON (landed review 2026-09-03, blocker 3).
Both original and quarantine present: the quarantine (its name embeds the
session prefix and the agent id) advances, and the original is left for the
reconciler to archive, verify and reclaim as residue — or to leave alone
when git registers it as another worktree. Neither present: closed absent,
the backup ref re-created from the recorded head while the commit object
survives. A transient git failure: recorded on the member and retried with
persistent backoff. Nothing is ever resolved by looking for a similar name.

===========================================================================
WHAT IS NOT HERE, DELIBERATELY
===========================================================================
No liveness inference. No name lookup. No lead acceptance. No feature flag
that turns cleanup off. `TeammateIdle` (its payload unmeasured on this
platform) and `TaskCompleted` hold no authority here.
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


def pending_terminal_path(session_id, agent_id):
    """A terminal event that arrived BEFORE the manifest sealed (review
    2026-09-03, blocker 4). Keyed by (session_id, agent_id); consumed when the
    manifest later seals, or routed through the reconciler's creation-time
    cleanup after PENDING_TERMINAL_GRACE_SECONDS."""
    return os.path.join(session_dir(session_id), "pending-terminal", _seg(agent_id, "agent_id") + ".json")


def now_iso():
    return datetime.now(timezone.utc).isoformat()


# --------------------------------------------------------------------------
# durable writes
# --------------------------------------------------------------------------

# THE ONE NARROW PORTABILITY EXCEPTION for the directory fsync (landed review
# 2026-09-03, blocker 6). These errnos are a filesystem's statement that a
# directory descriptor HAS no fsync — EINVAL is the documented answer of a
# descriptor type that cannot be synced (seen on some network and FUSE mounts),
# ENOTSUP/EOPNOTSUPP the FUSE spelling of the same statement. They are the
# only errors swallowed, and they are swallowed with a notice. EIO, ENOSPC,
# EBADF, EACCES, ENOENT and every other error mean the sync FAILED, and are
# raised: the caller was promised durability and must not be told it got it.
_DIR_FSYNC_UNSUPPORTED = frozenset(
    x for x in (errno.EINVAL, getattr(errno, "ENOTSUP", None), getattr(errno, "EOPNOTSUPP", None))
    if x is not None)
_dir_fsync_unsupported_noted = set()


def _fsync_dir(path):
    """Make the rename that just landed in `path` durable, or RAISE.

    Until this revision every error here — opening the directory AND syncing
    it — was swallowed, while atomic_write_json documented "temp file, fsync,
    rename, directory fsync; raises on failure". A terminal claim reported
    durable could therefore vanish after a crash, because the directory entry
    naming it was never forced to disk (landed review 2026-09-03, blocker 6).

    THE WEAKER GUARANTEE ON A FILESYSTEM THAT CANNOT SYNC A DIRECTORY (the
    errnos in _DIR_FSYNC_UNSUPPORTED, and only those): the rename is still
    atomic — a reader sees the old record or the new, never a torn one — and
    the file's own bytes were fsynced; what is NOT guaranteed is that the new
    directory entry survives a crash or power loss before the filesystem's
    own metadata flush. On such a mount a claim can be lost to a crash in
    that window and is re-made by the next ingress or reconciler pass. The
    exception is announced once per process on stderr, naming the mount and
    the errno, so it is never silent."""
    fd = os.open(path, os.O_RDONLY)
    try:
        try:
            os.fsync(fd)
        except OSError as e:
            if e.errno in _DIR_FSYNC_UNSUPPORTED:
                if path not in _dir_fsync_unsupported_noted:
                    _dir_fsync_unsupported_noted.add(path)
                    sys.stderr.write("worktree-transactions: NOTICE: %s cannot fsync a directory (errno %d %s); "
                                     "renames there are atomic but not crash-durable until the filesystem flushes "
                                     "its own metadata. Every other write here is fully durable.\n"
                                     % (path, e.errno, errno.errorcode.get(e.errno, "?")))
                return
            raise
    finally:
        os.close(fd)


def atomic_write_json(path, obj):
    """temp file -> fsync -> rename -> directory fsync. Raises on failure —
    including on a failed directory fsync (blocker 6): by then the rename has
    landed, so the record IS on disk, but it is not durable, and the caller is
    told so by the exception rather than told it succeeded. Every caller is
    idempotent on a re-read of what exists, so a retry converges."""
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
    """(sealed, tx_or_reason). Both facts — the bound record from the parent's
    PostToolUse[Agent] and the start record from the worker's own
    SubagentStart — must exist; they may arrive in either order.

    A PENDING TERMINAL EVENT IS CONSUMED HERE (review 2026-09-03, blocker 4):
    if the agent's only terminal event arrived before the manifest could seal,
    the seal is immediately followed by the claim and the terminalization it
    would have triggered, and the returned transaction is terminal. The
    caller that sealed a dead agent's manifest learns it is dead."""
    sealed, res = _try_seal_locked(session_id, agent_id)
    if sealed:
        res = _consume_pending_terminal(session_id, agent_id, res)
    return sealed, res


def _consume_pending_terminal(session_id, agent_id, tx):
    """Outside the seal lock (claim_terminal and terminalize take it
    themselves). Idempotent: a pending record with a terminal transaction
    behind it is simply removed."""
    p = read_pending_terminal(session_id, agent_id)
    if not p:
        return tx
    if not tx.get("terminal"):
        won, t2 = claim_terminal(session_id, agent_id, p.get("ingress") or "SubagentStop",
                                 detail=p.get("detail") or "", via_pending=p)
        if t2 is not None:
            tx = terminalize(session_id, agent_id, p.get("first_path") or None) or t2
    if tx.get("terminal"):
        try:
            os.unlink(pending_terminal_path(session_id, agent_id))
        except OSError:
            pass
    return tx


def _try_seal_locked(session_id, agent_id):
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

def _crash_point(name):
    """TEST-ONLY crash injection (review 2026-09-03, blocker 5): with
    RICHOS_TX_CRASH_AFTER=<name> the process dies — no cleanup, no further
    writes — immediately after the named write. The three points in
    claim_terminal are `tx`, `index` and `name`; worktree-transactions.test.sh
    T55–T57 crash at each and prove the agent still reads as terminal and the
    indexes are repaired by the next ingress or reconciler pass."""
    if (os.environ.get("RICHOS_TX_CRASH_AFTER") or "") == name:
        os._exit(137)


def _repair_terminal_indexes(tx):
    """The TRANSACTION is the source of truth for terminal state; the two
    marker files are derived indexes the guards read in O(1). Any caller that
    holds a terminal transaction repairs them, idempotently — a crash between
    the transaction write and either index write (blocker 5) is healed by the
    next claim, the next ingress, the next barrier evaluation that reaches the
    transaction, or the next reconciler pass, whichever comes first."""
    if not tx or not tx.get("terminal"):
        return
    sid = tx.get("session_id") or ""
    aid = tx.get("agent_id") or ""
    try:
        p = terminal_index_path(aid)
        if not os.path.isfile(p):
            touch_marker(p, sid + "\n")
    except ValueError:
        pass
    if tx.get("teammate") and sid:
        try:
            p = terminal_name_path(sid, tx["teammate"])
            if not os.path.isfile(p):
                touch_marker(p, aid + "\n")
        except ValueError:
            pass


def record_pending_terminal(session_id, agent_id, ingress, detail="", first_path=""):
    """Persist an attributable terminal event for an agent whose manifest is
    NOT sealed (review 2026-09-03, blocker 4). The FIRST event is the terminal
    one and is kept; a later one changes nothing. The agent-id index is
    written too: the first SubagentStop is terminal by policy, sealed or not,
    so the agent is forbidden to return from this moment and the barrier and
    the resume guard refuse it in O(1). Returns the record."""
    if not AGENT_ID_RE.match(agent_id or ""):
        raise ValueError("not an agent id: %r" % (agent_id,))
    p = pending_terminal_path(session_id, agent_id)
    existing = read_json(p)
    if existing:
        return existing
    rec = {"record": "pending-terminal", "session_id": session_id, "agent_id": agent_id,
           "ingress": ingress, "detail": detail, "first_path": first_path or "", "ts": now_iso(),
           "epoch": time.time()}
    atomic_write_json(p, rec)
    try:
        touch_marker(terminal_index_path(agent_id), session_id + "\n")
    except ValueError:
        pass
    return rec


def read_pending_terminal(session_id, agent_id):
    try:
        return read_json(pending_terminal_path(session_id, agent_id))
    except ValueError:
        return None


def claim_terminal(session_id, agent_id, ingress, detail="", via_pending=None):
    """(won, tx). Exactly one caller wins the claim on a sealed transaction;
    every later caller gets (False, tx) and resumes idempotently. An unsealed
    or unknown agent is (False, None) — and its terminal event is RECORDED as
    pending (blocker 4), never discarded: the manifest that seals later is
    terminalized at once, and one that never seals is routed through the
    reconciler's creation-time cleanup.

    ORDER OF WRITES, AND WHY EACH IS SURVIVABLE: the transaction's terminal
    record is written first and is the source of truth; the agent-id index and
    the session-scoped name index follow. A crash after any of the three
    leaves a transaction that reads as terminal from the transaction itself
    (is_terminal_agent consults it when the index is absent), and every later
    claim — including the losing ingress — repairs whichever index is missing."""
    with tx_lock(session_id, agent_id):
        tx = load_tx(session_id, agent_id)
        if not tx or not tx.get("sealed"):
            # ATTRIBUTABLE means this lifecycle has a fact about the agent — a
            # bound record (the lead meant to own something) or a start record
            # (the binder may still be on its way). An agent id nobody has
            # ever recorded is silence: a stop event about nobody.
            if AGENT_ID_RE.match(agent_id or "") and (read_bound(session_id, agent_id) or read_start(session_id, agent_id)):
                record_pending_terminal(session_id, agent_id, ingress, detail,
                                        first_path=(detail if ingress == "WorktreeRemove" else ""))
            return False, None
        if tx.get("terminal"):
            _repair_terminal_indexes(tx)
            return False, tx
        tx["terminal"] = {"ingress": ingress, "detail": detail, "ts": now_iso()}
        if via_pending:
            tx["terminal"]["via_pending"] = {"ts": via_pending.get("ts"), "ingress": via_pending.get("ingress")}
        tx["state"] = "terminal"
        atomic_write_json(tx_path(session_id, agent_id), tx)
        _crash_point("tx")
        # The two indexes the resume guard and the barrier read in O(1).
        touch_marker(terminal_index_path(agent_id), session_id + "\n")
        _crash_point("index")
        if tx.get("teammate"):
            try:
                touch_marker(terminal_name_path(session_id, tx["teammate"]), agent_id + "\n")
            except ValueError:
                pass
        _crash_point("name")
        return True, tx


def is_terminal_agent(agent_id, session_id=None):
    """Terminal by the index (O(1)), OR by the transaction itself when the
    index is absent or was never written (blocker 5). With a session id the
    lookup is exact; without one, every session's record for this EXACT agent
    id is consulted — an agent id is the platform's own identity, never a name.
    A transaction found terminal repairs its indexes on the way out."""
    try:
        if os.path.isfile(terminal_index_path(agent_id)):
            return True
    except ValueError:
        return False
    candidates = []
    if session_id:
        try:
            candidates.append(tx_path(session_id, agent_id))
        except ValueError:
            return False
    else:
        try:
            sessions = os.listdir(tx_root())
        except OSError:
            sessions = []
        for s in sessions:
            if s in ("terminal", "terminal-names"):
                continue
            try:
                candidates.append(tx_path(s, agent_id))
            except ValueError:
                continue
    for p in candidates:
        tx = read_json(p)
        if tx and tx.get("record") == "transaction" and tx.get("terminal"):
            _repair_terminal_indexes(tx)
            return True
        # A pending terminal event (unsealed at the time) is terminal by
        # policy too; its index write may have been lost to the same crash.
        pend = read_json(os.path.join(os.path.dirname(p), "pending-terminal", os.path.basename(p)))
        if pend and pend.get("record") == "pending-terminal":
            try:
                touch_marker(terminal_index_path(agent_id), (pend.get("session_id") or "") + "\n")
            except ValueError:
                pass
            return True
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


def find_unsealed_by_native_path(session_id, path):
    """The agent id an UNSEALED native worktree belongs to, for recording a
    pending terminal event (blocker 4) — never for a claim. The platform names
    its native isolation worktree `agent-<agent_id>`, so the basename IS the
    platform id; it is accepted only when this session holds a bound record
    or a start record for that EXACT id. A directory that merely looks like
    one, with no record behind it, resolves nothing."""
    want = norm_path(path)
    base = os.path.basename(want.rstrip("/")) if want else ""
    if not base.startswith("agent-"):
        return ""
    aid = base[len("agent-"):]
    if not AGENT_ID_RE.match(aid):
        return ""
    try:
        if read_bound(session_id, aid) or read_start(session_id, aid):
            return aid
    except ValueError:
        return ""
    return ""


def taskstop_result_id(tool_response):
    """The exact task id a SUCCESSFUL TaskStop result returned, or "".

    THE EXPLICIT-KILL INGRESS (CEO specification 2026-09-03, femcboost
    docs/plans/worktree-terminal-authority-fix-recommendation-2026-09-03.md,
    section 1). Measured on this machine 2026-09-03 (lead transcript, session
    df2b4fd1): the lead issued TaskStop with the REUSABLE teammate name
    ("zach-opus-b1") and the tool result was a JSON string —
        {"message": "Successfully stopped task: a5d5a2e681fa0f003 (...)",
         "task_id": "a5d5a2e681fa0f003", "task_type": "local_agent",
         "command": "..."}
    — whose task_id is exactly the transaction's ownership id, supplied by
    the platform after the task actually stopped. Nothing consumed it, and
    the killed worker's cross-repository worktree leaked.

    Accepted structured forms: a dict; a JSON string encoding a dict; a list
    of content blocks whose text encodes such a dict. The id comes from the
    structured `task_id` field ONLY — never from the human-readable message
    sentence, never from the request's task_id (the name). A result carrying
    an error marker, no structured task_id, or an id of the wrong shape
    resolves nothing: TaskStop may legitimately target an agent that owns no
    RichOS worktree, and a failed stop stops nothing."""
    obj = _structured_result(tool_response, 0)
    if not isinstance(obj, dict):
        return ""
    if obj.get("is_error") or obj.get("error") or obj.get("success") is False:
        return ""
    tid = obj.get("task_id")
    if not isinstance(tid, str) or not AGENT_ID_RE.match(tid):
        return ""
    return tid


def _structured_result(value, depth):
    if depth > 3:
        return None
    if isinstance(value, dict):
        if "task_id" not in value and value.get("type") == "text" and isinstance(value.get("text"), str):
            return _structured_result(value["text"], depth + 1)
        return value
    if isinstance(value, str):
        s = value.strip()
        if not s.startswith("{"):
            return None
        try:
            return _structured_result(json.loads(s), depth + 1)
        except ValueError:
            return None
    if isinstance(value, list):
        for item in value:
            r = _structured_result(item, depth + 1)
            if isinstance(r, dict) and "task_id" in r:
                return r
        return None
    return None


def iter_pending_terminals():
    """Every unconsumed pending terminal record, as (session_id, agent_id, record)."""
    root = tx_root()
    try:
        sessions = sorted(os.listdir(root))
    except OSError:
        return
    for s in sessions:
        pd = os.path.join(root, s, "pending-terminal")
        if s in ("terminal", "terminal-names") or not os.path.isdir(pd):
            continue
        try:
            names = sorted(os.listdir(pd))
        except OSError:
            continue
        for n in names:
            if not n.endswith(".json"):
                continue
            rec = read_json(os.path.join(pd, n))
            if rec and rec.get("record") == "pending-terminal":
                yield s, n[:-5], rec


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

def close_absent(session_id, agent_id, index, reason):
    """A member whose original AND quarantine are both gone is closed
    AUTOMATICALLY — never parked in a manual `missing` state (landed review
    2026-09-03, blocker 3; CEO specification section 4). What is preserved
    is exactly what remains, and nothing is searched for:
      - the backup ref is (re)created from the recorded head (the HEAD
        save_ref read, else head_at_seal) when that commit object still
        exists in the repository — the platform can delete a native
        worktree and its branch, but the objects outlive both;
      - a registration git still holds for the vanished path is pruned
        (`git worktree prune` drops only registrations whose directory is
        gone);
      - the absence, its reason and what was preserved are recorded on the
        member, and it is `removed`.
    A backup-ref write that FAILS while the object exists is a transient
    failure and raises, so the caller retries; the member is not closed on
    a lost ref that could still be saved."""
    tx = load_tx(session_id, agent_id)
    m = tx["members"][index]
    repo = m.get("repo") or ""
    ref = m.get("backup_ref") or backup_ref(session_id, agent_id, m.get("branch"))
    head = m.get("head") or m.get("head_at_seal") or ""
    preserved = "no-head-recorded"
    repo_present = bool(repo) and os.path.isdir(repo)
    if repo_present and head:
        rc, _, _ = _git(repo, "cat-file", "-e", head + "^{commit}")
        if rc == 0:
            rc2, _, err = _git(repo, "update-ref", ref, head)
            if rc2 != 0:
                raise RuntimeError("closing absent member %s: update-ref %s failed: %s" % (m["path"], ref, err.strip()[:200]))
            preserved = "backup-ref"
        else:
            preserved = "commit-object-gone"
    elif head and not repo_present:
        preserved = "repository-not-present"
    if repo_present:
        _git(repo, "worktree", "prune")
    return update_member(session_id, agent_id, index, state="removed", closed="absent",
                         absence_reason=reason, absence_recorded_ts=now_iso(), removed_ts=now_iso(),
                         head=head or m.get("head") or "", head_preserved=preserved,
                         backup_ref=(ref if preserved == "backup-ref" else m.get("backup_ref")))


def save_ref(session_id, agent_id, index):
    """bound -> ref_saved. Idempotent: the HEAD is read from whichever of the
    original or the quarantine exists; neither present closes the member
    absent (close_absent)."""
    tx = load_tx(session_id, agent_id)
    m = tx["members"][index]
    if m.get("state") != "bound":
        return tx
    orig = m["path"]
    quar = m.get("quarantine") or quarantine_name(orig, session_id, agent_id)
    # The quarantine is preferred as the source when it exists: its name
    # embeds this session prefix and this agent id, so it is this member's
    # own tree; whatever stands at the original path after a rename is
    # residue or somebody else's registration, never the HEAD to save.
    src = quar if os.path.isdir(quar) else (orig if os.path.isdir(orig) else "")
    if not src:
        return close_absent(session_id, agent_id, index, "neither %s nor %s exists at ref_saved" % (orig, quar))
    head = head_of(src)
    ref = backup_ref(session_id, agent_id, m.get("branch"))
    if not head:
        # git cannot read the directory (landed review 2026-09-03, blocker 3
        # — no `failed` state waits for a person). If git still REGISTERS it,
        # the failure is transient (a lock, a busy index): recorded on the
        # member and retried with backoff by the reconciler. If git no longer
        # registers it, the directory is orphaned from its repository — its
        # administrative directory is gone — and no git command will ever
        # succeed inside it: the backup ref is taken from head_at_seal while
        # that commit object survives, the member is marked git_unreadable,
        # and it advances so the reconciler captures its RAW bytes, verifies
        # them and closes it.
        reg = registered_worktrees(m["repo"]) if os.path.isdir(m.get("repo") or "") else None
        if reg is not None and norm_path(src) in reg and not reg[norm_path(src)].get("prunable"):
            return _soft_failure(session_id, agent_id, index,
                                 "could not read HEAD of %s (git still registers it; retried with backoff)" % src)
        sealed_head = m.get("head_at_seal") or ""
        preserved = "no-head-at-seal"
        if sealed_head and os.path.isdir(m.get("repo") or ""):
            rc, _, _ = _git(m["repo"], "cat-file", "-e", sealed_head + "^{commit}")
            if rc == 0:
                rc2, _, err = _git(m["repo"], "update-ref", ref, sealed_head)
                if rc2 != 0:
                    return _soft_failure(session_id, agent_id, index, "update-ref %s failed: %s" % (ref, err.strip()[:200]))
                preserved = "backup-ref"
            else:
                preserved = "commit-object-gone"
        return update_member(session_id, agent_id, index, state="ref_saved", git_unreadable=True,
                             git_unreadable_reason="git cannot read %s and no longer registers it" % src,
                             head=sealed_head, head_preserved=preserved,
                             backup_ref=(ref if preserved == "backup-ref" else None), quarantine=quar)
    rc, _, err = _git(m["repo"], "update-ref", ref, head)
    if rc != 0:
        return _soft_failure(session_id, agent_id, index, "update-ref %s failed: %s" % (ref, err.strip()[:200]))
    return update_member(session_id, agent_id, index, state="ref_saved",
                         backup_ref=ref, head=head, quarantine=quar)


def _soft_failure(session_id, agent_id, index, why):
    """A TRANSIENT failure: the member keeps its state, the attempt and the
    reason are recorded, and the reconciler retries it with persistent
    backoff (landed review 2026-09-03, blocker 3). Nothing here is a queue
    for a person."""
    tx = load_tx(session_id, agent_id)
    m = tx["members"][index]
    return update_member(session_id, agent_id, index, attempts=int(m.get("attempts") or 0) + 1,
                         last_error=why[:300], last_attempt=now_iso())


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
    if not o and not q:
        return close_absent(session_id, agent_id, index, "neither %s nor %s exists at quarantine" % (orig, quar))
    # BOTH PRESENT IS A POLICY, NOT A HARD FAILURE (landed review 2026-09-03,
    # blocker 3). The quarantine name embeds this session prefix and this
    # agent id, so a directory at that exact name is this member's own
    # quarantine, produced by this member's own rename (a crash between the
    # rename and its record, or a re-run); whatever stands at the original
    # path afterwards is residue, or a registration somebody else made.
    # Nothing is chosen between them and nothing is renamed over anything:
    # the quarantine is ours and advances; the original is recorded present
    # and left EXACTLY where it is for the reconciler, which archives and
    # verifies residue before removing it and never touches a path git
    # registers as another worktree.
    both = o and q
    if o and not q:
        try:
            os.rename(orig, quar)
        except OSError as e:
            return _soft_failure(session_id, agent_id, index, "rename %s -> %s failed: %s" % (orig, quar, e))
        _fsync_dir(os.path.dirname(orig))
    both_fields = {"original_present_at_quarantine": True, "original_present_ts": now_iso()} if both else {}
    if m.get("git_unreadable"):
        # No administrative directory to repair and nothing for git to list:
        # the raw bytes are what the reconciler captures.
        return update_member(session_id, agent_id, index, state="quarantined", quarantine=quar, **both_fields)
    # RE-POINT GIT AT THE QUARANTINE. After a raw rename the repository's
    # registration still names the ORIGINAL path and is "prunable"; the
    # harness's own cleanup (or anyone's `git worktree prune`) would then
    # delete the admin directory the quarantine's `.git` file points at, and
    # every later git read of the quarantine (index, status, HEAD) would fail.
    # `git worktree repair <new path>` rewrites the admin pointer to the
    # quarantine (measured: rc 0, "repair: gitdir incorrect" is its normal
    # output), so the registration is valid again and the branch stays
    # checked out here — which also makes the harness's `branch -D` refuse.
    #
    # THE RESULT IS CHECKED, AND THE POSTCONDITION IS VERIFIED (review
    # 2026-09-03, blocker 6). A repair whose return code was ignored recorded
    # `quarantined` over a registration that still named the vanished
    # original; the next prune deleted the admin directory the quarantine's
    # `.git` file points at, and the reconciler lost the index it claimed to
    # preserve. The member advances only when git lists the quarantine as the
    # exact registered path and not prunable. Otherwise it stays `ref_saved`
    # with the quarantine recorded, the directory preserved, the failure
    # written on the member, and the step retried by the next run — the
    # same call is idempotent on the "only the quarantine exists" branch.
    rc, out, err = _git(m["repo"], "worktree", "repair", quar)
    reg = registered_worktrees(m["repo"])
    entry = (reg or {}).get(norm_path(quar))
    if rc != 0 or entry is None or entry.get("prunable"):
        why = ("git worktree repair %s exited %d: %s" % (quar, rc, (err or out).strip()[:200]) if rc != 0
               else "git does not list %s as a registered worktree of %s after repair" % (quar, m["repo"]) if entry is None
               else "git lists %s as PRUNABLE after repair" % quar)
        return update_member(session_id, agent_id, index, quarantine=quar,
                             attempts=int(m.get("attempts") or 0) + 1,
                             last_error="quarantine not advanced: " + why, last_attempt=now_iso())
    return update_member(session_id, agent_id, index, state="quarantined", quarantine=quar, **both_fields)


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
    _repair_terminal_indexes(tx)
    if not tx.get("members"):
        return close_if_empty(session_id, agent_id)
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


def close_if_empty(session_id, agent_id):
    """A terminal transaction with NO members — a main-checkout-run or remote
    spawn, or a pending terminal event whose agent had no verifiable member
    (landed review 2026-09-03, blocker 2) — is `removed` the moment it is
    terminal: there is nothing to quarantine, capture or delete, and a
    tombstone that never reaches `removed` would be counted as pending and
    never expire. The terminal record, the ingress and the agent-id index
    all stand; only the state advances."""
    with tx_lock(session_id, agent_id):
        tx = load_tx(session_id, agent_id)
        if not tx or not tx.get("terminal") or tx.get("members") or tx.get("state") == "removed":
            return tx
        tx["state"] = "removed"
        tx["removed_ts"] = now_iso()
        tx["closed"] = "no-members"
        atomic_write_json(tx_path(session_id, agent_id), tx)
        return tx


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
           "pending_retry": 0, "failed": 0, "failed_present": 0,
           "pending_terminals": 0, "pending_terminals_unbindable": 0}
    for _s, _a, rec in iter_pending_terminals():
        out["pending_terminals"] += 1
        if rec.get("unbindable"):
            out["pending_terminals_unbindable"] += 1
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
    p.add_argument("--session-id", default="")

    p = sub.add_parser("terminal-name")
    p.add_argument("--session-id", required=True)
    p.add_argument("--teammate", required=True)

    p = sub.add_parser("by-native-path")
    p.add_argument("--session-id", required=True)
    p.add_argument("--path", required=True)

    p = sub.add_parser("pending", help="show the pending terminal record, exit 1 if none")
    p.add_argument("--session-id", required=True)
    p.add_argument("--agent-id", required=True)

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
    if a.cmd == "pending":
        rec = read_pending_terminal(a.session_id, a.agent_id)
        print(json.dumps(rec, sort_keys=True, indent=1)); return 0 if rec else 1
    if a.cmd == "claim":
        won, tx = claim_terminal(a.session_id, a.agent_id, a.ingress, a.detail)
        if tx is None:
            print(json.dumps({"claimed": False, "reason": "no sealed transaction",
                              "pending": bool(read_pending_terminal(a.session_id, a.agent_id))})); return 3
        tx = terminalize(a.session_id, a.agent_id, a.first_path or None)
        print(json.dumps({"claimed": won, "transaction": tx}, sort_keys=True))
        return 0 if won else 2
    if a.cmd == "terminal-agent":
        return 0 if is_terminal_agent(a.agent_id, a.session_id or None) else 1
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
