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
#   (l) THE GROUPED DIRECTORY — a declaration at `.richos/row-currency` governs
#       exactly as a root one does (proved by a REFUSAL, never by a load);
#       declared in both places at once is BROKEN; a DECLARATION in `.richos/`
#       that nothing resolves is BROKEN too, because the alternative is a
#       contract switched off by a `git mv`; and anything else sharing that
#       directory is left alone, because it is a shared RichOS directory and a
#       resolver policing all of it would take an adopter offline.
#   (l) THE PREMISE WARRANT — a CEO item's stated reason for asking. Adopted
#       and unadopted; moved and unmoved (two-sided, both directions asserted);
#       the paste that clears it; `unobservable` with a reason and without;
#       a pin with no stated fact; required and not required; and every way the
#       declaration can be wrong. Plus the census, which is asserted to be
#       PRESENT on a clean run — the whole point of it is that "nothing to say"
#       and "never ran" must not be the same output.
#   (m) SECTION 3 IS UNCHANGED. The stamp walk was extracted so both warrants
#       share one implementation; the three section-3 refusal sentences are
#       asserted AT RUNTIME, out of real refusals, so a refactor cannot quietly
#       reword a contract 20 governed rows are written against.
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

# write_ceo_record <record-repo> <section-1-item-block> <section-3-rows...>
# The same record shape as write_record, with a real '### <id> <STATE> - ...'
# item in section 1. A CEO item is a BLOCK, not a table row, and the two shapes
# are parsed by one function — so a suite that only ever wrote table rows would
# prove the easy half of that claim.
write_ceo_record() {
    local rec="$1" ceo="$2"; shift 2
    {
        printf '# Open items\n\n'
        printf '## 1. Waiting on the CEO — a decision\n\n'
        printf '%s\n\n' "$ceo"
        printf '## 2. Waiting on the CEO — his hands\n\n_Nothing._\n\n'
        printf '## 3. Buildable now — nobody blocked\n\n'
        printf '| # | Item | State |\n|---|---|---|\n'
        local r
        for r in "$@"; do printf '%s\n' "$r"; done
        printf '\n## Deliberately NOT open\n\nnothing\n'
    } > "$rec/wiki/open-items.md"
}

# ceo_item <id> <premise-line-or-empty>
ceo_item() {
    printf '### %s READY-FOR-CEO — a ruling only he can give\n' "$1"
    printf -- '- **Open:** `rec/docs/note.md`\n'
    printf -- '- **Time:** 10 minutes\n'
    printf -- '- **Done:** a ruling recorded in the decisions page\n'
    printf -- '- **Unblocks:** the thing that waits on it\n'
    [ -n "${2:-}" ] && printf -- '- **Premise:** %s\n' "$2"
    printf '\nSome prose explaining the choice.\n'
}

