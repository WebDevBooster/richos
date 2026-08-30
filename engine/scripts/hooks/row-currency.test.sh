#!/usr/bin/env bash
#
# row-currency.test.sh — regression tests for the row-currency contract:
# scripts/lib/row-currency.sh, scripts/lib/row-currency.py, the CLI
# scripts/row-currency-lint.sh, and the guard that runs them at every landing
# (scripts/hooks/guard-row-currency-commits.sh).
#
# ONE suite for all four files on purpose: they are one subject — a predicate
# and its chokepoint — and splitting them would create several places to
# remember to update, which is the defect class the mechanism exists to remove.
#
# ===========================================================================
# EVERYTHING HERE RUNS ON INVENTED FIXTURES
# ===========================================================================
# The record this was built for lives in a separate PRIVATE repository that a
# CI runner cannot see and must never be given. So CI proves the PREDICATE
# against synthetic records, and the real record is checked locally, at every
# landing, by the guard. The four real 2026-08-29 cases are replayed against
# real history by a script in that private repository; the SHAPE of each one is
# covered here, so a CI runner still fails if any of them stops being caught.
#
# The trap that creates is closed by name: there is no case here that is
# skipped when something is missing. "Nothing to check" is asserted as its own
# distinguishable outcome and can never be mistaken for a pass.
#
# Covers:
#   (a) STAND-DOWN — the precision floor. An undeclared repository, a non-
#       commit Bash command, a non-Bash payload and a LINKED WORKTREE are all
#       untouched. Get any of these wrong and the guard fires on every
#       engineer, every hour, and is switched off by lunchtime.
#   (b) THE FOUR REAL SHAPES — work created under a row stamped absent; work
#       modified under a row stamped at the old id; a directory tree moving;
#       and a claim in the message with no row change. All refused, by item id.
#   (c) THE FIX — re-stamping the row lets the same landing through, and the
#       refusal printed the exact warrant that does it.
#   (d) NO SILENT NO-OP — a governed row with no warrant, a bad status token, a
#       missing section, an unwarranted status with no stamp and a vanished
#       record are all loud.
#   (e) TERMINAL — a CLOSED row is exempt from the pin AND named in a NOTE on
#       every run, including a clean one.
#   (f) PRECISION OF THE CLAIM CHECK — a version number, a path, a quoted prior
#       message, a phase label, a pipeline stage and an ordinary unrelated
#       message all pass untouched.
#   (g) CROSS-REPOSITORY — a peer repository is checked against the record next
#       door; a peer whose record is NOT on this machine stands down LOUDLY and
#       blocks nothing; a peer the record does not name back is BROKEN.
#   (h) THE MERGE — `git merge` is gated, and against the tree the merge will
#       actually produce rather than the branch tip.
#   (i) NO OVERRIDE — an escape token in the prompt does not exist and does not
#       work.
#   (j) FAIL-CLOSED conventions, matching the hook family.
#   (k) REGISTRATION on both surfaces, plus the probe's oracle and Layer R.
#
# Run directly: scripts/hooks/row-currency.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Declare the root under test: run from a session seated elsewhere the guard
# would resolve THAT repository, find no adoption marker, stand down, and every
# case below would pass by never running.
RICHOS_ENTITY_ROOT="$ENGINE_ROOT"
export RICHOS_ENTITY_ROOT
unset CLAUDE_PROJECT_DIR

GUARD="$SCRIPT_DIR/guard-row-currency-commits.sh"
LINT="$ENGINE_ROOT/scripts/row-currency-lint.sh"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
SCRATCH="$(mktemp -d -t rctest.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$GUARD" "$LINT" "$ENGINE_ROOT/scripts/lib/row-currency.sh" \
         "$ENGINE_ROOT/scripts/lib/row-currency.py"; do
    [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-rc test}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-rc test}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-t@t}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-t@t}"
# THROWAWAY REPOSITORIES MUST NOT RUN THE OPERATOR'S GLOBAL HOOKS. This machine
# sets core.hooksPath globally to an identity guard, which rejected every
# fixture commit because the suite commits under an invented author. The result
# was not a red suite: it was fixtures with no HEAD, warrants with no stamp, and
# thirteen cases failing for a reason that had nothing to do with what they
# test. Pinned through the environment so it reaches every git invocation here,
# including the guard's own.
mkdir -p "$SCRATCH/nohooks"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$SCRATCH/nohooks"

