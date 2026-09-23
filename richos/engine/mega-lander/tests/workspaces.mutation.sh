#!/usr/bin/env bash
#
# workspaces.mutation.sh — PROVES the workspace spec's suite CAN FAIL, one point
# at a time. Invoked by workspaces.test.sh; the loop is mutation-harness.sh.
# Every mutant removes ONE rule of docs/plans/worktree-spec-2026-09-11.md from
# mega-lander/workspaces.py in a throwaway copy of the engine and names the
# test, named after its point, that must go red.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mutation-harness.sh
. "$SCRIPT_DIR/../../scripts/lib/mutation-harness.sh"
mutation_begin "workspaces.py (the CEO's workspace spec)" "mega-lander/tests/workspaces.test.sh"

W="mega-lander/workspaces.py"

mutant p01-non-cc-accepted "test_point_01_every_non_native_workspace_is_named_cc" "$W" \
    '    if not (branch or "").startswith(CC_PREFIX):{NL}        raise SpecError("branch %r is not named cc/' \
    '    if False:{NL}        raise SpecError("branch %r is not named cc/' \
    "a non-native workspace not named cc/ would be registered (points 1, 3)."

mutant p02-codex-branch-deleted "test_point_02_codex_is_never_touched" "$W" \
    '    if b.startswith(CODEX_PREFIX):{NL}        return None, "branch %s is codex/' \
    '    if False:{NL}        return None, "branch %s is codex/' \
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

# 2026-09-22: a SUBAGENT's compaction fired SessionStart with the lead's
# session_id and the subagent's worktree, and locked the lead out for 33 minutes.
# The lock-out itself is refused by three independent rules (the platform's
# launch record, the first record, and no refusal from a compact's cwd), so no
# single removal turns "never locks out the lead" red; each rule is proven by
# the case it alone decides.
mutant p03-subagent-compaction-is-the-lead "test_point_03_a_subagent_compaction_gets_none_of_the_leads_context" "$W" \
    '    foreign = bool(payload_cwd and lead_cwd and payload_cwd != lead_cwd and source not in LAUNCH_SOURCES)' \
    '    foreign = False' \
    "a subagent's compaction would be taken for the lead's own start (point 3, 2026-09-22)."

mutant p03-first-record-overwritten "test_point_03_without_the_platform_record_the_first_record_decides" "$W" \
    '    elif prev.get("cwd"):' \
    '    elif False:' \
    "with no platform record, a later SessionStart would move the lead's recorded directory (point 3)."

mutant p03-platform-record-not-asked "test_point_03_a_session_launched_in_a_workspace_is_still_forbidden" "$W" \
    '    if plat and plat.get("cwd"):{NL}        lead_cwd, basis = realpath(str(plat["cwd"])), "platform"' \
    '    if False:{NL}        lead_cwd, basis = realpath(str(plat["cwd"])), "platform"' \
    "the directory a session was LAUNCHED in would be taken from a hook payload instead of the platform's own record (point 3)."

mutant p03-stored-flag-trusted "test_point_03_a_wrong_stored_flag_is_re_derived_at_the_verdict" "$W" \
    '    plat = platform_session(session_id, rec.get("pid"))' \
    '    plat = None' \
    "a wrong FORBIDDEN on the lead's record would stand for the rest of the session, as it did on 2026-09-22 (point 3)."

mutant p03-subagent-gets-lead-context "test_point_03_a_subagent_compaction_gets_none_of_the_leads_context" "$W" \
    '        if foreign:{NL}            # A subagent'"'"'s compaction' \
    '        if False:{NL}            # A subagent'"'"'s compaction' \
    "a subagent's compaction would be handed the lead's land-or-discard gate, which it can do nothing about."

mutant p04-no-automatic-land "test_point_04_landed_means_workspace_and_branch_deleted_automatically" "$W" \
    '        if auto and not _past(deadline):{NL}            try:{NL}                res = land(' \
    '        if False:{NL}            try:{NL}                res = land(' \
    "merged work would stay undecided until somebody ran a command (point 4)."

