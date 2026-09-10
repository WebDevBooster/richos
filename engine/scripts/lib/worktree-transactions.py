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
New Claude-owned native members use bound -> platform-pending -> removed.
Their original worktree, index, registration and lock remain platform-owned.
Removal is observed only after both exact path and complete registry absence.
The following quarantine state machine applies to historical linked members:

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
                 "unregistered", "platform-pending", "removed")
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
    return {"class": "native", "cleanup_owner": "claude-code", "repo": repo, "path": cwd_real,
            "branch": reg[cwd_real].get("branch") or branch_of(cwd_real),
            "head_at_seal": reg[cwd_real].get("head") or head_of(cwd_real),
            "state": "bound"}, ""


def _verify_external_member(m):
    """A prepared external member must STILL be what the prepared record said."""
    if m.get('class') == 'managed-image':
        try:
            record = _managed_workspaces().verify_member(m)
            if branch_of(m['path']) != (m.get('branch') or ''):
                return None, 'managed workspace branch changed after preparation'
            return dict(m, head_at_seal=head_of(m['path']), state='bound'), ''
        except Exception as error:
            return None, 'managed workspace verification failed: ' + str(error)
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


def _managed_workspaces():
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'managed-workspace-integration.py')
    spec = importlib.util.spec_from_file_location('managed_workspaces', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def try_seal(session_id, agent_id):
    """(sealed, tx_or_reason). Both facts — the bound record from the parent's
    PostToolUse[Agent] and the start record from the worker's own
    SubagentStart — must exist; they may arrive in either order.

    A PENDING TERMINAL EVENT IS CONSUMED HERE (review 2026-09-03, blocker 4):
    if the agent's only terminal event arrived before the manifest could seal,
    the seal is immediately followed by the claim and the terminalization it
    would have triggered, and the returned transaction is terminal. The
    caller that sealed a dead agent's manifest learns it is dead.

    A NEVER-READ NATIVE SHELL IS DE-MATERIALIZED HERE, and only here, because
    the seal is the first moment the member set is known and bound to an
    agent id. It runs AFTER the pending-terminal consumption so a shell the
    platform is already tearing down is never raced. It is advisory in the
    strongest sense: scripts/lib/shell-worktree-sparse.py records its own
    refusals, this call cannot raise, and a missing module simply means no
    shell is shrunk. Nothing about the lifecycle depends on it."""
    sealed, res = _try_seal_locked(session_id, agent_id)
    if sealed:
        res = _consume_pending_terminal(session_id, agent_id, res)
        res = _sparsify_shell(session_id, agent_id, res)
    return sealed, res


_SHELL_SPARSE_MOD = "unloaded"    # sentinel: None is a real, cached answer


def _load_shell_sparse():
    """The sparsifier, loaded by path like every other sibling here. Returns
    None if it is absent or unimportable — a seal never depends on it.

    CACHED PER PROCESS, and the reason is the write barrier: it calls
    try_seal in a poll loop every 0.25s for up to SEAL_WAIT_SECONDS, so one
    hook process can reach here twenty times. An absent module is cached as
    None too; re-deciding that on every poll is the same waste."""
    global _SHELL_SPARSE_MOD
    if _SHELL_SPARSE_MOD != "unloaded":
        return _SHELL_SPARSE_MOD
    _SHELL_SPARSE_MOD = None
    try:
        import importlib.util
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "shell-worktree-sparse.py")
        if not os.path.isfile(p):
            return None
        spec = importlib.util.spec_from_file_location("shell_worktree_sparse", p)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _SHELL_SPARSE_MOD = mod
    except Exception:
        _SHELL_SPARSE_MOD = None
    return _SHELL_SPARSE_MOD


