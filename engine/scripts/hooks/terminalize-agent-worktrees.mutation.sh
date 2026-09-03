#!/usr/bin/env bash
#
# terminalize-agent-worktrees.mutation.sh — PROVES the terminal ingress's
# suite CAN FAIL, one property at a time. Invoked by
# terminalize-agent-worktrees.test.sh; the loop is scripts/lib/mutation-harness.sh.
# Case ids (R14 etc.) are the ones that suite prints on both PASS and FAIL.
# The hook is thin by design; the properties that live in the library are
# proven by worktree-transactions.mutation.sh and are not repeated here.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SCRIPT_DIR/../lib/mutation-harness.sh"
mutation_begin "terminalize-agent-worktrees (the terminal ingress)" "scripts/hooks/terminalize-agent-worktrees.test.sh"

H="scripts/hooks/terminalize-agent-worktrees.sh"

mutant worktreeremove-ignored "R14" "$H" \
    'elif event == "WorktreeRemove":{NL}    path = str(d.get("worktree_path") or d.get("path") or d.get("cwd") or "")' \
    'elif event == "WorktreeRemove":{NL}    path = ""' \
    "the native deletion race would have no ingress: the harness could remove a native worktree before SubagentStop and nothing would have quarantined it."

mutant worktreeremove-adopts-stranger "R20" "$H" \
    '    try:{NL}        aid = tx.find_by_native_path(sid, path)' \
    '    try:{NL}        aid = tx.find_by_native_path(sid, path) or "a000000000000t01"' \
    "a path RichOS never sealed would be resolved to SOME sealed transaction and acted on — exact-path resolution is what keeps a stranger's directory out of every claim."

mutant claim-not-made "R07" "$H" \
    '    won, t = tx.claim_terminal(sid, aid, ingress, detail=(first_path or ""))' \
    '    won, t = False, tx.load_tx(sid, aid)' \
    "no terminal record would ever be written; the resume guard and the write barrier would never learn the agent is over."

mutant terminalize-not-run "R05" "$H" \
    '    t = tx.terminalize(sid, aid, first_path)' \
    '    t = tx.load_tx(sid, aid)' \
    "the claim would be recorded and nothing quarantined; the harness's own removal would delete uncaptured bytes."

mutant stop-acts-on-teammateidle "R25" "$H" \
    'if event in ("SubagentStop", ""):' \
    'if event in ("SubagentStop", "", "TeammateIdle", "TaskCompleted"):' \
    "the two diagnostic-only events (never fired for a real agent; 580 fixture rows) would acquire destructive authority."

mutant unsealed-claimed "R21" "$H" \
    'if t is None:{NL}    raise SystemExit(0)   # unsealed or unknown: nothing bound, nothing to terminalize' \
    'if t is None:{NL}    tx.touch_marker(tx.terminal_index_path(aid), sid + "\n"); raise SystemExit(0)' \
    "an agent that never sealed would be sealed and claimed by its own stop event — ownership invented at the moment of death."

mutation_end