mutant p05-gate-has-no-budget "test_point_05_the_gate_answers_inside_its_budget" "$W" \
    '        if auto and not _past(deadline):{NL}            try:{NL}                res = land(rec["key"], me, auto=True, deadline=deadline)' \
    '        if auto:{NL}            try:{NL}                res = land(rec["key"], me, auto=True, deadline=None)' \
    "the gate's answer would depend on finishing an unbounded scan inside somebody else's hook timeout; the platform cancels an overrun hook and discards its output, so it would decide nothing and say nothing (point 5)."

mutant p05-new-work-not-blocked "test_point_05_no_new_work_while_finished_work_is_pending" "$W" \
    '    if blocking and not (helps & set(value for i in blocking for value in (i["name"], i["key"]))):' \
    '    if False:' \
    "Rich could start new work while finished work is neither landed nor discarded (point 5)."

mutant p05-turn-end-not-blocked "test_point_05_no_turn_end_while_finished_work_is_pending" "$W" \
    '    if not blocking:{NL}        msg = ' \
    '    if True:{NL}        msg = ' \
    "Rich could end his turn with finished work pending (point 5)."

mutant p05-ceo-wait-unblocks-new-work "test_point_05_a_ceo_discard_question_blocks_nothing_else" "$W" \
    '            "blocks_new_work": not under_way,' \
    '            "blocks_new_work": kind != "ceo-discard",' \
    "the round-7 mis-build restored: an item waiting on the CEO's word would be the one kind of pending item that lets new work start, against \"New work stays blocked either way\" (point 5)."

mutant p05-land-under-way-still-blocks "test_point_05_a_land_under_way_does_not_block_new_work" "$W" \
    '    under_way = _land_under_way(rec, kind)[0]' \
    '    under_way = False' \
    "the freeze CEO ruling §77 ended restored: a land recorded as started and merged locally would still block every new agent while its checks run (point 5 as amended)."

mutant p05-started-record-alone-unblocks "test_point_05_a_started_record_with_no_merge_still_blocks_new_work" "$W" \
    '            if not is_ancestor(repo, sha, tip):{NL}                return False, "%s is not merged into %s yet" % (label, branch)' \
    '            if False:{NL}                return False, "%s is not merged into %s yet" % (label, branch)' \
    "a --started record with nothing merged behind it would let new work start, so a promise to land would count as a land under way (§77: merged locally or with its checks running)."

mutant p05-any-wait-counts-as-under-way "test_point_05_only_a_started_land_counts_as_under_way" "$W" \
    '    if kind != "started":{NL}        return False, "no land has been recorded as started"' \
    '    if not kind:{NL}        return False, "no land has been recorded as started"' \
    "a merged item waiting on something outside Rich's reach would let new work start, though no land is in progress (§77 names only a land under way)."

mutant p05-a-notification-counts-as-the-ceo "test_point_05_answering_the_ceo_names_the_pending_work" "$W" \
    '    if d.get("queueSkipAttachments") or d.get("promptSource") == "system":{NL}        return False{AND}    if isinstance(origin, dict):{NL}        return kind == "human"' \
    '    if False:{NL}        return False{AND}    if isinstance(origin, dict):{NL}        return True' \
    "a turn begun by a platform notification (a stamped origin that is not a person's) would count as answering the CEO, and the one allowance would be spent by something he never sent (point 5)."

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
    '        row = {"key": rec["key"], "call": call or "", "at": now(), "repos": snap, "tips": tips}{NL}        write_json(_slot_path(rec["key"], call), row)' \
    '        row = {"key": rec["key"], "call": call or "", "at": now(), "repos": snap, "tips": tips}' \
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
    '                if target and is_ancestor(repo, tip, target):{NL}                    continue                          # entirely landed: nothing at stake' \
    '                if False:{NL}                    continue                          # entirely landed: nothing at stake' \
    "a ref that is entirely in the branch this work integrates on -- the shape of every bookmark Rich cuts in the main checkout -- would be claimed and deleted by an agent that never made it (points 1, 8)."

