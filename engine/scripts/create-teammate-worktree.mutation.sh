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

mutant create-without-registration "C17" "$F" \
    '    refuse "the workspace could not be registered, so it was not created: ${_reg_err#workspaces: REFUSED — }"' \
    '    :' \
    "a workspace whose registration failed would be created anyway — registered by nothing, so no spawn could name it and nothing could ever land it (point 3)."

mutant branch-not-cc "C01" "$F" \
    'BRANCH="cc/$NAME"' \
    'BRANCH="$NAME"' \
    "the workspace would be created on a branch not named cc/ (point 1); the registry refuses it, so every creation would fail."

mutant codex-base-allowed "C12b" "$F" \
    '    codex/*|refs/heads/codex/*)' \
    '    no-codex-check-*)' \
    "an agent's workspace could be branched straight off a codex/ branch (point 2)."

mutant failure-not-recorded "C22" "$F" \
    '    python3 "$WS_PY" ${SESS_ARGS[@]+"${SESS_ARGS[@]}"} confirm-cc --name "$NAME" --path "$DIR" --failed "$1" >/dev/null 2>&1 || true' \
    '    :' \
    "a registration whose creation failed would sit as a workspace nobody can tell was never made."

mutation_end
