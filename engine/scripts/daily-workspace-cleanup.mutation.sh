#!/usr/bin/env bash
#
# daily-workspace-cleanup.mutation.sh — PROVES the daily lane's suite CAN
# FAIL, one refusal at a time. Invoked by daily-workspace-cleanup.test.sh; the
# loop is scripts/lib/mutation-harness.sh. Case ids are the unittest method
# names the wrapper prints on its PASS/FAIL lines.
#
# WHY THIS FILE EXISTS. Round 10 (docs/worktree-reclaim-round-10-2026-09-10.md)
# is the tenth attempt at this class, and the wiki's replacement warning is
# blunt: every round shipped a green suite that encoded its author's premise.
# Each mutant below removes ONE thing that stands between a terminal worktree
# and its removal and demands the named case goes red — which is the only
# evidence that the refusal was ever doing anything. The live-locked member,
# the running session, the process in the tree, the unmerged branch, the
# untracked file, the unverified archive: each has a mutant here.
#
# NOT COVERED, stated rather than implied:
#   * the capture-store rooting refusal (_assert_capture_rooting). Its mutant
#     would make the suite archive a sandbox's residue into the OPERATOR'S
#     REAL ~/.claude/state/worktree-captures/, which is the exact write the
#     refusal exists to prevent. It is a four-line fail-closed check reviewed
#     by reading, and its positive case
#     (test_residue_refuses_when_capture_store_is_at_default_...) is in the
#     suite.
#   * platform_lock_is_absent (round 11, renamed round 12). It reads the SAME artifact
#     owner_check's liveness veto reads — Claude Code's lock on the native
#     registration — so a mutant that made it lie is caught by the veto, by
#     _release_dead_lock's no-pid refusal, or by assess's lock-pid branch, and
#     would prove nothing about the predicate itself. It is kept as a second,
#     cheaper reading because the immediate lane needs to say WHO is holding
#     the workspace without running the whole lane, and because a defense in
#     depth over the one artifact that decides is worth its two lines. Its
#     positive case (the live lock refuses, the platform's own release lets
#     the reclaim through) is
#     test_native_of_a_running_session_is_reclaimed_when_the_platform_releases_its_lock.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$SCRIPT_DIR/lib/mutation-harness.sh"
mutation_begin "daily-workspace-cleanup (the reclaim lane)" "scripts/daily-workspace-cleanup.test.sh"

D="scripts/lib/daily-workspace-cleanup.py"
P="scripts/lib/completion-proof.py"
X="scripts/lib/worktree-transactions.py"

mutant residue-archive-skipped "test_ignored_disposable_is_dropped_and_ignored_residue_is_archived_verified_then_reclaimed" "$D" \
    "        residue_record, residue_archived = (archive_residue(tx, transaction, index, member['path'], residue){NL}                                            if residue else (None, {}))" \
    "        residue_record, residue_archived = None, residue_manifest(member['path'], residue) if residue else {}" \
    "an ignored file the disposable policy does not name would go with the tree and no copy would exist — PF9: git worktree remove deletes ignored files without refusing."

mutant nested-repository-dropped-as-disposable "test_a_nested_repository_under_a_disposable_path_is_ARCHIVED_whole_never_dropped" "$D" \
    "    return is_nested_repository(rel) or '.git' in rel.rstrip('/').split('/')" \
    "    return False" \
    "a clone an agent made under an ignored vendor/, .cache/ or node_modules/ -- with commits nowhere else -- would be classified disposable by its PARENT's name and deleted by the non-force removal with no copy taken. Frank R1, round two: reproduced under the lane's own binary, the only loss path found in two rounds."

mutant ignored-last-look-removed "test_an_ignored_file_written_after_the_archive_HOLDS_the_removal" "$D" \
    "        unchanged, why_changed = residue_last_look(member['path'], repo, residue_archived)" \
    "        unchanged, why_changed = True, ''" \
    "an ignored file written between the archive and the rm -- by a writer the process probe did not see -- would be deleted with the tree while the journal named a verified archive that does not hold it (Sage D3, round two)."

mutant residue-verification-skipped "test_unverifiable_residue_archive_holds_the_tree" "$D" \
    "    verify_residue_archive(tar_path, manifest)" \
    "    pass" \
    "a residue archive that did not verify would still authorize the removal it exists to precede."