def _sparsify_shell(session_id, agent_id, tx):
    """Best-effort. The `sparse` block it writes is advisory data on the
    member; no member state changes and no other field is touched.

    ELIGIBILITY IS NOT DECIDED HERE. Every condition — the spawn kind, the
    member state, a transaction that is already terminal — belongs to
    shell-worktree-sparse.eligible(), in one place, where the mutation
    harness can prove each one load-bearing. A second copy of a rule in the
    caller is not defense in depth; it is a rule that can be removed from its
    own module without any test noticing."""
    if not isinstance(tx, dict):
        return tx
    mod = _load_shell_sparse()
    if mod is None:
        return tx

    def persist(index, **fields):
        with tx_lock(session_id, agent_id):
            return update_member(session_id, agent_id, index, **fields)

    try:
        return mod.maybe_sparsify(tx, persist) or tx
    except Exception:
        return tx


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
                if ext.get('class') == 'managed-image':
                    try:
                        _managed_workspaces().bind_member(ext, session_id, agent_id)
                    except Exception as error:
                        return False, 'managed workspace binding failed: ' + str(error)
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
        for member in tx["members"]:
            if member.get("class") != "managed-image":
                member["cleanup_policy"] = "integrated-daily"
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
      - any exact registration still present retains this member pending,
        because its index may hold unique objects; no bulk prune is permitted;
      - the absence, its reason and what was preserved are recorded on the
        member, and it is `removed`.
    A backup-ref write that FAILS while the object exists is a transient
    failure and raises, so the caller retries; the member is not closed on
    a lost ref that could still be saved."""
    tx = load_tx(session_id, agent_id)
    m = tx["members"][index]
    if platform_native(m):
        return observe_platform_native(session_id, agent_id, index)
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
        registered = strict_registered_worktrees(repo)
        retained = [p for p in (m.get("path"), m.get("quarantine")) if p and norm_path(p) in registered]
        if retained:
            return _soft_failure(session_id, agent_id, index,
                                 "missing workspace retains Git registration/index; exact offline cleanup required: " + retained[0])
    return update_member(session_id, agent_id, index, state="removed", closed="absent",
                         absence_reason=reason, absence_recorded_ts=now_iso(), removed_ts=now_iso(),
                         head=head or m.get("head") or "", head_preserved=preserved,
                         backup_ref=(ref if preserved == "backup-ref" else m.get("backup_ref")))


def platform_native(member):
    return member.get("class") == "native" and "cleanup_owner" in member


def platform_owns_path(path):
    """Exact active platform ownership, with strict transaction-store reads.

    False requires complete inventory. Missing stores mean no recorded owner;
    unreadable, replaced or malformed stores refuse automatic mutation.
    """
    root = tx_root()
    if not os.path.lexists(root):
        return False
    if os.path.islink(root) or not os.path.isdir(root):
        raise RuntimeError("platform ownership store is not a directory")
    def entries(directory):
        with os.scandir(directory) as listing:
            return list(listing)
    found = False
    for session in entries(root):
        if session.name in ("terminal", "terminal-names"):
            continue
        if session.is_symlink():
            raise RuntimeError("platform ownership session is a symlink")
        if not session.is_dir(follow_symlinks=False):
            continue
        for entry in entries(session.path):
            if not entry.name.endswith(".json"):
                continue
            if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
                raise RuntimeError("platform ownership record is not a regular file")
            with open(entry.path, encoding="utf-8") as stream:
                record = json.load(stream)
            if not isinstance(record, dict):
                raise RuntimeError("platform ownership record malformed")
            if record.get("record") != "transaction":
                raise RuntimeError("platform ownership record kind unknown")
            members = record.get("members")
            if not isinstance(members, list) or not all(isinstance(m, dict) for m in members):
                raise RuntimeError("platform ownership members malformed")
            for member in members:
                if platform_native(member) and member.get("state") != "removed":
                    if not isinstance(member.get("path"), str) or not os.path.isabs(member["path"]):
                        raise RuntimeError("platform ownership path malformed")
                    if norm_path(member["path"]) == norm_path(path):
                        found = True
    return found


def strict_registered_worktrees(repo):
    """Complete NUL registry used for observational platform cleanup only.

    A failed, empty or malformed read is unknown, never proof of removal.
    """
    rc, raw, err = _git(repo, "worktree", "list", "--porcelain", "-z")
    if rc or not raw or not raw.endswith("\0\0"):
        raise RuntimeError("platform cleanup registry unavailable: " + err[:200])
    entries = {}
    for record in raw[:-2].split("\0\0"):
        values = {}
        fields = record.split("\0")
        for field in fields:
            key, _, value = field.partition(" ")
            if key not in ("worktree", "HEAD", "branch", "detached", "bare", "locked", "prunable") or key in values:
                raise RuntimeError("platform cleanup registry malformed")
            values[key] = value
        path = values.get("worktree", "")
        if not fields[0].startswith("worktree ") or not os.path.isabs(path) or norm_path(path) in entries:
            raise RuntimeError("platform cleanup registry path malformed")
        if "bare" in values:
            if values["bare"] or any(key in values for key in ("HEAD", "branch", "detached")):
                raise RuntimeError("platform cleanup bare registry malformed")
        elif (not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", values.get("HEAD", ""))
              or ("branch" in values) == ("detached" in values)
              or ("detached" in values and values["detached"])
              or ("branch" in values and (not values["branch"].startswith("refs/heads/")
                  or _git(repo, "check-ref-format", values["branch"])[0]))):
            raise RuntimeError("platform cleanup registry identity malformed")
        entries[norm_path(path)] = values
    return entries


def observe_platform_native(session_id, agent_id, index):
    """Preserve a terminal commit and observe Claude's own worktree removal.

    Never rename, sparsify, prune registrations, unlock or remove a platform
    checkout. Historical records lack this ownership marker and keep their
    recovery path. A retained platform checkout stays explicitly pending.
    """
    t = load_tx(session_id, agent_id)
    m = t["members"][index]
    if not platform_native(m) or m.get("cleanup_owner") != "claude-code" or not t.get("terminal"):
        raise RuntimeError("not a terminal Claude-owned native member; unknown owner retained")
    if m.get("state") == "removed":
        return t
    if m.get("quarantine") or m.get("quarantine_path"):
        raise RuntimeError("platform-owned native member has historical quarantine; retained")
    repo, path = m.get("repo") or "", m.get("path") or ""
    if not repo or not path or not os.path.isdir(repo):
        raise RuntimeError("platform cleanup repository/path unavailable")
    reg = strict_registered_worktrees(repo)
    entry = reg.get(norm_path(path))
    if entry is not None and entry.get("branch", "") != ("refs/heads/" + m["branch"] if m.get("branch") else ""):
        raise RuntimeError("platform cleanup registration branch changed; retained")
    head = m.get("head") or (entry or {}).get("HEAD") or m.get("head_at_seal") or ""
    if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", head):
        raise RuntimeError("platform cleanup has no valid recovery commit")
    ref = backup_ref(session_id, agent_id, m.get("branch"))
    if _git(repo, "cat-file", "-e", head + "^{commit}")[0]:
        raise RuntimeError("platform cleanup recovery commit unavailable")
    symbolic, _, _ = _git(repo, "symbolic-ref", "-q", ref)
    if symbolic == 0:
        raise RuntimeError("platform cleanup recovery ref is symbolic; retained")
    previous_rc, previous, _ = _git(repo, "rev-parse", "--verify", "--quiet", ref)
    if previous_rc not in (0, 1) or (previous_rc == 0 and previous.strip() != head):
        raise RuntimeError("platform cleanup recovery ref changed; retained")
    expected = head if previous_rc == 0 else "0" * len(head)
    rc, _, err = _git(repo, "update-ref", "--no-deref", ref, head, expected)
    if rc:
        raise RuntimeError("platform cleanup recovery ref failed: " + err[:200])
    # A fresh complete registry read plus lexists, including dangling links,
    # must both prove absence. No filesystem mutation follows this observation.
    remaining = strict_registered_worktrees(repo)
    absent = norm_path(path) not in remaining and not os.path.lexists(path)
    fields = dict(head=head, backup_ref=ref, head_preserved="backup-ref",
                  state="removed" if absent else "platform-pending",
                  last_error=None if absent else "Claude Code cleanup pending: native path or registration remains",
                  blocked=False, blocked_reason=None, retry_after_epoch=0)
    if absent:
        fields.update(closed="platform-removed", removed_ts=now_iso())
    return update_member(session_id, agent_id, index, **fields)


def save_ref(session_id, agent_id, index):
    """bound -> ref_saved. Idempotent: the HEAD is read from whichever of the
    original or the quarantine exists; neither present closes the member
    absent (close_absent)."""
    tx = load_tx(session_id, agent_id)
    m = tx["members"][index]
    if platform_native(m):
        return observe_platform_native(session_id, agent_id, index)
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
    if platform_native(m):
        return observe_platform_native(session_id, agent_id, index)
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


class _ModuleSelf(object):
    """A live view of THIS module's namespace.

    The reclaim lane takes the transactions module as its first argument, and
    this file is loaded BY PATH (importlib.spec_from_file_location) from a
    dozen callers, so it is not in sys.modules under any stable name and
    cannot look itself up. Attribute reads go straight to the current
    globals, so nothing here can go stale.
    """

    def __getattr__(self, name):
        try:
            return globals()[name]
        except KeyError:
            raise AttributeError(name)


_SELF = _ModuleSelf()
_DAILY_MOD = None


def _daily():
    """The reclaim lane, loaded once per process. Kept here rather than
    imported at module scope so a missing or broken lane can never stop a
    terminal event from being RECORDED — the record is the part nothing may
    lose."""
    global _DAILY_MOD
    if _DAILY_MOD is None:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "daily_workspace_cleanup",
            os.path.join(os.path.dirname(__file__), "daily-workspace-cleanup.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _DAILY_MOD = mod
    return _DAILY_MOD


def _ledger():
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "worktree_ledger", os.path.join(os.path.dirname(__file__), "worktree-ledger.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _teammate_is_unique_in_session(session_id, agent_id, teammate):
    """Exactly ONE transaction in this session carries this teammate name.

    This is what makes a name-joined ledger row an EXACT join rather than a
    guess. `guard-worktree-isolation.sh` refuses any spawn whose name has ever
    been used in the session — active or completed, with no escape hatch — so
    within one session a teammate name identifies one agent. That is a claim
    about a guard, so it is CHECKED here rather than trusted: if two
    transactions in this session carry the name, nothing is bound.
    """
    if not teammate:
        return False
    found = 0
    try:
        names = os.listdir(session_dir(session_id))
    except OSError:
        return False
    for n in names:
        if not n.endswith(".json"):
            continue
        rec = read_json(os.path.join(session_dir(session_id), n))
        if rec and rec.get("record") == "transaction" and rec.get("teammate") == teammate:
            found += 1
    return found == 1


def bind_late_members(session_id, agent_id):
    """Bind workspaces this agent was given AFTER its manifest sealed.

    THE HOLE THIS CLOSES, measured on this machine 2026-09-10. zach-opus-dor2
    (agent af3b228967dc2b627) had FOUR workspaces. Its manifest sealed at
    10:56:58 with the two that existed then. Two more were created at 11:03:26
    and 11:03:29, mid-assignment, by `create-teammate-worktree.sh` — which
    cannot write an agent id, because the orchestrator runs it BEFORE the
    spawn. Those two joined no transaction, so no terminal ingress could ever
    name them, and both were still standing, merged and clean, an hour after
    the agent finished. Cross-repository worktrees are 48 of 53 on this
    machine and the second one is routine, so this was not an edge case: it
    was every workspace after the first, structurally unreclaimable for the
    life of the session.

    THE JOIN IS EXACT OR IT DOES NOT HAPPEN. A candidate row must be in the
    ownership ledger, in THIS session, and either

      * carry THIS agent id — the platform's own identity, the strong form; or
      * carry no agent id at all AND name this transaction's teammate, when
        exactly one transaction in this session carries that name.

    and then the path must still BE what the row said: the top level of a
    linked worktree of the named repository, on the named branch
    (_verify_external_member, the same check the seal itself uses). A path any
    other transaction already owns is never taken. Nothing is matched by
    prefix, by directory shape or by what it sits next to.

    Returns the transaction, bound members included. Never raises.
    """
    try:
        tx = load_tx(session_id, agent_id)
        if not tx or not tx.get("sealed"):
            return tx
        # COSTS NOTHING WHEN THERE IS NOTHING NEW. This runs on the stop path,
        # which fires over a thousand times a session, and a full ledger read
        # per transaction per event would be a real cost for a rare event. The
        # ledger is append-only, so its size and mtime are an exact statement
        # that nothing has been added since the last scan.
        ledger_file = _ledger().ledger_path()
        try:
            stamp = "%s:%s" % (os.path.getmtime(ledger_file), os.path.getsize(ledger_file))
        except OSError:
            stamp = ""
        if stamp and tx.get("late_scan_stamp") == stamp:
            return tx
        teammate = tx.get("teammate") or ""
        owned = set(member_paths())
        mine = set(norm_path(m.get("path")) for m in (tx.get("members") or []))
        name_join_ok = _teammate_is_unique_in_session(session_id, agent_id, teammate)
        candidates = {}
        for row in _ledger().read_all():
            if row.get("event") not in ("prepared", "registered"):
                continue
            if (row.get("session_id") or "") != session_id:
                continue
            row_aid = (row.get("agent_id") or "").strip()
            if row_aid:
                if row_aid != agent_id:
                    continue
            elif not (name_join_ok and row.get("teammate") == teammate):
                continue
            path = norm_path(row.get("worktree") or "")
            if not path or path in mine or path in owned:
                continue
            candidates.setdefault(path, row)
        if not candidates:
            if stamp:
                with tx_lock(session_id, agent_id):
                    tx = load_tx(session_id, agent_id)
                    if tx:
                        tx["late_scan_stamp"] = stamp
                        atomic_write_json(tx_path(session_id, agent_id), tx)
            return tx
        with tx_lock(session_id, agent_id):
            tx = load_tx(session_id, agent_id)
            mine = set(norm_path(m.get("path")) for m in (tx.get("members") or []))
            added = []
            for path, row in sorted(candidates.items()):
                if path in mine:
                    continue
                member, why = _verify_external_member(
                    {"class": "hand-rolled", "repo": row.get("repo"), "path": path,
                     "branch": row.get("branch")})
                if not member:
                    sys.stderr.write("late member %s not bound: %s\n" % (path, why))
                    continue
                member["cleanup_policy"] = "integrated-daily"
                member["bound_late"] = {"ts": now_iso(), "ledger_event": row.get("event"),
                                        "ledger_ts": row.get("ts"),
                                        "join": "agent-id" if (row.get("agent_id") or "").strip() else "teammate-name"}
                tx.setdefault("members", []).append(member)
                added.append(path)
            if not added:
                return tx
            tx["late_bindings"] = (tx.get("late_bindings") or 0) + len(added)
            tx["late_scan_stamp"] = stamp
            atomic_write_json(tx_path(session_id, agent_id), tx)
            sys.stderr.write("bound %d workspace(s) created after the seal: %s\n"
                             % (len(added), ", ".join(added)))
            return tx
    except Exception as error:
        sys.stderr.write("late binding for %s/%s did not run: %s\n" % (session_id[:8], agent_id, error))
        return load_tx(session_id, agent_id)


def terminalize(session_id, agent_id, first_path=None):
    """Persist terminal progress for the exact bound members, native first,
    AND RECLAIM WHAT IS ALREADY CLEAN — in this event, not on a timer.

    Managed images delegate to their daemon. Historical linked worktrees keep
    the quarantine/capture route and its explicit erasure refusal.

    ROUND 11 (2026-09-10). This function used to record ownership and stop:
    "the daily reconciler rechecks clean integration before non-force
    removal". So the system learned an agent was finished immediately and
    acted on it up to 24 hours later. It now calls the SAME lane the nightly
    reconciler calls (daily-workspace-cleanup.reclaim_now -> reconcile), with
    every refusal intact and the decision still the lane's. Anything the lane
    refuses, or that is still locked when the bounded wait expires, is left
    exactly as it was for the nightly backstop — which is unchanged and still
    covers the crash, the killed process and the machine that slept.

    The record is written FIRST and the reclaim cannot disturb it: a failure
    in the lane is caught, journalled on the member and never raised, because
    a terminal event must never be prevented by a cleanup.
    """
    tx = load_tx(session_id, agent_id)
    if not tx or not tx.get("terminal"):
        return tx
    _repair_terminal_indexes(tx)
    # A workspace created AFTER the seal joins here, or it joins nothing ever.
    tx = bind_late_members(session_id, agent_id) or tx
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
            member = tx['members'][i]
            if platform_native(member):
                try:
                    if member.get("cleanup_policy") != "integrated-daily":
                        raise ValueError("historical native member")
                    proof = _daily().remember_native(member)
                    update_member(session_id, agent_id, i, daily_cleanup=proof)
                except Exception:
                    # A failed clean proof cannot prevent Claude-owned cleanup
                    # and cannot authorize later deletion of an unproved ref.
                    pass
                try:
                    observe_platform_native(session_id, agent_id, i)
                except Exception as error:
                    _soft_failure(session_id, agent_id, i, str(error))
                _reclaim_in_event(session_id, agent_id, i)
                continue
            if member.get('class') == 'managed-image':
                if member.get('state') == 'removed':
                    continue
                try:
                    record = _managed_workspaces().terminal_member(member, session_id, agent_id)
                    update_member(session_id, agent_id, i, state='managed-terminal',
                                  manager_state=record['state'], last_error=None)
                except Exception as error:
                    update_member(session_id, agent_id, i, last_error=str(error), last_attempt=now_iso())
                continue
            if member.get("cleanup_policy") != "integrated-daily":
                # Historical records retain their original recovery protocol.
                save_ref(session_id, agent_id, i)
                quarantine(session_id, agent_id, i)
                continue
            # The ordinary terminal ingress RECLAIMS what is already clean and
            # integrated, here, in this event. Dirty or unfinished bytes stay
            # at their original path — the lane refuses them exactly as it
            # always did, and the nightly pass retries.
            _reclaim_in_event(session_id, agent_id, i)
        return load_tx(session_id, agent_id)


def _reclaim_in_event(session_id, agent_id, index):
    """Run the reclaim lane for ONE member and swallow everything. The lane
    itself never raises; this is the second belt, because the caller is a
    platform terminal event and the record it just wrote is what matters."""
    try:
        outcome, detail = _daily().reclaim_now(_SELF, load_tx(session_id, agent_id), index)
    except Exception as error:  # pragma: no cover - defended twice deliberately
        sys.stderr.write("immediate reclaim for %s/%s member %d raised: %s\n"
                         % (session_id[:8], agent_id, index, error))
        return None, str(error)
    return outcome, detail


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


def member_paths():
    """Every path any transaction owns — each member's original path AND its
    quarantine name. A caller that must not act on a directory the terminal
    reconciler owns needs both, because a member spends most of its life under
    the second name."""
    out = set()
    for tx in iter_transactions():
        for m in tx.get("members") or []:
            for key in (m.get("path"), m.get("quarantine")):
                if key:
                    out.add(norm_path(key))
    return sorted(out)


def native_roles():
    """{path: "shell"|"workspace"} for every NATIVE member of every transaction.

    A cross-repository spawn gets a native worktree in the SESSION's repository
    and a hand-rolled one in the repository it actually edits. The native one is
    a SHELL: never written to, and holding the one thing that matters — the
    platform-owned lock agent-liveness.sh reads. Telling a 266 MB shell from a
    real workspace changes nothing about what may be removed and everything
    about how a report reads.

    Until now that distinction came only from the OWNERSHIP LEDGER, whose own
    `shells` command declares what it misses: "a shell whose native
    registration was never written does not appear here. Absence from this list
    is not evidence that a worktree is a workspace." This is the second,
    independent source, and it is a better one — the spawn KIND is written by
    guard-worktree-isolation.sh at PreToolUse[Agent], before the worker exists,
    and a spawn whose intent cannot be written durably is REFUSED. So the role
    is recorded rather than inferred:

        native+external   the native member is a SHELL
        native            the native member IS the workspace
        adopted / other   no role: an adoption never observed the spawn, and
                          saying nothing is the honest answer

    A member's quarantine carries its member's role, because renaming a
    directory does not change what it was."""
    out = {}
    for tx in iter_transactions():
        kind = tx.get("kind") or ""
        if kind == "native+external":
            role = "shell"
        elif kind == "native":
            role = "workspace"
        else:
            continue
        for m in tx.get("members") or []:
            if m.get("class") != "native":
                continue
            for key in (m.get("path"), m.get("quarantine")):
                p = norm_path(key) if key else ""
                if p:
                    out[p] = role
    return out


def member_present(m):
    return os.path.isdir(m.get("path") or "") or os.path.isdir(m.get("quarantine") or "")


def native_member_gone(m):
    """(gone, why) for a sealed transaction's native member, verified against
    the RECORDED repository and path and nothing else: the directory no
    longer exists, or git no longer lists it as a worktree of that
    repository, or lists it prunable. When git itself cannot be read nothing
    is decided (not gone). ONE definition, shared by the reconciler's
    native-disappearance backstop and by the metrics, so what `--status`
    calls missing is exactly what the backstop retires."""
    path = m.get("path") or ""
    repo = m.get("repo") or ""
    if not path:
        return False, ""
    if not os.path.isdir(path):
        return True, "native member %s no longer exists on disk" % path
    if not repo or not os.path.isdir(repo):
        return False, ""
    reg = registered_worktrees(repo)
    if reg is None:
        return False, ""
    entry = reg.get(norm_path(path))
    if entry is None:
        return True, "git no longer lists %s as a worktree of %s" % (path, repo)
    if entry.get("prunable"):
        return True, "git lists %s as PRUNABLE (its administrative directory is gone)" % path
    return False, ""


def metrics():
    """The definition of done, with nothing omitted and NOTHING CALLED LIVE
    THAT WAS NOT EXAMINED (CEO specification 2026-09-03, section 5).
    `sealed_live` used to mean only "sealed and not terminal", and on this
    machine it counted a killed worker whose native worktree the platform
    had torn down as live while --status said done. Now every sealed
    non-terminal transaction is examined: its native member is PRESENT
    (directory exists and git registers it, non-prunable, in the recorded
    repository) or MISSING (cleanup debt: the backstop retires it); a
    transaction with no native member is external-only (its termination has
    no platform witness) or member-less (a main-checkout-run or remote
    spawn; nothing to clean). Terminal members are counted present only
    while they are not `removed`: a directory that reappears at a removed
    member's old path is somebody else's, never dead-present. A failed
    member with a directory present is always counted.

    `blocked` is counted SEPARATELY from `pending_retry` and is a SUBSET of
    it. A blocked member is still retried — nothing is parked for a person —
    but the condition it is waiting on is one that waiting cannot clear, and
    filing it under "pending normal retry" reports a deadlock as a process
    under control. Thirty members sat that way for a full day on 2026-09-04
    (the harness lock; reconcile-terminal-worktrees.py
    _break_own_quarantine_lock), each with a backoff doubling to six hours,
    and the status line called every one of them a normal retry."""
    out = {"transactions": 0,
           "sealed_native_present": 0, "sealed_native_missing": 0,
           "sealed_external_only_unclaimed": 0, "sealed_no_member": 0,
           "terminal": 0, "removed": 0,
           "terminal_pending_cleanup": 0, "terminal_cleanup_failed": 0,
           "terminal_members": 0, "terminal_members_present": 0,
           "pending_retry": 0, "blocked": 0, "failed": 0, "failed_present": 0,
           "pending_terminals": 0, "pending_terminals_unbindable": 0,
           # The never-read shell, counted rather than believed. `refused` is
           # not a fault and it is not hidden either: a shell somebody wrote
           # into is left at full size on purpose, and a number that only ever
           # went up would say the policy always applies when it does not.
           "shells_sparsified": 0, "shells_sparse_refused": 0, "shell_bytes_freed": 0}
    for _s, _a, rec in iter_pending_terminals():
        out["pending_terminals"] += 1
        if rec.get("unbindable"):
            out["pending_terminals_unbindable"] += 1
    for tx in iter_transactions():
        out["transactions"] += 1
        members = tx.get("members") or []
        for m in members:
            sp = m.get("sparse")
            if not isinstance(sp, dict):
                continue
            if sp.get("applied"):
                out["shells_sparsified"] += 1
                try:
                    out["shell_bytes_freed"] += int(sp.get("bytes_freed") or 0)
                except (TypeError, ValueError):
                    pass
            else:
                out["shells_sparse_refused"] += 1
        if not tx.get("terminal"):
            nat = next((m for m in members if m.get("class") == "native"), None)
            if nat is None:
                out["sealed_external_only_unclaimed" if members else "sealed_no_member"] += 1
            elif native_member_gone(nat)[0]:
                out["sealed_native_missing"] += 1
            else:
                out["sealed_native_present"] += 1
            continue
        out["terminal"] += 1
        daily_pending = any(m.get("cleanup_policy") == "integrated-daily"
                            and (m.get("daily_cleanup") or {}).get("phase") != "complete" for m in members)
        if tx.get("state") == "removed" and not daily_pending:
            out["removed"] += 1
        for m in members:
            out["terminal_members"] += 1
            st = m.get("state")
            if st == "removed" and not (m.get("cleanup_policy") == "integrated-daily"
                    and (m.get("daily_cleanup") or {}).get("phase") != "complete"):
                continue
            present = member_present(m)
            if present:
                out["terminal_members_present"] += 1
            if st in TERMINAL_STATES:
                out["failed"] += 1
                if present:
                    out["failed_present"] += 1
            else:
                out["pending_retry"] += 1
                if m.get("blocked"):
                    out["blocked"] += 1
    out["terminal_pending_cleanup"] = out["pending_retry"]
    out["terminal_cleanup_failed"] = out["failed"]
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
    p = sub.add_parser("native-roles", help="<path>\\t<shell|workspace> per native member")
    p = sub.add_parser("member-paths", help="every member path AND quarantine any transaction owns")
    p = sub.add_parser("platform-owned", help="exact active Claude-owned path: exit 0 owned, 1 absent, 2 unknown")
    p.add_argument("--path", required=True)
    p = sub.add_parser("owner-of", help="the transaction owning an exact path: <sid8>/<aid>\\t<kind>\\t<state>\\t<policy>\\t<phase>\\t<hold>; exit 1 if none")
    p.add_argument("--path", required=True)

    a = ap.parse_args(argv)
    if a.cmd == "owner-of":
        want = norm_path(a.path)
        for tx in iter_transactions():
            for m in tx.get("members") or []:
                if want and norm_path(m.get("path") or "") == want or (m.get("quarantine") and norm_path(m["quarantine"]) == want):
                    phase = (m.get("daily_cleanup") or {}).get("phase") or ""
                    hold = (m.get("blocked_reason") or m.get("last_error") or "").replace("\t", " ").replace("\n", " ")
                    print("%s/%s\t%s\t%s\t%s\t%s\t%s" % ((tx.get("session_id") or "?")[:8], tx.get("agent_id") or "?",
                                                         tx.get("kind") or "", m.get("state") or "", m.get("cleanup_policy") or "",
                                                         phase, hold))
                    return 0
        return 1
    if a.cmd == "platform-owned":
        try:
            return 0 if platform_owns_path(a.path) else 1
        except Exception as error:
            print("platform ownership unavailable: " + str(error), file=sys.stderr)
            return 2
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
    if a.cmd == "member-paths":
        for p in member_paths():
            print(p)
        return 0
    if a.cmd == "native-roles":
        for p, role in sorted(native_roles().items()):
            print("%s\t%s" % (p, role))
        return 0
    if a.cmd == "list":
        for tx in iter_transactions():
            print("%s\t%s\t%s\t%s\t%s" % (tx.get("session_id"), tx.get("agent_id"), tx.get("teammate"),
                                          tx.get("state"), ",".join(m.get("state") or "" for m in tx.get("members") or [])))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