mutant p03-borrowed-branch-attributed "test_point_08_a_branch_that_existed_before_the_call_is_never_created_in_it" "$W" \
    '        b = set(latest["repos"][repo] or []){NL}        before = b if before is None else (before | b){NL}    return before' \
    '        b = set(latest["repos"][repo] or []){NL}        before = b if before is None else (before | b){NL}    return set()' \
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
    '    if fin:{NL}        return "FINISHED", "agent %s (%s) is finished: %s" % (aid, rec.get("name"), why){AND}    if finished_state(rec)[0]:{NL}        _drop_snapshots(rec["key"]){NL}        return []' \
    '    if fin:{NL}        snapshot_refs(rec, str(payload.get("tool_use_id") or "")){NL}        return "FINISHED", "agent %s (%s) is finished: %s" % (aid, rec.get("name"), why){AND}    if False:{NL}        _drop_snapshots(rec["key"]){NL}        return []' \
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
    '    branch = (work or {}).get("branch") or ""{NL}    if not branch:' \
    '    branch = ((worktree_list(repo) or [{}])[0].get("branch") or ""){NL}    if not branch:' \
    "the branch a land is tested against would be INFERRED from the main checkout at land time instead of read from the record, which is the one thing point 14 forbids: \"nothing infers it and nothing guesses it\"."

mutant p14-spawn-not-refused-without-a-record "test_point_14_the_integration_branch_is_recorded_never_inferred" "$W" \
    '    missing = _unrecorded_repos(repos){NL}    if missing:' \
    '    missing = _unrecorded_repos(repos){NL}    if False:' \
    "a spawn (and a cc/ workspace) would be registered with NO body of work recorded, bound to nothing — and a nothing-bound agent is judged at land time against whichever body of work is current, so a later unrelated recording moves its verdict: the guess both round-6 reviewers reproduced (point 14, \"before its first agent is spawned\")."

# The witness token here used to name test_point_14_the_integration_branch_is_
# recorded_never_inferred, which stays green under this mutant (round 7 §5:
# 44/45); the red lands at the orphan-binding test, so that is the witness.
mutant p14-nothing-bound-falls-back-to-current "test_point_14_a_record_bound_to_nothing_is_refused_never_guessed" "$W" \
    '    if work is None and chain:{NL}        return "", "", (' \
    '    if False:{NL}        return "", "", (' \
    "a chain bound to no body of work would be proved against the repository's CURRENT record at land time — the \"heals later\" fallback round 7 removed, which is a guess about which work the agent belongs to (point 14)."

mutant p14-floor-restored "test_point_14_the_integration_branch_is_recorded_never_inferred" "$W" \
    '    if repo not in cur["repos"]:{NL}        cur["repos"].append(repo){NL}        write_json(path, cur)' \
    '    if repo not in cur["repos"]:{NL}        cur["repos"].append(repo){NL}        write_json(path, cur){NL}    _m = _norm_repo(repo){NL}    if _m and not all_integration_records().get(_m):{NL}        _wl = worktree_list(_m){NL}        _b = (_wl[0].get("branch") or "") if _wl else ""{NL}        if _b:{NL}            _write_integration(_m, _b, "first-registration", "the floor")' \
    "a registration would DERIVE the integration branch from whatever the main checkout happens to be on and write it down as though it were recorded, which point 14 forbids outright: \"nothing infers it and nothing guesses it\". The derived record is also the one that cannot be corrected -- with no record the land refuses and Rich recording the branch HEALS it; with the floor's record the land refuses forever and the workspace is left behind (points 5, 14)."

mutant p14-frozen-copy-restored "test_point_14_the_integration_branch_is_recorded_never_inferred" "$W" \
    '    _bind_body_of_work(rec, repo){NL}    return w{AND}    branch = (work or {}).get("branch") or ""{NL}    if not branch:' \
    '    _ir = integration_record(repo){NL}    if _ir and _ir.get("branch"):{NL}        rec.setdefault("integration", {})[realpath(repo)] = _ir["branch"]{NL}    return w{AND}    branch = ""{NL}    for _r in chain:{NL}        branch = (_r.get("integration") or {}).get(realpath(repo)) or ""{NL}        if branch:{NL}            break{NL}    if not branch:{NL}        branch = (work or {}).get("branch") or ""{NL}    if not branch:' \
    "the branch would be FROZEN onto each agent at its registration and preferred over the live record, so a correction could never reach an agent already in flight: its land would be proved against a branch that is no longer the one this work integrates on, it would refuse forever, its workspace would be left behind and point 5 would be blocked (point 14)."

