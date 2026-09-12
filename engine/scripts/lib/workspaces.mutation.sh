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
    '        if auto and not _past(deadline):{NL}            try:{NL}                res = land(' \
    '        if False:{NL}            try:{NL}                res = land(' \
    "merged work would stay undecided until somebody ran a command (point 4)."

mutant p05-gate-has-no-budget "test_point_05_the_gate_answers_inside_its_budget" "$W" \
    '        if auto and not _past(deadline):{NL}            try:{NL}                res = land(rec["key"], me, auto=True, deadline=deadline)' \
    '        if auto:{NL}            try:{NL}                res = land(rec["key"], me, auto=True, deadline=None)' \
    "the gate's answer would depend on finishing an unbounded scan inside somebody else's hook timeout; the platform cancels an overrun hook and discards its output, so it would decide nothing and say nothing (point 5)."

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

mutant p09-readonly-not-registered "test_point_09_a_restarted_read_only_agent_is_refused_every_tool" "$W" \
    '        save_agent(rec){NL}    event("registered-readonly"' \
    '        pass{NL}    event("registered-readonly"' \
    "a read-only agent would carry no registration, so the lock-out could never find it finished and a restarted Explore — which carries Bash — could write (point 9)."

mutant p09-processes-not-stopped "test_point_09_every_process_it_started_is_stopped_before_deletion" "$W" \
    '    pids = processes_in(paths)' \
    '    pids = []' \
    "a process the agent started would keep running while its workspace is deleted under it (point 9)."

mutant p03-no-snapshot-no-pair "test_point_10_a_side_branch_switched_away_from_blocks_the_land" "$W" \
    '        write_json(_refs_path(rec["key"]), {"key": rec["key"], "at": now(), "repos": snap})' \
    '        snap = snap' \
    "the FIRST half of the pair would record nothing, so no ref could ever be shown to be new: creation would be unobservable and every branch an agent created would be left behind (points 3, 10)."

mutant p03-created-ref-not-attributed "test_point_10_branches_created_in_a_workspace_go_with_it" "$W" \
    '                    mine.append((repo, b))' \
    '                    pass' \
    "a branch the agent created in its own workspace would never be attributed to it, so it would be left behind when its work is landed or discarded (points 3, 10)."

mutant p03-attribution-without-own-work "test_point_03_another_live_agents_branch_is_never_attributed" "$W" \
    '    return set(t for t in tips if t and not is_ancestor(repo, t, target))' \
    '    return set(t for t in tips if t)' \
    "an agent that has produced nothing of its own would still count as having work, so everything that appeared during its tool call -- a second agent's whole spawn, in the normal case of two agents in one repository -- would be on its line of history and become its own (points 3, 5, 8). Reproduced exactly that way on 2026-09-11."

mutant p03-unrelated-ref-attributed "test_point_03_a_branch_rich_cuts_in_the_main_checkout_is_never_the_agents" "$W" \
    '                if not any(t == tip or is_ancestor(repo, t, tip) or is_ancestor(repo, tip, t){NL}                           for t in own):' \
    '                if False and any(t == tip or is_ancestor(repo, t, tip) or is_ancestor(repo, tip, t){NL}                           for t in own):' \
    "co-occurrence in time would be attribution again: a ref carrying somebody else's unlanded commit, cut while the agent happened to be in a tool call, would be deleted with the agent (point 8)."

mutant p03-landed-ref-attributed "test_point_03_a_branch_rich_cuts_in_the_main_checkout_is_never_the_agents" "$W" \
    '                if is_ancestor(repo, tip, target):{NL}                    continue                          # entirely landed: nothing at stake' \
    '                if False:{NL}                    continue                          # entirely landed: nothing at stake' \
    "a ref that is entirely in the branch this work integrates on -- the shape of every bookmark Rich cuts in the main checkout -- would be claimed and deleted by an agent that never made it (points 1, 8)."

