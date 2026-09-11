#!/usr/bin/env bash
# Mutation harness for guard-worktree-removal.sh: M1-M4 cover the rule-4
# (filesystem rm) rewrite, M5-M7 the 2026-09-02 clause-scoping fix to the git
# rules, M12-M16 the workspace spec's no-override refusals. M5 and M7 are the under-blocking direction, M6 the over-permissive
# one -- a fix for a false positive can always be faked by disabling the
# guard, so that direction gets a mutant of its own.
# Each mutant strips ONE fix back out and asserts (a) the suite fails, (b) the
# SPECIFIC named case fails, and (c) the mutation actually applied — a sed that
# matched nothing would give a green run that looked like a green run.
#
# EVERY MUTANT RUNS IN A THROWAWAY COPY OF THE WHOLE ENGINE, for the reason set
# out at length in scripts/lib/mutation-harness.sh: this harness used to mutate
# the SHIPPED guard-worktree-removal.sh in place and put it back with
# `trap ... EXIT`, and an EXIT trap is a promise conditional on exiting. A
# `kill -9`, an OOM kill or a closed terminal between the two writes left the
# operator's live removal guard modified with nothing to say so — and this
# harness is invoked by contract-integrity.test.sh, so the window was open on
# every CI verify. It also never checked, even on a clean exit, that the guard
# HAD been put back: its sibling did, this one did not.
#
# The sandbox is the whole mechanical layer, M0 proves the unmutated sandbox
# suite is green before any mutant is trusted, and M99 witnesses the shipped
# guard's contents AND mtime across the run — never opened for writing, rather
# than restored afterwards.
set -uo pipefail
SRC_ENG="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/mutation-harness.sh
. "$SRC_ENG/scripts/lib/mutation-harness.sh"
# shellcheck source=../lib/tree-witness.sh
. "$SRC_ENG/scripts/lib/tree-witness.sh"

SHIPPED_GUARD="$SRC_ENG/scripts/hooks/guard-worktree-removal.sh"
tw_pick_mtime
SHIPPED_BEFORE="$(tw_file_witness "$SHIPPED_GUARD")"

mutation_sandbox_engine "$SRC_ENG"
ENG="$MUT_SANDBOX_ENGINE"
GUARD="$ENG/scripts/hooks/guard-worktree-removal.sh"
SUITE="$ENG/scripts/hooks/guard-worktree-removal.test.sh"
# THE PRISTINE REFERENCE SANDBOX, NEVER MUTATED. It exists for two jobs only:
# the M0 baseline below, and the final md5 assertion that nothing wrote to it.
# Each mutant builds its OWN copy -- see _mut_worker_sandbox.
#
# `restore` USED TO PUT THIS ONE BACK BETWEEN MUTANTS, and that is exactly what
# made the harness unsafe to run concurrently: two mutants would have written the
# same file, and the second would have measured the first one's mutation. It is
# kept here as a LOUD FAILURE rather than deleted, so a mutant block that still
# calls it stops the run instead of quietly sharing a sandbox again.
restore() {
    echo "ERROR: restore() was called. This harness no longer shares one sandbox" >&2
    echo "       between mutants -- each builds its own. A call here means a mutant" >&2
    echo "       block was not converted, and it would be mutating the reference" >&2
    echo "       sandbox that M0 and the final md5 check depend on." >&2
    exit 2
}

# shellcheck source=../lib/stopwatch.sh
. "$SRC_ENG/scripts/lib/stopwatch.sh"
# shellcheck source=../lib/mutation-pool.sh
. "$SRC_ENG/scripts/lib/mutation-pool.sh"
mut_pool_init
MUT_WALL_T0="$(sw_now_ms)"

# _mut_worker_sandbox — a throwaway engine copy for ONE mutant.
#
# It ASSIGNS to the caller's locals (bash is dynamically scoped), so each mutant
# function declares `local ENG GUARD SUITE W_DIR MUT_SCORE` and everything the
# block already says about "$GUARD" and "$SUITE" keeps working unchanged against
# the worker's own files.
_mut_worker_sandbox() {
    W_DIR="$(cd "$(mktemp -d -t mutant-sandbox.XXXXXX)" && pwd -P)" || return 1
    ENG="$W_DIR/engine"
    mkdir -p "$ENG"
    if ! mutation_copy_engine "$ENG" "$SRC_ENG"; then
        echo "UNPROVEN  ??   <- could not build this mutant's sandbox" >&2
        rm -rf "$W_DIR"
        return 1
    fi
    GUARD="$ENG/scripts/hooks/guard-worktree-removal.sh"
    SUITE="$ENG/scripts/hooks/guard-worktree-removal.test.sh"
    MUT_SCORE=unproven
    return 0
}