# ---------------------------------------------------------------------------
# Fixtures. Two repositories, because the real relationship is two
# repositories and a suite that only ever tested one would prove the easy half.
#
#   <name>-record   owns wiki/open-items.md, .ceo-todos and .row-currency
#   <name>-work     owns the work, and a peer .row-currency pointing next door
# ---------------------------------------------------------------------------
# A fixture helper that returned "" would produce a warrant with no stamp, and
# every case using it would then fail for a reason that has nothing to do with
# what it is testing. So it dies instead.
oid_of() {
    local v
    v="$(git -C "$1" rev-parse --verify --quiet "HEAD:$2" 2>&1)"
    case "$v" in
        [0-9a-f]*) printf '%s' "$v" | cut -c1-12 ;;
        *) echo "FATAL: fixture could not identify $2 in $1: [$v]" >&2; exit 1 ;;
    esac
}

mk_pair() {
    # mk_pair <name> -> prints "<record-repo> <work-repo>"
    local name="$1" rec="$SCRATCH/$1/record" work="$SCRATCH/$1/work"
    mkdir -p "$rec/wiki" "$rec/docs" "$work/lib" "$work/tree/inner"
    git -C "$rec" init -q
    git -C "$work" init -q

    printf '# A record repo\n\nStart at [CEO-TODOs.md](CEO-TODOs.md).\n' > "$rec/README.md"
    printf 'a note about the work\n' > "$rec/docs/note.md"
    {
        echo 'TODO_RECORD="wiki/open-items.md"'
        echo 'TODO_VIEW="CEO-TODOs.md"'
        echo 'ROOT_README="README.md"'
        echo 'CEO_SECTIONS="1 2"'
        echo 'PREPARER_SECTION="3"'
        echo "ARTIFACT_ROOTS=\"rec=. work=../../$1/work nowhere=../no-such-sibling\""
    } > "$rec/.ceo-todos"
    {
        echo 'ROW_SECTIONS="3"'
        echo 'ROW_STATUS_TOKENS="OPEN BUILT CLOSED"'
        echo 'ROW_TERMINAL_TOKENS="CLOSED"'
    } > "$rec/.row-currency"

    printf 'the shipped thing\n' > "$work/lib/thing.js"
    printf 'one\n' > "$work/tree/inner/a.txt"
    printf 'ROW_RECORD_REPO="../../%s/record"\n' "$1" > "$work/.row-currency"

    git -C "$work" add -A >/dev/null 2>&1
    git -C "$work" commit -qm "work: the starting point" >/dev/null 2>&1
    git -C "$rec" add -A >/dev/null 2>&1
    git -C "$rec" commit -qm "record: the starting point" >/dev/null 2>&1
    printf '%s %s' "$rec" "$work"
}

# write_record <record-repo> <section-3-rows...>  (each row a full '| ... |' line)
write_record() {
    local rec="$1"; shift
    {
        printf '# Open items\n\n'
        printf '## 1. Waiting on the CEO — a decision\n\n_Nothing._\n\n'
        printf '## 2. Waiting on the CEO — his hands\n\n_Nothing._\n\n'
        printf '## 3. Buildable now — nobody blocked\n\n'
        printf '| # | Item | State |\n|---|---|---|\n'
        local r
        for r in "$@"; do printf '%s\n' "$r"; done
        printf '\n## Deliberately NOT open\n\nnothing\n'
    } > "$rec/wiki/open-items.md"
}

commit_record() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm "${2:-record}" >/dev/null 2>&1; }

payload() {
    # payload <cwd> <command>
    printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$1" "$2"
}

run_guard() {
    # run_guard <cwd> <command> -> GRC, GOUT
    GOUT="$(payload "$1" "$2" | "$BASH_BIN" "$GUARD" 2>&1 >/dev/null)"
    GRC=$?
    return 0
}

run_lint() {
    LOUT="$("$BASH_BIN" "$LINT" "$@" 2>&1)"
    LRC=$?
    return 0
}

echo "=== row currency: the predicate, the CLI and the landing guard ==="

