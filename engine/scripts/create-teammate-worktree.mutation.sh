#!/usr/bin/env bash
#
# create-teammate-worktree.mutation.sh — PROVES create-teammate-worktree.test.sh
# CAN FAIL, one property at a time. Invoked by that suite; the loop is
# scripts/lib/mutation-harness.sh. Case ids (C17 etc.) are the ones the suite
# prints on both its PASS and FAIL lines.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$SCRIPT_DIR/lib/mutation-harness.sh"
mutation_begin "create-teammate-worktree" "scripts/create-teammate-worktree.test.sh"

F="scripts/create-teammate-worktree.sh"

mutant no-rollback "C17" "$F" \
    '    git -C "$MAIN" worktree remove --force "$DIR" >/dev/null 2>&1 || rm -rf "$DIR"{NL}    git -C "$MAIN" worktree prune >/dev/null 2>&1 || true{NL}    git -C "$MAIN" branch -D "$NAME" >/dev/null 2>&1 || true' \
    '    :' \
    "a tree whose record could not be written would be left on disk — unbindable, unsealable, and never cleaned up: the object the helper exists to prevent."

mutant session-optional "C19" "$F" \
    '[ -n "$SESSION" ] || rollback "no session id could be resolved' \
    '[ -n "$SESSION" ] || SESSION="" ; true || rollback "no session id could be resolved' \
    "a prepared record with an empty session id would be written; no spawn-intent can ever match it, so the tree could never be bound."

mutant writes-registered-not-prepared "C04" "$F" \
    'REG_ARGS=(record prepared --teammate "$NAME" --session-id "$SESSION"' \
    'REG_ARGS=(record registered --teammate "$NAME" --session-id "$SESSION"' \
    "the helper would write the old best-effort row; the spawn guard's prepared-record check would refuse every tree it creates."

# The write-status check and the read-back are deliberately redundant: either
# alone catches an unwritable ledger, so neither alone is load-bearing under a
# single mutation. Removing BOTH (one mutant, two edits) must turn C17 red.
mutant no-write-check-no-readback "C17" "$F" \
    'if ! python3 "$LEDGER_PY" "${REG_ARGS[@]}" >/dev/null 2>&1; then{NL}    rollback{AND}if ! python3 "$LEDGER_PY" prepared --session-id "$SESSION" --teammate "$NAME" --worktree "$DIR" >/dev/null 2>&1; then{NL}    rollback' \
    'if ! python3 "$LEDGER_PY" "${REG_ARGS[@]}" >/dev/null 2>&1; then{NL}    :; fi; if false; then{NL}    rollback{AND}if ! python3 "$LEDGER_PY" prepared --session-id "$SESSION" --teammate "$NAME" --worktree "$DIR" >/dev/null 2>&1; then{NL}    :; fi; if false; then{NL}    rollback' \
    "a failed ledger write would be reported as success and the tree kept, unbindable and never cleaned up."

mutation_end