mutant p03-borrowed-branch-attributed "test_point_08_a_pre_existing_branch_the_agent_only_checked_out_survives" "$W" \
    '            before = set(prior["repos"][repo] or [])' \
    '            before = set()' \
    "every ref would look new, so a PRE-EXISTING branch the agent merely checked out would become the agent's and a discard would delete it with git branch -D (point 8, in the destructive direction)."

mutant p03-recorded-elsewhere-ignored "test_point_03_a_continuing_agents_branch_is_never_its_predecessors" "$W" \
    '            elsewhere = _refs_recorded_elsewhere(rec["key"])' \
    '            elsewhere = set()' \
    "a ref registered to ANOTHER agent could be attributed to this one whenever it is on the same line of history -- which is exactly what a continuation is, since the new agent's workspace is cut from the old agent's branch (points 3, 7, 8)."

mutant p10-one-workspace-left "test_point_10_a_cross_repository_agent_loses_both_workspaces_as_one" "$W" \
    '        for w in workspaces:{NL}            # Point 3' \
    '        for w in workspaces[:1]:{NL}            # Point 3' \
    "a cross-repository agent's second workspace would be left behind (point 10)."

mutant p10-observed-after-the-run-ended "test_point_10_a_branch_rich_cut_from_its_branch_is_not_the_agents" "$W" \
    '    if fin:{NL}        return "FINISHED", "agent %s (%s) is finished: %s" % (aid, rec.get("name"), why){AND}    if finished_state(rec)[0]:{NL}        _drop_snapshot(rec["key"]){NL}        return []' \
    '    if fin:{NL}        snapshot_refs(rec){NL}        return "FINISHED", "agent %s (%s) is finished: %s" % (aid, rec.get("name"), why){AND}    if False:{NL}        _drop_snapshot(rec["key"]){NL}        return []' \
    "a finished agent's restarted call would open a window of its own, so a branch Rich cuts in the workspace afterwards to rescue the work would be attributed to the agent and deleted with it, or would hold its land hostage (points 7, 8, 9)."

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

mutant p14-land-reads-a-moving-head "test_point_14_work_merged_onto_its_dev_branch_counts_as_landed" "$W" \
    '    tip = branch_tip(main, branch)' \
    '    tip = git(main, "rev-parse", "HEAD")[1].strip()' \
    "landed would go back to meaning \"in whatever the main checkout has checked out just now\", so work merged onto its dev branch would be reported not landed and its workspaces and branches would be left behind (points 4, 14)."

mutant p14-target-inferred-not-recorded "test_point_14_the_integration_branch_is_recorded_never_inferred" "$W" \
    '        branch = (integration_record(repo) or {}).get("branch") or ""' \
    '        branch = ((worktree_list(repo) or [{}])[0].get("branch") or "")' \
    "the branch a land is tested against would be INFERRED from the main checkout at land time instead of read from the record, which is the one thing point 14 forbids: \"nothing infers it and nothing guesses it\"."

mutant p14-in-flight-target-moves "test_point_14_the_integration_branch_is_recorded_never_inferred" "$W" \
    '    ir = integration_record(repo){NL}    if ir and ir.get("branch"):{NL}        rec.setdefault("integration", {})[realpath(repo)] = ir["branch"]' \
    '    ir = None{NL}    if ir and ir.get("branch"):{NL}        rec.setdefault("integration", {})[realpath(repo)] = ir["branch"]' \
    "an agent would not keep the branch recorded when it was spawned, so recording the integration branch for the NEXT body of work would silently move the target of an agent already in flight (point 14)."

mutant p14-unmerged-counts-as-landed "test_point_14_work_merged_nowhere_is_not_landed" "$W" \
    '                if rc == 0 and not is_ancestor(repo, out.strip(), tip):{AND}        if t and not is_ancestor(repo, t, tip):' \
    '                if False:{AND}        if False:' \
    "a branch that reached neither main nor its dev branch would be counted as landed, and deleted (points 4, 8, 14)."

mutation_end
