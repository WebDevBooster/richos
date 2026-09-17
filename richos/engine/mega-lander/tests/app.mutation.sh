#!/usr/bin/env bash
#
# app.mutation.sh — PROVES THE LAND LOCK'S TESTS CAN FAIL, one property at a
# time. Invoked by app.test.sh; the loop is scripts/lib/mutation-harness.sh.
#
# WHY THIS HARNESS EXISTS AT ALL. Before 2026-09-17 two conversation threads
# each took their own lock file and both landed into one repository at the same
# moment; `mega-lander/tests/app.test.py` was GREEN throughout, because it ran
# one thread and one thread never contends with itself. A suite that is green
# with the property present and green with it removed measures nothing, and that
# is exactly the state the land lock's tests would be in without this file.
#
# Every mutant below removes ONE property of the lock in a throwaway copy of the
# engine and names the test that must go red for it.
#
# Run directly: mega-lander/tests/app.mutation.sh
# Exit 0 = every property is proven load-bearing.

set -uo pipefail
[ -n "${RICHOS_MUTATION_INNER:-}" ] && exit 0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/mutation-harness.sh
. "$SCRIPT_DIR/../../scripts/lib/mutation-harness.sh"

mutation_begin "the per-repository land lock (app.py integrate)" "mega-lander/tests/app.test.sh"

A="mega-lander/app.py"

# --- 1. THE LAND IS UNDER THE LOCK, OR IT IS NOT LOCKED AT ALL -------------
# The before-state itself: `integrate` reaches `git merge --ff-only` holding
# only per-conversation locks, so two threads merge into one repository at once.
mutant land-not-locked "test_two_conversations_landing_in_one_repository_take_one_lock_and_the_merge_is_under_it" "$A" \
    '    with land_lock(scope,repository) as land:' \
    '    with contextlib.nullcontext({}) as land:' \
    "the fast-forward would run with no lock on the repository at all -- the exact defect, restored: two threads' merges race and the loser's finished, reviewed work is re-implemented."

# --- 2. THE LOCK IS KEYED TO THE REPOSITORY -------------------------------
# A lock keyed to nothing is machine-wide, which is "correct" and makes every
# unrelated pair of conversations queue behind each other for no reason.
mutant lock-not-keyed-to-the-repository "test_one_repository_reached_two_ways_is_one_lock_and_two_repositories_are_two" "$A" \
    '    canonical = canonical_repository(repo){NL}    name = os.path.basename(canonical.rstrip("/"))' \
    '    canonical = "every repository at once"{NL}    name = os.path.basename(canonical.rstrip("/"))' \
    "one lock would cover every repository on the machine, so two conversations landing into two different repositories -- the case the CEO says he will actually run -- would wait on each other."

# --- 3. ONE REPOSITORY REACHED TWO WAYS IS ONE LOCK -----------------------
# Without the canonicalization the key is the string it was reached by: a
# symlinked connection, or a linked worktree, gets its own lock file and the two
# of them move the same branch at the same time.
mutant canonical-path-not-resolved "test_one_repository_reached_two_ways_is_one_lock_and_two_repositories_are_two" "$A" \
    '    return os.path.realpath(os.path.expanduser(common or str(repo)))' \
    '    return str(repo)' \
    "two paths to one repository -- a symlink, or a linked worktree sharing the ref store -- would take two different locks and race on the same branch."

# --- 4. THE LOCK LIVES OUTSIDE BOTH CONVERSATION PARTITIONS ---------------
# The whole defect wearing a new name: a lock file under a per-thread directory
# is a lock two threads cannot share.
mutant partition-home-accepted "test_the_land_lock_refuses_to_live_inside_either_conversation_partition" "$A" \
    '        if base == partition or base.is_relative_to(partition):' \
    '        if False:' \
    "the land lock could be pointed inside \$RICHOS_WORKSPACES_DIR or the app state root, where each thread has its own copy -- two locks again, and nothing would say so."

# --- 5. THE SECOND LANDER WAITS; IT NEVER REFUSES THE WORK ---------------
# The bound is a backstop for a stuck holder. If it is the FIRST answer instead,
# every ordinary overlap refuses reviewed work and costs it an implementation
# and a review to recover.
mutant contention-refuses-instead-of-waiting "test_the_second_lander_waits_for_the_first_and_never_refuses_the_work" "$A" \
    '                waited = time.monotonic() - started{NL}                if waited >= timeout:' \
    '                waited = time.monotonic() - started{NL}                if True:' \
    "a land that merely overlapped another would be refused instead of queued, and a refused land sends finished, reviewed work back for a fresh implementation and a fresh review."

# --- 6. AND THE REFUSAL NAMES THE HOLDER ---------------------------------
# The matched control for mutant 5. A refusal is allowed, at the bound; a
# refusal that cannot say who is holding the repository is an unactionable one,
# and the operator's only next move would be to guess.
mutant refusal-does-not-name-the-holder "test_a_holder_past_the_bound_is_refused_by_name_with_nothing_merged" "$A" \
    '    if not holder:{NL}        return "another conversation, which left no readable record in the lock file"' \
    '    if True:{NL}        return "another conversation, which left no readable record in the lock file"' \
    "the refusal at the bound would say only that somebody was landing, never which conversation -- and the one thing the reader needs is which other thread to go and look at."

# --- 7. A WAIT IS REPORTED, NOT SILENT -----------------------------------
# "The second lander WAITS, in order, AND SAYS SO." A silent wait looks exactly
# like a slow land, and a land nobody can see queueing is a land nobody believes
# is serialized.
mutant wait-not-reported "test_the_second_lander_waits_for_the_first_and_never_refuses_the_work" "$A" \
    '        if holder is not None:{NL}            status["waited_for"] = _land_holder_text(holder)' \
    '        if False:{NL}            status["waited_for"] = _land_holder_text(holder)' \
    "a land that queued behind another conversation for minutes would report nothing about it, so the serialization would be invisible to the only person who could notice it was wrong."

mutation_end