# declare_premise <record-repo> <sections> [required]
declare_premise() {
    printf 'PREMISE_SECTIONS="%s"\n' "$2" >> "$1/.ceo-todos"
    [ -n "${3:-}" ] && printf 'PREMISE_REQUIRED="%s"\n' "$3" >> "$1/.ceo-todos"
    return 0
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

# 1b. THE SAME REFUSAL, IN THE HOUSE STYLE — a MULTI-LINE commit message.
#
# Every case above and below passes a one-line message, and for four days that
# was the only shape this suite ever handed the guard. The shipped command
# splitter cut inside quotes, so a message with a blank line in it — which is
# how every commit message in this project is written — was torn in half, both
# halves failed to shlex, and NO `git commit` was recognized in the call at all.
# The guard exited 0 having looked at nothing.
#
# Measured over every transcript on this machine since the guard shipped:
# 189 of 592 commit/merge calls at a governed main checkout (31.9%) were never
# recognized, and 29 commits reached richos-hq's main carrying a stale row.
# Found by a sibling guard's author, not by this suite — which is why the case
# is here and why it uses the shape the corpus actually contains.
set -- $(mk_pair multiline); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | the flywheel is unbuilt at both ends | **State:** `OPEN` — `work/lib/new.js`@`-` |'
commit_record "$REC"
printf 'the work that just landed\n' > "$WORK/lib/new.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"feat: the loop turns\n\nA second paragraph, and a blank line above it: the house style.\n\nThe splitter that cut inside quotes never saw this commit at all.\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-STALE'; then
    ok "a MULTI-LINE commit message is still recognized as a commit and refused"
else
    bad "multi-line message not refused (rc=$GRC) — the splitter cut inside the quotes: $GOUT"
fi

# 1c. AND THE SAME AGAIN WITH A SEPARATOR INSIDE THE MESSAGE. `;`, `&&` and `|`
# are ordinary punctuation in English prose and are what the old splitter cut
# on, so a message that contains one must not disappear either.
run_guard "$WORK" 'git commit -m \"feat: it turns; and it keeps turning && nothing else\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-STALE'; then
    ok "a message containing ; and && is still one commit, and is still refused"
else
    bad "message-with-separators not refused (rc=$GRC): $GOUT"
fi

# 1d. THE OTHER HALF OF THE SAME SUBJECT: a heredoc that WRITES a document
# containing the words `git commit` is not a commit. The walker shlexes that
# line out of the body happily, and this guard then runs the row predicate and
# can REFUSE the write. Measured: 12 calls in the transcript corpus recognized
# only because of a heredoc body, 2 at a governed main checkout. Describing a
# command is not issuing one.
run_guard "$WORK" 'cat > runbook.md <<EOF\nTo land the work run:\ngit commit -m \"the subject\"\nEOF'
if [ "$GRC" -eq 0 ]; then
    ok "a heredoc that WRITES the words 'git commit' into a document is not a commit"
else
    bad "a documented command was treated as a commit (rc=$GRC): $GOUT"
fi

# 1e. ...and the exception that keeps the recall. `bash <<EOF` really does
# execute its body, so a heredoc fed to a SHELL is still read in full. Without
# this the previous case would be a way to launder a landing past the guard.
run_guard "$WORK" 'bash <<EOF\ngit commit -m \"feat: the loop turns\"\nEOF'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-STALE'; then
    ok "a heredoc fed to a SHELL is still a command, and is still refused"
else
    bad "shell-fed heredoc not refused (rc=$GRC) — the body really does execute: $GOUT"
fi

# 1f. ...and `git commit -F -` still reads its message out of the heredoc it was
# handed. The blanking is applied to the text the walker segments, never to the
# message map, and this is the case that proves the two did not get confused.
run_guard "$WORK" 'git commit -F - <<MSG\nfeat: the loop turns\n\nopen-items 3.1 is done\nMSG'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'ROW-STALE'; then
    ok "git commit -F - still reads its message from the heredoc body"
else
    bad "commit -F - was not recognized (rc=$GRC): $GOUT"
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
# git-jurisdiction.sh is carried for the same reason seat-jurisdiction.sh is:
# the guard REFUSES TO START without it, so a fixture missing it would refuse
# for the wrong reason and this case would pass over a guard that never reached
# the predicate it is about. That is the sandbox-list defect, one suite down.
cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" "$ENGINE_ROOT/scripts/lib/seat-jurisdiction.sh" "$ENGINE_ROOT/scripts/lib/git-jurisdiction.sh" "$TMPENG/scripts/lib/"
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
# (l) THE PREMISE WARRANT — is the reason for asking him this still true?
# ---------------------------------------------------------------------------
# The case this exists for, in one line: item 1.8 asked the CEO to rule on a
# question whose premise had been false for three days. It was not finished, so
# its Done-check was correctly silent; it was not a section-3 row, so nothing
# pinned it. Every case below is a shape of that.

# NOT ADOPTED — the precision floor, and it comes first for the same reason
# stand-down does. A repository that declares no PREMISE_SECTIONS must be
# untouched by all of this, however its CEO items are written.
set -- $(mk_pair prem_unadopted); REC="$1"; WORK="$2"
OLD="$(oid_of "$WORK" lib/thing.js)"
write_ceo_record "$REC" "$(ceo_item 1.1 "\`work/lib/thing.js\`@\`$OLD\` — the thing still says what it said")" \
    '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
printf 'the shipped thing, moved on\n' > "$WORK/lib/thing.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work moves\"'
if [ "$GRC" -eq 0 ]; then
    ok "premise: an undeclared PREMISE_SECTIONS checks nothing and blocks nothing"
else
    bad "premise: unadopted repository was blocked (rc=$GRC): $GOUT"
fi
if printf '%s' "$GOUT" | grep -q 'PREMISE CENSUS: sections=-'; then
    ok "premise: the census SAYS it is not adopted rather than passing in silence"
else
    bad "premise: no census line on an unadopted run: $GOUT"
fi

# THE TWO-SIDED CANARY. Both directions, on one fixture, so neither can pass
# for the wrong reason: an UNMOVED premise passes, and the moment the pinned
# artifact moves the same landing is refused.
set -- $(mk_pair prem_moved); REC="$1"; WORK="$2"
declare_premise "$REC" "1"
OLD="$(oid_of "$WORK" lib/thing.js)"
write_ceo_record "$REC" "$(ceo_item 1.1 "\`work/lib/thing.js\`@\`$OLD\` — nothing reads the thing, measured on the 30th")" \
    '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
printf 'unrelated work\n' > "$WORK/lib/other.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"chore: something else entirely\"'
if [ "$GRC" -eq 0 ]; then
    ok "premise: an UNMOVED premise passes (the negative half of the canary)"
else
    bad "premise: unmoved premise was refused (rc=$GRC): $GOUT"
fi
if printf '%s' "$GOUT" | grep -q 'PREMISE CENSUS: sections=1 items=1 evaluated=1 pinned=1'; then
    ok "premise: the census proves the evaluator ran on the passing side"
else
    bad "premise: census wrong or absent on the passing side: $GOUT"
fi

printf 'the shipped thing, and now something DOES read it\n' > "$WORK/lib/thing.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"feat: the destination declares the scope now\"'
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'item 1.1' \
   && printf '%s' "$GOUT" | grep -q 'PREMISE-MOVED'; then
    ok "premise: a MOVED premise refuses the landing, naming the item and the code"
else
    bad "premise: moved premise not refused (rc=$GRC): $GOUT"
fi
if printf '%s' "$GOUT" | grep -q 'work/lib/thing.js'; then
    ok "premise: the refusal names WHAT moved, not just that something did"
else
    bad "premise: the refusal does not name the artifact: $GOUT"
fi

# THE PASTE. The refusal prints the warrant the item should now carry, fact and
# all, and pasting it clears the same landing — the same contract section 3 has.
NEWP="$(printf '%s' "$GOUT" | sed -n 's/.*`work\/lib\/thing.js`@`\([0-9a-f]*\)`.*/\1/p' | head -1)"
if [ -n "$NEWP" ]; then
    write_ceo_record "$REC" "$(ceo_item 1.1 "\`work/lib/thing.js\`@\`$NEWP\` — something DOES read it now, and the question is narrower")" \
        '| 3.1 | fine | **State:** `CLOSED` |'
    commit_record "$REC" "record: 1.1 re-read"
    run_guard "$WORK" 'git commit -m \"feat: the destination declares the scope now\"'
    [ "$GRC" -eq 0 ] && ok "premise: re-stating the premise with the printed pin clears the refusal" \
                     || bad "premise: the printed warrant did not clear it (rc=$GRC): $GOUT"
else
    bad "premise: could not read a replacement object id out of the refusal"
fi
if printf '%s' "$GOUT" | grep -q 'PREMISE CENSUS'; then
    ok "premise: the census rides on the clean verdict too, never only on refusals"
else
    bad "premise: no census on the cleared run: $GOUT"
fi

# UNOBSERVABLE — the DONE-CHECK-MANUAL precedent. Counted, printed, never silent.
set -- $(mk_pair prem_unobs); REC="$1"; WORK="$2"
declare_premise "$REC" "1"
write_ceo_record "$REC" "$(ceo_item 1.1 '`unobservable "railway login is a shell command and leaves nothing on disk"`')" \
    '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
if [ "$GRC" -eq 0 ] && printf '%s' "$GOUT" | grep -q 'PREMISE-UNOBSERVABLE'; then
    ok "premise: an item may declare its premise unobservable, and is NAMED for it"
else
    bad "premise: unobservable declaration wrong (rc=$GRC): $GOUT"
fi
if printf '%s' "$GOUT" | grep -q 'unobservable=1'; then
    ok "premise: the unobservable declaration is COUNTED by the census"
else
    bad "premise: unobservable not counted: $GOUT"
fi

# ...and a BARE marker exempts nothing.
write_ceo_record "$REC" "$(ceo_item 1.1 '`unobservable "dunno"`')" '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'PREMISE-UNOBSERVABLE-NO-REASON' \
    && ok "premise: a bare or unreasoned unobservable marker is refused, never accepted" \
    || bad "premise: unreasoned unobservable should block (rc=$GRC): $GOUT"

# A PIN WITH NO STATED FACT. The pin alone can be cleared by retyping a hex
# string; the sentence is what forces a human to decide the question survives.
write_ceo_record "$REC" "$(ceo_item 1.1 "\`rec/docs/note.md\`@\`$(oid_of "$REC" docs/note.md)\`")" \
    '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'PREMISE-NO-FACT' \
    && ok "premise: a pin with no stated fact is refused — a re-stamp must not be mechanical" \
    || bad "premise: factless pin should block (rc=$GRC): $GOUT"

# NEITHER SHAPE.
write_ceo_record "$REC" "$(ceo_item 1.1 'we are fairly sure nothing reads it')" \
    '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'PREMISE-UNPINNED' \
    && ok "premise: prose that pins nothing and claims nothing is refused" \
    || bad "premise: unpinned premise should block (rc=$GRC): $GOUT"

# NOT REQUIRED (the default): named on every verdict, blocks nothing.
set -- $(mk_pair prem_optional); REC="$1"; WORK="$2"
declare_premise "$REC" "1"
write_ceo_record "$REC" "$(ceo_item 1.1 '')" '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
if [ "$GRC" -eq 0 ] && printf '%s' "$GOUT" | grep -q 'PREMISE-NOT-STATED'; then
    ok "premise: with PREMISE_REQUIRED unset, a premise-less item is NAMED and never blocked"
else
    bad "premise: optional mode wrong (rc=$GRC): $GOUT"
fi
if printf '%s' "$GOUT" | grep -q 'unstated=1'; then
    ok "premise: the unstated item is counted by the census, not merely mentioned"
else
    bad "premise: unstated not counted: $GOUT"
fi

# REQUIRED: the same record, one line of declaration different.
set -- $(mk_pair prem_required); REC="$1"; WORK="$2"
declare_premise "$REC" "1" "1"
write_ceo_record "$REC" "$(ceo_item 1.1 '')" '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'PREMISE-MISSING' \
    && ok "premise: PREMISE_REQUIRED=1 turns the notice into a refusal" \
    || bad "premise: required mode should block (rc=$GRC): $GOUT"

# EVERY WAY THE DECLARATION CAN BE WRONG IS BROKEN, never a quiet pass.
set -- $(mk_pair prem_reqnosec); REC="$1"; WORK="$2"
printf 'PREMISE_REQUIRED="1"\n' >> "$REC/.ceo-todos"
write_ceo_record "$REC" "$(ceo_item 1.1 '')" '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'BROKEN' \
    && ok "premise: PREMISE_REQUIRED=1 over no section is BROKEN — a requirement over nothing" \
    || bad "premise: required-with-no-sections should be broken (rc=$GRC): $GOUT"

set -- $(mk_pair prem_notceo); REC="$1"; WORK="$2"
declare_premise "$REC" "3"
write_ceo_record "$REC" "$(ceo_item 1.1 '')" '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
# THE REASON, not just the verdict. This case was first written asserting only
# "BROKEN" and it passed with the subset check surgically removed — because
# section 3 is also the ROW section, so the overlap check refused instead and
# the output looked identical. A case that cannot tell which check fired is a
# case that cannot tell whether its own check exists.
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'not one of CEO_SECTIONS' \
    && ok "premise: a premise section outside CEO_SECTIONS is BROKEN, and says so" \
    || bad "premise: non-CEO premise section should be broken by the SUBSET check (rc=$GRC): $GOUT"

# The overlap the two contracts must never have: one section, two warrants.
set -- $(mk_pair prem_overlap); REC="$1"; WORK="$2"
declare_premise "$REC" "1"
printf 'ROW_SECTIONS="1 3"\nROW_STATUS_TOKENS="OPEN BUILT CLOSED"\nROW_TERMINAL_TOKENS="CLOSED"\n' > "$REC/.row-currency"
write_ceo_record "$REC" "$(ceo_item 1.1 '')" '| 3.1 | fine | **State:** `CLOSED` |'
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'BROKEN' \
    && ok "premise: a section declared as BOTH a row section and a premise section is BROKEN" \
    || bad "premise: overlap should be broken (rc=$GRC): $GOUT"

# A declared premise section that is not in the record: BROKEN, for exactly the
# reason a missing ROW_SECTION is — the check would look at nothing and pass.
set -- $(mk_pair prem_nosection); REC="$1"; WORK="$2"
declare_premise "$REC" "2"
{
    printf '# Open items\n\n## 1. Waiting on the CEO — a decision\n\n_Nothing._\n\n'
    printf '## 3. Buildable now\n\n| # | Item | State |\n|---|---|---|\n| 3.1 | fine | **State:** `CLOSED` |\n'
} > "$REC/wiki/open-items.md"
commit_record "$REC"
run_guard "$REC" 'git commit -m \"anything\"'
[ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -q 'BROKEN' \
    && ok "premise: a declared premise section absent from the record is BROKEN" \
    || bad "premise: absent premise section should be broken (rc=$GRC): $GOUT"

# ---------------------------------------------------------------------------
# (m) SECTION 3 IS UNCHANGED BY THE EXTRACTION
# ---------------------------------------------------------------------------
# The stamp walk now serves two warrants. Twenty governed rows in the real
# record are written against the sentences it produced when it served one, so
# each of the three is asserted HERE, AT RUNTIME, out of a real refusal —
# never by grepping the source, which would only prove a string is present
# somewhere and not that this code path still emits it.
set -- $(mk_pair sec3_words); REC="$1"; WORK="$2"

# 1. MOVED.
OLD="$(oid_of "$WORK" lib/thing.js)"
write_record "$REC" "| 3.1 | open | **State:** \`OPEN\` — \`work/lib/thing.js\`@\`$OLD\` |"
commit_record "$REC"
printf 'moved on\n' > "$WORK/lib/thing.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work\"'
printf '%s' "$GOUT" | grep -qF 'The work moved; this row still describes what it used to be.' \
    && ok "section 3 wording unchanged: the MOVED refusal" \
    || bad "section 3 MOVED refusal was reworded: $GOUT"

# 2. APPEARED — stamped absent, and the work now exists.
set -- $(mk_pair sec3_appeared); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | unbuilt | **State:** `OPEN` — `work/lib/new.js`@`-` |'
commit_record "$REC"
printf 'it landed\n' > "$WORK/lib/new.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work\"'
printf '%s' "$GOUT" | grep -qF 'The row was written before the work was.' \
    && ok "section 3 wording unchanged: the APPEARED refusal" \
    || bad "section 3 APPEARED refusal was reworded: $GOUT"

# 3. VANISHED — stamped at an id, and the work is gone.
set -- $(mk_pair sec3_vanished); REC="$1"; WORK="$2"
OLD="$(oid_of "$WORK" lib/thing.js)"
write_record "$REC" "| 3.1 | open | **State:** \`OPEN\` — \`work/lib/thing.js\`@\`$OLD\` |"
commit_record "$REC"
rm -f "$WORK/lib/thing.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work\"'
printf '%s' "$GOUT" | grep -qF 'no longer exists. The row describes work that is not there.' \
    && ok "section 3 wording unchanged: the VANISHED refusal" \
    || bad "section 3 VANISHED refusal was reworded: $GOUT"

# ---------------------------------------------------------------------------
# (l) THE GROUPED DECLARATION DIRECTORY
# ---------------------------------------------------------------------------
# The declaration may live at `.richos/row-currency` instead of the repository
# root. EVERY OTHER CASE IN THIS FILE ALREADY PROVES THE ROOT FORM, which is
# what makes these the interesting half: the move must not turn a governed
# repository into a stood-down one, and a stood-down guard is the failure that
# looks exactly like a clean run.
#
# So the first case here is a REFUSAL, not a load. A test that only proved the
# file was found would pass just as well over a guard that found it and then
# decided nothing.

# 1. A grouped declaration GOVERNS: the vanished-warrant refusal still fires.
set -- $(mk_pair grouped_governs); REC="$1"; WORK="$2"
OLD="$(oid_of "$WORK" lib/thing.js)"
write_record "$REC" "| 3.1 | open | **State:** \`OPEN\` — \`work/lib/thing.js\`@\`$OLD\` |"
commit_record "$REC"
mkdir -p "$WORK/.richos"
git -C "$WORK" mv .row-currency .richos/row-currency >/dev/null 2>&1
rm -f "$WORK/lib/thing.js"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work\"'
if [ "$GRC" -ne 0 ] && printf '%s' "$GOUT" | grep -qF 'no longer exists. The row describes work that is not there.'; then
    ok "a declaration at .richos/row-currency GOVERNS — the vanished-warrant landing is refused"
else
    bad "a grouped declaration stood the guard down (rc=$GRC): $GOUT"
fi

# 2. ...and the same repository lets a CURRENT row through. A guard that
#    refuses everything is not a working guard either.
set -- $(mk_pair grouped_allows); REC="$1"; WORK="$2"
OLD="$(oid_of "$WORK" lib/thing.js)"
write_record "$REC" "| 3.1 | open | **State:** \`OPEN\` — \`work/lib/thing.js\`@\`$OLD\` |"
commit_record "$REC"
mkdir -p "$WORK/.richos"
git -C "$WORK" mv .row-currency .richos/row-currency >/dev/null 2>&1
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work\"'
[ "$GRC" -eq 0 ] && ok "a grouped declaration over a CURRENT row passes silently" \
                 || bad "a current row under a grouped declaration was refused (rc=$GRC): $GOUT"

# 3. BOTH forms at once is BROKEN. Choosing one quietly is how the wrong one
#    stays live — the sentence `.ceo-todos` already carries about its legacy name.
set -- $(mk_pair grouped_both); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | a row | **State:** `CLOSED` |'
commit_record "$REC"
mkdir -p "$WORK/.richos"
cp "$WORK/.row-currency" "$WORK/.richos/row-currency"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work\"'
if [ "$GRC" -ne 0 ] && printf '%s' "$GOUT" | grep -qF 'carries BOTH .richos/row-currency and .row-currency'; then
    ok "a declaration in two places at once is BROKEN and REFUSES, never a silent choice"
else
    bad "two declarations were resolved rather than refused (rc=$GRC): $GOUT"
fi

# 4. A DECLARATION in `.richos/` that nothing resolves is BROKEN TOO — the trap
#    the directory would otherwise create. Move `.ceo-todos` in there and its
#    contract switches off in silence; this is what stops that.
set -- $(mk_pair grouped_stray); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | a row | **State:** `CLOSED` |'
commit_record "$REC"
mkdir -p "$WORK/.richos"
git -C "$WORK" mv .row-currency .richos/row-currency >/dev/null 2>&1
printf 'TODO_RECORD="wiki/open-items.md"\n' > "$WORK/.richos/ceo-todos"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work\"'
if [ "$GRC" -ne 0 ] && printf '%s' "$GOUT" | grep -qF '.richos/ceo-todos is a declaration, and nothing reads a declaration from there'; then
    ok "an unresolved DECLARATION in .richos/ is BROKEN and names itself — a half-migration cannot look finished"
else
    bad "a stray declaration in .richos/ was ignored rather than refused (rc=$GRC): $GOUT"
fi

# 5. ...and ANYTHING ELSE in that directory is none of the resolver's business.
#    `.richos/` is a SHARED RichOS directory: the ECS entity manifest has sat at
#    `.richos/entity.json` in femcboost since 2026-08-27, and scripts/ecs/ecs_cli.py
#    takes that path as a default argument. A resolver policing the whole
#    directory would have refused every commit in that repository. This case is
#    that repository, in miniature.
set -- $(mk_pair grouped_neighbors); REC="$1"; WORK="$2"
write_record "$REC" '| 3.1 | a row | **State:** `CLOSED` |'
commit_record "$REC"
mkdir -p "$WORK/.richos"
git -C "$WORK" mv .row-currency .richos/row-currency >/dev/null 2>&1
printf '{"schemaVersion":1,"entityId":"sample"}\n' > "$WORK/.richos/entity.json"
printf '# what lives here\n' > "$WORK/.richos/README.md"
git -C "$WORK" add -A >/dev/null 2>&1
run_guard "$WORK" 'git commit -m \"work\"'
[ "$GRC" -eq 0 ] && ok "entity.json and a README share .richos/ without breaking anything" \
                 || bad "an unrelated neighbor in .richos/ was treated as a stray (rc=$GRC): $GOUT"

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
for lib in scripts/lib/row-currency.sh scripts/lib/row-currency.py scripts/lib/declaration-path.sh; do
    grep -q "$lib" "$ENGINE_ROOT/scripts/hooks/install.sh" 2>/dev/null \
        && ok "$lib is sidecar-hashed by install.sh (the guard delegates its whole decision to it)" \
        || bad "$lib NOT hashed by install.sh"
done

# ---------------------------------------------------------------------------
# THE MUTATION HARNESS — a green suite is evidence of nothing until somebody
# has watched it go red for the right reason. Skipped inside a mutation sandbox
# so a mutant cannot run mutants.
# ---------------------------------------------------------------------------
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -x "$SCRIPT_DIR/guard-row-currency-commits.mutation.sh" ]; then
    echo ""
    echo "=== running the mutation harness ==="
    "$SCRIPT_DIR/guard-row-currency-commits.mutation.sh" || FAIL=$((FAIL + 1))
fi

echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    printf '  %s/%s cases passed\n' "$PASS" "$TOTAL"
    exit 0
fi
printf '  %s/%s cases passed — %s FAILED\n' "$PASS" "$TOTAL" "$FAIL"
exit 1