# ---------------------------------------------------------------------------
# (a) STAND-DOWN — the precision floor
# ---------------------------------------------------------------------------
set -- $(mk_pair standdown); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | a row with no warrant at all | |'
commit_record "$REC"
rm -f "$REC/.row-currency" "$WORK/.row-currency"
run_guard "$REC" 'git commit -m \"anything\"'
if [ "$GRC" -eq 0 ]; then
    ok "a repository with no declaration is untouched, however bad its rows"
else
    bad "stand-down failed: fired in an undeclared repository (rc=$GRC): $GOUT"
fi

set -- $(mk_pair notacommit); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | a row with no warrant at all | |'
commit_record "$REC"
run_guard "$REC" 'git status --short'
[ "$GRC" -eq 0 ] && ok "a Bash command that is not a commit or merge passes untouched" \
                 || bad "non-commit Bash should pass (rc=$GRC)"

run_guard "$REC" 'echo \"git commit -m x\"'
[ "$GRC" -eq 0 ] && ok "the words 'git commit' inside an echo are not a commit" \
                 || bad "an echoed commit string should pass (rc=$GRC): $GOUT"

GOUT="$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"y"}}' | "$BASH_BIN" "$GUARD" 2>&1 >/dev/null)"; GRC=$?
[ "$GRC" -eq 0 ] && ok "a non-Bash tool payload passes untouched" \
                 || bad "non-Bash payload should pass (rc=$GRC)"

run_guard "$REC" 'git commit --dry-run'
[ "$GRC" -eq 0 ] && ok "--dry-run creates no commit and is not gated" \
                 || bad "--dry-run should pass (rc=$GRC)"

# A LINKED WORKTREE. The single most important precision case in this file:
# every engineer works in one, and a guard that fires there is a guard that is
# switched off the same day.
git -C "$REC" worktree add -q "$SCRATCH/notacommit/wt" -b side >/dev/null 2>&1
# Asserted, not assumed: if the worktree were not there the case below would
# pass by testing nothing, which is the failure mode this whole engine keeps
# finding in its own checks.
[ -e "$SCRATCH/notacommit/wt/.git" ] || bad "fixture: the linked worktree was not created"
run_guard "$SCRATCH/notacommit/wt" 'git commit -m \"engineer work\"'
if [ "$GRC" -eq 0 ]; then
    ok "a commit in a LINKED WORKTREE is untouched — a proposal is not a landing"
else
    bad "worktree commits must not be gated (rc=$GRC): $GOUT"
fi

# ---------------------------------------------------------------------------
# (b) THE FOUR REAL SHAPES
# ---------------------------------------------------------------------------
# 1. work CREATED under a row stamped absent  (2026-08-29 items 3.4, 3.6, 3.12)
set -- $(mk_pair created); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | the flywheel is unbuilt at both ends | **State:** `OPEN` — `work/lib/new.js`@`-` |'
commit_record "$REC"
printf 'the work that just landed\n' > "$WORK/lib/new.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"feat: the loop turns\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'item 3.1' \
   && printf '%s' "$GOUT" | grep -q 'ROW-STALE'; then
    ok "work CREATED under a row stamped absent is refused, naming the item"
else
    bad "created-work case not refused (rc=$GRC): $GOUT"
fi
if printf '%s' "$GOUT" | grep -q 'PASTE  item 3.1'; then
    ok "the refusal prints the warrant the row should now carry"
else
    bad "no PASTE line in the refusal: $GOUT"
fi

# 2. work MODIFIED under a row stamped at the old id  (2026-08-29 item 3.7)
set -- $(mk_pair modified); REC="$1"; WORK="$2"
OLD="$(oid_of "$WORK" lib/thing.js)"
write_record "$REC" "| 3.1 | the canceller is still open | **State:** \`OPEN\` — \`work/lib/thing.js\`@\`$OLD\` |"
commit_record "$REC"
printf 'the shipped thing, now with a canceller\n' > "$WORK/lib/thing.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"voice: a real canceller\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-STALE'; then
    ok "work MODIFIED under a row stamped at the old id is refused"
else
    bad "modified-work case not refused (rc=$GRC): $GOUT"
fi

