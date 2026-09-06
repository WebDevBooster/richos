#!/usr/bin/env python3
"""worktree-adoption.py — WHAT MAY CLAIM A WORKTREE THAT NO TERMINAL
TRANSACTION CLAIMED.

===========================================================================
THE COVERAGE HOLE THIS CLOSES
===========================================================================
Two mechanisms exist and they do not meet.

  * reap-stale-worktrees.sh can IDENTIFY a worktree that should go. It is
    DRY-RUN by construction and removes nothing (2026-09-05: re-arming it
    would restore the sweep-decides-liveness design the CEO killed).
  * reconcile-terminal-worktrees.py can ACT, and owns only what a terminal
    TRANSACTION claimed — a spawn the engine observed, terminalized by a
    platform event about a specific agent id.

Between them sits every worktree spawned before the transaction store existed
or by a route that wrote no terminal event. Nothing automatic will ever come
for those. Measured on this machine 2026-09-06 with
`reap-stale-worktrees.sh /Users/alex/ab/femcboost --discover`:

    removed=0 would-remove=3 skipped=37 errors=0 residue=0
    verdict: PENDING — ... would-remove=3 worktree(s) passed every gate and
    NOTHING removed them ... An operator removes them by hand.

"An operator removes them by hand, forever" is not a cleanup mechanism. This
file is the third thing: a claim the RECORD can make, on evidence, so those
worktrees enter the one managed pipeline that already exists.

===========================================================================
WHAT ADOPTION IS, AND WHY IT IS NOT THE THING THE SAFETY DOCUMENT FORBIDS
===========================================================================
`docs/workspace-retirement-safety.md` rules:

    Restoring automatic deletion requires an enforced access boundary, not
    another unchecked override flag.

ADOPTION DELETES NOTHING, AND IT CANNOT BE MADE TO. It creates a sealed,
terminal transaction over one exact worktree and hands it to
reconcile-terminal-worktrees.py, whose member state machine ends at

    "verified": unregister_member  ->  BlockedFailure(
        "exclusive-access-unavailable: automatic erasure is disabled")

The pipeline saves a backup ref, renames the tree to quarantine, captures its
bytes and index, verifies the archive against its own digests, and then
REFUSES to go further. That refusal is not a policy this file consults; it is
the next step in the machine this file hands to. An adopted worktree therefore
gains preservation and a verified archive and loses nothing — the exact
opposite of the container deletion the safety document was written about.

What adoption restores is automatic RETIREMENT, which is what the terminal
reconciler already does today, on a claim gate this file makes strictly
stronger (see EVIDENCE TIERS).

===========================================================================
EVIDENCE TIERS — WHAT MAY AUTHORIZE A CLAIM
===========================================================================
A terminal ingress is authorized by a platform event about a specific agent
id. Nothing that reads a filesystem reproduces that, so adoption is authorized
only by evidence of the same KIND — positive, durable, and about an identity
rather than about a path being quiet.

  T1  transaction-terminal.  The transaction store marks this agent id
      terminal. The platform's own event, already on record.

  T2  session-gone.  A durable ledger record binds this EXACT path to a
      session id, and that session's recorded pid+start is absent from the
      process table (`gone`) or has been recycled under a different start
      (`reused`). Every agent of a session is a thread of that one process:
      when the process is gone, the CEO's rule that an agent "is forbidden to
      return" is enforced by the operating system rather than by a hook. This
      is the same clause the ownership ledger's own judge accepts, read
      through the same `process_status()` — never a second implementation.

  T3  witnessed lock release.  A persisted `terminated` witness for the exact
      path ("native isolation worktree registered and unlocked").

**T1 or T2 authorizes. T3 NEVER authorizes.** T3 is recorded beside the
claim as corroboration and nothing else. That is deliberate and it is the
line between this design and the nine that failed: T3 is an observation a
SWEEP made about a lock, and "the sweep decided the agent was gone" is the
exact design the CEO ended on 2026-09-03. T1 and T2 are facts about a
process, held by the platform and by the kernel.

ABSENCE IS NEVER EVIDENCE. No tier is satisfied by a missing record, a
missing lock, a quiet directory or an old timestamp.

===========================================================================
THE NINE GATES — ALL must hold, and each refusal names the gate
===========================================================================
  G1 exists            the path is a directory on disk
  G2 linked-worktree   it is the TOP LEVEL of a LINKED worktree (never a main
                       checkout, never a subdirectory of one)
  G3 not-a-container   no OTHER registered worktree lies underneath it
  G4 unclaimed         no transaction anywhere names this path (as a member
                       path or as a member's quarantine)
  G5 unlocked          git does not list the worktree as locked
  G6 owner-terminated  T1 or T2 above
  G7 merged            its branch exists and is a merge-base ancestor of the
                       repository's own HEAD branch (no hardcoded "main")
  G8 clean             `git status --porcelain` is empty, tracked AND
                       untracked
  G9 no-live-process   no process references the path

G3 is the 2026-09-05 negative control given its own gate rather than being
left to G2. G2 already refuses `/Users/alex/ab/richos-wt` because a container
is not a worktree top level; G3 refuses it a second time on a second property,
because the failure that day was a malformed caller supplying the container of
all worktrees and one refusal for one reason is how that becomes possible
again. G3 carries two independent probes — the candidate's own repository's
worktree list, and a shallow scan for a nested `gitdir: .../worktrees/`
pointer belonging to any other repository. Their joint limit is declared at
`_nested_worktree_pointers`.

EVERY GATE IS O(1) IN GIT CALLS. `evaluate()` runs inside a session-start
inventory, once per selected worktree, so a gate that consulted a whole-machine
registry would put hundreds of `git worktree list` calls on a hook path.

===========================================================================
HERMETIC ROOTING — FAIL-CLOSED, NOT BEST-EFFORT
===========================================================================
This module reads the ownership LEDGER (RICHOS_WORKTREE_LEDGER) and writes the
TRANSACTION store (RICHOS_WORKTREE_TX_DIR). A sandboxed suite that overrides
one and not the other would read the OPERATOR'S REAL worktrees and quarantine
them into a temporary directory — a test that renames a live engineer's tree.

So `adopt()` REFUSES unless the two are rooted consistently: both overridden
(a sandbox) or neither (production). One without the other is
`REFUSED hermetic-rooting`, exit 4. `evaluate()` is read-only and is allowed
in any rooting; only the writing path is gated.

===========================================================================
CLI
===========================================================================
    worktree-adoption.py candidates
    worktree-adoption.py evaluate --worktree <path>      exit 0 adoptable, 3 refused
    worktree-adoption.py adopt --worktree <path> [--dry-run]
    worktree-adoption.py adopt --all [--dry-run]
    worktree-adoption.py rooting                          exit 0 consistent, 4 not

Environment (test affordances; never set in a real session):
    RICHOS_WORKTREE_LEDGER      the ownership ledger
    RICHOS_WORKTREE_TX_DIR      the transaction store
    RICHOS_ADOPTION_PROCESSES   stands in for the process table: newline-
                                separated "<pid> <command line>" rows, or
                                "none" for an empty table
    RICHOS_CLAUDE_PROCESSES     (ledger) the `claude` process table
    RICHOS_SESSIONS_DIR         (ledger) the harness session registry
"""