mutant session-gone-on-any-status "test_native_of_an_engine_derived_terminal_fact_stays_platform_owned" "$D" \
    "        if status not in ('gone', 'reused'):{NL}            return False, 'session %s pid %s is %s' % (sid[:8], pid, status)" \
    "        if False:{NL}            return False, 'session %s pid %s is %s' % (sid[:8], pid, status)" \
    "a native checkout of a RUNNING session would be removed on the strength of a recorded identity alone — a live agent's workspace, which is the failure that ended round 5. Round 11 added an agent-sized ground beside this one, so the case pinned here is the one where the agent ground does NOT apply and only the session ground can refuse."

mutant no-identity-means-gone "test_native_with_no_recorded_session_identity_is_not_provably_gone" "$D" \
    "    if not identities:{NL}        return False, 'no process identity recorded for session %s; not provably gone' % sid[:8]" \
    "    if not identities:{NL}        return True, 'mutant: absence read as death'" \
    "absence of a record would be read as evidence the owner is gone — the inference doctrine forbids and nine rounds died on."

# The lock's own pid is checked INDEPENDENTLY of the session verdict and of
# owner_check's liveness veto; removing all three is what it takes to make the
# contradiction case (ledger says gone, lock pid runs) delete a tree.
mutant dead-lock-check-removed "test_native_lock_held_by_a_running_pid_holds_whatever_the_ledger_says" "$D" \
    "    if status != 'gone':{NL}        raise RuntimeError('lock pid %s is %s; retained' % (pid, status)){AND}    if live.get('verdict') != 'NOT-ALIVE':{NL}        raise RuntimeError('native owner is live or unknown: ' + str(live.get('reason'))){AND}        if status not in ('gone', 'reused'):{NL}            return False, 'session %s pid %s is %s' % (sid[:8], pid, status)" \
    "    if False:{NL}        raise RuntimeError('lock pid %s is %s; retained' % (pid, status)){AND}    if False:{NL}        raise RuntimeError('native owner is live or unknown: ' + str(live.get('reason'))){AND}        if False:{NL}            return False, 'session %s pid %s is %s' % (sid[:8], pid, status)" \
    "a lock held by a RUNNING pid would be released and the tree removed because a ledger row said the session was gone — a contradiction resolved in favor of deleting."

mutant process-hold-removed "test_process_standing_in_the_tree_holds_it_and_nothing_is_killed" "$D" \
    "        pids = processes_using(member['path']){NL}        if pids:{NL}            raise RuntimeError" \
    "        pids = []{NL}        if pids:{NL}            raise RuntimeError" \
    "a process standing in the tree would have its directory removed under it."

mutant absent-native-integration-check-removed "test_absent_native_without_receipt_keeps_an_unintegrated_branch" "$D" \
    "    if tip and proof_api.git(repo, 'merge-base', '--is-ancestor', tip, main, allowed=(0, 1)).returncode:" \
    "    if False:" \
    "a branch carrying commits main does not contain would be deleted by compare-and-set — PF2: git protects nothing here, the branch ref is the only copy."

mutant ingress-set-widened "test_unsupported_competing_terminal_ingress_remains_reserved" "$D" \
    "ACCEPTED_INGRESSES = ('SubagentStop', 'WorktreeRemove', 'NativeMemberGone', 'TaskStop', 'Adoption')" \
    "ACCEPTED_INGRESSES = ('SubagentStop', 'WorktreeRemove', 'NativeMemberGone', 'TaskStop', 'Adoption', 'TaskCompleted')" \
    "an event nobody measured (TaskCompleted, diagnostic only by ruling) would count as a terminal fact and release a competing reservation."

mutant platform-ground-widened "test_native_of_an_engine_derived_terminal_fact_stays_platform_owned" "$D" \
    "PLATFORM_TERMINAL_INGRESSES = ('SubagentStop', 'WorktreeRemove', 'TaskStop')" \
    "PLATFORM_TERMINAL_INGRESSES = ('SubagentStop', 'WorktreeRemove', 'TaskStop', 'Adoption', 'NativeMemberGone')" \
    "this engine's OWN derivation of terminality would be read as the platform saying the worker stopped, and a running session's checkout would be taken out of its hands on evidence the platform never gave."

mutant ingress-hands-native-back-to-the-nightly "test_native_terminal_ingress_reclaims_in_the_same_event" "$X" \
    "                    _soft_failure(session_id, agent_id, i, str(error)){NL}                _reclaim_in_event(session_id, agent_id, i, deadline)" \
    "                    _soft_failure(session_id, agent_id, i, str(error)){NL}                pass" \
    "a finished agent's NATIVE checkout would be recorded at the terminal event and reclaimed up to 24 hours later by the 04:00 job — the gap the CEO was looking at on 2026-09-10."