# 3. a DIRECTORY tree moving (the shape item 3.7 really had)
set -- $(mk_pair treecase); REC="$1"; WORK="$2"
OLD="$(oid_of "$WORK" tree)"
write_record "$REC" "| 3.1 | the crate as it was | **State:** \`OPEN\` — \`work/tree/\`@\`$OLD\` |"
commit_record "$REC"
printf 'two\n' > "$WORK/tree/inner/b.txt"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"voice: another file in the crate\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-STALE'; then
    ok "a DIRECTORY stamp moves when any file under it changes"
else
    bad "directory-tree case not refused (rc=$GRC): $GOUT"
fi

# 4. a CLAIM in the message with no row change  (2026-08-29 item 3.12)
set -- $(mk_pair claimcase); REC="$1"; WORK="$2"
OLD="$(oid_of "$WORK" lib/thing.js)"
write_record "$REC" "| 3.1 | untouched by this landing | **State:** \`OPEN\` — \`work/lib/thing.js\`@\`$OLD\` |"
commit_record "$REC"
printf 'unrelated\n' > "$WORK/lib/other.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"Item 3.1 engineering half. Nothing it points at moved.\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'CLAIM-UNANSWERED'; then
    ok "a message that NAMES an item whose row did not change is refused"
else
    bad "claim case not refused (rc=$GRC): $GOUT"
fi

# ---------------------------------------------------------------------------
# (c) THE FIX — and it is exactly what the refusal printed
# ---------------------------------------------------------------------------
set -- $(mk_pair fixed); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | unbuilt | **State:** `OPEN` — `work/lib/new.js`@`-` |'
commit_record "$REC"
printf 'the work that just landed\n' > "$WORK/lib/new.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"feat: it landed\"'
NEWOID="$(printf '%s' "$GOUT" | sed -n 's/.*`work\/lib\/new.js`@`\([0-9a-f]*\)`.*/\1/p' | head -1)"
if [ -n "$NEWOID" ]; then
    write_record "$REC" "| 3.1 | BUILT, and here is what it is | **State:** \`BUILT\` — \`work/lib/new.js\`@\`$NEWOID\` |"
    commit_record "$REC" "record: 3.1 is built"
    run_guard "$WORK" 'git commit -m \"feat: it landed\"'
    [ "$GRC" -eq 0 ] && ok "re-stamping the row with the printed warrant lets the same landing through" \
                     || bad "the printed warrant did not clear the refusal (rc=$GRC): $GOUT"
else
    bad "could not read a replacement object id out of the refusal"
fi

# ---------------------------------------------------------------------------
# (d) NO SILENT NO-OP
# ---------------------------------------------------------------------------
set -- $(mk_pair loud); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | a governed row with no warrant | |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-UNWARRANTED' \
    && ok "a governed row with NO warrant is refused, not ignored" \
    || bad "unwarranted row should block (rc=$GRC): $GOUT"

write_record "$REC" '| 3.1 | a row with a made-up status | **State:** `SORTOF` — `rec/docs/note.md`@`-` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-BAD-STATUS' \
    && ok "a status token outside the declared vocabulary is refused" \
    || bad "bad status should block (rc=$GRC): $GOUT"

write_record "$REC" '| 3.1 | open work pinned to nothing | **State:** `OPEN` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-NO-STAMP' \
    && ok "open work with no stamp is refused — a row pointing at nothing cannot go stale" \
    || bad "unstamped open row should block (rc=$GRC): $GOUT"

write_record "$REC" '| 3.1 | pinned into a repository nobody declared | **State:** `OPEN` — `elsewhere/x.md`@`abcdef123456` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-UNKNOWN-PREFIX' \
    && ok "a stamp under an undeclared artifact root is refused" \
    || bad "unknown prefix should block (rc=$GRC): $GOUT"

# A declared root that is NOT on this machine: SKIPPED and NAMED, never blocked
# and never invisible.
write_record "$REC" '| 3.1 | work in a sibling nobody cloned | **State:** `OPEN` — `nowhere/x.md`@`abcdef123456` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
if [ "$GRC" -eq 0 ] && printf '%s' "$GOUT" | grep -q 'NOT CHECKED'; then
    ok "an artifact root that is not on this machine is SKIPPED and named, never blocked"
else
    bad "absent root should skip loudly (rc=$GRC): $GOUT"