mutant p03-one-window-per-agent "test_point_14_two_of_one_agents_own_calls_open_at_once_keep_both_windows" "$W" \
    '    if call:{NL}        return os.path.join(_refs_dir(key), "c." + _key_segment(call) + ".json"){NL}    return os.path.join(_refs_dir(key), "u.%020d.%s.json" % (time.time_ns(), os.urandom(4).hex()))' \
    '    return os.path.join(_refs_dir(key), "one-slot.json")' \
    "the creation window would go back to ONE SLOT PER AGENT, so two of the agent's own calls open at once would clobber each other's window: the second Post would find nothing to compare against, and a ref created in that call -- a side branch carrying real commits included -- would be attributed to nobody while land() still reported LANDED (points 3, 5, 8, 10)."

# REPLACED, AND THE REASON IS THE POINT OF THIS ROUND. This mutant used to turn
# `all_open=True` into `all_open=False` and claimed the difference was
# load-bearing. It is not any more: since the before-sets are UNIONED rather
# than intersected, and the last snapshot always joins that union, WHICH open
# windows get consumed no longer changes what is attributed -- only whether
# they are left on disk for a finished agent, which nothing reads. Keeping it
# would have been a dead assertion wearing the shape of a rule, which is the
# class of defect this round exists to end. What IS still load-bearing is that
# the end-of-run signal observes AT ALL, so that is what is mutated.
mutant p03-no-end-of-run-observation "test_point_14_two_of_one_agents_own_calls_open_at_once_keep_both_windows" "$W" \
    '    observe_created_refs(rec, all_open=True){NL}    event("end", key=rec["key"], signal=signal_name, detail=detail)' \
    '    event("end", key=rec["key"], signal=signal_name, detail=detail)' \
    "the end-of-run signal would stop being an agent's LAST observation, so a ref created in a call whose PostToolUse never arrived -- because the run ended inside it -- would be attributed to nobody and left behind (points 3, 10)."

mutant p03-end-of-run-ignores-the-last-snapshot "test_point_03_a_ref_created_after_the_last_post_is_still_the_agents" "$W" \
    '    if all_open and latest and isinstance(latest.get("repos"), dict):{NL}        priors.append(latest)' \
    '    if False:{NL}        priors.append(latest)' \
    "the end-of-run signal would observe only windows still OPEN, so a ref created by the agent's own backgrounded process after its last PostToolUse consumed the window would be compared against nothing, attributed to nobody, and left behind by a land that reports success (points 3, 9, 10)."

mutant p03-backgrounded-window-consumed-at-its-post "test_point_03_a_backgrounded_calls_ref_after_its_post_is_still_the_agents" "$W" \
    '    background = str(payload.get("tool_name") or "") == "Bash" and bool(ti.get("run_in_background"))' \
    '    background = False' \
    "the platform's run_in_background stamp would be ignored, so a backgrounded call's window would be consumed at its Post and the ref its process creates afterwards -- which the next call's snapshot already holds -- would be attributed to nobody and left behind (points 3, 9, 10)."

mutant p14-unmerged-counts-as-landed "test_point_14_work_merged_nowhere_is_not_landed" "$W" \
    '                if rc == 0 and not is_ancestor(repo, out.strip(), tip):{AND}        if t and not is_ancestor(repo, t, tip):' \
    '                if False:{AND}        if False:' \
    "a branch that reached neither main nor its dev branch would be counted as landed, and deleted (points 4, 8, 14)."

mutant p08-refused-call-widens-the-window "test_point_03_a_refused_call_never_widens_the_window_to_the_whole_run" "$W" \
    '            before = b if before is None else (before | b){NL}    if latest and repo in (latest.get("repos") or {}):' \
    '            before = b if before is None else (before & b){NL}    if False:' \
    "the open windows would be INTERSECTED again and the last snapshot would stop narrowing them, so one window leaked by a REFUSED PreToolUse would make the end-of-run comparison ask \"what appeared while this agent existed\" instead of \"what changed during this call\" -- and a branch Rich cut between two of the agent's calls would be attributed to the agent and destroyed by its discard (point 8)."

