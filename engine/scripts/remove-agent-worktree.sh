#!/usr/bin/env bash
#
# remove-agent-worktree.sh — the ONLY sanctioned way to remove an
# agent-associated worktree (a native `<entity>/.claude/worktrees/agent-<id>`
# OR a hand-rolled external-repo worktree).
#
# WHY THIS EXISTS (a downstream adopter's operator directive, 2026-08-24):
#   The orchestrator removed a RUNNING agent's hand-rolled worktree because it
#   checked the WRONG artifact for liveness — the hand-rolled worktree (which
#   carries NO agent lock) instead of the agent's isolation-worktree lock in
#   the ENTITY's own repository. The agent was alive and had to be canceled.
#   A doctrine note is not enough — removal must be gated by STRUCTURE.
#
# THE AUTHORITATIVE RULE (the crux — do not deviate), as it stands after the
# 2026-09-06 review:
#   A workspace may be destroyed only when BOTH hold —
#     BINDING   the asserted owner is tied to THIS exact path: an ownership
#               record (scripts/lib/worktree-ledger.py) names it, or the path
#               is that agent's own isolation worktree registered in the
#               repository under the harness's directory name.
#     EVIDENCE  the owner is NOT-ALIVE on POSITIVE evidence: a witnessed
#               termination on record, an OBSERVED registered-and-unlocked (or
#               stale-locked, dead pid) isolation worktree, or a host session
#               provably over.
#   An agent is ALIVE iff its native isolation worktree, registered in the
#   entity's checkout, is locked with a LIVE pid — that part has not changed.
#   What HAS changed: an ABSENT/unregistered isolation worktree is NOT "not
#   alive" for this script's purposes. It is an absence, and absence says
#   nothing about whether anyone stopped. Hand-rolled external-repo worktrees
#   carry NO lock — they are NEVER the liveness source (checking one is the
#   exact 2026-08-24 mistake).
#
# WHY THAT CHANGED (2026-09-05 / 2026-09-06). This script used to ask the lock
# resolver "is agent-X locked here?" and proceed on NOT-ALIVE. The resolver
# answers NOT-ALIVE for an owner that does not exist, because no such agent is
# locked anywhere. On 2026-09-05 a caller's zsh loop failed to word-split, the
# owner arrived as a string naming nobody, the path arrived as
# /Users/alex/ab/richos-wt/ — the PARENT of every RichOS worktree on the
# machine — and this script deleted it and reported success, twice. The first
# repair (1b84a1c) stopped the recursive delete of an unregistered path but
# left the decision rule in place; the independent review of 2026-09-06 then
# reproduced the incident's own logic error through it: `--owner
# never-registered` against a REGISTERED worktree whose real owner was
# verified ALIVE removed it, exit 0.
#   Diagnosis: richos-hq docs/verification/worktree-container-deletion-2026-09-05.md
#   Review:    richos-hq docs/verification/worktree-removal-fix-review-2026-09-06/
#
# SO THIS SCRIPT DECIDES NOTHING. Both of its modes are thin routes into
# scripts/lib/workspace-retire.py, which holds the ONE termination authority
# (`termination_authority()`), the ONE workspace lock, the ONE preservation
# routine and the ONE journal. It stays inside THIS script's name because
# scripts/hooks/guard-worktree-removal.sh recognizes that name as its
# sanctioned escape route — a new file name would be blocked by the guard, and
# a guard whose escape route is not installed is a guard that only blocks.
# The guard and this helper MOVE AS A PAIR and must never be split.
#
# WHICH REPOSITORY IS "THE ENTITY"? Resolved by the engine's two-root contract
# (scripts/lib/resolve-roots.sh): $RICHOS_ENTITY_ROOT, else $CLAUDE_PROJECT_DIR,
# else $PWD — never this script's own location, which is the ENGINE and is
# usually not the repository being governed at all. Overridable with
# --entity-repo for tests and for cross-entity operator work.
#
# TWO MODES.
#
#   RETIREMENT (preferred):
#     remove-agent-worktree.sh --workspace <ws-id> [--owner <a>] [--repo <r>]
#                              [<path>] [--dry-run] [--retention-days <n>]
#
#   The caller names an IDENTITY and nothing else. Repository, path, branch and
#   owner are DERIVED from the ownership ledger; --owner, --repo and a
#   positional path become ASSERTIONS that must AGREE with the record, and can
#   never widen the target. The workspace is preserved (committed, staged,
#   dirty, untracked AND ignored), its tip made reachable from a backup ref,
#   and its directory RENAMED to quarantine with a retention period. Nothing is
#   deleted; branch deletion is a separate operation. There is no way to spell
#   `/Users/alex/ab/richos-wt/` as a workspace ID, because no ownership record
#   has ever named it. A structured JSON outcome goes to stdout.
#
#   LEGACY (the reaper's route, and operator work from a bare path):
#     remove-agent-worktree.sh --owner <agent-id> <worktree-path> \
#         [--branch <branch>] [--repo <repo-path>] [--force]
#
#   Routed to `workspace-retire.py remove`, which since the SECOND review of
#   2026-09-06 is an ADAPTER onto the retirement transaction and nothing more:
#   it resolves the path and the owner to the same workspace identity, asks
#   the same termination authority, and then runs the SAME sequence retirement
#   runs — preserve unconditionally (committed, staged, dirty, untracked AND
#   ignored; verified by re-reading), re-check ownership after preservation,
#   RENAME to quarantine under <parent>/.richos-retired/, re-check again after
#   the rename and undo on any change, record before and after, unlock and
#   prune the git registration. NOTHING IS DELETED. The directory is gone from
#   its path and from git, which is all the reaper ever relied on; the bytes
#   remain in quarantine indefinitely and in a verified archive
#   after it.
#
#   WHY (the second review's three findings, all on this route): a worker that
#   acquired the workspace during preservation lost its new file, because the
#   re-check the last round added lived in retirement mode only; an ordinary
#   removal without --force erased an ignored file with no archive at all,
#   because a clean `git status` was read as "nothing to lose"; and `--branch`
#   naming an UNRELATED unmerged branch deleted it, with the backup ref
#   protecting the target's tip instead. Two lifecycle sequences sharing one
#   authority was two places for the same check to be missing from one of
#   them, so there is now one sequence.
#
#   It refuses: an owner it cannot bind to the path (`owner-unbound`), an
#   owner that is ALIVE or INDETERMINATE, a directory that is not a registered
#   worktree of the repository (exit 5 — this used to be the recursive
#   delete), a directory that CONTAINS other worktrees (exit 5), a tree with
#   modified or untracked paths when --force is not given
#   (`dirty-without-force`), a --branch that is not the branch checked out at
#   the path (`branch-mismatch`), a retired path reoccupied by an object no
#   newer ownership record claims (`already-retired-path-reoccupied`), and a
#   journal that will not take a record.
#
#   --owner <agent-id>   REQUIRED. Accepts "agent-<id>" or "<id>". Must be
#                        BOUND to <worktree-path> (see the rule above).
#   <worktree-path>      REQUIRED. The worktree directory to retire.
#   --branch <branch>    Optional ASSERTION: must be the branch checked out at
#                        <worktree-path>, else refused before anything moves.
#                        When it matches, it is deleted AFTER the quarantine by
#                        compare-and-delete (`git update-ref -d <ref> <tip>`)
#                        against the tip the backup ref
#                        refs/richos/retired/<ws-id>/<branch> was read back to
#                        hold; a branch that moved in between is left in place.
#   --repo <repo-path>   Optional. The git repo that OWNS <worktree-path>.
#                        Defaults to the entity main checkout.
#   --force              Proceed although the tree has modified or untracked
#                        paths. Without it, such a tree is refused exactly as
#                        `git worktree remove` would refuse it — the reaper
#                        treats "needed --force" as proof a gate was wrong.
#                        Preservation does not depend on this flag.
#
# ENTITY OVERRIDE:
#   --entity-repo <path>  (or env REMOVE_AGENT_ENTITY_REPO) overrides the repo
#   whose isolation-worktree locks are authoritative for a HAND-ROLLED
#   worktree's owner. A native worktree's lock is read from the repository that
#   registers it, which is by construction the entity that spawned it.
#
# Exit codes:
#   0  quarantined, already-retired or a passing --dry-run (both modes; the
#      legacy mode's success line still reads "removed agent worktree" and says
#      in the same line where the quarantine is).
#   2  usage error.
#   3  REFUSED — nothing removed. Owner alive, indeterminate, unresolved or
#      unbound; repository unreadable; identity changed; lock contended; and
#      in retirement mode every refusal at all, always BEFORE any mutation.
#   4  a step was attempted and FAILED (preservation, journal, lock, git
#      worktree remove); the outcome's `stage` names which. Nothing is
#      reported removed that is not on record as removed.
#   5  legacy mode only: the target is a directory that is NOT a registered
#      worktree of the repository, or one that CONTAINS other worktrees.

