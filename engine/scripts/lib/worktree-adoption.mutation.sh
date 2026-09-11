#!/usr/bin/env bash
#
# worktree-adoption.mutation.sh — PROVES worktree-adoption.test.sh CAN FAIL,
# one refusal at a time. Invoked by that suite; the loop is
# scripts/lib/mutation-harness.sh. Case ids (A24 etc.) are the ones the suite
# prints on both its PASS and FAIL lines.
#
# WHY THIS FILE MATTERS MORE THAN MOST. Adoption is the only mechanism in this
# engine that claims a workspace nobody claimed, and every one of its nine
# gates is a refusal. A suite full of refusals is the easiest kind of suite to
# pass for the wrong reason: a resolver that refused everything, or one whose
# gate never ran at all, would print thirty-eight green lines. Each mutant
# below deletes ONE refusal and demands that the named case goes red — which is
# the only evidence that the refusal was ever doing anything.
#
# NOT COVERED, stated rather than implied:
#   * The unreadable-process-table branch of G9 (`live_pids_for` returning
#     None). Making `ps` fail inside a sandbox means breaking PATH for the
#     whole suite, which would go red everywhere and prove nothing about that
#     branch specifically. It is a two-line fail-closed path reviewed by
#     reading, not by mutation.
#   * The reconciler's refusal to erase (`unregister_member ->
#     BlockedFailure`). That property belongs to
#     reconcile-terminal-worktrees.py and is proven by its own suite; adoption
#     depends on it and does not implement it.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mutation-harness.sh
. "$SCRIPT_DIR/mutation-harness.sh"
mutation_begin "worktree-adoption" "scripts/lib/worktree-adoption.test.sh"

F="scripts/lib/worktree-adoption.py"

# --- G3: the 2026-09-05 container --------------------------------------------
# BOTH probes go in one mutant, deliberately. Removing either one alone is not
# observable, because the other still catches the fixture — which is the whole
# point of carrying two, and is exactly what `{AND}` is for.
mutant container-gate-removed "A24" "$F" \
    '    under = sorted(w for w in own{NL}                   if w != path and w.startswith(path.rstrip("/") + os.sep)){NL}    under += _nested_worktree_pointers(path){AND}    if under:' \
    '    under = []{AND}    if False:' \
    "the container of every worktree would pass the gate written for it, and the 2026-09-05 deletion would be reachable again."

# --- G6: the live-session veto -----------------------------------------------
mutant live-session-veto-removed "A03" "$F" \
    '    alive = [s for s in statuses if s[3] == "alive"]{NL}    if alive:' \
    '    alive = [s for s in statuses if s[3] == "alive"]{NL}    if False:' \
    "a path bound to one dead session and one RUNNING session would be claimed on the dead one — a verdict about the wrong owner, over a live agent's workspace."

# --- G6: the tier boundary ---------------------------------------------------
mutant t3-authorizes "A05" "$F" \
    '            corroboration.append("T3 witness (never authorizing): %s at %s for agent %s"{NL}                                 % (t.get("reason") or t.get("witness") or "?", t.get("ts"), aid))' \
    '            return "T3", ("witnessed lock release for agent %s" % aid)' \
    "a SWEEP's own observation of a released lock would authorize a claim — the sweep-decides-liveness design the CEO ended on 2026-09-03, rebuilt one tier lower."

# --- G7: unmerged work -------------------------------------------------------
mutant merged-gate-removed "A10" "$F" \
    '    rc, _out, _err = _git(repo, "merge-base", "--is-ancestor", "refs/heads/" + branch, target){NL}    if rc != 0:' \
    '    rc, _out, _err = _git(repo, "merge-base", "--is-ancestor", "refs/heads/" + branch, target){NL}    if False:' \
    "a branch carrying unlanded commits would be quarantined — the two committed escalations that sat unread in femcboost are exactly this population."

# --- G8: untracked files -----------------------------------------------------
mutant clean-gate-ignores-untracked "A12" "$F" \
    '    rc, out, _err = _git(path, "status", "--porcelain")' \
    '    rc, out, _err = _git(path, "status", "--porcelain", "--untracked-files=no")' \
    "a workspace holding UNTRACKED files would read as clean; the bytes a teammate never committed are the ones a claim must never move unexamined."

# --- G5: the lock ------------------------------------------------------------
mutant lock-gate-removed "A14" "$F" \
    '    if locked:{NL}        return _refuse("unlocked"' \
    '    if False:{NL}        return _refuse("unlocked"' \
    "a LOCKED worktree would be claimed, and the lock is the platform's own statement that the workspace may still be in use."