mutant p03-unpaired-post-attributes-nothing "test_point_03_a_post_that_carries_no_call_id_still_ends_a_call" "$W" \
    '        own = [p] if os.path.exists(p) else [q for q in _open_slots(key) if not _is_background(q)][:1]' \
    '        own = [p] if os.path.exists(p) else []' \
    "a PostToolUse whose own window is missing -- the platform does not always carry tool_use_id on both halves -- would find nothing at either end, so a ref created inside that call would be attributed to nobody until the end of the run and, once the run had ended, to nobody at all (point 3)."

mutant p14-attribution-waits-for-the-record "test_point_14_attribution_never_waits_for_the_record" "$W" \
    '            _branch, target, _why_not = integration_target([rec], repo){NL}            wl = worktree_list(repo) or []' \
    '            _branch, target, _why_not = integration_target([rec], repo){NL}            if _why_not:{NL}                event("attribution-skipped", key=rec["key"], repo=repo,{NL}                      refs=fresh_refs, why=_why_not){NL}                continue{NL}            wl = worktree_list(repo) or []' \
    "attribution would WAIT for the integration branch to be recorded. It happens once, at the end of a tool call, so \"skipped\" means attributed to NOBODY PERMANENTLY: recording the branch afterwards unblocks the land and never goes back, and land() then reports success over a commit that reached no integration branch (points 5, 8, 10 through 14). The trace it wrote had one producer and no consumer."

mutant p03-borrowed-tip-counts-as-own-work "test_point_14_a_tip_the_agent_only_borrowed_is_not_its_work" "$W" \
    '                if _made_here(subject):{NL}                    tips.add(sha)' \
    '                if True:{NL}                    tips.add(sha)' \
    "every commit the workspace's HEAD ever MOVED TO would count as the agent's own work, checkouts included, so a ref Rich cut at a tip the agent merely BORROWED would be on the agent's line of work and would be deleted with it (points 3, 8)."

mutant p14-moved-recorded-branch-not-reported "test_point_14_a_recorded_branch_moved_in_an_agents_call_is_reported_and_left_alone" "$W" \
    '    _restore_protected_refs(rec, priors + bg_priors, latest)' \
    '    pass' \
    "a recorded branch (or a codex/ ref) moved or deleted during an agent's call by an unnamed verb, a verb the guard missed or a non-git write would go unseen: no report, and a deleted one never re-created — the doorway class no verb list can close (points 2, 14)."

mutant p14-a-move-is-put-back-again "test_point_14_the_engine_never_moves_the_recorded_branch_when_two_agents_run" "$W" \
    '                if cur is not None:{AND}    return git(repo, "update-ref", "-m", msg, "--no-deref", "refs/heads/" + branch, tip, "")' \
    '                if False:{AND}    return git(repo, "update-ref", "--no-deref", "refs/heads/" + branch, tip)' \
    "THE PRE-2026-09-14 BEHAVIOR, restored exactly: a MOVE would be written back instead of reported, by an unconditional, unattributed update-ref. That line moved refs/heads/main in richos three times in one night -- twice within twelve seconds in opposite directions, while Rich was landing -- because the check infers the writer from the SHAPE of the result and his ordinary land has the same shape as the doorway it hunts, and because each write manufactured the condition the next agent's check fired on (docs/verification/ref-write-forensics-2026-09-14.md; reproduced from nothing at docs/verification/protected-ref-oscillation-2026-09-14-logs/repro.py, where --mode destruction loses a merge he had just made)."

mutant p14-the-restore-write-is-anonymous-and-unconditional "test_point_02_the_restore_of_a_deleted_ref_is_create_only_and_never_clobbers" "$W" \
    '    return git(repo, "update-ref", "-m", msg, "--no-deref", "refs/heads/" + branch, tip, "")' \
    '    return git(repo, "update-ref", "--no-deref", "refs/heads/" + branch, tip)' \
    "the one write this check still makes would go back to the exact line that moved refs/heads/main unattributed: no old value, so it clobbers a ref somebody re-created between the deletion and the check instead of refusing; and no -m, so it lands in the reflog with an EMPTY message, which is what cost a day of forensics on 2026-09-13 (points 2, 14)."

