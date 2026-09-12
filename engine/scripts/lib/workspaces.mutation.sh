#!/usr/bin/env bash
#
# workspaces.mutation.sh — PROVES the workspace spec's suite CAN FAIL, one point
# at a time. Invoked by workspaces.test.sh; the loop is mutation-harness.sh.
# Every mutant removes ONE rule of docs/plans/worktree-spec-2026-09-11.md from
# scripts/lib/workspaces.py in a throwaway copy of the engine and names the
# test, named after its point, that must go red.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mutation-harness.sh
. "$SCRIPT_DIR/mutation-harness.sh"
mutation_begin "workspaces.py (the CEO's workspace spec)" "scripts/lib/workspaces.test.sh"

W="scripts/lib/workspaces.py"

mutant p01-non-cc-accepted "test_point_01_every_non_native_workspace_is_named_cc" "$W" \
    '    if not (branch or "").startswith(CC_PREFIX):{NL}        raise SpecError("branch %r is not named cc/' \
    '    if False:{NL}        raise SpecError("branch %r is not named cc/' \
    "a non-native workspace not named cc/ would be registered (points 1, 3)."

mutant p02-codex-branch-deleted "test_point_02_codex_is_never_touched" "$W" \
    '    if b.startswith(CODEX_PREFIX):{NL}        return False, "branch %s is codex/' \
    '    if False:{NL}        return False, "branch %s is codex/' \
    "a codex/ branch named for deletion would be deleted (point 2)."

mutant p03-registration-without-identity "test_point_03_failed_registration_means_no_spawn" "$W" \
    '    if not ident:{NL}        raise SpecError("the session'"'"'s process identity could not be read from the operating system, "{NL}                        "so its end' \
    '    if False:{NL}        raise SpecError("the session'"'"'s process identity could not be read from the operating system, "{NL}                        "so its end' \
    "a registration that could never tell its session ended would be accepted, so a failed registration would still spawn (point 3)."

mutant p03-unregistered-ignored "test_point_03_unregistered_workspace_and_branch_are_finished_work" "$W" \
    '    made = []{NL}    for repo, path, branch, kind in found:' \
    '    made = []{NL}    for repo, path, branch, kind in []:' \
    "a cc/ or native workspace with no registration would sit forever, never counted as finished work (point 3, hole 6)."

mutant p03-worktree-session-allowed "test_point_03_claude_worktree_sessions_are_not_allowed" "$W" \
    '        if s and s.get("forbidden"):' \
    '        if False:' \
    "a claude --worktree session would be allowed to work (point 3)."

mutant p04-no-automatic-land "test_point_04_landed_means_workspace_and_branch_deleted_automatically" "$W" \
    '        if auto:{NL}            try:{NL}                res = land(' \
    '        if False:{NL}            try:{NL}                res = land(' \
    "merged work would stay undecided until somebody ran a command (point 4)."

mutant p05-new-work-not-blocked "test_point_05_no_new_work_while_finished_work_is_pending" "$W" \
    '    if blocking and not (helps & set(i["name"] for i in blocking)):' \
    '    if False:' \
    "Rich could start new work while finished work is neither landed nor discarded (point 5)."

mutant p05-turn-end-not-blocked "test_point_05_no_turn_end_while_finished_work_is_pending" "$W" \
    '    if not blocking:{NL}        msg = ' \
    '    if True:{NL}        msg = ' \
    "Rich could end his turn with finished work pending (point 5)."

mutant p05-allowance-never-spent "test_point_05_the_answer_allowance_is_spent_once_per_item" "$W" \
    '        if not spent:' \
    '        if True:' \
    "a reply could name the pending work every turn forever without ever handling it, so nothing would make the work get handled afterwards (point 5)."

mutant p06-native-not-registered "test_point_06_native_workspaces_registered_at_spawn_and_deleted_on_land" "$W" \
    '            _add_workspace(rec, "native", main, npath, NATIVE_BRANCH_PREFIX + agent_id, "PostToolUse[Agent]"){AND}            _add_workspace(rec, "native", main_checkout(native), native, branch, "SubagentStart")' \
    '            pass{AND}            pass' \
    "the workspace Claude Code creates would never be registered, so it would pile up (point 6)."

mutant p07-ceo-order-discarded "test_point_07_ceo_ordered_work_needs_his_word" "$W" \
    '    if ordered and not (ceo_word or "").strip():' \
    '    if False:' \
    "work the CEO ordered would be discarded without his word (point 7)."

mutant p07-continuation-keeps-old "test_point_07_unfinished_work_is_continued_by_a_new_agent" "$W" \
    '        _delete(old, [w for w in live_workspaces(old) if w.get("path")], branches=False,' \
    '        (lambda *a, **k: None)(old, [w for w in live_workspaces(old) if w.get("path")], branches=False,' \
    "the old workspaces of continued work would never be deleted when the new agent starts (point 7)."

mutant p08-uncommitted-landed "test_point_08_nothing_uncommitted_is_ever_landed" "$W" \
    '    if problems:{NL}        raise SpecError("cannot %s' \
    '    if False:{NL}        raise SpecError("cannot %s' \
    "a workspace with uncommitted work would be landed and deleted, losing it (point 8)."

mutant p09-finished-not-locked "test_point_09_a_finished_agent_is_refused_every_tool" "$W" \
    '    if fin:{NL}        return "FINISHED"' \
    '    if False:{NL}        return "FINISHED"' \
    "a restarted finished agent could write again (point 9)."

mutant p09-processes-not-stopped "test_point_09_every_process_it_started_is_stopped_before_deletion" "$W" \
    '    pids = processes_in(paths)' \
    '    pids = []' \
    "a process the agent started would keep running while its workspace is deleted under it (point 9)."

mutant p10-one-workspace-left "test_point_10_a_cross_repository_agent_loses_both_workspaces_as_one" "$W" \
    '        for w in workspaces:{NL}            # Point 3' \
    '        for w in workspaces[:1]:{NL}            # Point 3' \
    "a cross-repository agent's second workspace would be left behind (point 10)."

mutant p11-pause-ignored "test_point_11_a_recorded_pause_is_not_finished_and_resumes" "$W" \
    '        if pause and pause.get("at", 0) <= end.get("at", 0):' \
    '        if False:' \
    "a paused agent would be taken for finished and locked out (point 11)."

mutant p12-gone-process-not-ended "test_point_12_process_gone_finishes_its_agents" "$W" \
    '        if st == "gone":' \
    '        if False:' \
    "an agent whose session crashed would never be finished (point 12)."

mutant p12-reused-pid-trusted "test_point_12_a_reused_process_number_is_not_the_session" "$W" \
    '        elif st == "ok" and text != ident["pid_start"]:' \
    '        elif False:' \
    "a reused process number would keep an ended session running forever (point 12)."

mutant p12-other-session-steals "test_point_12_two_sessions_each_handle_their_own" "$W" \
    '        st, _ = session_state(owner, rec.get("session_identity"), cache){NL}        if st != "ended":{NL}            return False' \
    '        st, _ = session_state(owner, rec.get("session_identity"), cache){NL}        if False:{NL}            return False' \
    "a running session would handle another running session's agents (point 12)."

mutant p13-no-retry "test_point_13_a_failed_deletion_is_retried_until_it_succeeds" "$W" \
    '        if not d or d.get("next_at", 0) > now():{NL}            continue' \
    '        if True:{NL}            continue' \
    "a deletion that failed once would never be tried again (point 13)."

mutation_end
