#!/usr/bin/env python3
"""workspace-retire.py — RETIREMENT OF A REGISTERED AGENT WORKSPACE.

===========================================================================
WHY THIS FILE EXISTS
===========================================================================
On 2026-09-05 the sanctioned remover was handed malformed arguments by a
caller whose zsh loop failed to word-split. The owner arrived as one joined
string naming no registered agent; the target arrived as the literal path
prefix with an empty name appended — `/Users/alex/ab/richos-wt/`, the PARENT
of every RichOS worktree on the machine. The remover could not recognize that
target as a registered worktree, and its response to not recognizing it was
an unconditional `rm -rf`. It deleted the container of every workspace and
reported success, twice.

    Failing to recognize the target made the operation stronger than
    recognizing it.

That is the sentence this file is written against. A registered worktree at
least gets git's own refusal to remove a dirty tree without `--force`. An
unrecognized path got no refusal at all, and the fatal invocation never
passed `--force`.

Diagnosis: richos-hq `docs/verification/worktree-container-deletion-2026-09-05.md`
(author: Codex). The immediate containment — the fallback now refuses — landed
as `1b84a1c` in `remove-agent-worktree.sh`. THIS file is the operation that
diagnosis specifies beyond the containment.

===========================================================================
THE SHAPE OF THE FIX: THE CALLER NAMES AN IDENTITY, NEVER A PATH
===========================================================================
The incident is not repairable by validating the caller's path harder,
because the caller's path was a real, non-empty, existing directory and every
string check it could have failed, it passed. The repair is that a caller
does not get to supply a path AT ALL.

A caller supplies ONE opaque workspace ID. Repository, path, branch, class,
owner and session are DERIVED from the ownership ledger — the protected
record written at creation (`prepared`, by create-teammate-worktree.sh) and
at binding (`registered`, by detect-nonnative-worktree.sh). Caller-supplied
`--owner` / `--repo` / `--path` are ASSERTIONS, never inputs: they must AGREE
with what the record says or the operation refuses. They can never widen the
target, only fail to match it.

    ws-<16 hex> = sha256(realpath(repo) NUL realpath(worktree))

The ID names the (repository, workspace path) pair and nothing reusable. It
is deliberately not a name, a branch or a teammate: those keys are reusable
across sessions, and `worktree-ledger.py` already removed them from
destructive authority for that reason (docs/plans/worktree-real-fix-2026-09-03.md).

There is no way to spell `/Users/alex/ab/richos-wt/` as a workspace ID,
because no ownership record has ever named it. That path resolves to
`unknown-workspace` and the operation stops before it looks at the disk.

===========================================================================
NOTHING HERE DELETES A WORKSPACE
===========================================================================
Retirement is a RENAME. The workspace directory is renamed, in place, on the
same filesystem, to `<path>.richos-retired-<ws-id>-<utc>`, and git's now
dangling registration is pruned. No `rm`, no `rmtree`, no `git worktree
remove --force`, no code path that erases a directory a caller pointed at.

Erasure happens in exactly one place — `sweep`, the retention expiry — and it
will only erase a directory that satisfies SIX independent conditions, all
minted by this operation itself and none supplied by a caller:

    1. it is named in this module's own COMPLETED retirement record (an
       intent whose completion never landed is never erased);
    2. its name matches the quarantine pattern this module mints;
    3. its (st_dev, st_ino) equals the identity recorded at rename time;
    4. it is not a symlink;
    5. a preservation archive for it exists and re-verifies;
    6. every entry now in the directory is in that archive, byte for byte
       (review 2026-09-06, finding 2 — the archive authorizes the erasure of
       exactly what it holds).

And the erase is put on record before it happens. The legacy route
(`remove`) does still remove a registered worktree with `git worktree
remove`, because the reaper relies on the directory being gone; it preserves
first whenever `--force` could destroy content, and it reaches that line only
through the same authority as everything else.

===========================================================================
ABSENCE IS NOT AUTHORITY — AND THERE IS ONE AUTHORITY
===========================================================================
The incident's liveness verdict was NOT-ALIVE for an owner that did not
exist. The resolver was answering "no such agent is locked here", which is
true of every string that is not an agent id, and the remover read it as
"confirmed dead".

The first fix (2026-09-05) put a positive-evidence check in THIS file's
retirement path and left the legacy path-addressed route reading the lock
resolver directly. The review of 2026-09-06 reproduced the incident's own
logic error through that route: `--owner never-registered` against a
registered worktree whose real owner was verified ALIVE deleted it, exit 0.
Absence of a record was still being read as evidence of death, one door over.

So there is now ONE function every destructive path consults —
`termination_authority()` — and it authorizes only when BOTH hold:

    BINDING     the asserted owner is bound to THIS exact path: an ownership
                record names it, or the path is that agent's own isolation
                worktree registered in the repository (the harness names the
                directory after the agent). An owner nobody can bind to the
                path is `owner-unbound`, however dead it may be.
    EVIDENCE    NOT-ALIVE rests on something POSITIVE: a witnessed
                termination on record, an OBSERVED registered-and-unlocked
                (or stale-locked) isolation worktree, or a host session
                provably over. The ledger's `judge()` lands absence in
                INDETERMINATE by construction, and the native branch requires
                the resolver's `registered` flag rather than trusting the
                verdict word.

ALIVE, INDETERMINATE, UNRESOLVED and unbound all refuse. The legacy route
(`remove`), retirement (`retire`) and the sweep (through the record) share
this one function. Two implementations of "may I destroy this" is how one of
them silently becomes the stale one.

===========================================================================
SERIALIZATION AGAINST WORKER STARTUP — THREE LAYERS, ONE LIMIT
===========================================================================
An exclusive `flock` on `<root>/locks/<ws-id>.lock` is held across every
mutating step; under it the ledger is RE-READ and compared against the
snapshot taken before it. That catches a worker that acquired while we were
waiting for the lock.

It did NOT catch a worker that acquired AFTER the under-lock check and before
the rename (review 2026-09-06, finding 2): the new worker's file was in the
quarantine, absent from the archive, and the sweep erased it. So:

    LAYER 1   after preservation, before the rename: records and verdict are
              re-read; a change refuses `reacquired`, nothing renamed.
    LAYER 2   after the rename: re-read AGAIN; a change renames the directory
              BACK through the held parent descriptor and refuses
              `reacquired-after-quarantine`. The worker's cwd followed the
              inode through both renames; its files are where it put them.
    LAYER 3   the sweep erases only a quarantine whose every byte is in the
              verified archive (`quarantine-diverged` otherwise). The archive
              authorizes the erasure of exactly what it holds.

THE LIMIT, stated: the creation path does not take this lock
(`startup_guard()` exists for it; `create-teammate-worktree.sh` is outside
this file, and the harness's native isolation worktrees are created by code
this repository does not own). A process using the directory with no lock,
no record and no session identity is invisible to every layer above. That is
the case the incident analysis's OS-enforced boundary exists for, and nothing
in this module can stand in for it.

===========================================================================
THE JOURNAL IS WRITTEN BEFORE THE MOVE, AND EVERY WRITE IS READ
===========================================================================
Review 2026-09-06, finding 3: a read-only journal, a renamed and pruned
workspace, `quarantined` reported, `restore` answering `no-retirement-record`.
Now: the journal is probed for append before anything is touched; an INTENT
record naming the planned quarantine path is written before the rename and
refuses the operation if it cannot be; the COMPLETION record is written
before `git worktree prune` and, if it cannot be, the rename is UNDONE and the
outcome is `failed`; the sweep records before it erases; `restore` reads the
newest record carrying a verified archive, completed or not; `reconcile` lists
every intent whose completion never landed, with what the disk says now.
===========================================================================
CLI
===========================================================================
    workspace-retire.py list [--repo R]        ws-ids and their identities
    workspace-retire.py resolve <ws-id>        derived identity, no mutation
    workspace-retire.py retire <ws-id> [--owner O] [--repo R] [--path P]
                                [--dry-run] [--retention-days N]
    workspace-retire.py retire-branch <ws-id> [--retention-days N] [--dry-run]
    workspace-retire.py sweep [--retention-days N] [--execute]
    workspace-retire.py restore <ws-id> <destination>
    workspace-retire.py records [<ws-id>]
    workspace-retire.py reconcile              intents whose completion never landed
    workspace-retire.py authorize --entity-repo E --repo R --owner O --path P
    workspace-retire.py remove    --entity-repo E --repo R --owner O --path P
                                [--force] [--branch B]   (the legacy route)

Every subcommand prints ONE JSON object (or a JSON array for `list`/`records`)
on stdout. Exit codes:

    0   quarantined | already-retired | ok        (the outcome field says which)
    2   usage
    3   refused          — nothing was mutated
    4   failed           — an attempted step failed; see `stage`
    5   remove only: the target is a directory that is not a registered worktree

Environment:
    RICHOS_WORKSPACE_RETIRE_DIR   state root (default ~/.claude/state/workspace-retirement)
    RICHOS_WORKTREE_LEDGER        the ownership ledger (read-only here)
    RICHOS_WORKSPACE_RETENTION_DAYS  default retention, days (default 14)
"""

import argparse
import errno
import fcntl
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import time
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))

OUTCOME_REFUSED = "refused"
OUTCOME_ALREADY = "already-retired"
OUTCOME_QUARANTINED = "quarantined"
OUTCOME_FAILED = "failed"
OUTCOME_OK = "ok"
OUTCOME_IN_PROGRESS = "in-progress"   # an INTENT on record; the completion is a later record

EXIT_OK = 0
EXIT_USAGE = 2
EXIT_REFUSED = 3
EXIT_FAILED = 4
EXIT_UNREGISTERED = 5   # legacy route only: a directory that is not a registered worktree

WS_ID_RE = re.compile(r"^ws-[0-9a-f]{16}$")
QUARANTINE_RE = re.compile(r"\.richos-retired-ws-[0-9a-f]{16}-\d{8}T\d{6}Z$")

DEFAULT_RETENTION_DAYS = 14


# --------------------------------------------------------------------------
# the ownership ledger — imported, never reimplemented
# --------------------------------------------------------------------------

def _ledger_module():
    """scripts/lib/worktree-ledger.py, loaded by path (hyphenated file name).

    This module does NOT decide liveness or ownership itself. Two
    implementations of "alive" is how one of them silently becomes the stale
    one — the defect `remove-agent-worktree.sh` already names in its own
    header. If the ledger library is missing, every destructive path here
    refuses; it does not guess.
    """
    import importlib.util
    path = os.path.join(HERE, "worktree-ledger.py")
    if not os.path.isfile(path):
        return None
    try:
        spec = importlib.util.spec_from_file_location("worktree_ledger_for_retire", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


# --------------------------------------------------------------------------
# state roots
# --------------------------------------------------------------------------

def state_root():
    v = (os.environ.get("RICHOS_WORKSPACE_RETIRE_DIR") or "").strip()
    if v:
        return v
    return os.path.join(os.path.expanduser("~"), ".claude", "state", "workspace-retirement")


def records_path():
    return os.path.join(state_root(), "retirements.jsonl")


def locks_dir():
    return os.path.join(state_root(), "locks")


def preserved_dir():
    return os.path.join(state_root(), "preserved")


def retention_days(explicit=None):
    if explicit is not None:
        return float(explicit)
    v = (os.environ.get("RICHOS_WORKSPACE_RETENTION_DAYS") or "").strip()
    if v:
        try:
            return float(v)
        except ValueError:
            pass
    return float(DEFAULT_RETENTION_DAYS)


def now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _stamp():
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def _parse_iso(s):
    try:
        return datetime.strptime((s or "").replace("Z", "+0000"), "%Y-%m-%dT%H:%M:%S%z")
    except Exception:
        return None


def lex_path(p):
    """LEXICAL normalization: absolute, `.` and `..` collapsed, no trailing
    slash — and NO symlink resolution.

    Workspace identity is minted from this and not from `realpath`, and the
    difference is load-bearing. Under `realpath`, replacing a workspace
    directory with a symlink to somewhere else SILENTLY CHANGES the identity
    the record mints, so the substituted workspace stops resolving at all and
    the operation reports "unknown workspace" instead of "somebody put a
    symlink where your workspace was". Worse, a path resolved through the
    symlink is the object the LINK points at, which is exactly the object a
    destructive operation must not touch.

    So identity is lexical and stable, and the SYMLINK is caught where it can
    be caught honestly: at the open, with O_NOFOLLOW, against the exact name
    the record holds.
    """
    p = (p or "").strip()
    if not p:
        return ""
    p = p.rstrip("/") or "/"
    try:
        return os.path.normpath(os.path.abspath(p))
    except Exception:
        return p


def norm_path(p):
    """Symlink-resolved form. Used only for COMPARING two spellings of a path
    that both exist — never for minting identity."""
    p = (p or "").strip().rstrip("/")
    if not p:
        return ""
    try:
        return os.path.realpath(p)
    except Exception:
        return p


def same_path(a, b):
    """True when two spellings name the same location, lexically or after
    symlink resolution. Either agreeing is enough; neither is not."""
    if not a or not b:
        return False
    if lex_path(a) == lex_path(b):
        return True
    return norm_path(a) == norm_path(b)


def append_record(rec):
    """Append one retirement record durably. Returns True on success."""
    path = records_path()
    rec = dict(rec)
    rec.setdefault("ts", now_iso())
    try:
        d = os.path.dirname(path)
        os.makedirs(d, exist_ok=True)
        existed = os.path.exists(path)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(rec, sort_keys=True) + "\n")
            f.flush()
            os.fsync(f.fileno())
        if not existed:
            try:
                dfd = os.open(d, os.O_RDONLY)
                try:
                    os.fsync(dfd)
                finally:
                    os.close(dfd)
            except OSError:
                pass
        return True
    except Exception:
        return False