mutant p14-protected-set-keyed-by-name-across-repositories "test_point_14_a_recorded_branch_is_protected_in_its_own_repository_only" "$W" \
    '    recorded = _protected_names(repo)' \
    '    recorded = set(w["branch"] for w in all_bodies_of_work().values() if (w or {}).get("branch"))' \
    "the protected set would go back to matching on branch NAME across every body of work, so 'main' recorded for one repository would protect -- and make writable -- refs/heads/main in every other. Three bodies of work on this machine, all three integrating on main (forensics §4)."

mutant p14-the-leads-move-reported-too "test_point_14_a_recorded_branch_moved_in_an_agents_call_is_reported_and_left_alone" "$W" \
    '                    else:{NL}                        landed = land_by_another_conversation(repo, b, old, cur){NL}                        if not landed:{NL}                            continue                    # a descendant carrying none of the agent'"'"'s work: the lead'"'"'s land{NL}                        action, why = "LANDED", landed  # except when the land record names another conversation' \
    '                    else:{NL}                        why = "moved"' \
    "the lead's own land onto the recorded branch during an agent's call would be reported as an agent's move (point 14: landing is his). It no longer UNDOES his land -- nothing does -- but a report that fires on every ordinary land is alarm fatigue, and this check's whole remaining value is that it only speaks when something is wrong."

mutant p14-end-of-run-reports-the-leads-land "test_point_14_the_leads_land_after_the_agents_last_call_is_not_undone" "$W" \
    '                elif b not in windowed:' \
    '                elif False:' \
    "the own-work rule would apply with no call open, so the lead's fast-forward of the agent's OWN branch onto the recorded one -- made after its last call, before its end signal -- would be reported as the agent's doing at the end signal (measured as a LAND REFUSAL on certification-sage-runner-round case R8, 2026-09-13, back when this branch of the rule also wrote)."

# --- THE OTHER CONVERSATION'S LAND (2026-09-17) ---------------------------
# The land lock made two threads' lands take turns. These five prove the second
# half: the thread that waited moved the branch under the other one's agents,
# and they are TOLD -- from the land record, never from the shape of the move.

mutant p14-another-conversations-land-not-reported "test_point_14_another_conversations_land_is_reported_and_this_conversations_is_not" "$W" \
    '                        landed = land_by_another_conversation(repo, b, old, cur)' \
    '                        landed = None' \
    "the before-state restored: EVERY fast-forward of the recorded branch during an agent's call would be silent, including the one made by the other conversation's land. Its agents would carry on against a base that had moved, with their snapshots, their records and their own land's before-tip stale and nothing saying so."

mutant p14-end-of-run-land-not-reported "test_point_14_another_conversations_land_is_reported_and_this_conversations_is_not" "$W" \
    '                elif b not in windowed:{NL}                    landed = land_by_another_conversation(repo, b, old, cur)' \
    '                elif b not in windowed:{NL}                    landed = None' \
    "another conversation's land made after the agent's LAST call -- the commonest moment for it, since that is when the agent is being landed and cleaned up -- would go unrecorded on the one record that outlives the run."

mutant p14-this-conversations-own-land-reported "test_point_14_another_conversations_land_is_reported_and_this_conversations_is_not" "$W" \
    '            if thread == mine:{NL}                return None             # this conversation'"'"'s own land' \
    '            if False:{NL}                return None             # this conversation'"'"'s own land' \
    "a conversation would be told about its OWN land -- the one it made, on the work of the very agents being told. Every land in a one-thread day would fire it, which is how a report becomes wallpaper and the cross-thread case it exists for stops being read."

mutant p14-terminal-land-reported-as-unattributed "test_point_14_another_conversations_land_is_reported_and_this_conversations_is_not" "$W" \
    '        if not records:{NL}            return None                 # land records are not in use here' \
    '        if not records:{NL}            records = [{}]' \
    "a repository that keeps NO land records -- the terminal path, where Rich lands with a hand-run git merge that writes nothing -- would have every one of his lands reported as a move nothing names. Those teammates are already told at the push by guard-inflight-notify.sh; this would put an alarm on the most ordinary write a recorded branch ever receives."

