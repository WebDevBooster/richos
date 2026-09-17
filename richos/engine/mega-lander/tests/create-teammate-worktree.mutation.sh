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
. "$SCRIPT_DIR/../../scripts/lib/mutation-harness.sh"
mutation_begin "create-teammate-worktree" "mega-lander/tests/create-teammate-worktree.test.sh"

F="mega-lander/create-teammate-worktree.sh"

mutant name-check-skipped "C07" "$F" \
    'if ! _name_msg="$(teammate_name_check "$NAME" "$ALLOWED_MODELS")"; then{NL}    refuse "$_name_msg"{NL}fi' \
    ':' \
    "a name that fails the shared shape (scripts/lib/teammate-name.sh) — including 2-part, run-together and over-length-identifier names guard-worktree-isolation.sh also refuses on this same rule — would create a workspace anyway (point 1)."

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

# The rule the 2026-09-17 multi-repository fix had to keep while widening the
# one beside it: ONE workspace per repository per name (point 3), even though a
# SECOND REPOSITORY under that name is now the ordinary thing (point 10). The
# helper's branch check answers the same question first, so this proves the
# REGISTRY's own refusal — the one that survives a missing branch.
mutant second-workspace-same-repository "C27" "mega-lander/workspaces.py" \
    '        clash = [w for w in live_workspaces(rec){NL}                 if w.get("kind") == "cc" and realpath(w.get("repo") or "") == repo]' \
    '        clash = []' \
    "one name could hold two workspaces in the SAME repository, both wanting the branch cc/<name> — point 3's one registration per repository, which the widening to several repositories must not cost."

mutant finished-agent-gets-another-workspace "C28" "mega-lander/workspaces.py" \
    '            fin, _paused, why = finished_state(rec){NL}            if fin:' \
    '            fin, _paused, why = finished_state(rec){NL}            if False:' \
    "a FINISHED agent would be given a new workspace in another repository — it never writes again (point 9) and its work is already landed or discarded (points 5, 7), so the workspace could only be left behind."

mutant failure-not-recorded "C22" "$F" \
    '    python3 "$WS_PY" ${SESS_ARGS[@]+"${SESS_ARGS[@]}"} confirm-cc --name "$NAME" --path "$DIR" --failed "$1" >/dev/null 2>&1 || true' \
    '    :' \
    "a registration whose creation failed would sit as a workspace nobody can tell was never made."

mutation_end