def read_records(ws_id=None):
    out = []
    try:
        with open(records_path(), encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                if not isinstance(d, dict):
                    continue
                if ws_id and (d.get("workspace") or {}).get("id") != ws_id:
                    continue
                out.append(d)
    except Exception:
        pass
    return out


def last_retirement(ws_id):
    """The most recent record for this workspace whose outcome was a
    completed quarantine. Refusals and failures are on record too, and
    deliberately do NOT make a workspace look retired."""
    hits = [r for r in read_records(ws_id) if r.get("outcome") == OUTCOME_QUARANTINED]
    return hits[-1] if hits else None


def last_preserving_record(ws_id):
    """The newest record for this workspace that carries a VERIFIED
    preservation archive — a completed quarantine, a completed legacy
    removal, or an INTENT whose completion never landed (a crash, or a
    journal that stopped taking writes between the two).

    `restore` reads this and not `last_retirement()`, because the archive was
    verified before the intent was written, and a workspace whose completion
    record is missing is exactly the workspace somebody most needs to find.
    Review 2026-09-06, finding 3: with the completion record lost, `restore`
    answered `no-retirement-record` over an intact archive.
    """
    hits = [r for r in read_records(ws_id)
            if r.get("operation") in ("retire", "remove")
            and r.get("outcome") in (OUTCOME_QUARANTINED, OUTCOME_OK, OUTCOME_IN_PROGRESS)
            and (r.get("preservation") or {}).get("status") == "verified"]
    return hits[-1] if hits else None


def journal_probe():
    """Prove the journal can take a record BEFORE anything is moved.

    Review 2026-09-06, finding 3: the journal was a read-only file, the
    workspace was renamed and pruned, `append_record()` returned False, the
    caller ignored it and reported `quarantined`. A retirement nobody can find
    the record of is a workspace nobody can find. So the journal is opened for
    append first — an operation that fails for every reason a later append
    would — and every later append's return value is read.
    """
    path = records_path()
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        os.close(fd)
        return True, ""
    except OSError as e:
        return False, "the retirement journal %s cannot be opened for append (%s)" % (path, e)


# --------------------------------------------------------------------------
# workspace identity
# --------------------------------------------------------------------------

def workspace_id(repo, path):
    """ws-<16 hex> over the (repository, workspace path) pair.

    NOT over a teammate name, a branch or a directory basename: those are
    reusable across sessions, and a destructive verdict keyed on a reusable
    key can act on a later, unrelated tree.
    """
    h = hashlib.sha256()
    h.update(lex_path(repo).encode("utf-8"))
    h.update(b"\0")
    h.update(lex_path(path).encode("utf-8"))
    return "ws-" + h.hexdigest()[:16]


def _run(cwd, *args, **kw):
    timeout = kw.pop("timeout", 30)
    try:
        return subprocess.run(list(args), cwd=cwd if cwd else None,
                              capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def _git(cwd, *args, **kw):
    return _run(None, "git", "-C", cwd, *args, **kw)


def _git_out(cwd, *args):
    res = _git(cwd, *args)
    if res is None or res.returncode != 0:
        return ""
    return res.stdout.strip()


def registered_worktree_paths(repo):
    """Exact paths git itself registers for a repository, or None if git could
    not be asked (which is never read as 'none')."""
    res = _git(repo, "worktree", "list", "--porcelain")
    if res is None or res.returncode != 0:
        return None
    return [line[len("worktree "):] for line in res.stdout.splitlines()
            if line.startswith("worktree ")]


def known_workspace_paths(records):
    """Every path any ownership record has ever named. Used only to prove a
    target is not somebody's PARENT."""
    mod_events = ("registered", "prepared")
    out = set()
    for r in records:
        if r.get("event") in mod_events and r.get("worktree"):
            out.add(lex_path(r.get("worktree")))
    return out


def _is_proper_ancestor(parent, child):
    parent = parent.rstrip("/")
    child = child.rstrip("/")
    return bool(parent) and bool(child) and child != parent and child.startswith(parent + "/")


def resolve_workspace(ws_id, ledger=None):
    """Derive (repository, path, branch, class, owners, sessions) for a
    workspace ID from the ownership ledger, or explain why it cannot be.

    Returns a dict with `ok` True/False. When False, `reason_code` and
    `reason` say why, and NOTHING has looked at the filesystem yet.
    """
    if not (ws_id or "").strip():
        return {"ok": False, "reason_code": "empty-workspace-id",
                "reason": "no workspace ID was supplied. This operation takes a registered "
                          "workspace ID and derives the repository, path and owner from the "
                          "ownership ledger; it never takes a path from a caller."}
    ws_id = ws_id.strip()
    if not WS_ID_RE.match(ws_id):
        return {"ok": False, "reason_code": "malformed-workspace-id",
                "reason": ("'%s' is not a workspace ID (expected ws-<16 lowercase hex>). A path, "
                           "a teammate name or a branch is not accepted here and never will be — "
                           "on 2026-09-05 a caller-supplied path was the whole incident."
                           % ws_id)}

    mod = ledger if ledger is not None else _ledger_module()
    if mod is None:
        return {"ok": False, "reason_code": "ledger-missing",
                "reason": "scripts/lib/worktree-ledger.py could not be loaded. The ownership "
                          "record is the ONLY source of a workspace's repository, path and "
                          "owner; without it there is nothing to derive from and nothing is "
                          "acted on."}

    records = mod.read_all()
    # Index every ownership record by the ID its own (repo, path) pair mints.
    by_id = {}
    for r in records:
        if r.get("event") not in ("registered", "prepared"):
            continue
        repo = r.get("repo") or ""
        wt = r.get("worktree") or ""
        if not repo or not wt:
            continue
        by_id.setdefault(workspace_id(repo, wt), []).append(r)

    regs = by_id.get(ws_id)
    if not regs:
        return {"ok": False, "reason_code": "unknown-workspace",
                "reason": ("no ownership record mints the workspace ID %s. %d ownership record(s) "
                           "were read from %s. An unregistered target is exactly the case where "
                           "nothing has established what it is, so it is the case where this "
                           "operation does nothing at all."
                           % (ws_id, sum(1 for r in records
                                         if r.get("event") in ("registered", "prepared")),
                              mod.ledger_path()))}

    repos = {lex_path(r.get("repo")) for r in regs}
    paths = {lex_path(r.get("worktree")) for r in regs}
    if len(repos) != 1 or len(paths) != 1:
        # Cannot happen for a hash over exactly those two fields, and is
        # therefore a corrupted record set rather than a normal state.
        return {"ok": False, "reason_code": "ambiguous-workspace",
                "reason": ("the ownership records minting %s disagree about the repository (%s) "
                           "or the path (%s). Ambiguity refuses."
                           % (ws_id, sorted(repos), sorted(paths)))}

    repo = sorted(repos)[0]
    path = sorted(paths)[0]
    owners = sorted({(r.get("agent_id") or "").strip() for r in regs if r.get("agent_id")})
    teammates = sorted({(r.get("teammate") or "").strip() for r in regs if r.get("teammate")})
    sessions = sorted({(r.get("session_id") or "").strip() for r in regs if r.get("session_id")})
    branches = sorted({(r.get("branch") or "").strip() for r in regs if r.get("branch")})
    classes = sorted({(r.get("class") or "").strip() for r in regs if r.get("class")})

    return {
        "ok": True,
        "id": ws_id,
        "repo": repo,
        "path": path,
        "branch": branches[0] if len(branches) == 1 else (branches[-1] if branches else ""),
        "branches": branches,
        "class": classes[0] if len(classes) == 1 else ",".join(classes),
        "owners": owners,
        "teammates": teammates,
        "sessions": sessions,
        "records": len(regs),
        "record_signature": _record_signature(regs),
        "_regs": regs,
        "_all": records,
        "_mod": mod,
    }


def _record_signature(regs):
    """A stable digest of the ownership record set for a path. Compared before
    and after taking the lock: if it changed, somebody acquired this workspace
    while we were deciding."""
    h = hashlib.sha256()
    for r in sorted(regs, key=lambda x: json.dumps(x, sort_keys=True)):
        h.update(json.dumps(r, sort_keys=True).encode("utf-8"))
        h.update(b"\n")
    return h.hexdigest()[:16]


# --------------------------------------------------------------------------
# filesystem identity — the exact object, held by descriptor
# --------------------------------------------------------------------------

class FsTarget(object):
    """A directory held open by descriptor, with its parent held open too.

    Requirement 3 of the diagnosis: "Resolve and validate the exact filesystem
    object. Prevent symlink substitution and path changes between validation
    and execution."

    Both opens use O_NOFOLLOW, so a symlink at either component fails to open
    rather than being followed. The (st_dev, st_ino) captured at validation is
    re-checked immediately before the rename, and the rename itself is issued
    through the parent's descriptor (`renameat`), so a path swapped ABOVE the
    parent after validation cannot redirect it.
    """

    def __init__(self, path):
        self.path = path
        self.parent = os.path.dirname(path)
        self.base = os.path.basename(path)
        self.pfd = None
        self.tfd = None
        self.st = None
        self.error = None
        self.error_code = None

    def open(self):
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_NOFOLLOW
        try:
            self.pfd = os.open(self.parent, flags)
        except OSError as e:
            self.error_code = "parent-unopenable"
            self.error = "could not open the containing directory %s: %s" % (self.parent, e)
            return False
        try:
            if os.open in os.supports_dir_fd:
                self.tfd = os.open(self.base, flags, dir_fd=self.pfd)
            else:
                self.tfd = os.open(self.path, flags)
        except OSError as e:
            # WHICH ERRNO O_NOFOLLOW PRODUCES IS PLATFORM-DEPENDENT, and the
            # refusal must not be. Linux raises ELOOP; the BSD/macOS kernel
            # evaluates O_DIRECTORY first and raises ENOTDIR for a symlink to
            # a directory. Both are the same event, so the LINK ITSELF is what
            # is asked, not the errno. Keying the message off the errno alone
            # reported "not a directory" for a symlink substitution — a true
            # sentence that names the wrong problem, which is how a finding
            # gets read as noise.
            if os.path.islink(self.path):
                self.error_code = "symlink-target"
                self.error = ("%s is a symlink, not a directory (errno %s). A destructive "
                              "operation never follows one: the object it points at is not the "
                              "object the record names." % (self.path, errno.errorcode.get(
                                  e.errno, e.errno)))
            elif e.errno in (errno.ELOOP, errno.EMLINK):
                self.error_code = "symlink-target"
                self.error = ("%s could not be opened without following a symlink. A destructive "
                              "operation never follows one." % self.path)
            elif e.errno == errno.ENOTDIR:
                self.error_code = "not-a-directory"
                self.error = "%s is not a directory." % self.path
            elif e.errno == errno.ENOENT:
                self.error_code = "path-absent"
                self.error = "%s does not exist." % self.path
            else:
                self.error_code = "unopenable"
                self.error = "could not open %s: %s" % (self.path, e)
            self.close()
            return False
        self.st = os.fstat(self.tfd)
        return True

    def fsid(self):
        if self.st is None:
            return ""
        return "%d:%d" % (self.st.st_dev, self.st.st_ino)

    def still_the_same(self):
        """Re-stat through the held descriptor AND by name, and require both to
        name the same object. The held descriptor cannot change identity; the
        by-name lookup can, and a difference is exactly the substitution this
        check exists to catch."""
        try:
            live = os.fstat(self.tfd)
        except OSError:
            return False
        if (live.st_dev, live.st_ino) != (self.st.st_dev, self.st.st_ino):
            return False
        try:
            byname = os.lstat(self.base, dir_fd=self.pfd) if os.stat in os.supports_dir_fd \
                else os.lstat(self.path)
        except OSError:
            return False
        return (byname.st_dev, byname.st_ino) == (self.st.st_dev, self.st.st_ino)

    def rename_to(self, new_base):
        """renameat(parent_fd, base -> parent_fd, new_base). Atomic, and it
        cannot be redirected by anything that changes a path component above
        the parent after validation."""
        if os.rename in os.supports_dir_fd:
            os.rename(self.base, new_base, src_dir_fd=self.pfd, dst_dir_fd=self.pfd)
        else:
            os.rename(self.path, os.path.join(self.parent, new_base))
        return os.path.join(self.parent, new_base)

    def close(self):
        for fd in (self.tfd, self.pfd):
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
        self.tfd = None
        self.pfd = None


# --------------------------------------------------------------------------
# the retirement lock
# --------------------------------------------------------------------------

class WorkspaceLock(object):
    """flock, exclusive, non-blocking after a bounded wait. Kernel-released,
    so it is never stranded by a crash."""

    def __init__(self, ws_id, wait_seconds=5.0):
        self.ws_id = ws_id
        self.wait = wait_seconds
        self.fd = None
        self.error = ""
        self.path = os.path.join(locks_dir(), ws_id + ".lock")

    def acquire(self):
        """Returns True, False (contended) or raises nothing: an unusable lock
        directory is reported as `self.error` and False, because a retirement
        that cannot serialize must refuse rather than crash — a traceback is
        an outcome nobody can read a `reason_code` out of."""
        try:
            os.makedirs(locks_dir(), exist_ok=True)
            self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT, 0o600)
        except OSError as e:
            self.error = "the retirement lock at %s could not be opened: %s" % (self.path, e)
            self.fd = None
            return False
        deadline = time.time() + self.wait
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except OSError:
                if time.time() >= deadline:
                    os.close(self.fd)
                    self.fd = None
                    return False
                time.sleep(0.1)

    def release(self):
        if self.fd is not None:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = None


def startup_guard(ws_id, wait_seconds=30.0):
    """THE ENTRY POINT A CREATOR SHOULD CALL, and does not yet.

    A worker startup that acquires this lock before writing its ownership
    record is serialized against retirement by the kernel: retirement cannot
    begin while it is held, and a creation that begins after retirement took
    the lock will find the workspace quarantined rather than half-renamed.

    `create-teammate-worktree.sh` is not wired to it — that is the creation
    path and it is outside this file. The harness's own native isolation
    worktrees are created by code this repository does not own and can never
    be wired to it. So the lock alone is NOT what protects a starting worker;
    what does, as of the 2026-09-06 review (finding 2), is three layers that
    need nothing from the creator:

      1. after preservation and before the rename, the ownership records and
         the termination verdict are re-read; any change refuses (`reacquired`);
      2. after the rename, they are re-read AGAIN; any change renames the
         directory BACK through the same parent descriptor and refuses
         (`reacquired-after-quarantine`) — a worker that acquired in the
         microseconds between the last check and the rename finds its
         workspace where it left it;
      3. the retention sweep erases a quarantine only when every byte in it is
         in the verified archive (`quarantine-diverged` otherwise), so a file
         written into the directory after preservation is never the copy that
         goes.

    What remains open, stated rather than implied: a process that is using
    the directory without a lock, an ownership record or a session identity
    is invisible to every check here. That is the case the OS-enforced
    boundary in the incident analysis exists for.
    """
    lock = WorkspaceLock(ws_id, wait_seconds=wait_seconds)
    return lock if lock.acquire() else None


# --------------------------------------------------------------------------
# preservation
# --------------------------------------------------------------------------

def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def _walk_manifest(root, arc_prefix):
    """Every entry under `root`, including untracked and ignored files, with
    symlinks recorded as symlinks and never followed."""
    entries = []
    for dirpath, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
        dirnames.sort()
        filenames.sort()
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_dir = ""
        for name in list(dirnames):
            full = os.path.join(dirpath, name)
            rel = os.path.join(rel_dir, name) if rel_dir else name
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                dirnames.remove(name)
                entries.append({"path": os.path.join(arc_prefix, rel), "type": "symlink",
                                "mode": stat.S_IMODE(st.st_mode),
                                "linkname": os.readlink(full), "src": full})
            else:
                entries.append({"path": os.path.join(arc_prefix, rel), "type": "dir",
                                "mode": stat.S_IMODE(st.st_mode), "src": full})
        for name in filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.join(rel_dir, name) if rel_dir else name
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                entries.append({"path": os.path.join(arc_prefix, rel), "type": "symlink",
                                "mode": stat.S_IMODE(st.st_mode),
                                "linkname": os.readlink(full), "src": full})
            elif stat.S_ISREG(st.st_mode):
                entries.append({"path": os.path.join(arc_prefix, rel), "type": "file",
                                "mode": stat.S_IMODE(st.st_mode), "size": st.st_size,
                                "sha256": _sha256_file(full), "src": full})
            else:
                entries.append({"path": os.path.join(arc_prefix, rel), "type": "other",
                                "mode": stat.S_IMODE(st.st_mode), "src": full})
    return entries


def _git_facts(path, repo):
    """The git state a clean `git status` would hide. Requirement 5: a clean
    status is NOT a preservation check — on 2026-09-05 the two files reported
    unrecoverable were UNTRACKED acknowledgement files in a tree whose status
    would have read clean of tracked changes.
    """
    facts = {}
    facts["head"] = _git_out(path, "rev-parse", "HEAD")
    facts["branch"] = _git_out(path, "symbolic-ref", "--short", "HEAD")
    facts["detached"] = not bool(facts["branch"])
    facts["git_dir"] = _git_out(path, "rev-parse", "--absolute-git-dir")
    res = _git(path, "status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching")
    facts["status"] = (res.stdout.splitlines() if res and res.returncode == 0 else [])
    facts["staged"] = [l for l in _git_out(path, "diff", "--cached", "--name-only").splitlines() if l]
    facts["untracked"] = [l[3:] for l in facts["status"] if l.startswith("?? ")]
    facts["ignored"] = [l[3:] for l in facts["status"] if l.startswith("!! ")]
    facts["dirty"] = [l for l in facts["status"]
                      if not l.startswith("?? ") and not l.startswith("!! ")]
    facts["repo_head"] = _git_out(repo, "rev-parse", "HEAD")
    return facts


def preserve(ws, target, dest_dir):
    """Archive the workspace — committed, staged, dirty, untracked AND ignored
    — plus git's per-worktree administrative directory (which is where the
    INDEX lives, and which `git worktree prune` destroys).

    Then RE-READ the archive and compare every member's bytes against the
    digest taken from disk. An archive that has not been read back is a
    success report over something that never ran, which is the failure class
    this whole change exists to stop.

    Returns a dict; `status` is "verified" or "failed".
    """
    out = {"status": "failed", "archive": "", "manifest": "", "entries": 0,
           "bytes": 0, "reason": ""}
    try:
        os.makedirs(dest_dir, exist_ok=True)
    except OSError as e:
        out["reason"] = "could not create the preservation directory %s: %s" % (dest_dir, e)
        return out

    facts = _git_facts(target.path, ws["repo"])
    entries = _walk_manifest(target.path, "workspace")

    gitdir = facts.get("git_dir") or ""
    gitdir_entries = []
    # A linked worktree's administrative directory sits inside the OWNING
    # repository, survives the rename, and is destroyed by `git worktree
    # prune`. It carries the index — the staged state — so it is preserved
    # here or the staged state is not preserved at all.
    if gitdir and os.path.isdir(gitdir) and os.path.realpath(gitdir) != os.path.realpath(
            os.path.join(target.path, ".git")):
        gitdir_entries = _walk_manifest(gitdir, "gitdir")
    all_entries = entries + gitdir_entries

    archive = os.path.join(dest_dir, "workspace.tar")
    try:
        with tarfile.open(archive, "w", format=tarfile.PAX_FORMAT) as tar:
            for e in all_entries:
                ti = tarfile.TarInfo(name=e["path"])
                ti.mode = e.get("mode", 0o644)
                if e["type"] == "dir":
                    ti.type = tarfile.DIRTYPE
                    tar.addfile(ti)
                elif e["type"] == "symlink":
                    ti.type = tarfile.SYMTYPE
                    ti.linkname = e["linkname"]
                    tar.addfile(ti)
                elif e["type"] == "file":
                    ti.size = e["size"]
                    with open(e["src"], "rb") as fh:
                        tar.addfile(ti, fh)
                    out["bytes"] += e["size"]
                else:
                    # Sockets, fifos and devices are recorded in the manifest
                    # and NOT archived. Named rather than silently dropped.
                    continue
    except Exception as e:
        out["reason"] = "archiving failed: %s" % e
        return out

    manifest = {
        "workspace": {k: ws[k] for k in ("id", "repo", "path", "branch", "class",
                                         "owners", "teammates", "sessions")},
        "fsid": target.fsid(),
        "git": facts,
        "entries": [{k: v for k, v in e.items() if k != "src"} for e in all_entries],
        "counts": {
            "files": sum(1 for e in all_entries if e["type"] == "file"),
            "dirs": sum(1 for e in all_entries if e["type"] == "dir"),
            "symlinks": sum(1 for e in all_entries if e["type"] == "symlink"),
            "other": sum(1 for e in all_entries if e["type"] == "other"),
            "untracked": len(facts.get("untracked") or []),
            "ignored": len(facts.get("ignored") or []),
            "staged": len(facts.get("staged") or []),
            "dirty": len(facts.get("dirty") or []),
        },
        "created": now_iso(),
    }
    mpath = os.path.join(dest_dir, "manifest.json")
    try:
        with open(mpath, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
    except Exception as e:
        out["reason"] = "could not write the manifest: %s" % e
        return out

    ok, why = verify_archive(archive, manifest)
    out["archive"] = archive
    out["manifest"] = mpath
    out["entries"] = len(all_entries)
    out["counts"] = manifest["counts"]
    out["git"] = {"head": facts.get("head"), "branch": facts.get("branch"),
                  "detached": facts.get("detached")}
    if not ok:
        out["reason"] = why
        return out
    out["status"] = "verified"
    out["reason"] = ("archive re-read and every member matched the digest taken from disk "
                     "(%d entries, %d bytes)" % (len(all_entries), out["bytes"]))
    return out


def verify_archive(archive, manifest):
    """Read the archive back and require it to reproduce the manifest exactly:
    the same member set, the same types, the same link targets, and for every
    regular file the same sha256 recomputed from the archived bytes."""
    want = {e["path"]: e for e in manifest.get("entries", []) if e["type"] != "other"}
    seen = {}
    try:
        with tarfile.open(archive, "r") as tar:
            for ti in tar:
                e = want.get(ti.name)
                if e is None:
                    return False, "archive holds an entry the manifest does not: %s" % ti.name
                if e["type"] == "file":
                    if not ti.isreg():
                        return False, "%s is a file on disk and not a file in the archive" % ti.name
                    fh = tar.extractfile(ti)
                    h = hashlib.sha256()
                    while True:
                        b = fh.read(1 << 20)
                        if not b:
                            break
                        h.update(b)
                    if h.hexdigest() != e["sha256"]:
                        return False, "archived bytes of %s do not match the digest read from disk" % ti.name
                elif e["type"] == "dir":
                    if not ti.isdir():
                        return False, "%s is a directory on disk and not one in the archive" % ti.name
                elif e["type"] == "symlink":
                    if not ti.issym() or ti.linkname != e.get("linkname"):
                        return False, "symlink %s does not match its recorded target" % ti.name
                seen[ti.name] = True
    except Exception as e:
        return False, "archive could not be re-read: %s" % e
    missing = sorted(set(want) - set(seen))
    if missing:
        return False, ("archive is missing %d entry/entries the manifest records, first: %s"
                       % (len(missing), missing[0]))
    return True, "ok"


def restore(ws_id, destination):
    """Extract the newest verified preservation archive for a workspace to a
    destination, then re-verify what landed against the manifest. This is what
    makes requirement 6 a claim rather than a hope: retention is worth nothing
    if the archive was never proven to reproduce the tree."""
    rec = last_preserving_record(ws_id)
    if not rec:
        return {"operation": "restore", "outcome": OUTCOME_REFUSED,
                "reason_code": "no-retirement-record",
                "reason": "no retirement or removal carrying a verified preservation "
                          "archive is on record for %s." % ws_id}
    pres = rec.get("preservation") or {}
    archive = pres.get("archive") or ""
    mpath = pres.get("manifest") or ""
    if not archive or not os.path.isfile(archive) or not os.path.isfile(mpath):
        return {"operation": "restore", "outcome": OUTCOME_FAILED,
                "reason_code": "archive-missing",
                "reason": "the recorded preservation archive is not on disk: %s" % archive}
    with open(mpath, encoding="utf-8") as f:
        manifest = json.load(f)
    ok, why = verify_archive(archive, manifest)
    if not ok:
        return {"operation": "restore", "outcome": OUTCOME_FAILED,
                "reason_code": "archive-corrupt", "reason": why}
    os.makedirs(destination, exist_ok=True)
    with tarfile.open(archive, "r") as tar:
        for ti in tar:
            tar.extract(ti, destination)
    # Re-verify on the extracted tree: the bytes that landed, not the bytes we
    # sent.
    bad = []
    for e in manifest.get("entries", []):
        p = os.path.join(destination, e["path"])
        if e["type"] == "file":
            if not os.path.isfile(p) or _sha256_file(p) != e["sha256"]:
                bad.append(e["path"])
        elif e["type"] == "dir":
            if not os.path.isdir(p):
                bad.append(e["path"])
        elif e["type"] == "symlink":
            if not os.path.islink(p) or os.readlink(p) != e.get("linkname"):
                bad.append(e["path"])
    if bad:
        return {"operation": "restore", "outcome": OUTCOME_FAILED,
                "reason_code": "restore-mismatch",
                "reason": "%d restored entry/entries do not match the manifest, first: %s"
                          % (len(bad), bad[0]),
                "destination": destination}
    return {"operation": "restore", "outcome": OUTCOME_OK,
            "destination": destination,
            "workspace": rec.get("workspace"),
            "entries": len(manifest.get("entries", [])),
            "counts": manifest.get("counts"),
            "git": manifest.get("git", {}).get("head"),
            "reason": "every recorded entry was restored and re-verified byte for byte."}


# --------------------------------------------------------------------------
# the termination authority — ONE function, consulted by EVERY path that destroys
# --------------------------------------------------------------------------

AUTH_BASIS_WITNESSED = "witnessed-termination"
AUTH_BASIS_OBSERVED = "observed-isolation-worktree"
AUTH_BASIS_SESSION = "session-provably-over"


def _owner_forms(owner):
    """'<id>' or 'agent-<id>' -> ('<id>', 'agent-<id>'); ('', '') for nothing."""
    o = (owner or "").strip()
    if not o:
        return "", ""
    bare = o[len("agent-"):] if o.startswith("agent-") else o
    return bare, "agent-" + bare


def _public_auth(auth):
    return {k: auth.get(k) for k in ("authorized", "verdict", "basis", "binding", "reason_code")}


def termination_authority(entity, repo, path, owner="", records=None, ledger_mod=None,
                          live_mod=None):
    """May THIS path be destroyed on the strength of what is known about its
    owner? Returns a dict; `authorized` is True only on BINDING and EVIDENCE.

    BINDING — the owner is tied to this exact path by one of exactly two
    things: an ownership record (`registered`/`prepared`) naming the path, or
    the path being that agent's own isolation worktree, registered in `repo`
    under the directory name the harness gives it. When `owner` is empty
    (retirement mode, where the record IS the caller's identity), a record
    must exist. Anything else is `owner-unbound` — and on 2026-09-05 the
    unbound owner was the whole incident: a string naming nobody, a real
    path, and a resolver truthfully reporting that nobody was locked here.

    EVIDENCE — NOT-ALIVE must rest on something that happened, never on
    something that is missing. Through a record, the ledger's `judge()`
    decides: it lands absence in INDETERMINATE by construction and returns
    NOT-ALIVE only for a witnessed termination, an OBSERVED registered
    isolation worktree that is unlocked or stale-locked, or a host session
    provably over. Through the native binding, the resolver's own evidence
    decides, and `registered` must be True: an unlocked or stale-locked
    worktree that IS there is an observation; a worktree that is not there is
    nothing.

    Never raises. Never writes. The verdict dict it consulted rides along as
    `liveness` so the record can carry it.
    """
    out = {"authorized": False, "verdict": "", "basis": "", "binding": "",
           "reason_code": "", "reason": "", "owner": owner or "", "liveness": None}
    if ledger_mod is None:
        out.update(reason_code="ledger-missing",
                   reason="scripts/lib/worktree-ledger.py could not be loaded; without the "
                          "ownership record nothing binds an owner to a path and nothing is "
                          "authorized.")
        return out
    if live_mod is None:
        out.update(reason_code="liveness-resolver-missing",
                   reason="scripts/lib/agent-liveness.py could not be loaded, so the isolation-"
                          "worktree lock cannot be read. A termination that cannot be witnessed "
                          "is not a termination.")
        return out
    if records is None:
        records = ledger_mod.read_all()
    bare, agent_dir = _owner_forms(owner)
    lp = lex_path(path)

    regs = ledger_mod.registrations(records, worktree=path)
    if not regs:
        regs = [r for r in records if r.get("event") in ledger_mod.OWNERSHIP_EVENTS
                and lex_path(r.get("worktree") or "") == lp]
    owners = sorted({(r.get("agent_id") or "").strip() for r in regs if r.get("agent_id")})
    teammates = sorted({(r.get("teammate") or "").strip() for r in regs if r.get("teammate")})

    if regs:
        if bare and bare not in owners and agent_dir not in owners \
                and bare not in teammates and (owner or "").strip() not in teammates:
            out.update(binding="ownership-record", reason_code="owner-unbound",
                       reason=("the ownership record for %s names owner(s) %s and teammate(s) %s — "
                               "not '%s'. An owner that does not match is a caller who does not "
                               "know what it is acting on, and whether THAT owner is alive says "
                               "nothing about this path. On 2026-09-05 exactly this shape deleted "
                               "the parent of every workspace on the machine."
                               % (lp, owners or "<none>", teammates or "<none>", owner)))
            return out
        out["binding"] = "ownership-record"
        v = ledger_mod.judge(entity, path, [], records, write=False, repo=repo, mod=live_mod)
        out["liveness"] = v
        out["verdict"] = v.get("verdict") or ""
        if v.get("verdict") != ledger_mod.NOT_ALIVE:
            word = str(v.get("verdict") or "unresolved").lower()
            out.update(reason_code="owner-" + word,
                       reason=("the owner of %s is %s: %s. Destroying a workspace requires a "
                               "POSITIVE, witnessed termination — never the ABSENCE of an owner, "
                               "which is what authorized the 2026-09-05 deletion."
                               % (lp, v.get("verdict"), v.get("reason"))))
            return out
        reason = v.get("reason") or ""
        if "witnessed termination" in reason:
            basis = AUTH_BASIS_WITNESSED
        elif "OBSERVED now" in reason:
            basis = AUTH_BASIS_OBSERVED
        else:
            basis = AUTH_BASIS_SESSION
        out.update(authorized=True, basis=basis, reason_code="terminated", reason=reason)
        return out

    # No ownership record names this path.
    if not bare:
        out.update(reason_code="owner-unbound",
                   reason=("no ownership record names %s and no owner was asserted. Nothing binds "
                           "anybody to this directory, so nothing is authorized." % lp))
        return out
    # The one other binding: the agent's OWN isolation worktree, registered
    # in the repository under the harness's directory name. Its registration
    # and lock are an observation about THIS path, not about another
    # directory somewhere else.
    try:
        rec = live_mod.resolve(repo, agent_dir)
    except Exception as e:
        out.update(reason_code="owner-indeterminate",
                   reason="the liveness resolver failed for %s in %s: %s" % (agent_dir, repo, e))
        return out
    out["liveness"] = rec
    out["verdict"] = rec.get("verdict") or ""
    ev = rec.get("evidence") or {}
    matched = ev.get("worktree_path") or ""
    if not ev.get("registered") or not same_path(matched, path):
        out.update(reason_code="owner-unbound",
                   reason=("no ownership record names %s, and it is not agent %s's own isolation "
                           "worktree in %s%s. The absence of a record says nothing about who owns "
                           "this directory, and the absence of a lock says nothing about whether "
                           "anyone stopped — it is true of every string that is not an agent id. "
                           "Nothing is removed. If this is really an orphan, look at it and remove "
                           "it by hand; if a caller built these arguments, the caller is the bug."
                           % (lp, agent_dir, lex_path(repo),
                              (" (the resolver matched %s instead)" % matched) if ev.get("registered") else "")))
        return out
    out["binding"] = "native-worktree"
    if rec.get("verdict") == live_mod.ALIVE:
        out.update(reason_code="owner-alive",
                   reason="agent %s is ALIVE: %s. Nothing is removed." % (agent_dir, rec.get("reason")))
        return out
    if rec.get("verdict") != live_mod.NOT_ALIVE:
        out.update(reason_code="owner-indeterminate",
                   reason=("agent %s is INDETERMINATE: %s. Failing closed — a worktree we cannot "
                           "prove dead is not removed." % (agent_dir, rec.get("reason"))))
        return out
    # NOT-ALIVE with registered=True: the worktree IS here and is unlocked,
    # or locked by a pid that is provably dead. An observation of this path.
    out.update(authorized=True, basis=AUTH_BASIS_OBSERVED, reason_code="terminated",
               reason="OBSERVED now: " + (rec.get("reason") or ""))
    if ledger_mod.terminations(records, bare):
        out["reason"] += " (a witnessed termination for this agent is also on record)"
    return out


def _rename_back(target, qbase):
    """Undo a quarantine rename through the SAME parent descriptor it was
    made through. None on success, else the error text. The directory inode
    is unchanged either way; only its name moves."""
    try:
        if os.rename in os.supports_dir_fd:
            os.rename(qbase, target.base, src_dir_fd=target.pfd, dst_dir_fd=target.pfd)
        else:
            os.rename(os.path.join(target.parent, qbase), target.path)
        return None
    except OSError as e:
        return str(e)


def _reacquired_since(ws, mod, live_mod, lock_entity):
    """Re-read the ownership records and re-run the authority for a workspace
    already validated. ("", "") when nothing changed; else (code, why)."""
    fresh = resolve_workspace(ws["id"], ledger=mod)
    if not fresh.get("ok"):
        return fresh["reason_code"], fresh["reason"]
    if fresh["record_signature"] != ws["record_signature"]:
        return "reacquired", ("the ownership records for %s changed (%s -> %s): a worker acquired "
                              "this workspace while retirement was in flight."
                              % (ws["id"], ws["record_signature"], fresh["record_signature"]))
    auth = termination_authority(lock_entity, ws["repo"], ws["path"], records=fresh["_all"],
                                 ledger_mod=mod, live_mod=live_mod)
    if not auth["authorized"]:
        return auth["reason_code"], auth["reason"]
    return "", ""


# --------------------------------------------------------------------------
# the legacy, path-addressed route — a ROUTE, with no authority of its own
# --------------------------------------------------------------------------

def remove_legacy(entity, repo, path, owner, force=False, branch="", lock_wait=5.0,
                  dry_run=False):
    """`remove-agent-worktree.sh --owner <id> <path>`: the reaper's route and
    the operator's, now decided HERE and nowhere else.

    Until 2026-09-06 the shell helper decided this itself by asking the lock
    resolver about the owner and proceeding on NOT-ALIVE — which the resolver
    returns for an owner that does not exist. The 2026-09-05 containment
    stopped the recursive delete of an unregistered path and left that
    decision in place; the review reproduced it against a registered worktree
    whose real owner was verified ALIVE. This function runs the same
    `termination_authority()` as retirement, takes the same workspace lock,
    preserves (verified) when `--force` could destroy dirty content, writes
    its intent to the same journal before the removal and the completion
    after it, and copies the positive verdict to the ownership ledger.

    It still REMOVES rather than quarantines: the reaper relies on the
    directory being gone and on deleting the branch itself with `-d`, and an
    operator with `--force` has already collected artifacts. What it never
    does is decide from absence, act on an owner it cannot bind to the path,
    or touch a directory that is not a registered worktree of `repo`.
    """
    bare, agent_dir = _owner_forms(owner)
    p = lex_path(path)
    r = lex_path(repo)
    e_lock = lex_path(entity) if entity else r
    out = {"operation": "authorize" if dry_run else "remove", "ts": now_iso(),
           "owner": owner or "", "owner_id": agent_dir, "path": p, "repo": r,
           "entity": e_lock, "force": bool(force), "branch": {"name": branch, "deleted": False}}

    def refuse(code, reason, extra=None, exit_code=None):
        out.update({"outcome": OUTCOME_REFUSED, "reason_code": code, "reason": reason})
        if extra:
            out.update(extra)
        if exit_code is not None:
            out["exit"] = exit_code
        return out

    def failed(stage, code, reason, extra=None):
        out.update({"outcome": OUTCOME_FAILED, "stage": stage, "reason_code": code, "reason": reason})
        if extra:
            out.update(extra)
        return out

    if not p or not bare:
        return refuse("usage", "--owner and a worktree path are both required.", exit_code=EXIT_USAGE)
    if p == "/" or os.path.dirname(p) == p:
        return refuse("path-is-root", "%s has no parent; it is not a worktree." % p)
    mod = _ledger_module()
    live_mod = mod._liveness_module() if mod is not None else None
    if mod is None:
        return refuse("ledger-missing", "scripts/lib/worktree-ledger.py could not be loaded; "
                                        "nothing binds an owner to a path without it.")
    records = mod.read_all()

    reg_paths = registered_worktree_paths(r)
    if reg_paths is None:
        return refuse("repo-unreadable",
                      "git could not list the worktrees of %s, so it is not established that %s is "
                      "one of them. Failing closed." % (r, p))

    # A container first: the incident's target was a parent directory, and a
    # directory that holds other worktrees is refused whatever else it is.
    for other in sorted(known_workspace_paths(records) | {lex_path(x) for x in reg_paths}
                        | {norm_path(x) for x in reg_paths}):
        if _is_proper_ancestor(p, other):
            return refuse("path-is-parent",
                          "%s CONTAINS another worktree (%s). A directory that holds other "
                          "workspaces is a container, not a workspace; on 2026-09-05 this shape "
                          "took every workspace on the machine. Nothing is removed."
                          % (p, other), exit_code=EXIT_UNREGISTERED)

    if not any(same_path(p, x) for x in reg_paths):
        if os.path.isdir(p) or os.path.islink(p):
            return refuse("not-registered-worktree",
                          "%s is a directory, and it is NOT a registered worktree of %s. This is the "
                          "case where nothing has established what the path IS — so it is the case "
                          "where this operation does least, not most. Until 2026-09-05 it did an "
                          "unconditional 'rm -rf' here and deleted the parent directory of every "
                          "RichOS worktree on the machine, reporting success. If this really is an "
                          "orphaned agent directory, look at it and remove it by hand. If a caller "
                          "built this path, the caller is the bug." % (p, r),
                          exit_code=EXIT_UNREGISTERED)
        return refuse("path-absent",
                      "nothing exists at %s and %s does not register it. There is nothing to remove, "
                      "and a branch is not deleted on the strength of a path that is not there."
                      % (p, r))

    ws_id = workspace_id(r, p)
    ws = {"id": ws_id, "repo": r, "path": p, "branch": branch, "class": "", "owners": [bare],
          "teammates": [], "sessions": [], "records": 0, "record_signature": ""}
    out["workspace"] = _public_ws(ws)

    target = FsTarget(p)
    if not target.open():
        return refuse(target.error_code, target.error)
    try:
        fsid = target.fsid()
        dotgit = os.path.join(p, ".git")
        if not os.path.lexists(dotgit):
            return refuse("not-a-worktree-root", "%s has no .git entry; it is not a git worktree." % p,
                          exit_code=EXIT_UNREGISTERED)
        if os.path.isdir(dotgit) and not os.path.islink(dotgit):
            return refuse("main-checkout", "%s has a .git DIRECTORY: it is a repository's main "
                                           "checkout, never a removal target." % p)

        auth = termination_authority(e_lock, r, p, owner=bare, records=records,
                                     ledger_mod=mod, live_mod=live_mod)
        out["liveness"] = auth.get("liveness")
        out["authority"] = _public_auth(auth)
        if not auth["authorized"]:
            return refuse(auth["reason_code"], auth["reason"])

        if dry_run:
            out.update({"outcome": OUTCOME_OK, "reason_code": "would-remove",
                        "reason": "every gate passed; nothing was mutated (authorize only)."})
            return out

        ok, why = journal_probe()
        if not ok:
            return failed("journal", "journal-unwritable",
                          "%s. A removal nobody can find the record of does not begin. Nothing was "
                          "removed." % why)

        lock = WorkspaceLock(ws_id, wait_seconds=lock_wait)
        if not lock.acquire():
            if lock.error:
                return failed("lock", "lock-unavailable", "%s. Nothing was removed." % lock.error)
            return refuse("workspace-busy",
                          "another operation holds the workspace lock for %s (%s). Nothing was "
                          "removed." % (ws_id, lock.path))
        try:
            records2 = mod.read_all()
            auth2 = termination_authority(e_lock, r, p, owner=bare, records=records2,
                                          ledger_mod=mod, live_mod=live_mod)
            out["liveness"] = auth2.get("liveness")
            out["authority"] = _public_auth(auth2)
            if not auth2["authorized"]:
                return refuse(auth2["reason_code"], "under the lock, " + auth2["reason"])
            if not target.still_the_same():
                return refuse("identity-changed",
                              "%s is no longer the object validated a moment ago (%s). Nothing "
                              "was removed." % (p, fsid))

            pres = None
            if force:
                # --force is the flag that lets git destroy dirty and
                # untracked content. So it is the flag that preserves first.
                dest = os.path.join(preserved_dir(), ws_id, _stamp())
                pres = preserve(ws, target, dest)
                out["preservation"] = pres
                if pres.get("status") != "verified":
                    rec = failed("preservation", "preservation-failed",
                                 "preservation did not verify (%s). Nothing was removed; the "
                                 "worktree is untouched at %s." % (pres.get("reason"), p))
                    append_record(rec)
                    return rec

            head = _git_out(p, "rev-parse", "HEAD")
            cur_branch = _git_out(p, "symbolic-ref", "--short", "HEAD")
            backup_ref = ""
            if head:
                backup_ref = "refs/richos/retired/%s/%s" % (ws_id, cur_branch or branch or "HEAD")
                rr = _git(r, "update-ref", backup_ref, head)
                if rr is None or rr.returncode != 0:
                    rec = failed("backup-ref", "backup-ref-failed",
                                 "could not create the backup ref %s in %s. Nothing was removed."
                                 % (backup_ref, r))
                    append_record(rec)
                    return rec
            out["branch"] = {"name": branch, "checked_out": cur_branch, "backup_ref": backup_ref,
                             "head": head, "deleted": False}

            intent = dict(out)
            intent.update({"outcome": OUTCOME_IN_PROGRESS, "stage": "remove-intent",
                           "ts": now_iso(), "fsid": fsid})
            if not append_record(intent):
                return failed("journal", "journal-unwritable",
                              "the retirement journal at %s would not take the intent record. "
                              "Nothing was removed." % records_path())

            if not target.still_the_same():
                rec = refuse("identity-changed",
                             "%s changed identity after the intent was recorded. Nothing was "
                             "removed." % p)
                append_record(rec)
                return rec

            # A dead agent's native worktree may still carry a stale lock;
            # unlock so `git worktree remove` proceeds (no-op if not locked).
            _git(r, "worktree", "unlock", p)
            args = ["worktree", "remove"] + (["--force"] if force else []) + [p]
            rm = _git(r, *args)
            if rm is None or rm.returncode != 0:
                rec = failed("remove", "remove-failed",
                             "'git worktree remove' exited %s for %s (repo %s): %s. The worktree "
                             "likely has untracked/modified files. Collect any artifacts first "
                             "(scripts/collect-worktree-artifacts.sh), then re-run with --force."
                             % (rm.returncode if rm else "?", p, r,
                                (rm.stderr.strip() if rm else "git could not run")))
                append_record(rec)
                return rec
            _git(r, "worktree", "prune")

            if branch:
                if _git_out(r, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch):
                    d = _git(r, "branch", "-D", branch)
                    if d is not None and d.returncode == 0:
                        out["branch"]["deleted"] = True
                    else:
                        out["branch"]["note"] = ("could not delete branch %s (%s); its tip stays "
                                                 "reachable from %s" % (
                                                     branch, (d.stderr.strip() if d else "git could not run"),
                                                     backup_ref or "<no backup ref>"))
                else:
                    out["branch"]["note"] = "branch %s not found in %s — nothing to delete" % (branch, r)

            # An OBSERVATION is copied to the ownership ledger: the isolation
            # worktree this removal (or a later one) destroys is the only
            # evidence a hand-rolled tree in another repository ever had
            # about its owner, so the verdict is written down before it is
            # gone. ONLY an observation. A witnessed termination is already
            # on record. A session-over inference rests on the process table
            # and the session registry, which outlive this removal and can
            # be re-derived at any time — persisting it would upgrade the
            # weakest positive evidence into "witnessed termination on
            # record" for every later sweep (the reaper's own suite catches
            # exactly that: its case 20c re-registers a reaped agent under an
            # unaccounted process and requires INDETERMINATE, not a reap on
            # the strength of what an earlier run concluded).
            if auth2.get("basis") == AUTH_BASIS_OBSERVED and not mod.terminations(records2, bare):
                mod.append({"event": "terminated", "agent_id": bare, "worktree": p,
                            "reason": auth2["reason"], "witness": "remove-agent-worktree"})

            out.update({"outcome": OUTCOME_OK, "reason_code": "removed", "ts": now_iso(),
                        "reason": "%s removed from %s (%s: %s)%s."
                                  % (p, r, auth2.get("basis"), auth2.get("reason"),
                                     "; preserved and verified first" if pres else "")})
            out["journal"] = "complete" if append_record(out) else "incomplete"
            return out
        finally:
            lock.release()
    finally:
        target.close()


def reconcile():
    """Every retirement or removal INTENT with no later record resolving it,
    and what the disk says about it now. Reports; never mutates.

    A dangling intent is what a crash — or a journal that stopped taking
    writes — between the intent and the completion leaves behind. The sweep
    never erases from an intent, so a `quarantined-uncommitted` directory is
    safe where it stands; `restore` can extract its archive.
    """
    recs = read_records()
    out = []
    for i, r in enumerate(recs):
        if r.get("outcome") != OUTCOME_IN_PROGRESS or r.get("operation") not in ("retire", "remove"):
            continue
        wsid = (r.get("workspace") or {}).get("id") or ""
        op = r.get("operation")
        later = [x for x in recs[i + 1:]
                 if (x.get("workspace") or {}).get("id") == wsid and x.get("operation") == op
                 and x.get("outcome") in (OUTCOME_QUARANTINED, OUTCOME_OK, OUTCOME_FAILED,
                                          OUTCOME_REFUSED)]
        if later:
            continue
        q = r.get("quarantine") or {}
        src = q.get("source_path") or (r.get("workspace") or {}).get("path") or r.get("path") or ""
        qp = q.get("path") or ""
        arc = (r.get("preservation") or {}).get("archive") or ""
        item = {"workspace": wsid, "operation": op, "intent_ts": r.get("ts"),
                "source_path": src, "quarantine_path": qp,
                "source_present": bool(src and os.path.lexists(src)),
                "quarantine_present": bool(qp and os.path.lexists(qp)),
                "archive": arc, "archive_present": bool(arc and os.path.isfile(arc))}
        if item["quarantine_present"] and not item["source_present"]:
            item["state"] = ("quarantined-uncommitted: the directory was moved and the completion "
                             "record never landed. The quarantine is intact and the sweep never "
                             "erases from an intent; `restore` extracts the archive.")
        elif item["source_present"] and not item["quarantine_present"]:
            item["state"] = ("source-present: the operation did not complete (or was undone); "
                             "the workspace is at its own path and nothing needs recovering.")
        elif item["source_present"] and item["quarantine_present"]:
            item["state"] = ("both-present: a replacement occupies the source path and the "
                             "quarantine is intact.")
        else:
            item["state"] = ("neither-present: the source is gone and so is the quarantine (a "
                             "legacy removal, or somebody erased by hand). The archive is the "
                             "recovery copy if it is present.")
        out.append(item)
    return {"operation": "reconcile", "outcome": OUTCOME_OK, "dangling": out, "ts": now_iso()}

# --------------------------------------------------------------------------
# retirement
# --------------------------------------------------------------------------

def _refusal(ws_id, code, reason, ws=None, extra=None):
    rec = {"operation": "retire", "outcome": OUTCOME_REFUSED, "reason_code": code,
           "reason": reason, "ts": now_iso(),
           "workspace": _public_ws(ws) if ws else {"id": ws_id}}
    if extra:
        rec.update(extra)
    return rec


def _public_ws(ws):
    if not ws:
        return {}
    return {k: ws.get(k) for k in ("id", "repo", "path", "branch", "class",
                                   "owners", "teammates", "sessions", "records",
                                   "record_signature")}


def retire(ws_id, assert_owner="", assert_repo="", assert_path="",
           dry_run=False, retention=None, lock_wait=5.0, entity=""):
    """The retirement operation. Returns a structured outcome dict.

    `entity` is the repository whose isolation-worktree LOCK is authoritative
    for liveness — the session's own repository, resolved by the caller
    through the engine's two-root contract. It is NOT a target: it can only
    change which lock is read, never which directory is acted on. For a native
    isolation worktree the entity and the owning repository are the same, so
    it defaults to the repository derived from the record.
    """
    ws = resolve_workspace(ws_id)
    if not ws.get("ok"):
        return _refusal(ws_id, ws["reason_code"], ws["reason"])

    mod = ws["_mod"]
    ws_id = ws["id"]

    # --- Requirement 2: the assertions. A caller-supplied owner, repository
    # or path can only AGREE with the record; it can never widen the target.
    if assert_owner:
        want = assert_owner.strip()
        want_bare = want[len("agent-"):] if want.startswith("agent-") else want
        known = set(ws["owners"]) | {"agent-" + o for o in ws["owners"]} | set(ws["teammates"])
        if want not in known and want_bare not in known:
            return _refusal(ws_id, "owner-mismatch",
                            "the asserted owner '%s' is not an owner of %s. The record names "
                            "owner(s) %s and teammate(s) %s. An owner that does not match is a "
                            "caller who does not know what it is acting on, and on 2026-09-05 "
                            "that caller deleted the parent of every workspace on the machine."
                            % (assert_owner, ws_id, ws["owners"] or "<none>",
                               ws["teammates"] or "<none>"), ws)
    if assert_repo and not same_path(assert_repo, ws["repo"]):
        return _refusal(ws_id, "repo-mismatch",
                        "the asserted repository %s is not the repository this workspace belongs "
                        "to (%s)." % (lex_path(assert_repo), ws["repo"]), ws)
    if assert_path and not same_path(assert_path, ws["path"]):
        return _refusal(ws_id, "path-mismatch",
                        "the asserted path %s is not this workspace's path (%s)."
                        % (lex_path(assert_path), ws["path"]), ws)

    # --- Requirement 2: never a parent. Two independent checks, because the
    # incident's target was a parent directory and nothing stopped it.
    all_paths = known_workspace_paths(ws["_all"])
    reg_paths = registered_worktree_paths(ws["repo"])
    for other in sorted(all_paths | set(lex_path(p) for p in (reg_paths or []))
                        | set(norm_path(p) for p in (reg_paths or []))):
        if _is_proper_ancestor(ws["path"], other):
            return _refusal(ws_id, "path-is-parent",
                            "%s CONTAINS another known workspace (%s). A directory that holds "
                            "other workspaces is a container, not a workspace, and retiring it "
                            "would take every workspace inside it — which is exactly what "
                            "happened on 2026-09-05." % (ws["path"], other), ws)

    # --- Requirement 2 + 3: the object on disk must BE a linked worktree.
    target = FsTarget(ws["path"])
    prior = last_retirement(ws_id)
    if not target.open():
        if target.error_code == "path-absent":
            if prior:
                return {"operation": "retire", "outcome": OUTCOME_ALREADY,
                        "reason_code": "already-retired", "ts": now_iso(),
                        "workspace": _public_ws(ws),
                        "quarantine": prior.get("quarantine"),
                        "preservation": prior.get("preservation"),
                        "reason": "this workspace was already retired at %s; its path no longer "
                                  "exists and nothing was done." % prior.get("ts")}
            return _refusal(ws_id, "path-absent",
                            "the ownership record names %s, and nothing is there. No retirement "
                            "of this workspace is on record either, so what happened to it is "
                            "unknown and this operation does not act on unknowns."
                            % ws["path"], ws)
        return _refusal(ws_id, target.error_code, target.error, ws)

    try:
        fsid = target.fsid()

        # A replacement workspace at a retired path: the row the diagnosis
        # asks for by name. If we already retired this ID and something is
        # there now, it is NOT the thing we retired, and it is not ours.
        if prior:
            prior_fsid = (prior.get("quarantine") or {}).get("source_fsid")
            if prior_fsid and prior_fsid != fsid:
                return {"operation": "retire", "outcome": OUTCOME_ALREADY,
                        "reason_code": "already-retired-path-reoccupied", "ts": now_iso(),
                        "workspace": _public_ws(ws),
                        "quarantine": prior.get("quarantine"),
                        "reason": ("this workspace was already retired at %s. A DIFFERENT "
                                   "filesystem object now occupies %s (recorded %s, present %s) "
                                   "— it is a replacement and this operation will not touch it."
                                   % (prior.get("ts"), ws["path"], prior_fsid, fsid))}

        dotgit = os.path.join(ws["path"], ".git")
        if not os.path.lexists(dotgit):
            return _refusal(ws_id, "not-a-worktree-root",
                            "%s has no .git entry, so it is not a git worktree at all. This is "
                            "the shape of the 2026-09-05 target: a plain directory that merely "
                            "CONTAINED worktrees." % ws["path"], ws)
        if os.path.isdir(dotgit) and not os.path.islink(dotgit):
            return _refusal(ws_id, "main-checkout",
                            "%s has a .git DIRECTORY, so it is a repository's main checkout, not "
                            "a linked worktree. Retirement acts only on linked worktrees."
                            % ws["path"], ws)

        if reg_paths is None:
            return _refusal(ws_id, "repo-unreadable",
                            "git could not list the worktrees of %s, so it is not established "
                            "that %s is one of them. Failing closed."
                            % (ws["repo"], ws["path"]), ws)
        if not any(same_path(ws["path"], p) for p in reg_paths):
            return _refusal(ws_id, "not-registered-worktree",
                            "%s is not a worktree git registers for %s. An unregistered target "
                            "is where nothing has established what the path is, so it is where "
                            "this operation does least — until 2026-09-05 it did MOST here, an "
                            "unconditional recursive delete." % (ws["path"], ws["repo"]), ws)

        # --- Requirement 4: verified termination, on POSITIVE evidence only,
        # decided by the ONE authority every destructive path consults.
        #
        # THE RESOLVER IS PASSED EXPLICITLY, and this line is why. `judge()`
        # takes the liveness module as a keyword argument that DEFAULTS TO
        # None, and with None it skips the isolation-lock check entirely and
        # falls through to the session-identity evidence. The first version of
        # this call omitted it. Everything still ran, every refusal still
        # refused, and the suite still went green on nine of ten rows — but a
        # LIVE agent holding a locked worktree resolved INDETERMINATE instead
        # of ALIVE, because the lock was never read.
        #
        # That is the exact failure class this whole change exists to stop: a
        # check reporting an answer over something that never ran. It was
        # caught by the one row that asserted the SPECIFIC reason code rather
        # than "it refused", which is why every case in the suite asserts the
        # reason and not just the exit status.
        live_mod = mod._liveness_module()
        if live_mod is None:
            return _refusal(ws_id, "liveness-resolver-missing",
                            "scripts/lib/agent-liveness.py could not be loaded, so the "
                            "isolation-worktree lock — the ONE authoritative liveness signal — "
                            "cannot be read. Failing closed: a termination that cannot be "
                            "witnessed is not a termination.", ws)
        lock_entity = lex_path(entity) if entity else ws["repo"]
        auth = termination_authority(lock_entity, ws["repo"], ws["path"], records=ws["_all"],
                                     ledger_mod=mod, live_mod=live_mod)
        verdict = auth.get("liveness")
        if not auth["authorized"]:
            return _refusal(ws_id, auth["reason_code"], auth["reason"], ws,
                            {"liveness": verdict, "authority": _public_auth(auth)})

        if dry_run:
            return {"operation": "retire", "outcome": OUTCOME_OK, "dry_run": True,
                    "reason_code": "would-retire", "ts": now_iso(),
                    "workspace": _public_ws(ws), "liveness": verdict,
                    "authority": _public_auth(auth), "fsid": fsid,
                    "reason": "every gate passed; nothing was mutated because --dry-run was given."}

        # --- Requirement 8, its precondition: the journal must be able to
        # take a record BEFORE anything moves (review 2026-09-06, finding 3).
        ok, why = journal_probe()
        if not ok:
            return {"operation": "retire", "outcome": OUTCOME_FAILED, "stage": "journal",
                    "reason_code": "journal-unwritable", "ts": now_iso(),
                    "workspace": _public_ws(ws), "liveness": verdict,
                    "reason": ("%s. A retirement nobody can find the record of is a workspace "
                               "nobody can find, so it does not begin. The workspace was NOT "
                               "touched and is still at %s." % (why, ws["path"]))}

        # --- Requirement 4 (second half): serialize.
        lock = WorkspaceLock(ws_id, wait_seconds=lock_wait)
        if not lock.acquire():
            if lock.error:
                rec = {"operation": "retire", "outcome": OUTCOME_FAILED, "stage": "lock",
                       "reason_code": "lock-unavailable", "ts": now_iso(),
                       "workspace": _public_ws(ws),
                       "reason": ("%s. Retirement is serialized against worker startup and will "
                                  "not proceed unserialized. The workspace was NOT touched."
                                  % lock.error)}
                append_record(rec)
                return rec
            return _refusal(ws_id, "workspace-busy",
                            "another operation holds the retirement lock for %s (%s). Retirement "
                            "is serialized; it never proceeds beside a caller that may be "
                            "acquiring this workspace." % (ws_id, lock.path), ws)
        try:
            # Re-read the record set UNDER the lock. A record that appeared
            # between resolution and now means somebody took this workspace.
            fresh = resolve_workspace(ws_id, ledger=mod)
            if not fresh.get("ok"):
                return _refusal(ws_id, fresh["reason_code"], fresh["reason"], ws)
            if fresh["record_signature"] != ws["record_signature"]:
                return _refusal(ws_id, "reacquired",
                                "the ownership records for %s changed between validation (%s) "
                                "and the lock (%s) — a worker acquired this workspace while "
                                "retirement was deciding. Nothing was done."
                                % (ws_id, ws["record_signature"], fresh["record_signature"]),
                                fresh)
            auth2 = termination_authority(lock_entity, ws["repo"], ws["path"],
                                          records=fresh["_all"], ledger_mod=mod, live_mod=live_mod)
            verdict2 = auth2.get("liveness")
            if not auth2["authorized"]:
                return _refusal(ws_id, auth2["reason_code"],
                                "under the lock, " + auth2["reason"], ws,
                                {"liveness": verdict2, "authority": _public_auth(auth2)})
            if not target.still_the_same():
                return _refusal(ws_id, "identity-changed",
                                "%s is no longer the object validated a moment ago (recorded "
                                "%s). A path that changed under us is never acted on."
                                % (ws["path"], fsid), ws)

            # --- Requirement 5: preserve, and PROVE the preservation.
            dest = os.path.join(preserved_dir(), ws_id, _stamp())
            pres = preserve(ws, target, dest)
            if pres.get("status") != "verified":
                rec = {"operation": "retire", "outcome": OUTCOME_FAILED,
                       "stage": "preservation", "reason_code": "preservation-failed",
                       "ts": now_iso(), "workspace": _public_ws(ws),
                       "preservation": pres, "liveness": verdict2,
                       "reason": ("preservation did not verify (%s). The workspace was NOT "
                                  "touched and is still at %s." % (pres.get("reason"), ws["path"]))}
                append_record(rec)
                return rec

            # --- Requirement 7 (its first half): the branch's tip is made
            # reachable from a ref that is not the branch, BEFORE anything
            # moves. Branch DELETION is a separate operation.
            backup_ref = ""
            head = (pres.get("git") or {}).get("head") or ""
            branch = (pres.get("git") or {}).get("branch") or ws.get("branch") or ""
            if head:
                backup_ref = "refs/richos/retired/%s/%s" % (ws_id, branch or "HEAD")
                r = _git(ws["repo"], "update-ref", backup_ref, head)
                if r is None or r.returncode != 0:
                    rec = {"operation": "retire", "outcome": OUTCOME_FAILED,
                           "stage": "backup-ref", "reason_code": "backup-ref-failed",
                           "ts": now_iso(), "workspace": _public_ws(ws),
                           "preservation": pres,
                           "reason": ("could not create the backup ref %s in %s. The workspace "
                                      "was NOT touched." % (backup_ref, ws["repo"]))}
                    append_record(rec)
                    return rec

            # --- THE RACE, LAYER ONE (review 2026-09-06, finding 2). The
            # preservation took time, and a worker may have acquired this
            # workspace while it ran. Re-read the records and the verdict
            # BEFORE the rename; anything changed refuses, nothing moves.
            code, why = _reacquired_since(ws, mod, live_mod, lock_entity)
            if code:
                return _refusal(ws_id, code,
                                "after preservation and before the rename, %s Nothing was renamed; "
                                "the workspace is untouched at %s. The preservation archive at %s "
                                "is harmless and may be discarded."
                                % (why, ws["path"], pres.get("archive")), ws,
                                {"preservation": pres})
            if not target.still_the_same():
                return _refusal(ws_id, "identity-changed",
                                "%s changed identity between preservation and quarantine. "
                                "Nothing was renamed." % ws["path"], ws)

            # --- Requirement 8 (finding 3): the INTENT is on record before
            # the move. If it cannot be, the move does not happen.
            qbase = "%s.richos-retired-%s-%s" % (target.base, ws_id, _stamp())
            qplanned = os.path.join(target.parent, qbase)
            binfo = {"name": branch, "backup_ref": backup_ref, "head": head, "deleted": False,
                     "note": "branch deletion is a separate operation (retire-branch)"}
            intent = {"operation": "retire", "outcome": OUTCOME_IN_PROGRESS,
                      "stage": "quarantine-intent", "ts": now_iso(),
                      "workspace": _public_ws(ws), "liveness": verdict2, "preservation": pres,
                      "quarantine": {"path": qplanned, "source_path": ws["path"],
                                     "source_fsid": fsid},
                      "branch": binfo,
                      "reason": "about to rename %s to %s" % (ws["path"], qplanned)}
            if not append_record(intent):
                return {"operation": "retire", "outcome": OUTCOME_FAILED, "stage": "journal",
                        "reason_code": "journal-unwritable", "ts": now_iso(),
                        "workspace": _public_ws(ws), "preservation": pres,
                        "reason": ("the retirement journal at %s would not take the intent "
                                   "record. Nothing was renamed; the workspace is untouched at "
                                   "%s." % (records_path(), ws["path"]))}

            # --- Requirement 6: quarantine by RENAME. Nothing is deleted.
            try:
                qpath = target.rename_to(qbase)
            except OSError as e:
                rec = {"operation": "retire", "outcome": OUTCOME_FAILED,
                       "stage": "quarantine", "reason_code": "quarantine-failed",
                       "ts": now_iso(), "workspace": _public_ws(ws), "preservation": pres,
                       "reason": ("the quarantine rename of %s failed: %s. The workspace is "
                                  "UNCHANGED and still available at its own path."
                                  % (ws["path"], e))}
                append_record(rec)
                return rec

            try:
                qst = os.lstat(qpath)
                qfsid = "%d:%d" % (qst.st_dev, qst.st_ino)
            except OSError:
                qfsid = ""

            # --- THE RACE, LAYER TWO. A worker that acquired in the
            # microseconds between layer one and the rename is found HERE,
            # and the rename is undone through the same parent descriptor.
            # Its cwd followed the inode both ways; its files are where it
            # put them.
            code, why = _reacquired_since(ws, mod, live_mod, lock_entity)
            if code:
                undo = _rename_back(target, qbase)
                if undo is None:
                    rec = _refusal(ws_id, code + "-after-quarantine",
                                   "after the rename, %s The rename was UNDONE: the workspace is "
                                   "back at %s, byte for byte, and nothing was pruned. The "
                                   "preservation archive at %s is harmless."
                                   % (why, ws["path"], pres.get("archive")), ws,
                                   {"preservation": pres, "quarantine": None})
                else:
                    rec = {"operation": "retire", "outcome": OUTCOME_FAILED,
                           "stage": "quarantine-undo", "reason_code": code + "-after-quarantine",
                           "ts": now_iso(), "workspace": _public_ws(ws), "preservation": pres,
                           "quarantine": {"path": qpath, "source_path": ws["path"],
                                          "source_fsid": fsid, "fsid": qfsid},
                           "reason": ("after the rename, %s The rename back FAILED (%s): the "
                                      "workspace is at %s, intact, and nothing was pruned. "
                                      "Anything written after preservation is there too; the "
                                      "sweep never erases from an intent."
                                      % (why, undo, qpath))}
                append_record(rec)
                return rec

            # --- Requirement 8: the COMPLETION record — BEFORE git forgets
            # the worktree, so that if it cannot be written the rename can
            # still be undone into a worktree git still knows.
            until = datetime.now(timezone.utc) + timedelta(days=retention_days(retention))
            rec = {
                "operation": "retire", "outcome": OUTCOME_QUARANTINED, "ts": now_iso(),
                "workspace": _public_ws(ws),
                "liveness": verdict2,
                "authority": _public_auth(auth2),
                "preservation": pres,
                "quarantine": {
                    "path": qpath, "source_path": ws["path"], "source_fsid": fsid,
                    "fsid": qfsid,
                    "retain_until": until.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                    "retention_days": retention_days(retention),
                },
                "branch": binfo,
                "git_worktree_prune": "pending",
                "reason": ("the workspace was preserved (verified), its tip made reachable from "
                           "%s, and its directory RENAMED to quarantine. Nothing was deleted."
                           % (backup_ref or "<no head>")),
            }
            if not append_record(rec):
                undo = _rename_back(target, qbase)
                fail = {"operation": "retire", "outcome": OUTCOME_FAILED,
                        "stage": "journal-completion", "reason_code": "journal-unwritable",
                        "ts": now_iso(), "workspace": _public_ws(ws), "preservation": pres}
                if undo is None:
                    fail["reason"] = ("the retirement journal at %s would not take the completion "
                                      "record. The rename was UNDONE: the workspace is back at %s "
                                      "and git still registers it. No retirement is reported "
                                      "because none is on record." % (records_path(), ws["path"]))
                else:
                    fail["quarantine"] = {"path": qpath, "source_path": ws["path"],
                                          "source_fsid": fsid, "fsid": qfsid}
                    fail["reason"] = ("the retirement journal at %s would not take the completion "
                                      "record, and the rename back failed (%s). The workspace is "
                                      "at %s, intact, still registered with git, and named by the "
                                      "intent record; `reconcile` lists it and `restore` extracts "
                                      "the archive." % (records_path(), undo, qpath))
                return fail

            prune = _git(ws["repo"], "worktree", "prune")
            rec["git_worktree_prune"] = "ok" if (prune is not None and prune.returncode == 0) else "failed"
            append_record({"operation": "retire", "outcome": "note", "stage": "prune",
                           "ts": now_iso(), "workspace": _public_ws(ws),
                           "quarantine": rec["quarantine"],
                           "git_worktree_prune": rec["git_worktree_prune"]})
            return rec
        finally:
            lock.release()
    finally:
        target.close()

# --------------------------------------------------------------------------
# requirement 7: branch retirement, separate, with its own checks
# --------------------------------------------------------------------------

def retire_branch(ws_id, retention=None, dry_run=False):
    """Delete a retired workspace's branch — and ONLY when its commits stay
    reachable without it.

    Kept separate from workspace retirement on purpose. A branch is the last
    reference to work an engineer committed; the workspace directory is
    reproducible from it, and not the other way round. It has its own
    retention clock, and it refuses unless the backup ref this module wrote
    still points at the exact tip being deleted.
    """
    rec = last_retirement(ws_id)
    if not rec:
        return {"operation": "retire-branch", "outcome": OUTCOME_REFUSED,
                "reason_code": "not-retired",
                "reason": "no completed workspace retirement is on record for %s. The branch of "
                          "a live workspace is never deleted." % ws_id,
                "workspace": {"id": ws_id}}
    ws = rec.get("workspace") or {}
    repo = ws.get("repo") or ""
    binfo = rec.get("branch") or {}
    branch = binfo.get("name") or ""
    backup_ref = binfo.get("backup_ref") or ""
    head = binfo.get("head") or ""
    out = {"operation": "retire-branch", "workspace": ws, "branch": branch,
           "backup_ref": backup_ref, "ts": now_iso()}

    if not branch:
        out.update({"outcome": OUTCOME_ALREADY, "reason_code": "no-branch",
                    "reason": "the retired workspace had a detached HEAD; there is no branch."})
        return out
    if not _git_out(repo, "rev-parse", "--git-dir"):
        out.update({"outcome": OUTCOME_REFUSED, "reason_code": "repo-unreadable",
                    "reason": "%s is not readable as a git repository." % repo})
        return out
    tip = _git_out(repo, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch)
    if not tip:
        out.update({"outcome": OUTCOME_ALREADY, "reason_code": "branch-absent",
                    "reason": "refs/heads/%s no longer exists in %s." % (branch, repo)})
        return out

    # Retention: the branch's own clock, counted from the quarantine.
    started = _parse_iso(rec.get("ts"))
    days = retention_days(retention)
    if started:
        due = started + timedelta(days=days)
        if datetime.now(timezone.utc) < due:
            out.update({"outcome": OUTCOME_REFUSED, "reason_code": "within-retention",
                        "retain_until": due.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                        "reason": ("the workspace was quarantined at %s and this branch's own "
                                   "retention of %g day(s) has not elapsed. A branch is the last "
                                   "reference to committed work; it outlives the directory."
                                   % (rec.get("ts"), days))})
            return out

    # Reachability: the tip must survive the deletion.
    if not backup_ref:
        out.update({"outcome": OUTCOME_REFUSED, "reason_code": "no-backup-ref",
                    "reason": "no backup ref was recorded for this workspace, so deleting the "
                              "branch could make its commits unreachable."})
        return out
    backup_sha = _git_out(repo, "rev-parse", "--verify", "--quiet", backup_ref)
    if not backup_sha:
        out.update({"outcome": OUTCOME_REFUSED, "reason_code": "backup-ref-missing",
                    "reason": "the recorded backup ref %s is gone from %s. Refusing to delete "
                              "the only remaining reference." % (backup_ref, repo)})
        return out
    if backup_sha != tip:
        out.update({"outcome": OUTCOME_REFUSED, "reason_code": "branch-moved",
                    "tip": tip, "backup": backup_sha,
                    "reason": ("refs/heads/%s is at %s but the backup ref preserves %s. The "
                               "branch moved after retirement, so deleting it now would drop "
                               "commits nothing else references." % (branch, tip, backup_sha))})
        return out
    if head and head != tip:
        out.update({"outcome": OUTCOME_REFUSED, "reason_code": "branch-moved",
                    "reason": "the branch tip %s is not the head recorded at retirement (%s)."
                              % (tip, head)})
        return out
    for wt in (registered_worktree_paths(repo) or []):
        if _git_out(wt, "symbolic-ref", "--short", "HEAD") == branch:
            out.update({"outcome": OUTCOME_REFUSED, "reason_code": "branch-checked-out",
                        "reason": "%s is checked out at %s." % (branch, wt)})
            return out

    if dry_run:
        out.update({"outcome": OUTCOME_OK, "dry_run": True, "reason_code": "would-delete",
                    "reason": "every gate passed; nothing was deleted because --dry-run was given."})
        return out

    r = _git(repo, "branch", "-D", branch)
    if r is None or r.returncode != 0:
        out.update({"outcome": OUTCOME_FAILED, "reason_code": "delete-failed",
                    "reason": "git refused to delete %s: %s"
                              % (branch, (r.stderr.strip() if r else "git could not run"))})
        append_record(out)
        return out
    out.update({"outcome": OUTCOME_OK, "reason_code": "branch-deleted", "tip": tip,
                "reason": "refs/heads/%s deleted; its tip %s stays reachable from %s."
                          % (branch, tip, backup_ref)})
    append_record(out)
    return out


# --------------------------------------------------------------------------
# requirement 6: retention expiry — the ONLY code here that erases
# --------------------------------------------------------------------------

def quarantine_covered(qpath, manifest):
    """True only when EVERY entry now present in the quarantine directory is
    in the manifest with the same type, bytes and link target.

    Review 2026-09-06, finding 2: a worker wrote a file into the directory
    after preservation; the archive re-verified (against its own manifest,
    which of course it matched) and the sweep erased the quarantine — the
    only copy of that file. An archive authorizes the erasure of exactly what
    it holds and nothing else. Entries in the manifest that are missing from
    the quarantine are fine: the archive still has them.
    """
    want = {e["path"]: e for e in manifest.get("entries", []) if e.get("path", "").startswith("workspace")}
    try:
        live = _walk_manifest(qpath, "workspace")
    except OSError as e:
        return False, "the quarantine could not be walked: %s" % e
    for e in live:
        w = want.get(e["path"])
        if w is None:
            return False, "%s is present in the quarantine and absent from the archive" % e["path"]
        if w.get("type") != e.get("type"):
            return False, "%s is a %s in the quarantine and a %s in the archive" % (
                e["path"], e.get("type"), w.get("type"))
        if e["type"] == "file" and w.get("sha256") != e.get("sha256"):
            return False, "%s differs from the archived bytes" % e["path"]
        if e["type"] == "symlink" and w.get("linkname") != e.get("linkname"):
            return False, "symlink %s points somewhere the archive did not record" % e["path"]
    return True, "ok"


def sweep(retention=None, execute=False):
    """Erase quarantines whose retention has elapsed.

    This is the only function in this module that removes a directory, and it
    will remove nothing it did not itself mint. SIX conditions, ALL required:
    the path is named in this module's own COMPLETED retirement record; its
    basename matches the quarantine pattern; its (st_dev, st_ino) equals the
    identity recorded at rename time; it is not a symlink; its preservation
    archive exists and re-verifies against its manifest; and every entry now
    in the directory is in that archive (`quarantine_covered`). Then the
    erase is put on record BEFORE it happens.

    Any one of them failing is a SKIP with a named reason, never a best-effort
    delete. There is no caller-supplied path anywhere in this function. An
    INTENT record (`in-progress`) never reaches here: a quarantine whose
    completion was never recorded is never erased.
    """
    days = retention_days(retention)
    now = datetime.now(timezone.utc)
    results = []
    swept = set()
    for rec in reversed(read_records()):
        if rec.get("outcome") != OUTCOME_QUARANTINED:
            continue
        q = rec.get("quarantine") or {}
        qpath = q.get("path") or ""
        if not qpath or qpath in swept:
            continue
        swept.add(qpath)
        wsid = (rec.get("workspace") or {}).get("id") or ""
        item = {"workspace": wsid, "quarantine": qpath}

        if not QUARANTINE_RE.search(os.path.basename(qpath)):
            item.update({"action": "skip", "reason_code": "name-not-minted-here",
                         "reason": "%s is not a name this module mints." % os.path.basename(qpath)})
            results.append(item)
            continue
        if not os.path.lexists(qpath):
            item.update({"action": "gone", "reason_code": "already-gone",
                         "reason": "the quarantine directory is no longer present."})
            results.append(item)
            continue
        if os.path.islink(qpath):
            item.update({"action": "skip", "reason_code": "symlink",
                         "reason": "the recorded quarantine path is now a symlink."})
            results.append(item)
            continue
        try:
            st = os.lstat(qpath)
            live = "%d:%d" % (st.st_dev, st.st_ino)
        except OSError as e:
            item.update({"action": "skip", "reason_code": "unstatable", "reason": str(e)})
            results.append(item)
            continue
        if q.get("fsid") and q["fsid"] != live:
            item.update({"action": "skip", "reason_code": "identity-changed",
                         "reason": "the object at %s is not the one quarantined (recorded %s, "
                                   "present %s)." % (qpath, q["fsid"], live)})
            results.append(item)
            continue
        started = _parse_iso(rec.get("ts"))
        if started is None:
            item.update({"action": "skip", "reason_code": "no-timestamp",
                         "reason": "the retirement record carries no readable timestamp."})
            results.append(item)
            continue
        due = started + timedelta(days=days)
        if now < due:
            item.update({"action": "retain", "reason_code": "within-retention",
                         "retain_until": due.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
                         "reason": "retention of %g day(s) has not elapsed." % days})
            results.append(item)
            continue
        pres = rec.get("preservation") or {}
        archive, mpath = pres.get("archive") or "", pres.get("manifest") or ""
        if not archive or not os.path.isfile(archive) or not os.path.isfile(mpath):
            item.update({"action": "skip", "reason_code": "no-preservation",
                         "reason": "the preservation archive is not on disk; the quarantine is "
                                   "now the only copy and is kept."})
            results.append(item)
            continue
        try:
            with open(mpath, encoding="utf-8") as f:
                manifest = json.load(f)
            ok, why = verify_archive(archive, manifest)
        except Exception as e:
            ok, why = False, str(e)
        if not ok:
            item.update({"action": "skip", "reason_code": "preservation-unverifiable",
                         "reason": "the preservation archive did not re-verify (%s); the "
                                   "quarantine is kept." % why})
            results.append(item)
            continue
        # The archive authorizes the erasure of exactly what it holds.
        covered, why = quarantine_covered(qpath, manifest)
        if not covered:
            item.update({"action": "skip", "reason_code": "quarantine-diverged",
                         "reason": "the quarantine holds content the verified archive does not "
                                   "(%s). Something wrote into it after preservation, and erasing "
                                   "it would take the only copy. It is kept." % why})
            results.append(item)
            continue
        if not execute:
            item.update({"action": "would-erase", "reason_code": "retention-elapsed",
                         "reason": "retention elapsed, the archive re-verified, and the quarantine "
                                   "holds nothing the archive does not."})
            results.append(item)
            continue
        # The record precedes the erase. An erase nobody can find the record
        # of is the finding-3 shape one operation over.
        if not append_record({"operation": "sweep", "outcome": OUTCOME_IN_PROGRESS,
                              "stage": "erase-intent", "workspace": rec.get("workspace"),
                              "quarantine": q, "preservation": pres,
                              "reason": "retention elapsed; erasing the quarantine."}):
            item.update({"action": "skip", "reason_code": "journal-unwritable",
                         "reason": "the retirement journal would not take the erase record, so "
                                   "nothing is erased."})
            results.append(item)
            continue
        try:
            shutil.rmtree(qpath)
        except Exception as e:
            item.update({"action": "failed", "reason_code": "erase-failed", "reason": str(e)})
            append_record({"operation": "sweep", "outcome": OUTCOME_FAILED, "stage": "erase",
                           "workspace": rec.get("workspace"), "quarantine": q,
                           "reason": "rmtree failed: %s" % e})
            results.append(item)
            continue
        item.update({"action": "erased", "reason_code": "retention-elapsed",
                     "reason": "quarantine erased; the verified preservation archive remains at %s."
                               % archive})
        done = append_record({"operation": "sweep", "outcome": OUTCOME_OK,
                              "workspace": rec.get("workspace"), "quarantine": q,
                              "preservation": pres,
                              "reason": "retention elapsed; quarantine erased, archive retained."})
        item["journal"] = "complete" if done else "incomplete"
        results.append(item)
    return {"operation": "sweep", "outcome": OUTCOME_OK, "retention_days": days,
            "execute": bool(execute), "items": results, "ts": now_iso()}

# --------------------------------------------------------------------------
# listing
# --------------------------------------------------------------------------

def list_workspaces(repo_filter=""):
    mod = _ledger_module()
    if mod is None:
        return []
    records = mod.read_all()
    seen = {}
    for r in records:
        if r.get("event") not in ("registered", "prepared"):
            continue
        repo, wt = r.get("repo") or "", r.get("worktree") or ""
        if not repo or not wt:
            continue
        if repo_filter and not same_path(repo, repo_filter):
            continue
        wid = workspace_id(repo, wt)
        e = seen.setdefault(wid, {"id": wid, "repo": lex_path(repo), "path": lex_path(wt),
                                  "owners": [], "teammates": [], "branches": [], "records": 0})
        e["records"] += 1
        for key, field in (("owners", "agent_id"), ("teammates", "teammate"),
                           ("branches", "branch")):
            v = (r.get(field) or "").strip()
            if v and v not in e[key]:
                e[key].append(v)
    for wid, e in seen.items():
        e["present"] = os.path.isdir(e["path"])
        e["retired"] = bool(last_retirement(wid))
    return [seen[k] for k in sorted(seen)]


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _emit(obj):
    print(json.dumps(obj, indent=2, sort_keys=True))


def _exit_for(obj):
    if obj.get("exit") is not None:
        return int(obj["exit"])
    o = obj.get("outcome")
    if o == OUTCOME_REFUSED:
        return EXIT_REFUSED
    if o == OUTCOME_FAILED:
        return EXIT_FAILED
    return EXIT_OK


def _say(*lines):
    for l in lines:
        sys.stderr.write(l + "\n")


def _report_remove(res):
    """The human-readable face of the legacy route, on stderr. The JSON is on
    stdout; this is what a shell caller's `2>&1` capture and an operator's
    eye read. The refusal banner deliberately carries the verdict WORD
    (ALIVE / INDETERMINATE) where the verdict decided it."""
    o = res.get("outcome")
    if o == OUTCOME_OK:
        auth = res.get("authority") or {}
        b = (res.get("branch") or {})
        _say("✓ removed agent worktree: %s%s — agent '%s' %s. %s"
             % (res.get("path"), (" (branch %s)" % b.get("name")) if b.get("deleted") else "",
                res.get("owner_id"), auth.get("basis") or "terminated", res.get("reason") or ""))
        if b.get("name") and not b.get("deleted") and b.get("note"):
            _say("note: " + b["note"])
        if res.get("journal") == "incomplete":
            _say("note: the completion record did NOT land in the retirement journal; the intent "
                 "record did. `workspace-retire.py reconcile` lists it.")
        return
    label = "REFUSING" if o == OUTCOME_REFUSED else "FAILED"
    _say("=== remove-agent-worktree: %s — %s ===" % (label, res.get("reason_code")),
         "  target : %s" % res.get("path"),
         "  repo   : %s" % res.get("repo"),
         "  owner  : %s" % res.get("owner_id"))
    if res.get("stage"):
        _say("  stage  : %s" % res.get("stage"))
    _say("  " + str(res.get("reason") or "").replace("\n", "\n  "))
    _say("(<engine>/scripts/lib/workspace-retire.py remove)")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="workspace-retire.py")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list")
    p.add_argument("--repo", default="")

    p = sub.add_parser("resolve")
    p.add_argument("workspace")

    p = sub.add_parser("retire")
    p.add_argument("workspace")
    p.add_argument("--owner", default="", help="ASSERTION: must match the recorded owner")
    p.add_argument("--repo", default="", help="ASSERTION: must match the recorded repository")
    p.add_argument("--path", default="", help="ASSERTION: must match the recorded path")
    p.add_argument("--entity-repo", default="",
                   help="the repository whose isolation-worktree lock is authoritative for "
                        "liveness. Not a target: it selects which lock is read, never which "
                        "directory is acted on.")
    p.add_argument("--retention-days", type=float, default=None)
    p.add_argument("--lock-wait", type=float, default=5.0)
    p.add_argument("--dry-run", action="store_true")

    p = sub.add_parser("retire-branch")
    p.add_argument("workspace")
    p.add_argument("--retention-days", type=float, default=None)
    p.add_argument("--dry-run", action="store_true")

    p = sub.add_parser("sweep")
    p.add_argument("--retention-days", type=float, default=None)
    p.add_argument("--execute", action="store_true")

    p = sub.add_parser("restore")
    p.add_argument("workspace")
    p.add_argument("destination")

    p = sub.add_parser("records")
    p.add_argument("workspace", nargs="?", default="")

    p = sub.add_parser("reconcile")

    for name in ("authorize", "remove"):
        p = sub.add_parser(name)
        p.add_argument("--entity-repo", default="",
                       help="the repository whose isolation-worktree locks are authoritative "
                            "for a hand-rolled worktree's owner")
        p.add_argument("--repo", required=True, help="the repository that registers <path>")
        p.add_argument("--owner", required=True, help="agent id or agent-<id>; must be BOUND to <path>")
        p.add_argument("--path", required=True, help="the registered worktree to act on")
        p.add_argument("--force", action="store_true",
                       help="remove only: pass --force to git worktree remove; the tree is "
                            "PRESERVED (verified archive) first")
        p.add_argument("--branch", default="", help="remove only: delete this branch after removal")
        p.add_argument("--lock-wait", type=float, default=5.0)

    p = sub.add_parser("workspace-id")
    p.add_argument("repo")
    p.add_argument("path")

    args = ap.parse_args(argv)

    if args.cmd == "list":
        _emit(list_workspaces(args.repo))
        return EXIT_OK
    if args.cmd == "workspace-id":
        print(workspace_id(args.repo, args.path))
        return EXIT_OK
    if args.cmd == "records":
        _emit(read_records(args.workspace or None))
        return EXIT_OK
    if args.cmd == "resolve":
        ws = resolve_workspace(args.workspace)
        if not ws.get("ok"):
            _emit({"operation": "resolve", "outcome": OUTCOME_REFUSED,
                   "reason_code": ws["reason_code"], "reason": ws["reason"],
                   "workspace": {"id": args.workspace}})
            return EXIT_REFUSED
        out = _public_ws(ws)
        out["present"] = os.path.isdir(ws["path"])
        _emit({"operation": "resolve", "outcome": OUTCOME_OK, "workspace": out})
        return EXIT_OK
    if args.cmd == "retire":
        res = retire(args.workspace, assert_owner=args.owner, assert_repo=args.repo,
                     assert_path=args.path, dry_run=args.dry_run,
                     retention=args.retention_days, lock_wait=args.lock_wait,
                     entity=args.entity_repo)
        if res.get("outcome") == OUTCOME_REFUSED:
            append_record(res)
        _emit(res)
        return _exit_for(res)
    if args.cmd == "retire-branch":
        res = retire_branch(args.workspace, retention=args.retention_days,
                            dry_run=args.dry_run)
        _emit(res)
        return _exit_for(res)
    if args.cmd == "sweep":
        _emit(sweep(retention=args.retention_days, execute=args.execute))
        return EXIT_OK
    if args.cmd == "reconcile":
        _emit(reconcile())
        return EXIT_OK
    if args.cmd in ("authorize", "remove"):
        res = remove_legacy(args.entity_repo, args.repo, args.path, args.owner,
                            force=args.force, branch=args.branch, lock_wait=args.lock_wait,
                            dry_run=(args.cmd == "authorize"))
        _report_remove(res)
        _emit(res)
        return _exit_for(res)
    if args.cmd == "restore":
        res = restore(args.workspace, args.destination)
        _emit(res)
        return _exit_for(res)
    ap.print_help(sys.stderr)
    return EXIT_USAGE


if __name__ == "__main__":
    sys.exit(main())