import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

ADOPTION_SESSION = "adopted"
ADOPTION_INGRESS = "Adoption"

# The gate identifiers are the refusal vocabulary. They are asserted by name in
# worktree-adoption.test.sh, so renaming one is a behavior change.
GATES = ("exists", "linked-worktree", "not-a-container", "unclaimed", "unlocked",
         "owner-terminated", "merged", "clean", "no-live-process")


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tx = _load("worktree_transactions", os.path.join(HERE, "worktree-transactions.py"))
wl = _load("worktree_ledger", os.path.join(HERE, "worktree-ledger.py"))


# --------------------------------------------------------------------------
# hermetic rooting
# --------------------------------------------------------------------------

DEFAULT_TX_ROOT = os.path.join(os.path.expanduser("~"), ".claude", "state", "worktree-transactions")


def rooting():
    """(ok, reason). Both stores at their default paths, or both away from them.

    The question is asked of the RESOLVED PATHS, not of whether an environment
    variable happens to be set. A caller that passes `--ledger` naming the very
    file the default resolves to has overridden nothing, and refusing it would
    be a refusal over a spelling."""
    led = os.path.abspath(wl.ledger_path())
    txd = os.path.abspath(tx.tx_root())
    led_default = led == os.path.abspath(wl.DEFAULT_PATH)
    tx_default = txd == os.path.abspath(DEFAULT_TX_ROOT)
    if led_default and tx_default:
        return True, "production: both stores at their default paths"
    if not led_default and not tx_default:
        return True, "sandbox: ledger=%s tx=%s" % (led, txd)
    if tx_default:
        return False, ("the ownership ledger is redirected (%s) while the transaction store is at its "
                       "DEFAULT (%s): adoption would read a sandbox ledger and write the operator's "
                       "real transaction store" % (led, txd))
    return False, ("the transaction store is redirected (%s) while the ownership ledger is at its "
                   "DEFAULT (%s): adoption would read the operator's REAL ownership ledger and "
                   "quarantine real worktrees into a sandbox" % (txd, led))