set -euo pipefail

HOOK_TAG="(<engine>/scripts/remove-agent-worktree.sh)"

err() { printf '%s\n' "$*" >&2; }

usage() {
    cat >&2 <<EOF
usage, RETIREMENT mode (preferred):
  remove-agent-worktree.sh --workspace <ws-id> [--owner <a>] [--repo <r>] \\
           [<path>] [--dry-run] [--retention-days <n>] [--entity-repo <path>]

  The caller names an IDENTITY. Repository, path, branch and owner are DERIVED
  from the ownership ledger; --owner, --repo and a positional path are
  ASSERTIONS that must AGREE with the record. The workspace is preserved
  (committed, staged, dirty, untracked AND ignored), its tip made reachable
  from a backup ref, and its directory RENAMED to quarantine with a retention
  period. NOTHING IS DELETED. A structured JSON outcome goes to stdout.

  List identities:   python3 <engine>/scripts/lib/workspace-retire.py list
  Delete a branch:   python3 <engine>/scripts/lib/workspace-retire.py retire-branch <ws-id>
  Inspect retention: python3 <engine>/scripts/lib/workspace-retire.py sweep
  Quarantines are kept indefinitely; sweep --execute refuses without exclusive access.
  Restore:           python3 <engine>/scripts/lib/workspace-retire.py restore <ws-id> <dest>
  Dangling intents:  python3 <engine>/scripts/lib/workspace-retire.py reconcile

usage, LEGACY mode (the reaper's route, and operator work from a bare path):
  remove-agent-worktree.sh --owner <agent-id> <worktree-path> \\
           [--branch <branch>] [--repo <repo-path>] [--force] \\
           [--entity-repo <path>]

  The SAME transaction as retirement, addressed by path + owner: preserved
  (verified), RENAMED to <parent>/.richos-retired/, registration pruned.
  Nothing is deleted. --branch is an ASSERTION that must name the branch
  checked out at the path; it is deleted afterward by compare-and-delete.
  Without --force a tree with modified or untracked paths is refused.

The ONLY sanctioned way to retire an agent-associated worktree. Acts only
when the owner is BOUND to the path (an ownership record, or the agent's own
isolation worktree) AND is NOT-ALIVE on POSITIVE evidence (witnessed
termination, observed unlocked/stale-locked isolation worktree, or a host
session provably over). Absence is refused. An unregistered directory is
refused (it used to be recursively deleted — 2026-09-05).
$HOOK_TAG
EOF
}

OWNER=""
WT_PATH=""
BRANCH=""
REPO=""
ENTITY_OVERRIDE="${REMOVE_AGENT_ENTITY_REPO:-}"
FORCE=0
WORKSPACE=""
DRY_RUN=0
RETENTION=""
LOCK_WAIT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --workspace)      WORKSPACE="${2:-}"; shift 2 ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --retention-days) RETENTION="${2:-}"; shift 2 ;;
        --lock-wait)      LOCK_WAIT="${2:-}"; shift 2 ;;
        --owner)          OWNER="${2:-}"; shift 2 ;;
        --branch)         BRANCH="${2:-}"; shift 2 ;;
        --repo)           REPO="${2:-}"; shift 2 ;;
        --entity-repo)    ENTITY_OVERRIDE="${2:-}"; shift 2 ;;
        --force)          FORCE=1; shift ;;
        -h|--help)        usage; exit 2 ;;
        --) shift; break ;;
        -*) err "ERROR: unknown option: $1"; usage; exit 2 ;;
        *)
            if [ -z "$WT_PATH" ]; then WT_PATH="$1"; shift
            else err "ERROR: unexpected extra argument: $1"; usage; exit 2; fi
            ;;
    esac