# _mut_score — the verdict as an EXIT CODE, because a pool worker is a subshell
# and an incremented counter in there is discarded at the closing paren.
_mut_score() {
    rm -rf "$W_DIR"
    [ "$MUT_SCORE" = proven ]
}
# If this trap never runs, a directory under TMPDIR survives. Nothing else.
trap 'rm -rf "$MUT_SANDBOX_DIR"' EXIT

PROVEN=0; UNPROVEN=0

check() { # <id> <desc> <expected-red-case-substrings...>
    local id="$1" desc="$2"; shift 2
    local out rc missing="" want prered=""
    # BASELINE SUBTRACTION — see M0. A case already red before any mutation
    # cannot have been turned red BY a mutation, so a mutant naming it would be
    # scoring off somebody else's failure.
    for want in "$@"; do
        grep -qE "^${want}" "$BASELINE_FAILS" 2>/dev/null && prered="$prered ${want}"
    done
    if [ -n "$prered" ]; then
        printf 'UNPROVEN  %-4s %s  <- case(s) ALREADY RED before any mutation, so this mutant proves nothing about them:%s\n' \
            "$id" "$desc" "$prered"
        MUT_SCORE=unproven; return
    fi
    out="$("$SUITE" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'UNPROVEN  %-4s %s  <- suite still GREEN\n' "$id" "$desc"
        MUT_SCORE=unproven; return
    fi
    for want in "$@"; do
        printf '%s' "$out" | grep -qE "^  FAIL  ${want}" || missing="$missing $want"
    done
    if [ -z "$missing" ]; then
        printf 'PROVEN    %-4s %s ... turns%s red\n' "$id" "$desc" "$(printf ' %s' "$@")"
        MUT_SCORE=proven
    else
        printf 'UNPROVEN  %-4s %s  <- red but NOT at:%s\n' "$id" "$desc" "$missing"
        printf '%s\n' "$out" | grep '^  FAIL' | sed 's/^/            /'
        MUT_SCORE=unproven
    fi
}

applied() { # <id> <desc> ; returns 1 if the file did not change
    local id="$1" desc="$2"
    local after; after="$(md5 -q "$GUARD" 2>/dev/null || md5sum "$GUARD" | cut -d' ' -f1)"
    if [ "$after" = "$BASE_MD5" ]; then
        printf 'UNPROVEN  %-4s %s  <- MUTATION DID NOT APPLY\n' "$id" "$desc"
        MUT_SCORE=unproven; return 1
    fi
    return 0
}

BASE_MD5="$(md5 -q "$GUARD" 2>/dev/null || md5sum "$GUARD" | cut -d' ' -f1)"

echo "=== guard-worktree-removal mutation harness ==="

# --- M0 (THE BASELINE). Every mutant below reasons "the suite went red at the
# named case, so the property is load-bearing" — an inference that needs the
# named case to have been GREEN first, which nothing here used to check. A
# sandbox missing a dependency, OR a pre-existing regression anywhere in this
# suite, turns cases red for reasons unrelated to any mutation, and each
# affected mutant then scores PROVEN while proving nothing.
#
# The baseline is RECORDED, not required: `check` refuses to score a mutant
# whose case is already in this set, so a red baseline costs exactly the
# mutants it actually invalidates instead of aborting the run and reporting
# somebody else's regression as this harness being broken.
BASELINE_FAILS="$MUT_SANDBOX_DIR/baseline-fails.txt"
M0_OUT="$("$SUITE" 2>&1)"; M0_RC=$?
printf '%s\n' "$M0_OUT" | grep '^  FAIL  ' | sed 's/^  FAIL  //' > "$BASELINE_FAILS"
if [ "$M0_RC" -eq 0 ]; then
    printf 'PROVEN    %-4s %s\n' "M0" "the UNMUTATED sandbox suite is GREEN — every red below is a mutation's doing, not the sandbox's"
    PROVEN=$((PROVEN+1))
