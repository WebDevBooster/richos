#!/usr/bin/env bash
#
# guard-workspace-gate.sh — BLOCKING Stop hook. POINT 5 OF THE CEO'S WORKSPACE SPEC.
#
#   "while any finished agent's work is neither landed nor discarded (point 7),
#    Rich can neither start new work nor end his turn."
#                                   — docs/plans/worktree-spec-2026-09-11.md
#
# This is the turn-end half. The start-new-work half is the spawn guard
# (guard-worktree-isolation.sh clause 7 calls the same scripts/lib/workspaces.py
# register-spawn). Both read one list, and both land automatically, first,
# every finished agent whose work is already in main (point 4).
#
# THE PAGE'S EXCEPTIONS, AND ONLY THEM
#   - answering the CEO or obeying his stop order: the turn began with a message
#     from him (read from the transcript, never from prose), and the reply names
#     every pending item;
#   - every pending item is waiting on something Rich has already started to get
#     it landed (an agent spawned with `lands-pending: <name>` or
#     `continues: <name>` that is not finished, or `workspaces.sh wait <name>
#     --started '...'`), or on something outside his reach
#     (`workspaces.sh wait <name> --outside '...' --todo '<CEO TODO ref>'`);
#   - an item whose only way out is a discard that needs the CEO's word, asked
#     (`workspaces.sh wait <name> --ceo '<question>' --todo '<ref>'`), blocks
#     nothing at all.
#
# It is REPLACING, in the same Stop chain, notice-land-disposition.sh — a
# non-blocking notice whose third state ("held, with a stated reason") the page
# does not have: "Nothing finished is ever left neither landed nor discarded."
#
# FAILS OPEN ON ITS OWN ERROR, LOUDLY: a broken engine that could never let a
# turn end would trap the CEO's session. The failure is announced every turn.

set -o pipefail

# --- ROOT RESOLUTION -------------------------------------------------------
# TWO ROOTS, NEVER ONE. The full contract, and why the old single-root
# resolution was wrong the moment the engine became loadable by reference,
# is in scripts/lib/resolve-roots.sh. This bootstrap block is byte-identical
# in every hook that needs a root; contract-integrity-probe.sh Layer R asserts
# that, so a divergent copy is a probe failure rather than a surprise.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_RR_LIB="$SCRIPT_DIR/../lib/resolve-roots.sh"
if [ ! -f "$_RR_LIB" ]; then
    {
        echo "=== RICHOS ENGINE: BROKEN INSTALL — ENFORCEMENT IS NOT ACTIVE ==="
        echo "  hook: scripts/hooks/guard-workspace-gate.sh"
        echo "  scripts/lib/resolve-roots.sh is missing at: $_RR_LIB"
        echo "  Without it this guard cannot tell WHICH REPOSITORY it governs."
        echo "  It will not guess, and it will not carry on quietly — a defense"
        echo "  that reports 'on' while protecting nothing is worse than none."
    } >&2
    exit 0
fi
# shellcheck source=../lib/resolve-roots.sh
. "$_RR_LIB"
ENGINE_ROOT="$(resolve_engine_root "$SCRIPT_DIR")"

INPUT="$(cat)"
if resolve_entity_root "$INPUT"; then
    ENTITY_ROOT="$RICHOS_ENTITY_ROOT_RESOLVED"
elif [ "$RICHOS_ROOT_STATUS" = "not-adopted" ]; then
    exit 0
else
    root_failure_banner "scripts/hooks/guard-workspace-gate.sh" >&2
    exit 0
fi

LIB="$SCRIPT_DIR/../lib/workspaces.py"
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$LIB" ]; then
    echo "=== WORKSPACE GATE NOT RUNNING: python3 or $LIB is unavailable. Point 5 of docs/plans/worktree-spec-2026-09-11.md is NOT enforced until the engine is restored. ===" >&2
    exit 0
fi

ERRF="$(mktemp "${TMPDIR:-/tmp}/workspace-gate.XXXXXX")" || ERRF=""
if [ -z "$ERRF" ]; then
    echo "=== WORKSPACE GATE NOT RUNNING: no temporary file could be made. ===" >&2
    exit 0
fi
OUT="$(printf '%s' "$INPUT" | python3 "$LIB" --entity "$ENTITY_ROOT" gate-stop 2>"$ERRF")"
RC=$?
ERR="$(cat "$ERRF")"
rm -f "$ERRF"
case "$RC" in
    0)
        [ -n "$OUT" ] && printf '%s\n' "$OUT"
        [ -n "$ERR" ] && printf '%s\n' "$ERR" >&2
        exit 0 ;;
    2)
        printf '%s\n' "$ERR" >&2
        echo "(hook: scripts/hooks/guard-workspace-gate.sh)" >&2
        exit 2 ;;
    *)
        {
            echo "=== WORKSPACE GATE FAILED TO EVALUATE (exit $RC) — the turn is allowed to end, and point 5 is NOT enforced this turn ==="
            printf '%s\n' "$ERR" | tail -20
            echo "(hook: scripts/hooks/guard-workspace-gate.sh)"
        } >&2
        exit 0 ;;
esac