# --- G9: a live process ------------------------------------------------------
mutant live-process-gate-removed "A16" "$F" \
    '    if pids:{NL}        return _refuse("no-live-process", "pid(s) %s reference %s"' \
    '    if False:{NL}        return _refuse("no-live-process", "pid(s) %s reference %s"' \
    "a directory a running process is sitting in would be renamed out from under it."

# --- G4: the terminal reconciler's own territory ------------------------------
mutant unclaimed-gate-removed "A30" "$F" \
    '    if claim:{NL}        return _refuse("unclaimed"' \
    '    if False:{NL}        return _refuse("unclaimed"' \
    "adoption would compete with the terminal reconciler for a worktree a transaction already owns — two owners for one directory, which is how a rename races a capture."

# --- G2: the main checkout ---------------------------------------------------
mutant main-checkout-accepted "A20" "$F" \
    '    if not tx.is_linked_worktree(path):' \
    '    if False and not tx.is_linked_worktree(path):' \
    "a repository's MAIN checkout would be eligible for a claim; a main checkout is never a teammate workspace and renaming one takes the repository with it."

# --- G2: an exact top level, never a subdirectory -----------------------------
mutant subdirectory-accepted "A22" "$F" \
    '    if top != path:' \
    '    if False:' \
    "any subdirectory of a workspace would be treated as a workspace, so a claim could name a path git never registered."

# --- hermetic rooting --------------------------------------------------------
mutant hermetic-rooting-removed "A40" "$F" \
    '    if led_default and tx_default:{NL}        return True, "production: both stores at their default paths"' \
    '    if True:{NL}        return True, "production: both stores at their default paths"' \
    "a suite that overrode only the transaction store would read the OPERATOR'S REAL ownership ledger and rename a live engineer's worktree into a temporary directory."

# --- the record is the enumeration, never a directory scan --------------------
# T4 RETIRED (round 14, 2026-09-11). The two mutants that stood here pinned the
# crash-recovery tier's preconditions; the tier is gone, and so are they. What
# replaces them pins the two properties that remain: an unidentifiable owner
# is never authorized (the exact authorization Sage D2 found), and a folder no
# record names is refused by name rather than falling through to a generic
# refusal.
mutant t4-resurrected "A70" "$F" \
    "        sid, pid, _start, _st = uncertain[0]{NL}        return None, (\"session %s pid %s has UNKNOWN process identity; retain its worktree \"" \
    "        sid, pid, _start, _st = uncertain[0]{NL}        return \"T4\", (\"mutant: crash recovery resurrected; session %s pid %s has UNKNOWN process identity; retain its worktree \"" \
    "an owner whose identity is malformed, legacy or absent would be authorized again on the strength of a process-name scan -- a running pid with an unreadable start token, a registration with no identity -- which is the exact authorization Sage D2 (round three) found and process-identity.test.sh forbids by name."

mutant no-record-is-not-refused "A72" "$F" \
    "    if not aids:{NL}        return None, (\"no ownership record: nothing in the ledger or the transaction store names %s, \"" \
    "    if not aids and False:{NL}        return None, (\"no ownership record: nothing in the ledger or the transaction store names %s, \"" \
    "a folder THIS ENGINE NEVER REGISTERED -- a stranger's directory, a CI checkout, one of the CEO's codex worktrees -- would be refused by a generic 'no authorizing evidence' line instead of by the sentence that says absence of a record is never a claim, and the codex case (A73) would lose the wording section 31 is satisfied by."

mutant candidates-from-disk "A60" "$F" \
    '    out = set(){NL}    for r in records:{NL}        p = r.get("worktree") or ""' \
    '    out = set(){NL}    scan = [{"worktree": os.path.join(d, n), "event": "registered"}{NL}            for d in {os.path.dirname(x.get("worktree") or "/") for x in records}{NL}            for n in (os.listdir(d) if os.path.isdir(d) else [])]{NL}    for r in list(records) + scan:{NL}        p = r.get("worktree") or ""' \
    "candidates would come from a directory scan instead of the record, and a directory nobody ever registered would become a claim target — absence of a record turned back into evidence."

# --- an adoption never disguises itself as a spawn ----------------------------
mutant adoption-disguised-as-a-spawn "A52" "$F" \
    '        "kind": "adopted",{AND}        "sealed_by": "adoption",' \
    '        "kind": "native",{AND}        "sealed_by": "try_seal",' \
    "an adoption would be indistinguishable from a spawn the platform witnessed and bound, so nobody reading the record later could tell an inferred claim from an observed one."

mutation_end