mutant ingress-hands-hand-rolled-back-to-the-nightly "test_hand_rolled_terminal_ingress_reclaims_in_the_same_event" "$X" \
    "            # always did, and the nightly pass retries.{NL}            _reclaim_in_event(session_id, agent_id, i, deadline)" \
    "            # always did, and the nightly pass retries.{NL}            pass" \
    "the same gap for the CROSS-REPOSITORY worktree, which is 48 of the 53 worktrees on this machine."

mutant ingress-ignores-the-platform-lock "test_ingress_waits_for_the_platform_to_release_its_own_lock_and_never_removes_it" "$D" \
    "        absent, why = platform_lock_is_absent(holder, proof_api.registry(repo).get(path))" \
    "        absent, why = True, 'mutant: the platform lock is ignored'" \
    "the ingress would walk past a lock the platform still holds — and after round 12 that lock is not a courtesy, it is the ONE present-tense liveness fact this platform provides (measured: it is written 43ms and 49ms BEFORE the run's start hook fires)."

# ROUND 12, 2026-09-10. The two mutants that stood here pinned
# `lock_names_nobody` and `_release_unattributable_lock` — the route that took
# the PLATFORM'S lock off a workspace and then deleted it. Both are gone, and
# so are their mutants: there is no longer a second door past a held lock, so
# there is nothing left to mutate. The refusal is now
# test_a_lock_that_names_nobody_is_STILL_A_LOCK_and_the_engine_never_takes_it_off,
# whose negative direction is covered by the mutants below instead.

mutant restart-after-terminal-ignored "test_a_restart_after_terminal_is_recorded_and_HOLDS_every_workspace_of_that_agent" "$D" \
    "    if not tx.running_after_terminal(transaction):{NL}        return False, ''" \
    "    if True:{NL}        return False, ''" \
    "the workspace of an agent the platform has STARTED AGAIN, mid-run, would be removed under it. Ten of the 66 workspace-owning terminal agents on this machine restarted after their terminal record; round 11 authorized deletion on the premise that none could."

# ROUND 13 (2026-09-10), Frank R2/R4: row 5 had one source and no expiry.
mutant second-source-ignored "test_a_lost_stop_note_is_closed_by_the_platforms_own_event_log_and_a_lost_start_note_is_opened_by_it" "$X" \
    "    out.extend(platform_lifecycle_after(transaction.get(\"session_id\") or \"\",{NL}                                        transaction.get(\"agent_id\") or \"\", terminal_ts))" \
    "    pass  # mutant: the platform's own event log is never consulted" \
    "a stop note lost to the 5-second flock a sweep holds for a whole reclaim would leave the run open in the record FOREVER, and a lost start note would leave a restart invisible to the lane; the platform wrote both events down in its own log and nothing would read it (Type J: a claim with no condition that voids it)."

mutant session-death-does-not-void-an-open-run "test_a_post_terminal_run_cannot_outlive_its_session" "$D" \
    "    if gone:{NL}        return False, ('a post-terminal run of agent %s was recorded open, but %s" \
    "    if False:{NL}        return False, ('a post-terminal run of agent %s was recorded open, but %s" \
    "a session that died with a post-terminal run open would hold that agent's workspaces forever on a note nothing could ever close — a run cannot outlive the process it ran in."

mutant stale-hold-never-names-a-person "test_a_stale_open_run_names_the_operator_remedy_and_the_remedy_works" "$D" \
    "    if since and age > stale:" \
    "    if False:" \
    "a run open for hours past anything ever observed would keep saying 'held until the run ends' — the RETRY vocabulary over a hold that has no way to clear — instead of naming what a person can check and do."

mutant process-probe-fails-open-again "test_a_process_probe_that_cannot_look_HOLDS_and_never_reports_an_empty_tree" "$D" \
    "    except Exception as error:{NL}        raise RuntimeError('RETRY, not a verdict: could not determine whether any process is standing '" \
    "    except Exception as error:{NL}        pass{NL}    if False:{NL}        raise RuntimeError('RETRY, not a verdict: could not determine whether any process is standing '" \
    "a timeout, a missing lsof or a permission error would return an empty list again, and the caller would read a failure to LOOK as a statement that nothing is there. The case exercises the REAL branch with lsof made unreachable, not only the test override."

