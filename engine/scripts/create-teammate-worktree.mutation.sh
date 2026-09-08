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

# NAMED ONE EXECUTABLE LINE AT A TIME, NOT AS A CONTIGUOUS BLOCK. This mutant
# used to quote the whole rollback body verbatim, including the
# `git worktree prune` line in the middle. 6472bb60 replaced that line with a
# comment (correctly — a BULK prune during rollback also drops unrelated
# native/legacy registrations whose directories are merely absent), and the
# block no longer matched anything: the harness reported MUTATION TARGET
# ABSENT and the rollback property went unproven from 6472bb60 until this fix.
# A mutation that cannot apply is indistinguishable from coverage, which is the
# trap this whole harness exists to close. So the two edits below name the two
# statements that DO the rolling back and nothing between them; a reworded
# comment, or a third statement added later, cannot silently unhook them again.
mutant no-rollback "C17" "$F" \
    '    git -C "$MAIN" worktree remove --force "$DIR" >/dev/null 2>&1 || rm -rf "$DIR"{AND}    git -C "$MAIN" branch -D "$NAME" >/dev/null 2>&1 || true' \
    '    :{AND}    :' \
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