else
    printf 'NOTE      %-4s the UNMUTATED sandbox suite is already RED (rc=%s) at %s case(s) BEFORE any mutation;\n' \
        "M0" "$M0_RC" "$(grep -c . "$BASELINE_FAILS")"
    printf '               no mutant below may score itself on these:\n'
    sed 's/^/                 /' "$BASELINE_FAILS"
fi

# --- M1: the WHOLE rule-4 rewrite reverted to the pre-move co-occurrence form.
# This is the code that actually shipped in the entity before the move: `\brm\b`
# anywhere, `-r` anywhere, and a path that is `.claude/worktrees/agent-*` or
# merely NAMED `*-wt`, all matched against the whole command line rather than
# one verb's own arguments.
_mutant_M1() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
python3 - "$GUARD" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
start = s.index("RM_CLAUSE = re.compile(")
end = s.index("# 5) Nobody starts a session in its own workspace")
old = '''def collect_rm(text):
  if re.search(r"\\brm\\b", cmd):
    recursive = re.search(r"(?:^|\\s)-[A-Za-z]*[rR][A-Za-z]*\\b", cmd) or re.search(r"--recursive\\b", cmd)
    path_hit = re.search(r"\\.claude/worktrees/agent-\\S+", cmd) or re.search(r"\\S*-wt(?=$|/|\\s)", cmd)
    if recursive and path_hit:
        reasons.append("rm -r of a worktree path (pre-move co-occurrence rule)")

'''
open(p, "w").write(s[:start] + old + s[end:])
PY
if applied M1 "rule 4 reverted to the pre-move co-occurrence form"; then
    # NOT g7: that shape passes under BOTH versions (the pre-move heuristic never
    # matched this worktree's name), so it is a pin. g8b is the faithful
    # reproduction of the incident. d2/g7c are the OTHER direction — the pre-move
    # rule also UNDER-blocked a real worktree that is not named `*-wt`.
    check M1 "rule 4 reverted to the pre-move co-occurrence form" "g7d" "g8 " "g8b" "d2 " "g7c"
fi
    _mut_score
}
mut_pool_submit M1 _mutant_M1

# --- M1b: ONLY the git-rm exclusion removed (clause scoping + structural test
# both kept). Isolates what that one line buys on its own.
_mutant_M1b() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
perl -0pi -e 's/    before = text\[:m\.start\(\)\]\.rstrip\(\)\n    if before\.split\(\)\[-1:\] == \["git"\]:\n        continue[^\n]*\n/    pass\n/' "$GUARD"
if applied M1b "the git-rm exclusion alone is removed"; then
    check M1b "the git-rm exclusion alone is removed" "g7d"
fi
    _mut_score
}
mut_pool_submit M1b _mutant_M1b

# --- M2: the structural linked-worktree test becomes the old `*-wt` string match.
_mutant_M2() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
perl -0pi -e 's/^def workspace_kind\(p\):\n/def workspace_kind(p):\n    if re.search(r"-wt(?:\/|\$)", p):\n        return "other"\n/m' "$GUARD"
if applied M2 "the *-wt naming heuristic comes back"; then
    check M2 "the *-wt naming heuristic comes back" "g8 "
fi
    _mut_score
}
mut_pool_submit M2 _mutant_M2

# --- M3: the structural test is gutted to "everything is a worktree" (the
# over-blocking direction — a guard that blocks everything satisfies "does it
# fire?" while being useless).
_mutant_M3() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
perl -0pi -e 's/^def workspace_kind\(p\):\n/def workspace_kind(p):\n    return "other"\n/m' "$GUARD"
if applied M3 "every rm -r target counts as a worktree"; then
    check M3 "every rm -r target counts as a worktree" "g4 "
fi
    _mut_score
}
mut_pool_submit M3 _mutant_M3

# --- M4: the structural test always says NO (the under-blocking direction).
_mutant_M4() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
perl -0pi -e 's/^def workspace_kind\(p\):\n/def workspace_kind(p):\n    return ""\n/m' "$GUARD"
if applied M4 "no rm -r target ever counts as a worktree"; then
    check M4 "no rm -r target ever counts as a worktree" "d2 " "S2 "
fi
    _mut_score
}
mut_pool_submit M4 _mutant_M4