fi

# The declared section does not exist -> BROKEN, never a clean lint over nothing.
set -- $(mk_pair nosection); REC="$1"; WORK="$2"
printf '# Open items\n\n## 1. A section\n\nnothing\n' > "$REC/wiki/open-items.md"
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'BROKEN' \
    && ok "a declared row section that does not exist is BROKEN, not a clean run" \
    || bad "missing section should be broken (rc=$GRC): $GOUT"

# The record itself is gone -> loud, never a quiet pass.
set -- $(mk_pair norecord); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | x | **State:** `CLOSED` |'
commit_record "$REC"
rm -f "$REC/wiki/open-items.md"
run_guard "$REC" 'git commit -am \"delete the record\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'NOT ON DISK' \
    && ok "a vanished record is a LOUD refusal — a guard with no subject protects nothing" \
    || bad "missing record should block loudly (rc=$GRC): $GOUT"

# A table row in a governed section with no id in its first cell.
set -- $(mk_pair unident); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | fine | **State:** `CLOSED` |' '| later | a row nobody can name | |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-UNIDENTIFIED' \
    && ok "a governed table row carrying no item id is refused, not skipped" \
    || bad "unidentified row should block (rc=$GRC): $GOUT"

# ---------------------------------------------------------------------------
# (e) TERMINAL — exempt from the pin, named on every run
# ---------------------------------------------------------------------------
set -- $(mk_pair terminal); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | this closed | **State:** `CLOSED` — `work/lib/thing.js` |'
commit_record "$REC"
printf 'changed after the item closed\n' > "$WORK/lib/thing.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work moves on\"'
if [ "$GRC" -eq 0 ] && printf '%s' "$GOUT" | grep -q 'ROW-TERMINAL-STILL-LISTED'; then
    ok "a CLOSED row is exempt from the pin AND named in a NOTE on a clean run"
else
    bad "terminal row handling wrong (rc=$GRC): $GOUT"
fi

# ---------------------------------------------------------------------------
# (f) PRECISION OF THE CLAIM CHECK
# ---------------------------------------------------------------------------
# Every message below names something that LOOKS like item 3.4 and is not. Each
# one is a real shape taken from the history of the repositories this governs.
set -- $(mk_pair precision); REC="$1"; WORK="$2"
OLD="$(oid_of "$WORK" lib/thing.js)"
write_record "$REC" "| 3.4 | open, and untouched by any of these | **State:** \`OPEN\` — \`work/lib/thing.js\`@\`$OLD\` |"
commit_record "$REC"
printf 'unrelated\n' > "$WORK/lib/unrelated.js"
git -C "$WORK" add -A >/dev/null 2>&1

precise() {
    # precise <label> <commit message>
    run_guard "$WORK" "git commit -m \\\"$2\\\""
    if [ "$GRC" -eq 0 ]; then
        ok "precision: $1"
    else
        bad "precision FAILED — $1 was refused (rc=$GRC): $GOUT"
    fi
}
precise "a version number (1.3.4) is not item 3.4" 'chore: bump the toolchain to 1.3.4'
precise "a path containing 3.4 is not item 3.4"    'docs: move the notes to docs/3.4/readme.md'
precise "a quoted prior commit message is inert"   'revert: undo \\\"wiki: rows were lying - 3.4 and 3.12\\\"'
precise "a phase label (P3.4) is not item 3.4"     'feat: P3.4 turn-boundary rotation'
precise "a pipeline stage is not an item"          'feat(pipeline): stage 3.4 now removes as well as detects'
precise "a measurement is not an item"             'measure: WER 3.4 percent against the reference'
precise "an ordinary unrelated message passes"     'chore: tidy the build script and drop a dead flag'
precise "a backticked id is code, not a claim"     'docs: the parser now accepts `3.4` as a literal'

# ...and the positive control, so none of the above passed for the wrong reason.
run_guard "$WORK" 'git commit -m \"open-items 3.4 is done\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'CLAIM-UNANSWERED'; then
    ok "positive control: 'open-items 3.4' IS a claim and is refused"
else
    bad "the claim check is asleep — 'open-items 3.4' passed (rc=$GRC): $GOUT"
fi

