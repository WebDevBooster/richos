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
#   * platform_released_its_lock (round 11). It reads the SAME artifact
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
    "        residue_record = archive_residue(tx, transaction, index, member['path'], residue) if residue else None" \
    "        residue_record = None" \
    "an ignored file the disposable policy does not name would go with the tree and no copy would exist — PF9: git worktree remove deletes ignored files without refusing."

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
    "                    _soft_failure(session_id, agent_id, i, str(error)){NL}                _reclaim_in_event(session_id, agent_id, i)" \
    "                    _soft_failure(session_id, agent_id, i, str(error)){NL}                pass" \
    "a finished agent's NATIVE checkout would be recorded at the terminal event and reclaimed up to 24 hours later by the 04:00 job — the gap the CEO was looking at on 2026-09-10."

mutant ingress-hands-hand-rolled-back-to-the-nightly "test_hand_rolled_terminal_ingress_reclaims_in_the_same_event" "$X" \
    "            # always did, and the nightly pass retries.{NL}            _reclaim_in_event(session_id, agent_id, i)" \
    "            # always did, and the nightly pass retries.{NL}            pass" \
    "the same gap for the CROSS-REPOSITORY worktree, which is 48 of the 53 worktrees on this machine."

mutant ingress-ignores-the-platform-lock "test_ingress_waits_for_the_platform_to_release_its_own_lock_and_never_removes_it" "$D" \
    "        released, why = platform_released_its_lock(holder, proof_api.registry(repo).get(path))" \
    "        released, why = True, 'mutant: the platform lock is ignored'" \
    "the ingress would walk past a lock Claude Code still holds instead of waiting for the platform's own release — the tree survives on the liveness veto behind it, but the engine would be deciding a question that is the platform's."

mutant untracked-refusal-removed "test_dirty_staged_and_untracked_refuse" "$P" \
    "    if git(path,'ls-files','--others','--exclude-standard','-z').stdout:{NL}        raise CompletionError" \
    "    if False:{NL}        raise CompletionError" \
    "an untracked file — work nobody committed — would be deleted with the tree."

mutant unintegrated-tree-removed "test_unintegrated_refuses" "$P" \
    "    if git(repo,'merge-base','--is-ancestor',proof['head'],main,allowed=(0,1)).returncode:{NL}        raise CompletionError('Current canonical main no longer contains the delivery')" \
    "    if False:{NL}        raise CompletionError('Current canonical main no longer contains the delivery')" \
    "a worktree whose commits main does not contain would be removed and its branch deleted — unlanded work gone."

mutation_end