# --- M5: the fix's clause scoping is reverted -- the git argument run stops at
# a newline instead of at a statement separator, so a later, unrelated command
# lends this one its flags again. This is the 2026-09-02 defect in one edit.
#
# It goes red in BOTH directions at once, which is worth stating because it was
# not obvious before the harness said it: RO2 starts false-firing (the `ls -d`
# is read as the branch rule's delete flag again), AND RD3/RD4/RD5 stop firing
# at all (the first verb on the line is read-only, it now owns the whole line,
# and the destructive verb behind it is never classified). One edit, a false
# positive and a false negative. Only RO2 and RD3 are asserted; the other two
# ride along and are left unasserted so this check keeps naming the minimum.
_mutant_M5() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
perl -0pi -e 's/\(\?P<args>\[\^\\n;\|&\)\]\*\)/(?P<args>[^\\n]*)/' "$GUARD"
if applied M5 "the git argument run bleeds across statement separators"; then
    check M5 "the git argument run bleeds across statement separators" "RO2" "RD3"
fi
    _mut_score
}
mut_pool_submit M5 _mutant_M5

# --- M6: the OTHER direction. The read-only allowlist is made to swallow the
# two destructive subcommands, which silences every false positive by silencing
# the guard. A suite that only asserted the RO half would call this green.
_mutant_M6() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
perl -0pi -e 's/    "whatchanged",/    "whatchanged", "worktree", "branch",/' "$GUARD"
if applied M6 "the read-only allowlist swallows worktree and branch"; then
    check M6 "the read-only allowlist swallows worktree and branch" "a  " "b  " "c  "
fi
    _mut_score
}
mut_pool_submit M6 _mutant_M6

# --- M7: git's value-taking global options stop being skipped, so `git -C
# <repo> worktree remove` reads the REPO PATH as its subcommand and finds no
# rule. The cross-repo removal is exactly the shape an operator sweep uses.
_mutant_M7() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
perl -0pi -e 's/    "-C", "-c", "--git-dir",/    "-c", "--git-dir",/' "$GUARD"
if applied M7 "git -C's value is no longer skipped when finding the subcommand"; then
    check M7 "git -C's value is no longer skipped when finding the subcommand" "a2 "
fi
    _mut_score
}
mut_pool_submit M7 _mutant_M7

# --- M8: the executable-text extraction is removed, so PROSE IS A COMMAND
# again. This is the 2026-09-03/04 defect in one edit: the classifier reads the
# whole Bash call as one string, and a commit message or a heredoc payload that
# QUOTES a removal is refused as though it performed one.
_mutant_M8() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
perl -0pi -e 's/^scan = executable_text\(cmd\)$/scan = cmd/m' "$GUARD"
# NOT PR1, and the reason is worth recording rather than hiding behind a case
# id that happens to be red. A SINGLE-LINE `git commit -m "... git worktree
# remove ..."` was never refused by the shipped guard: the outer invocation's
# argument run stops only at a statement separator, so the inner `git` sits
# inside the outer match and finditer never looks at it again. It is the
# MULTI-LINE form (PR2) that fired, because a newline ends the run and the
# second line reads as its own invocation -- which is exactly the shape a commit
# message in this project has. PR1 is a pin, PR2 is the reproduction.
if applied M8 "prose and payloads are scanned as if they were commands"; then
    check M8 "prose and payloads are scanned as if they were commands" "PR2" "PR5"
fi
    _mut_score
}
mut_pool_submit M8 _mutant_M8

# --- M9: the OTHER direction, and it is the one a blanking fix invites. The
# second pass over command substitutions is deleted, so text the shell WILL
# execute stops being classified -- `-m "$(git worktree remove <wt>)"` becomes a
# way to launder a removal through a message. A suite that only asserted the PR
# half would call this green.
_mutant_M9() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
perl -0pi -e 's/^for _sub in _SUBST\.finditer\(scan\):\n    collect_git\(_sub\.group\(0\)\)\n    collect_rm\(_sub\.group\(0\)\)$/for _sub in []:\n    pass/m' "$GUARD"
# PX3 alone. PX4's substitution sits at the start of its own heredoc line with
# no enclosing git invocation, so the FIRST pass already reaches it; only PX3 --
# a substitution nested inside another git command's argument run -- depends on
# the second pass. Asserting PX4 here would be asserting something this mutant
# does not remove.
if applied M9 "substitutions inside inert text stop being classified"; then
    check M9 "substitutions inside inert text stop being classified" "PX3"