# ---------------------------------------------------------------------------
# (g) CROSS-REPOSITORY
# ---------------------------------------------------------------------------
set -- $(mk_pair peerless); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | x | **State:** `CLOSED` |'
commit_record "$REC"
printf 'ROW_RECORD_REPO="../no-such-record-repository"\n' > "$WORK/.row-currency"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work in a clone with no private sibling\"'
if [ "$GRC" -eq 0 ] && printf '%s' "$GOUT" | grep -q 'STOOD DOWN'; then
    ok "a peer whose record is not on this machine stands down LOUDLY and blocks nothing"
else
    bad "absent record must not block (rc=$GRC): $GOUT"
fi

set -- $(mk_pair drift); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | x | **State:** `CLOSED` |'
sed -i.bak 's/ work=[^ ]*//' "$REC/.ceo-todos" && rm -f "$REC/.ceo-todos.bak"
commit_record "$REC"
run_guard "$WORK" 'git commit -m \"work\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'BROKEN'; then
    ok "a peer the record does not name back is BROKEN — half a contract enforces nothing"
else
    bad "pointer/roots drift should be broken (rc=$GRC): $GOUT"
fi

set -- $(mk_pair noceotodos); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | x | **State:** `CLOSED` |'
rm -f "$REC/.ceo-todos"
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'BROKEN'; then
    ok "a record form with no .ceo-todos to read the record path from is BROKEN"
else
    bad "record form without .ceo-todos should be broken (rc=$GRC): $GOUT"
fi

# ---------------------------------------------------------------------------
# (h) THE MERGE — the moment a proposal becomes the truth
# ---------------------------------------------------------------------------
set -- $(mk_pair mergecase); REC="$1"; WORK="$2"
OLD="$(oid_of "$WORK" lib/thing.js)"
write_record "$REC" "| 3.1 | the canceller is still open | **State:** \`OPEN\` — \`work/lib/thing.js\`@\`$OLD\` |"
commit_record "$REC"
git -C "$WORK" checkout -qb feature >/dev/null 2>&1
printf 'the shipped thing, now with a canceller\n' > "$WORK/lib/thing.js"
git -C "$WORK" add -A >/dev/null 2>&1
git -C "$WORK" commit -qm "voice: a real canceller" >/dev/null 2>&1
git -C "$WORK" checkout -q master >/dev/null 2>&1 || git -C "$WORK" checkout -q main >/dev/null 2>&1
run_guard "$WORK" 'git merge --no-ff feature -m \"Merge feature: a real echo canceller\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-STALE'; then
    ok "git merge is gated, against the tree the merge will actually produce"
else
    bad "the merge was not gated (rc=$GRC): $GOUT"
fi
if printf '%s' "$GOUT" | grep -q 'REFUSING THIS MERGE'; then
    ok "the refusal names the operation it refused"
else
    bad "the merge refusal does not name itself: $GOUT"
fi

# ---------------------------------------------------------------------------
# (i) NO OVERRIDE — there is no escape token, deliberately
# ---------------------------------------------------------------------------
set -- $(mk_pair override); REC="$1"; WORK="$2"
OLD="$(oid_of "$WORK" lib/thing.js)"
write_record "$REC" "| 3.1 | still open | **State:** \`OPEN\` — \`work/lib/thing.js\`@\`$OLD\` |"
commit_record "$REC"
printf 'moved on without the row\n' > "$WORK/lib/thing.js"
git -C "$WORK" add -A >/dev/null 2>&1
# The control first: this landing IS refused with no override at all.
run_guard "$WORK" 'git commit -m \"work moved\"'
[ "$GRC" -eq 2 ] || bad "fixture: the override case is not refused to begin with (rc=$GRC)"
GOUT="$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git commit -m \\"work moved\\""},"prompt":"row-currency-override: I will fix the row after the deploy"}' "$WORK" | "$BASH_BIN" "$GUARD" 2>&1 >/dev/null)"; GRC=$?
if [ "$GRC" -eq 2 ]; then
    ok "an override token in the prompt does not exist and does not work"
else
    bad "an override appears to have been honoured (rc=$GRC)"
fi

# ---------------------------------------------------------------------------
# (j) FAIL-CLOSED conventions
# ---------------------------------------------------------------------------
FAKEBIN="$(mktemp -d -t rctest-bin.XXXXXX)"
for t in bash git grep sed cat mktemp printf head cut tail rm cp awk tr; do
    p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$FAKEBIN/$t" 2>/dev/null