mutant last-look-before-removal-removed "test_a_relock_between_the_check_and_the_removal_makes_the_removal_FAIL" "$D" \
    "        if not fresh or 'locked' in fresh or 'prunable' in fresh:" \
    "        if False:" \
    "a workspace re-locked by the platform DURING the reclaim's preparation (archiving residue takes seconds; the platform locks before a restarted run begins) would go to the removal anyway. git refuses it behind this, so the tree survives — but the journal would say nothing about why, which is how the same class stayed invisible for eleven rounds."

mutant journal-overwrites-again "test_the_immediate_reclaim_journal_APPENDS_instead_of_overwriting" "$D" \
    "            tx.update_member(sid, aid, index, immediate_reclaim=entry,{NL}                             immediate_reclaim_history=history," \
    "            tx.update_member(sid, aid, index, immediate_reclaim=entry,{NL}                             immediate_reclaim_history=history[-1:]," \
    "only the last outcome would survive, as before — the reason 'zero of five reclaims happened in their own event' had to be established from timestamps rather than from the journal built to answer it."

mutant ceo-ruling-not-in-the-mechanism "test_a_codex_workspace_is_EXCLUDED_BY_CEO_RULING_at_every_door" "$D" \
    "    ceo_owned, why = ceo_owned_workspace(member){NL}    if ceo_owned:" \
    "    ceo_owned, why = ceo_owned_workspace(member){NL}    if False:" \
    "ceo-decisions.md section 31 would be back to resting on the record hole it explicitly says must not BE the protection -- 'we only ever remove what we registered' -- which a hand-written ledger row walked through on 2026-09-10."

mutant hand-written-ledger-row-binds-again "test_a_hand_written_ledger_row_RESERVES_but_never_BINDS" "$X" \
    "            elif not (name_join_ok and row.get(\"teammate\") == teammate{NL}                      and _ledger().row_may_bind_by_name(row)):" \
    "            elif not (name_join_ok and row.get(\"teammate\") == teammate):" \
    "any hand that can append a line to the ownership ledger could again bind a workspace nobody registered into the reclamation lane and have it deleted -- which happened at 14:23:47Z on 2026-09-10, and would pass identically with a codex/ path."

mutant late-binding-removed "test_a_workspace_created_after_the_seal_joins_the_transaction_and_is_reclaimed" "$X" \
    "    tx = bind_late_members(session_id, agent_id) or tx" \
    "    pass" \
    "a workspace given to an agent AFTER its manifest sealed would join no transaction, so no terminal ingress could ever name it -- two of zach-opus-dor2's four workspaces, structurally unreclaimable for the life of the session."

mutant late-binding-joins-an-ambiguous-name "test_a_late_row_is_NOT_bound_when_the_teammate_name_is_ambiguous" "$X" \
    "    return found == 1" \
    "    return True" \
    "a teammate name shared by two transactions in one session would still be treated as an exact join, so one agent's terminal event would bind and reclaim another's workspace."

mutant ownerless-row-of-any-session-retired "test_an_ownerless_row_of_a_LIVE_session_still_reserves" "$D" \
    "                    gone, _why = session_id_gone(row.get('session_id') or '', tx){NL}                    if gone:{NL}                        continue" \
    "                    if True:{NL}                        continue" \
    "a preparation row naming no agent would stop reserving whatever its session was doing -- including a session that is running right now, whose worktree it was written to protect."

mutant untracked-refusal-removed "test_dirty_staged_and_untracked_refuse" "$P" \
    "    if git(path,'ls-files','--others','--exclude-standard','-z').stdout:{NL}        raise CompletionError" \
    "    if False:{NL}        raise CompletionError" \
    "an untracked file — work nobody committed — would be deleted with the tree."

mutant unintegrated-tree-removed "test_unintegrated_refuses" "$P" \
    "    if git(repo,'merge-base','--is-ancestor',proof['head'],main,allowed=(0,1)).returncode:{NL}        # THE VERDICT IS RIGHT AND THE OLD REASON WAS MISLEADING (2026-09-10)." \
    "    if False:{NL}        # THE VERDICT IS RIGHT AND THE OLD REASON WAS MISLEADING (2026-09-10)." \
    "a worktree whose commits main does not contain would be removed and its branch deleted — unlanded work gone."

mutation_end