# --------------------------------------------------------------------------
# the process table
# --------------------------------------------------------------------------

def _process_rows():
    """[(pid, command line)] for every process, or None when it cannot be read.
    RICHOS_ADOPTION_PROCESSES stands in for it in tests ("none" = empty)."""
    override = os.environ.get("RICHOS_ADOPTION_PROCESSES")
    if override is not None:
        if override.strip() in ("none", ""):
            return []
        rows = []
        for line in override.splitlines():
            line = line.strip()
            if not line:
                continue
            pid, _, cmd = line.partition(" ")
            rows.append((pid, cmd))
        return rows
    try:
        res = subprocess.run(["ps", "-Ao", "pid=,command="], capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    if res.returncode != 0:
        return None
    rows = []
    for line in res.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        pid, _, cmd = line.partition(" ")
        rows.append((pid, cmd.strip()))
    return rows


def live_pids_for(path):
    """Pids whose command line references `path`, excluding this process and
    its parent — a tool that reported ITSELF as the live process would refuse
    every candidate and never say why. None when the table is unreadable,
    which is NOT the same as an empty list and is refused by G9."""
    rows = _process_rows()
    if rows is None:
        return None
    mine = {str(os.getpid()), str(os.getppid())}
    return [pid for pid, cmd in rows if pid not in mine and path in cmd]


# --------------------------------------------------------------------------
# the record
# --------------------------------------------------------------------------

def _records():
    return wl.read_all()


def candidate_paths(records=None):
    """Every worktree path THE RECORD names, from the record itself — never a
    directory scan and never a repository discovery pass. A registration or a
    `prepared` row names the path a spawn was given; a `terminated` or
    `finished` row names the path an agent worked in. Both are exact paths
    written at a moment somebody knew what they meant."""
    records = _records() if records is None else records
    out = set()
    for r in records:
        p = r.get("worktree") or ""
        if not p:
            continue
        if r.get("event") in ("registered", "prepared", "terminated", "finished"):
            out.add(wl.norm_path(p))
    return sorted(out)


def _session_identities(records):
    """{session_id: (pid, pid_start)} — the pid+start every agent of a session
    ran inside, taken from any ledger row of that session that recorded one."""
    out = {}
    for r in records:
        sid = r.get("session_id") or ""
        pid = r.get("session_pid")
        if not sid or not pid or sid in out:
            continue
        out[sid] = (pid, r.get("pid_start") or "")
    return out


def _rows_for_path(records, path):
    p = wl.norm_path(path)
    return [r for r in records if wl.norm_path(r.get("worktree") or r.get("cwd") or "") == p]


def _agent_ids_for_path(records, path):
    ids = []
    for r in _rows_for_path(records, path):
        aid = (r.get("agent_id") or "").strip()
        if aid and aid not in ids:
            ids.append(aid)
    # A native worktree carries the platform's own ownership statement in its
    # NAME: `.claude/worktrees/agent-<agent_id>` is created by the harness for
    # exactly that agent id, which is the same basis _verify_native_member
    # uses in the transaction library. It is an identity, not a name guess:
    # agent ids are platform-generated and are not reused.
    base = os.path.basename(wl.norm_path(path))
    if base.startswith("agent-"):
        aid = base[len("agent-"):]
        if tx.AGENT_ID_RE.match(aid) and aid not in ids:
            ids.append(aid)
    return ids


def owner_evidence(records, path):
    """(tier, detail) for the highest AUTHORIZING tier, or (None, why).

    T3 is never returned as an authorization; when it is all that exists the
    refusal says so and quotes it, because "there is a witness but it does not
    authorize" and "there is nothing" are different findings."""
    aids = _agent_ids_for_path(records, path)
    corroboration = []

    # THE LIVE-SESSION VETO COMES FIRST, BEFORE ANY TIER.
    # A worktree PATH is reusable: a name is freed when a tree is removed and a
    # later session can be given the same one. If the record binds this path to
    # two sessions, one long dead and one still running, then finding the dead
    # one first and stopping there is a verdict about the WRONG owner — the
    # exact reusable-key failure worktree-ledger.py was rewritten to end. So
    # every session bound to this path is resolved before anything is
    # authorized, and one living owner refuses the claim outright.
    ident = _session_identities(records)
    statuses = []
    seen = set()
    for r in _rows_for_path(records, path):
        sid = r.get("session_id") or ""
        if not sid or sid in seen:
            continue
        seen.add(sid)
        pid, start = (r.get("session_pid"), r.get("pid_start") or "")
        if not pid:
            pid, start = ident.get(sid, (None, ""))
        if not pid:
            corroboration.append("session %s recorded no pid" % sid[:8])
            continue
        statuses.append((sid, pid, start, wl.process_status(pid, start)))
    alive = [s for s in statuses if s[3] == "alive"]
    if alive:
        sid, pid, _start, _st = alive[0]
        return None, ("session %s is STILL RUNNING as pid %s and the record binds it to %s — a live "
                      "owner refuses the claim whatever else is on record" % (sid[:8], pid, path))

    # T1 — the transaction store marks the agent id terminal.
    for aid in aids:
        try:
            if tx.is_terminal_agent(aid):
                return "T1", ("transaction-terminal: the transaction store marks agent %s terminal "
                              "(a platform terminal ingress claimed it)" % aid)
        except Exception:
            continue

    # T2 — the owning session's process is provably gone.
    for sid, pid, start, status in statuses:
        if status in ("gone", "reused"):
            return "T2", ("session-gone: the host session %s ran as pid %s (started %s) and that "
                          "process is %s — every agent of that session was a thread of it"
                          % (sid[:8], pid, start or "?", status))
        corroboration.append("session %s pid %s is %s" % (sid[:8], pid, status))

    # T3 — a persisted witness. Corroboration only; never an authorization.
    for aid in aids:
        for t in wl.terminations(records, aid):
            corroboration.append("T3 witness (never authorizing): %s at %s for agent %s"
                                 % (t.get("reason") or t.get("witness") or "?", t.get("ts"), aid))

    if not aids:
        return None, ("no ownership record: nothing in the ledger or the transaction store names %s, "
                      "and absence of a record is never a claim" % path)
    return None, ("no authorizing evidence for %s (agents %s): T1 needs a terminal transaction, T2 "
                  "needs a host session whose pid is provably gone%s"
                  % (path, ",".join(aids), (" [" + "; ".join(corroboration) + "]") if corroboration else ""))


# --------------------------------------------------------------------------
# git helpers — thin, and every one of them reuses the transaction library
# --------------------------------------------------------------------------

def _git(cwd, *args):
    return tx._git(cwd, *args)


# One whole-machine index, derived once per process. It is a pure read, and it
# is cached because `adopt --all` evaluates every path the record names (497
# candidates on this machine) and re-deriving it per candidate would turn one
# pass into hundreds of thousands of transaction reads.
_CLAIM_CACHE = None


def _claimed_paths():
    """{path: "<session8>/<agent> (<state>)"} over every transaction's member
    paths AND quarantine names."""
    global _CLAIM_CACHE
    if _CLAIM_CACHE is not None:
        return _CLAIM_CACHE
    out = {}
    for t in tx.iter_transactions():
        who = "%s/%s (%s)" % (t.get("session_id", "?")[:8], t.get("agent_id", "?"), t.get("state"))
        for m in t.get("members") or []:
            for key in (m.get("path"), m.get("quarantine")):
                if key:
                    out.setdefault(tx.norm_path(key), who)
    _CLAIM_CACHE = out
    return out


def _claimed_by_transaction(path):
    return _claimed_paths().get(tx.norm_path(path), "")


def _nested_worktree_pointers(path):
    """Immediate subdirectories of `path` that are themselves linked worktrees,
    found WITHOUT any registry: a linked worktree's top level holds a `.git`
    FILE reading `gitdir: .../worktrees/<name>`.

    The registry half of G3 asks the candidate's OWN repository, which answers
    the common case exactly and costs one `git worktree list`. This half costs
    one shallow listing and sees a nested workspace belonging to ANY other
    repository, registered or not — which is precisely the shape a malformed
    caller produces. Two independent probes for one gate, because on 2026-09-05
    the container had exactly one refusal standing between it and `rm -rf`.

    WHAT NEITHER PROBE SEES, stated rather than implied: a worktree of a
    DIFFERENT repository nested two or more levels down. The registry half is
    scoped to one repository and this half to one directory level. Widening
    either means a whole-machine registry (hundreds of `git worktree list`
    calls per evaluation, and this runs inside a session-start inventory) or a
    recursive walk of an arbitrary tree. G2 refuses every container shaped like
    the one that failed, because a container is not a worktree top level, and
    G3 is the second refusal rather than the only one."""
    out = []
    try:
        names = os.listdir(path)
    except OSError:
        return out
    for n in names:
        marker = os.path.join(path, n, ".git")
        if not os.path.isfile(marker):
            continue
        try:
            with open(marker, encoding="utf-8", errors="replace") as f:
                head = f.read(4096)
        except OSError:
            continue
        if head.startswith("gitdir:") and "/worktrees/" in head:
            out.append(os.path.join(path, n))
    return out


def _invalidate_caches():
    """Adoption writes a transaction, so the claim index it just used is stale
    the instant it returns. `adopt --all` must not evaluate the next candidate
    against a claim map from before its own write."""
    global _CLAIM_CACHE
    _CLAIM_CACHE = None


def _locked(repo, path):
    reg = tx.registered_worktrees(repo) or {}
    entry = reg.get(tx.norm_path(path))
    if entry is None:
        return None
    return bool(entry.get("locked"))


# --------------------------------------------------------------------------
# the gates
# --------------------------------------------------------------------------

def _refuse(gate, why):
    return {"adoptable": False, "gate": gate, "reason": why}


def evaluate(path, records=None):
    """All nine gates over one exact path. Read-only: it writes nothing, takes
    no lock and mutates no worktree, so it is safe to call from a DRY-RUN
    inventory. The dict carries `gate` and `reason` on a refusal, and `tier`,
    `evidence` and `member` on an acceptance."""
    records = _records() if records is None else records
    path = wl.norm_path(path)

    # G1 exists
    if not os.path.isdir(path):
        return _refuse("exists", "%s is not a directory on disk" % path)

    # G2 linked-worktree
    top = tx.worktree_toplevel(path)
    if top != path:
        return _refuse("linked-worktree",
                       "%s is not the top level of a git worktree (git says the top level is %r)"
                       % (path, top or "<none>"))
    if not tx.is_linked_worktree(path):
        return _refuse("linked-worktree",
                       "%s is a MAIN checkout, not a linked worktree — a main checkout is never a "
                       "teammate workspace and is never adopted" % path)
    repo = tx.main_checkout_of(path)
    if not repo:
        return _refuse("linked-worktree", "the main checkout of %s could not be resolved" % path)

    # G3 not-a-container — the 2026-09-05 control, on its own property.
    own = tx.registered_worktrees(repo) or {}
    under = sorted(w for w in own
                   if w != path and w.startswith(path.rstrip("/") + os.sep))
    under += _nested_worktree_pointers(path)
    if under:
        return _refuse("not-a-container",
                       "%s CONTAINS %d other worktree(s) (%s) — a container of workspaces is never a "
                       "workspace, and supplying one is the 2026-09-05 deletion"
                       % (path, len(under), ", ".join(sorted(set(under))[:3])))

    # G4 unclaimed
    claim = _claimed_by_transaction(path)
    if claim:
        return _refuse("unclaimed",
                       "transaction %s already owns %s — the terminal reconciler owns its lifecycle "
                       "and adoption never competes with it" % (claim, path))

    # G5 unlocked
    locked = _locked(repo, path)
    if locked is None:
        return _refuse("unlocked", "%s is not registered as a worktree of %s, so its lock state "
                                   "cannot be read (unverifiable is not permission)" % (path, repo))
    if locked:
        return _refuse("unlocked", "%s is LOCKED — the lock is the platform's own statement that the "
                                   "workspace may still be in use" % path)

    # G6 owner-terminated
    tier, detail = owner_evidence(records, path)
    if tier is None:
        return _refuse("owner-terminated", detail)

    # G7 merged
    branch = tx.branch_of(path)
    if not branch:
        return _refuse("merged", "%s is on a detached HEAD — there is no branch to verify against, "
                                 "and unverifiable is not permission" % path)
    rc, _out, _err = _git(repo, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch)
    if rc != 0:
        return _refuse("merged", "%s no longer has a branch refs/heads/%s in %s" % (path, branch, repo))
    rc, target, _err = _git(repo, "symbolic-ref", "-q", "--short", "HEAD")
    target = target.strip()
    if not target:
        rc, target, _err = _git(repo, "rev-parse", "HEAD")
        target = target.strip()
    if not target:
        return _refuse("merged", "the HEAD of %s could not be read" % repo)
    rc, _out, _err = _git(repo, "merge-base", "--is-ancestor", "refs/heads/" + branch, target)
    if rc != 0:
        rc2, n, _err = _git(repo, "rev-list", "--count", "%s..refs/heads/%s" % (target, branch))
        return _refuse("merged", "%s carries %s commit(s) that %s does not — unmerged work is never "
                                 "swept and never adopted" % (branch, n.strip() or "?", target))

    # G8 clean
    rc, out, _err = _git(path, "status", "--porcelain")
    if rc != 0:
        return _refuse("clean", "`git status` failed in %s" % path)
    if out.strip():
        return _refuse("clean", "%s has %d modified or untracked path(s)"
                       % (path, len([x for x in out.splitlines() if x.strip()])))

    # G9 no-live-process
    pids = live_pids_for(path)
    if pids is None:
        return _refuse("no-live-process", "the process table could not be read, so 'nothing is using "
                                          "%s' could not be established (unverifiable is not permission)" % path)
    if pids:
        return _refuse("no-live-process", "pid(s) %s reference %s" % (",".join(pids), path))

    cls = "native" if os.path.basename(path).startswith("agent-") else "hand-rolled"
    return {
        "adoptable": True, "gate": "", "reason": "", "tier": tier, "evidence": detail,
        "member": {"class": cls, "repo": repo, "path": path, "branch": branch,
                   "head_at_seal": tx.head_of(path), "state": "bound"},
    }


# --------------------------------------------------------------------------
# the claim
# --------------------------------------------------------------------------

def adoption_agent_id(path):
    """Deterministic per PATH, so re-running adopts nothing twice, and visibly
    NOT a platform agent id, so no reader ever mistakes an adoption for a spawn
    the engine witnessed. The real owner's agent id and session are recorded
    as fields on the transaction, never forged into its key."""
    return "adopted-" + hashlib.sha1(wl.norm_path(path).encode("utf-8")).hexdigest()[:16]


def adopt(path, records=None, dry_run=False):
    """Evaluate, then create a sealed terminal transaction over the exact path
    and hand it to the reconciler. Returns the evaluation dict with `adopted`,
    `agent_id` and `state` added.

    A transaction is written DIRECTLY rather than through try_seal(): a seal
    requires a bound record and a start record, and adoption has neither by
    definition. Forging them would make an adoption indistinguishable from a
    spawn the platform witnessed, which is the one thing this record must never
    lie about. `kind: "adopted"` and `sealed_by: "adoption"` say what it is.
    (process_pending_terminals() writes a transaction the same way for the same
    kind of reason, so this is the file's existing shape, not a new one.)"""
    records = _records() if records is None else records
    res = evaluate(path, records)
    if not res.get("adoptable"):
        return res
    if dry_run:
        res["adopted"] = False
        res["state"] = "dry-run"
        return res

    ok, why = rooting()
    if not ok:
        return _refuse("hermetic-rooting", why)

    aid = adoption_agent_id(path)
    member = res["member"]
    owner_ids = _agent_ids_for_path(records, path)
    teammate = ""
    for r in _rows_for_path(records, path):
        if r.get("teammate"):
            teammate = r["teammate"]
            break
    t = {
        "record": "transaction",
        "session_id": ADOPTION_SESSION,
        "agent_id": aid,
        "tool_use_id": None,
        # The transaction's own `teammate` stays EMPTY on purpose: claim_terminal
        # writes a session-scoped terminal-name index from it, and an adoption
        # must not mark a name terminal in any session's namespace. The real
        # teammate is recorded under `adoption` where it is evidence, not an index.
        "teammate": "",
        "subagent_type": "",
        "kind": "adopted",
        "members": [member],
        "sealed": True,
        "sealed_ts": tx.now_iso(),
        "state": "sealed",
        "sealed_by": "adoption",
        "start_cwd": "",
        "terminal": None,
        "adoption": {
            "tier": res["tier"],
            "evidence": res["evidence"],
            "gates": list(GATES),
            "owner_agent_ids": owner_ids,
            "teammate": teammate,
            "ts": tx.now_iso(),
        },
    }
    with tx.tx_lock(ADOPTION_SESSION, aid):
        if tx.load_tx(ADOPTION_SESSION, aid) is None:
            tx.atomic_write_json(tx.tx_path(ADOPTION_SESSION, aid), t)
    tx.claim_terminal(ADOPTION_SESSION, aid, ADOPTION_INGRESS,
                      detail="adopted on %s evidence: %s" % (res["tier"], res["evidence"]))
    t2 = tx.terminalize(ADOPTION_SESSION, aid, member["path"])
    _invalidate_caches()
    res["adopted"] = True
    res["agent_id"] = aid
    res["state"] = (t2 or {}).get("state")
    res["members"] = [{"path": m.get("path"), "state": m.get("state"), "quarantine": m.get("quarantine")}
                      for m in (t2 or {}).get("members") or []]
    return res


def adopt_all(dry_run=False):
    """Every candidate the RECORD names, evaluated and adopted. Refusals are
    returned too: a pass that reported only what it took would be a pass whose
    denominator nobody can see."""
    records = _records()
    out = []
    for p in candidate_paths(records):
        res = adopt(p, records, dry_run=dry_run)
        res["worktree"] = p
        out.append(res)
    return out


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _cmd_rooting(_a):
    ok, why = rooting()
    print(("OK\t" if ok else "REFUSED\t") + why)
    return 0 if ok else 4


def _cmd_candidates(_a):
    for p in candidate_paths():
        print(p)
    return 0


def _cmd_evaluate(a):
    res = evaluate(a.worktree)
    if a.json:
        print(json.dumps(res, sort_keys=True))
    elif res.get("adoptable"):
        print("ADOPTABLE\t%s\t%s" % (res["tier"], res["evidence"]))
    else:
        print("REFUSED\t%s\t%s" % (res["gate"], res["reason"]))
    return 0 if res.get("adoptable") else 3


def _cmd_adopt(a):
    if not a.all and not a.worktree:
        print("REFUSED\tusage\tone of --worktree <path> or --all is required", file=sys.stderr)
        return 2
    if not a.dry_run:
        ok, why = rooting()
        if not ok:
            print("REFUSED\thermetic-rooting\t%s" % why, file=sys.stderr)
            return 4
    if a.all:
        results = adopt_all(dry_run=a.dry_run)
    else:
        one = adopt(a.worktree, dry_run=a.dry_run)
        one["worktree"] = wl.norm_path(a.worktree)
        results = [one]
    for r in results:
        if a.json:
            print(json.dumps(r, sort_keys=True))
        elif r.get("adoptable"):
            print("%s\t%s\t%s\t%s" % ("ADOPTED" if r.get("adopted") else "WOULD-ADOPT",
                                      r.get("worktree"), r.get("tier"), r.get("state")))
        else:
            print("REFUSED\t%s\t%s\t%s" % (r.get("worktree"), r.get("gate"), r.get("reason")))
    if not a.json:
        print("=== adoption: %d of %d candidate(s) %s ==="
              % (sum(1 for r in results if r.get("adoptable")), len(results),
                 "would be adopted" if a.dry_run else "adopted"))
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    ap = argparse.ArgumentParser(prog="worktree-adoption.py")
    # --ledger is the same override RICHOS_WORKTREE_LEDGER is, spelled as an
    # argument so a caller (reap-stale-worktrees.sh) can hand down the exact
    # ledger it is itself reading rather than hoping the environment agrees.
    # It is applied to this process only, and `rooting()` still judges the
    # RESOLVED path, so naming the default file overrides nothing.
    ap.add_argument("--ledger", default=None, help="the ownership ledger to read")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("rooting").set_defaults(fn=_cmd_rooting)
    sub.add_parser("candidates").set_defaults(fn=_cmd_candidates)

    p = sub.add_parser("evaluate")
    p.add_argument("--worktree", required=True)
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=_cmd_evaluate)

    p = sub.add_parser("adopt")
    p.add_argument("--worktree")
    p.add_argument("--all", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=_cmd_adopt)

    a = ap.parse_args(argv)
    if a.ledger:
        os.environ["RICHOS_WORKTREE_LEDGER"] = a.ledger
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
