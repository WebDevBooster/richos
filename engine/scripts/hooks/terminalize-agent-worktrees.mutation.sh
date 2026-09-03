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

mutant stop-promotes-cwd-to-owner "R28" "$H" \
    'if event in ("SubagentStop", ""):{NL}    aid = str(d.get("agent_id") or "")' \
    'if event in ("SubagentStop", ""):{NL}    aid = str(d.get("agent_id") or ""){NL}    if aid and not tx.load_tx(sid, aid):{NL}        aid = tx.find_by_native_path(sid, str(d.get("cwd") or "")) or aid' \
    "a nested or helper agent stopping inside a LIVE teammate's cwd would terminalize the teammate — measured 2026-09-03: nine such stops fired in one live worker's cwd in eight minutes (CEO specification, terminal-authority recommendation section 2)."

mutant stop-acts-on-teammateidle "R25" "$H" \
    'if event in ("SubagentStop", ""):' \
    'if event in ("SubagentStop", "", "TeammateIdle", "TaskCompleted"):' \
    "the two diagnostic-only events (never fired for a real agent; 580 fixture rows) would acquire destructive authority."

L="scripts/lib/worktree-transactions.py"

mutant pending-not-recorded "R21" "$L" \
    '            if AGENT_ID_RE.match(agent_id or "") and (read_bound(session_id, agent_id) or read_start(session_id, agent_id)):{NL}                record_pending_terminal(' \
    '            if False:{NL}                record_pending_terminal(' \
    "an unsealed worker's only terminal event would be discarded; a later bind or seal could never recover it and the worktree would remain forever (review 2026-09-03, blocker 4)."

mutant seal-ignores-pending "R21b" "$L" \
    '    sealed, res = _try_seal_locked(session_id, agent_id){NL}    if sealed:{NL}        res = _consume_pending_terminal(session_id, agent_id, res)' \
    '    sealed, res = _try_seal_locked(session_id, agent_id)' \
    "a manifest that sealed after its agent's stop would sit sealed and live, with a pending event nobody consumed, until the reconciler's grace period — and the barrier would let the dead agent write meanwhile."

mutant worktreeremove-unsealed-ignored "R21d" "$H" \
    '            aid = tx.find_unsealed_by_native_path(sid, path)' \
    '            aid = ""' \
    "the harness's removal of an unsealed agent's native worktree would be nobody's terminal event; the agent's prepared external members would leak."

mutant pending-for-nobody "R21e" "$L" \
    '            if AGENT_ID_RE.match(agent_id or "") and (read_bound(session_id, agent_id) or read_start(session_id, agent_id)):' \
    '            if AGENT_ID_RE.match(agent_id or ""):' \
    "every helper subagent's stop would leave a pending record and a terminal marker; the store would fill with facts about agents that never owned anything."

mutation_end