fi
    _mut_score
}
mut_pool_submit M9 _mutant_M9

# --- M10: restore the old assumption that default prune preserves Git metadata.
_mutant_M10() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
python3 - "$GUARD" <<'PY_MUTANT'
from pathlib import Path
import sys
path=Path(sys.argv[1]);source=path.read_text()
old='        elif sub2 == "prune":'
assert source.count(old)==1
path.write_text(source.replace(old, '        elif sub2 == "prune" and any(t.startswith("--expire") for t in rest):'))
PY_MUTANT
if applied M10 "plain and dry-run-overridden prune regain a direct bypass"; then
    check M10 "plain and dry-run-overridden prune regain a direct bypass" "g2 " "b3 "
fi
    _mut_score
}
mut_pool_submit M10 _mutant_M10

# --- M11: a workspaces.sh invocation cannot exempt a separate raw removal.
_mutant_M11() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
python3 - "$GUARD" <<'PY_MUTANT'
from pathlib import Path
import sys
path=Path(sys.argv[1]);source=path.read_text()
old='if helper and not reasons:'
assert source.count(old)==1
path.write_text(source.replace(old,'if helper:'))
PY_MUTANT
if applied M11 "a workspaces.sh call exempts a separate raw removal"; then
    check M11 "a workspaces.sh call exempts a separate raw removal" "b9 "
fi
    _mut_score
}
mut_pool_submit M11 _mutant_M11

# === THE SPEC'S OWN REFUSALS (docs/plans/worktree-spec-2026-09-11.md) =======
# Each of these is a refusal with NO override. The mutants below take one away
# and name the case that notices: the ack-carrying S* cases, because a mutant
# that merely demotes SPEC to BLOCK is still exit 2 without an ack.

# --- M12: an agent's workspace (cc/, worktree-*) reads as an ordinary linked
# worktree, so a worktree-remove-ack deletes it by hand (points 4, 7, 10).
_mutant_M12() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
python3 - "$GUARD" <<'PY_MUTANT'
from pathlib import Path
import sys
path=Path(sys.argv[1]);source=path.read_text()
old='''        return "system"'''
assert source.count(old)==1
path.write_text(source.replace(old,'''        return "other"'''))
PY_MUTANT
if applied M12 "an agent workspace is removable with an ack"; then
    check M12 "an agent workspace is removable with an ack" "S2 " "S3 " "S4 "
fi
    _mut_score
}
mut_pool_submit M12 _mutant_M12

# --- M13: a codex/ workspace is no longer recognized, so an ack removes it (point 2).
_mutant_M13() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
python3 - "$GUARD" <<'PY_MUTANT'
from pathlib import Path
import sys
path=Path(sys.argv[1]);source=path.read_text()
old='''    if br.startswith("codex/"):
        return "codex"
'''
assert source.count(old)==1
path.write_text(source.replace(old,''))
PY_MUTANT
if applied M13 "a codex/ workspace is removable with an ack"; then
    check M13 "a codex/ workspace is removable with an ack" "S6 "
fi
    _mut_score
}
mut_pool_submit M13 _mutant_M13

# --- M14: a codex/ branch delete stops being refused (point 2).
_mutant_M14() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
python3 - "$GUARD" <<'PY_MUTANT'
from pathlib import Path
import sys
path=Path(sys.argv[1]);source=path.read_text()
old='''        if deletes and any(re.search(r"(?:^|refs/heads/)codex/\S+", t) for t in rest):'''
assert source.count(old)==1
path.write_text(source.replace(old,'''        if False:'''))
PY_MUTANT
if applied M14 "a codex/ branch may be deleted"; then
    check M14 "a codex/ branch may be deleted" "S7 "
fi
    _mut_score
}
mut_pool_submit M14 _mutant_M14

# --- M15: a raw git worktree add is no longer refused (points 1, 3).
_mutant_M15() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
python3 - "$GUARD" <<'PY_MUTANT'
from pathlib import Path
import sys
path=Path(sys.argv[1]);source=path.read_text()
old='''        elif sub2 == "add":'''
assert source.count(old)==1
path.write_text(source.replace(old,'''        elif sub2 == "add" and False:'''))
PY_MUTANT
if applied M15 "a raw git worktree add is allowed"; then
    check M15 "a raw git worktree add is allowed" "RO11" "S9 "