mutant p14-land-attributed-by-branch-alone "test_point_14_another_conversations_land_is_reported_and_this_conversations_is_not" "$W" \
    '            if record.get("branch") != branch or record.get("commit") != found:' \
    '            if record.get("branch") != branch:' \
    "attribution would answer with the LATEST land on the branch instead of the one that made this move, so with two lands in a row an agent would be told the wrong conversation moved its base -- which is worse than being told nothing, and is exactly what the append-only record was written to prevent."

mutant p02-agent-write-inside-codex-passes-the-lock-out "test_point_02_a_codex_ref_deleted_in_an_agents_call_is_restored_and_a_move_is_reported" "$W" \
    '        cx = _codex_workspace_of(fp){NL}        if cx:' \
    '        cx = _codex_workspace_of(fp){NL}        if False:' \
    "a registered agent's Edit or Write aimed inside a codex/ workspace would pass the only hook that sees it (point 2: an agent never works inside a codex/ workspace)."

mutant p14-second-body-of-work-moves-the-first "test_point_14_a_second_body_of_work_never_moves_the_first_ones_agents" "$W" \
    '    for r in chain or []:{NL}        wid = (r.get("integration_work") or {}).get(main_key)' \
    '    for r in []:{NL}        wid = (r.get("integration_work") or {}).get(main_key)' \
    "the integration branch would go back to one slot per REPOSITORY, read live. Point 5 permits a second body of work to start in a repository while the first one's agents are still running, so recording the second body's branch -- which point 14 requires -- would move the first body's running agents onto it retroactively: their work is merged onto the branch they were spawned for, their land is measured against a branch they never heard of, it refuses forever, and their workspaces are stranded (points 5, 14)."

# POINT 3, WHEN THE HOOK THAT REGISTERS A SPAWN IS KILLED (2026-09-17). The
# registration is a write performed by a PreToolUse hook, and the platform runs
# the tool anyway when it kills one — so the registry can be left holding a
# named record with no agent id beside a provisional record carrying the
# platform's own start and end for the same run, and the finished work cannot
# be retired at all. These four prove the repair is load-bearing, and that it
# adopts recorded facts rather than supplying missing ones.
mutant p03-killed-registration-not-bound-at-its-post "test_point_03_a_spawn_whose_registration_was_killed_is_bound_at_its_post" "$W" \
    '        if not rec and name and NAME_RE.match(name):' \
    '        if False:' \
    "a spawn whose PreToolUse registration was killed would stay unbound at its Post, although the platform delivers the name and the agent id together there — the first moment the gap exists (point 3)."

mutant p03-missed-spawn-never-reconciled "test_point_03_a_spawn_the_registry_never_saw_is_reconciled_from_the_platforms_own_record" "$W" \
    '    if not rec or rec.get("agent_id") or rec.get("provisional") or rec.get("orphan"):{NL}        return rec' \
    '    if True:{NL}        return rec' \
    "a registration the registry never bound to an agent would never adopt the platform's own record of which agent it became, so its finished work could be retired only by hand — which is what point 11 forbids (\"automatically and never by Rich noticing\")."

mutant p03-reconciliation-picks-a-candidate "test_point_03_an_ambiguous_platform_record_is_never_guessed_at" "$W" \
    '    if len(hits) != 1:{NL}        return rec' \
    '    if not hits:{NL}        return rec' \
    "two of the platform's records answering to one name would be resolved by taking the first, which makes a reconciliation a guess between candidates instead of the adoption of a fact (point 3)."

mutant p03-reconciliation-invents-an-ending "test_point_03_a_reconciled_binding_never_invents_an_ending" "$W" \
    '        prov = _absorb_provisional(fresh, prov_key)' \
    '        prov = _absorb_provisional(fresh, prov_key){NL}        fresh["end"] = fresh.get("end") or {"at": now(), "signal": "SubagentStop", "detail": ""}' \
    "adopting the binding would also declare the run over, so an agent still working would be landed out from under itself. The platform's per-agent record proves WHICH agent the call became and says nothing about whether it has ended (points 3, 11)."

mutation_end
