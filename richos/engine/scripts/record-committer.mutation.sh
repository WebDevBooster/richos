#!/usr/bin/env bash
#
# record-committer.mutation.sh: PROVES record-committer.test.sh WOULD CATCH THE
# RECORD COMMITTER GOING WRONG (daily-driver plan step 8; two-installs spec point
# 28). Each mutant removes ONE property from a throwaway copy of the engine and
# demands that the NAMED case go red. The loop is scripts/lib/mutation-harness.sh.
#
# The loro writer is the committer's INPUT, not the subject under mutation, and the
# sandbox copy of the engine does not carry loro/. The suite is pointed at this
# checkout's writer through RICHOS_TEST_LORO_WRITE.
#
# Run directly: scripts/record-committer.mutation.sh

# THE MERGE GATE LEAVES THIS PASS TO THE NIGHTLY (richos/app/scripts/autocheck/README.md): the
# gate runs the suite with RICHOS_MUTATION_PASSES=0; nightly-engine.py runs every pass.
if [ "${RICHOS_MUTATION_PASSES:-}" = 0 ]; then echo "NOT RUN: $(basename "$0"), a mutation pass (RICHOS_MUTATION_PASSES=0, the merge gate; the nightly runs it)"; exit 0; fi

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/mutation-harness.sh
. "$ENGINE_ROOT/scripts/lib/mutation-harness.sh"

export RICHOS_TEST_LORO_WRITE="$ENGINE_ROOT/loro/bin/loro-write.mjs"
mutation_begin "the record committer" "scripts/record-committer.test.sh"
mutation_focus want-as-argument

L="scripts/lib/record_committer.py"

mutant land-lock-not-taken "K2 " "$L" \
    '        with LandLock(top):' \
    '        with open(os.devnull):' \
    "point 28 / §C 28: a tick would commit in the middle of the app lander's land."
mutant lease-ignored "K6 " "$L" \
    '            if holder is not None:{NL}                raise Skip("an operator land lease is held' \
    '            if False:{NL}                raise Skip("an operator land lease is held' \
    "a tick would move main under a lead that holds the land lease."
mutant merge-in-progress-ignored "K3 " "$L" \
    '    busy = OF.in_progress_files(paths["gitdir"]){NL}    if busy:' \
    '    busy = OF.in_progress_files(paths["gitdir"]){NL}    if False:' \
    "a tick would conclude a person's half-done merge with a machine commit."
mutant writer-lock-ignored "K4 " "$L" \
    '            with WriterLock(top):' \
    '            with open(os.devnull):' \
    "a tick could commit half of a two-file supersession while the writer is mid-write."
mutant commit-whole-index "K1 " "$L" \
    '"-m", message(files), "--", *files)' \
    '"-m", message(files))' \
    "a person's staged change would be swept into the committer's commit."
mutant pathspec-widened "K1 " "$L" \
    '    "loro/records",' \
    '    ".",' \
    "hand edits anywhere in the record would be committed past the landing guards."
mutant temporaries-committed "K1 " "$L" \
    '    ":(exclude,glob)**/.loro-*.incoming",' \
    '' \
    "the writer's half-written temporary file would be committed."
mutant fence-hooks-not-bypassed "K6 " "$L" \
    '                pre = ("-c", "core.hooksPath=/dev/null") if fenced else ()' \
    '                pre = ()' \
    "with the fence on, every tick would be refused and nothing would ever be committed."
mutant branch-not-checked "K5 " "$L" \
    '    if out.strip() != "refs/heads/" + branch:' \
    '    if False:' \
    "a tick would commit onto whatever branch a person has checked out."
# K10 has no mutant, and that is measured rather than overlooked: the committer
# once carried an explicit index.lock pre-check, its mutant left K10 green
# (2026-09-28), because git's own `add` refuses on the lock and names it. The
# pre-check was deleted for that reason. K10 stays as the behavioral proof that a
# concurrent git command turns a tick into a clean skip.
mutant worktree-accepted "K9 " "$L" \
    '    if not paths["main"] or paths["gitdir"] != paths["common"] or paths["top"] != paths["main"]:' \
    '    if not paths["main"]:' \
    "a tick could commit into a teammate's linked worktree."
mutant quiet-status-always-installed "K8 " "$L" \
    '    if "--quiet" in opts:{NL}        return 0 if ok else 3' \
    '    if "--quiet" in opts:{NL}        return 0' \
    "record-owner.sh on would believe a committer is installed when none is."
mutant interval-unbounded "K8 " "$L" \
    '    if not 60 <= interval <= 3600:' \
    '    if False:' \
    "a five-second job would run git in his record twelve times a minute."

mutation_end