fi
    _mut_score
}
mut_pool_submit M15 _mutant_M15

# --- M16: claude --worktree is no longer refused (point 3).
_mutant_M16() {
    local ENG GUARD SUITE W_DIR MUT_SCORE
    _mut_worker_sandbox || return 1
python3 - "$GUARD" <<'PY_MUTANT'
from pathlib import Path
import sys
path=Path(sys.argv[1]);source=path.read_text()
old='''if CLAUDE_WT.search(scan):'''
assert source.count(old)==1
path.write_text(source.replace(old,'''if False:'''))
PY_MUTANT
if applied M16 "claude --worktree is allowed"; then
    check M16 "claude --worktree is allowed" "S8 "
fi
    _mut_score
}
mut_pool_submit M16 _mutant_M16

# (the `restore` that used to sit here reset the SHARED sandbox before M99.
#  There is no shared mutated state any more: each mutant had its own copy.)
# --- the mutant verdicts, drained ------------------------------------------
# ADDITIVE: M0 above already scored, and M99 below still will. A worker that left
# no exit code counts as UNPROVEN rather than vanishing from the tally.
mut_pool_drain
# A harness that declared mutants and ran NONE must not exit 0.
mut_pool_require_submissions "$(basename "$0")"
PROVEN=$(( PROVEN + MUT_POOL_PASS ))
UNPROVEN=$(( UNPROVEN + MUT_POOL_FAIL ))
mut_pool_report_line "$(( $(sw_now_ms) - MUT_WALL_T0 ))"
mut_pool_cleanup
echo ""

# --- M99: THE SHIPPED GUARD WAS NEVER OPENED FOR WRITING. Contents AND mtime,
# because "restored correctly" and "never touched" are different guarantees and
# only the second one survives a kill between the two writes. This harness
# previously asserted neither.
SHIPPED_AFTER="$(tw_file_witness "$SHIPPED_GUARD")"
if [ "$SHIPPED_AFTER" != "$SHIPPED_BEFORE" ]; then
    echo "UNPROVEN  M99  THE SHIPPED GUARD WAS WRITTEN TO." >&2
    echo "            before: $SHIPPED_BEFORE" >&2
    echo "            after:  $SHIPPED_AFTER" >&2
    echo "            $SHIPPED_GUARD" >&2
    UNPROVEN=$((UNPROVEN+1))
elif tw_mtime_available; then
    printf 'PROVEN    %-4s %s\n' "M99" "the shipped guard was never opened for writing (contents AND mtime unchanged)"
    PROVEN=$((PROVEN+1))
else
    printf 'PROVEN    %-4s %s\n' "M99" "the shipped guard's CONTENTS are unchanged. No sub-second mtime format proved itself here, so this run cannot distinguish 'never touched' from 'written and restored' — named rather than assumed"
    PROVEN=$((PROVEN+1))
fi

# NEVER TOUCHED, not PUT BACK. This used to assert the shared sandbox guard had
# been RESTORED to its pristine bytes, which a mutate-and-restore harness
# satisfies while the whole risk lives in the interval between those two writes —
# and two mutants running at once would each be inside the other's interval.
# Every mutant now works in a copy of its own, so the reference sandbox is built
# once, read by M0, and never opened for writing at all.
FINAL_MD5="$(md5 -q "$GUARD" 2>/dev/null || md5sum "$GUARD" | cut -d' ' -f1)"
if [ "$FINAL_MD5" != "$BASE_MD5" ]; then
    echo "ERROR: the REFERENCE sandbox guard changed during the run (md5 $FINAL_MD5 != $BASE_MD5)." >&2
    echo "       Each mutant builds its own copy and mutates that; a change here means something" >&2
    echo "       mutated the shared reference, so M0's baseline no longer describes what the" >&2
    echo "       mutants ran against and every verdict above is suspect." >&2
    exit 1
fi
echo "reference sandbox guard never written to (md5 $FINAL_MD5); every mutant used its own copy"

if [ "$UNPROVEN" -gt 0 ]; then
    echo "=== mutation harness: $UNPROVEN UNPROVEN, $PROVEN proven ==="
    exit 1
fi
echo "=== mutation harness: all $PROVEN mutants proven load-bearing ==="