done
rc=0
out="$(printf '{}' | PATH="$FAKEBIN" "$BASH_BIN" "$GUARD" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF 'python3'; then
    ok "python3 missing fails CLOSED and names the interpreter"
else
    bad "python3-missing should fail closed naming python3 (rc=$rc)"
fi
rm -rf "$FAKEBIN"

TMPENG="$(mktemp -d -t rctest-eng.XXXXXX)"
mkdir -p "$TMPENG/scripts/hooks" "$TMPENG/scripts/lib"
cp "$GUARD" "$TMPENG/scripts/hooks/"
cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" "$TMPENG/scripts/lib/"
rc=0
out="$(printf '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"git commit -m x"}}' \
       | "$BASH_BIN" "$TMPENG/scripts/hooks/guard-row-currency-commits.sh" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF "row-currency.sh is missing"; then
    ok "a missing predicate library is a LOUD refusal, never a quiet skip"
else
    bad "missing predicate library should block loudly (rc=$rc): $out"
fi
rm -rf "$TMPENG"

# The CLI distinguishes "no contract" from "clean".
set -- $(mk_pair clitest); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | x | **State:** `CLOSED` |'
commit_record "$REC"
run_lint "$REC"
[ "$LRC" -eq 0 ] && ok "the CLI exits 0 on a current record" || bad "CLI should pass (rc=$LRC): $LOUT"
rm -f "$REC/.row-currency"
run_lint "$REC"
[ "$LRC" -eq 2 ] && printf '%s' "$LOUT" | grep -q 'NO CONTRACT' \
    && ok "the CLI refuses to call 'no contract here' a clean record" \
    || bad "CLI should distinguish no-contract from clean (rc=$LRC): $LOUT"

# --explain prints the extractor's own reasoning.
set -- $(mk_pair explain); REC="$1"; WORK="$2"
write_record "$REC" '| 3.4 | x | **State:** `CLOSED` |'
commit_record "$REC"
run_lint "$REC" --explain --message 'stage 3.4 and open-items 3.4'
if printf '%s' "$LOUT" | grep -q 'rejected' && printf '%s' "$LOUT" | grep -q 'CLAIM    3.4'; then
    ok "--explain shows both the accepted claim and the rejected candidate"
else
    bad "--explain did not report its own reasoning: $LOUT"
fi

# ---------------------------------------------------------------------------
# (k) REGISTRATION — both surfaces, or the engine ships a guard nobody loads
# ---------------------------------------------------------------------------
G=guard-row-currency-commits.sh
grep -q "$G" "$ENGINE_ROOT/hooks/hooks.json" 2>/dev/null \
    && ok "$G registered in hooks/hooks.json (plugin surface)" \
    || bad "$G NOT registered in hooks/hooks.json"
grep -q "$G" "$ENGINE_ROOT/.claude/settings.local.json" 2>/dev/null \
    && ok "$G registered in .claude/settings.local.json (seated surface)" \
    || bad "$G NOT registered in .claude/settings.local.json"
grep -q "^${G}|PreToolUse" "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" 2>/dev/null \
    && ok "$G declared in the probe's BR_EXPECTED oracle, on PreToolUse" \
    || bad "$G NOT declared in the probe's managed set"
grep -q "guard-row-currency-commits \\\\" "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" 2>/dev/null \
    && ok "$G listed among Layer R's root-resolving hooks" \
    || bad "$G NOT listed in Layer R's rooted-hook set — its bootstrap would go unchecked"
for lib in scripts/lib/row-currency.sh scripts/lib/row-currency.py; do
    grep -q "$lib" "$ENGINE_ROOT/scripts/hooks/install.sh" 2>/dev/null \
        && ok "$lib is sidecar-hashed by install.sh (the guard delegates its whole decision to it)" \
        || bad "$lib NOT hashed by install.sh"
done

echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    printf '  %s/%s cases passed\n' "$PASS" "$TOTAL"
    exit 0
fi
printf '  %s/%s cases passed — %s FAILED\n' "$PASS" "$TOTAL" "$FAIL"
exit 1