done
# Any trailing positionals after `--`.
if [ -z "$WT_PATH" ] && [ "$#" -gt 0 ]; then WT_PATH="$1"; shift; fi

if [ -z "$WORKSPACE" ] && { [ -z "$OWNER" ] || [ -z "$WT_PATH" ]; }; then
    err "ERROR: --owner <agent-id> and <worktree-path> are both required (legacy mode),"
    err "       or --workspace <ws-id> (retirement mode)."
    usage
    exit 2
fi

command -v git >/dev/null 2>&1 || { err "ERROR: git is required. $HOOK_TAG"; exit 2; }
command -v python3 >/dev/null 2>&1 || { err "ERROR: python3 is required. $HOOK_TAG"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Resolve the ENTITY main checkout — the authoritative liveness source ---
# NOT this script's own location. Under a by-reference engine, SCRIPT_DIR/..
# is the ENGINE, which is not the repository whose agents are being removed.
if [ -n "$ENTITY_OVERRIDE" ]; then
    ENTITY_MAIN="$ENTITY_OVERRIDE"
else
    _RR_LIB="$SCRIPT_DIR/lib/resolve-roots.sh"
    if [ ! -f "$_RR_LIB" ]; then
        err "ERROR: scripts/lib/resolve-roots.sh is missing at $_RR_LIB — cannot"
        err "       determine which repository's worktree lock is authoritative."
        err "       Pass --entity-repo <path> explicitly. $HOOK_TAG"
        exit 2
    fi
    # shellcheck source=lib/resolve-roots.sh
    . "$_RR_LIB"
    if resolve_entity_root ""; then
        ENTITY_MAIN="$RICHOS_ENTITY_ROOT_RESOLVED"
    else
        err "=== remove-agent-worktree: REFUSED — no governed entity ==="
        err "  Could not resolve an adopted repository for this session"
        err "  (status: ${RICHOS_ROOT_STATUS:-unknown}). The entity's worktree lock is"
        err "  the ONLY authoritative liveness signal, so there is nothing to check"
        err "  against and nothing is removed."
        err "  Run this from a session seated in the entity, or pass --entity-repo."
        err "  $HOOK_TAG"
        exit 3
    fi
fi

# --- The ONE library both modes route to --------------------------------------
# This script does not fall back to deciding anything itself when the library
# is missing. A helper that decides in the library's absence is a helper with a
# second implementation, and a second implementation is how the first one
# silently becomes the stale one — which is the whole shape of the defect the
# 2026-09-05 incident and the 2026-09-06 review found here, twice.
_WR_LIB="$SCRIPT_DIR/lib/workspace-retire.py"
if [ ! -f "$_WR_LIB" ]; then
    {
        echo "=== remove-agent-worktree: REFUSED — retirement library missing ==="
        echo "  scripts/lib/workspace-retire.py is absent at:"
        echo "    $_WR_LIB"
        echo "  It holds the ONE termination authority, the ONE workspace lock, the ONE"
        echo "  preservation routine and the ONE journal. Without it this script has"
        echo "  nothing to decide with, and it does not decide from a caller's strings."
        echo "  Failing closed: nothing was removed."
        echo "$HOOK_TAG"
    } >&2
    exit 3
fi

# ===========================================================================
# RETIREMENT MODE — the operation the 2026-09-05 diagnosis specifies
# ===========================================================================
if [ -n "$WORKSPACE" ]; then
    _WR_ARGS=(retire "$WORKSPACE" --entity-repo "$ENTITY_MAIN")
    # --owner / --repo / <path> are ASSERTIONS here, never inputs. They can
    # only fail to match what the record says; they can never widen the target.
    #
    # These are `if` statements and not `[ x ] && y` one-liners deliberately:
    # under `set -e` an AND-list whose test fails IS the command's status, and
    # the shell exits. A silent early exit in a removal helper is the exact
    # shape of a step that never ran while its caller reported success.
    if [ -n "$OWNER" ];     then _WR_ARGS+=(--owner "$OWNER"); fi
    if [ -n "$REPO" ];      then _WR_ARGS+=(--repo "$REPO"); fi
    if [ -n "$WT_PATH" ];   then _WR_ARGS+=(--path "$WT_PATH"); fi
    if [ -n "$RETENTION" ]; then _WR_ARGS+=(--retention-days "$RETENTION"); fi
    if [ -n "$LOCK_WAIT" ]; then _WR_ARGS+=(--lock-wait "$LOCK_WAIT"); fi
    if [ "$DRY_RUN" -eq 1 ]; then _WR_ARGS+=(--dry-run); fi
    if [ -n "$BRANCH" ]; then
        err "note: --branch is ignored in retirement mode. Branch deletion is a SEPARATE"
        err "      operation with its own retention and reachability checks:"
        err "        python3 $_WR_LIB retire-branch $WORKSPACE"
    fi
    if [ "$FORCE" -eq 1 ]; then
        err "note: --force is ignored in retirement mode. Nothing is deleted, so there is"
        err "      nothing for it to override — the workspace is preserved and RENAMED."
    fi
    _WR_RC=0
    python3 "$_WR_LIB" "${_WR_ARGS[@]}" || _WR_RC=$?
    exit "$_WR_RC"
fi

# ===========================================================================
# LEGACY MODE — a ROUTE into the same library, with no authority of its own
# ===========================================================================
# THE LOGIC IS NOT HERE ANY MORE, AND THAT IS THE POINT. Until 2026-09-06 this
# block asked scripts/lib/agent-liveness.sh about the owner, proceeded on any
# NOT-ALIVE, then checked whether the path was a registered worktree. Three
# things were wrong with that in the same direction: NOT-ALIVE covered
# "no such agent exists"; nothing established that the owner OWNED the path;
# and a `--force` removal preserved nothing. All three moved into
# `workspace-retire.py remove`, beside the retirement operation — and the
# second review then showed that "beside" was not "the same": the library's
# remove ran its own sequence and had its own three holes. It now runs
# retirement's sequence, so there is one thing to be wrong about.
#
# The library prints a human-readable banner on stderr (the refusal banner
# carries the verdict word — ALIVE, INDETERMINATE — where the verdict decided
# it) and the structured JSON outcome on stdout, and its exit code is this
# script's exit code, unchanged.
[ -n "$REPO" ] || REPO="$ENTITY_MAIN"

_WR_ARGS=(remove --entity-repo "$ENTITY_MAIN" --repo "$REPO" --owner "$OWNER" --path "$WT_PATH")
if [ -n "$BRANCH" ];    then _WR_ARGS+=(--branch "$BRANCH"); fi
if [ "$FORCE" -eq 1 ];  then _WR_ARGS+=(--force); fi
if [ -n "$LOCK_WAIT" ]; then _WR_ARGS+=(--lock-wait "$LOCK_WAIT"); fi
if [ "$DRY_RUN" -eq 1 ]; then _WR_ARGS[0]="authorize"; fi

_WR_RC=0
python3 "$_WR_LIB" "${_WR_ARGS[@]}" || _WR_RC=$?
if [ "$_WR_RC" -ne 0 ]; then
    err "$HOOK_TAG"
fi
exit "$_WR_RC"
