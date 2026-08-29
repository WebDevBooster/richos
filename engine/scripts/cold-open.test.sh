#!/usr/bin/env bash
#
# cold-open.test.sh — the cold-open HARNESS, driven by a stub reader.
#
# ===========================================================================
# WHY THE READER IS A STUB HERE, AND WHY THAT IS NOT A DODGE
# ===========================================================================
# The cold open's whole point is a reader with no context — which in practice
# means a language model, a network round-trip, and an answer that is different
# every time. None of that belongs in this engine's self-test: a suite that
# needs the network is a suite that goes red for reasons that are not defects,
# and a suite you learn to re-run until it passes has stopped being a suite.
#
# So the split is: the MECHANISM is tested here, hermetically, with a stub
# reader that prints a canned answer; the JUDGMENT is exercised on demand by
# scripts/cold-open.sh --run and lands as a committed transcript. What is
# asserted below is everything that can be true or false without asking a model
# anything —
#
#   * the prompt handed to the reader is the verbatim shipped file
#   * the reader is invoked in the REPOSITORY, with the prompt on stdin
#   * the default reader is customisation-free (a reader that loaded this
#     project's CLAUDE.md, plugins and hooks would not be cold, and the whole
#     exercise would be theatre)
#   * a failed or empty reading files NOTHING — an empty transcript would
#     satisfy the gate while proving that nobody read anything
#   * the transcript is stamped with the fingerprints the GATE will demand,
#     from the same code path the gate uses
#   * the harness refuses to read a page that is stale, so a transcript can
#     never describe a document no one has seen
#   * --record makes a human reading count identically, with no vendor in it
#
# Run directly: scripts/cold-open.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RICHOS_ENTITY_ROOT="$ENGINE_ROOT"
export RICHOS_ENTITY_ROOT
unset CLAUDE_PROJECT_DIR

CO="$ENGINE_ROOT/scripts/cold-open.sh"
RENDER="$ENGINE_ROOT/scripts/ceo-queue-render.sh"
PROMPT="$ENGINE_ROOT/scripts/lib/cold-open-prompt.md"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
SCRATCH="$(mktemp -d -t cotest.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$CO" "$RENDER" "$PROMPT" "$ENGINE_ROOT/scripts/lib/ceo-queue.sh"; do
    [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

# --- fixture ---------------------------------------------------------------
ANSWER_TEXT='## 1. What is this repository
It appears to be a working repository with a queue of things waiting on me, and
the front page points straight at that queue rather than at the product.
## 2. Where do I start
CEO-QUEUE.md, named in the first line of the README, which is where I looked.
## 5. What confused me
Nothing much, though I had to guess where the generated page comes from.'

mk_repo() {
    local repo="$SCRATCH/$1"
    mkdir -p "$repo/wiki" "$repo/docs/cold-open"
    git -C "$repo" init -q
    printf 'an artifact that exists\n' > "$repo/docs/prepared.md"
    printf '# A repo\n\nStart at [CEO-QUEUE.md](CEO-QUEUE.md).\n' > "$repo/README.md"
    {
        echo 'QUEUE_RECORD="wiki/open-items.md"'
        echo 'QUEUE_VIEW="CEO-QUEUE.md"'
        echo 'CEO_SECTIONS="1 2"'
        echo 'PREPARER_SECTION="3"'
        echo 'ARTIFACT_ROOTS="repo=."'
        echo 'COLD_OPEN_DIR="docs/cold-open"'
    } > "$repo/.ceo-queue"
    {
        printf '# Open items\n\n'
        printf '## 1. Waiting on the CEO — a decision\n\n'
        printf '### 1.1 READY-FOR-CEO — A decision that is prepared\n\n'
        printf -- '- **Open:** `repo/docs/prepared.md`\n'
        printf -- '- **Time:** 15 minutes\n'
        printf -- '- **Done:** a ruling recorded on the decisions page\n'
        printf -- '- **Unblocks:** the two build items downstream of it\n\n'
        printf '## 2. Waiting on the CEO — his hands\n\n'
        printf '## 3. Buildable now — nobody blocked\n\n'
    } > "$repo/wiki/open-items.md"
    "$BASH_BIN" "$RENDER" "$repo" >/dev/null 2>&1
    printf '%s' "$repo"
}

# A reader that is not a model: it records HOW it was invoked, then prints a
# canned answer. Everything the harness promises about the invocation is
# asserted from what this writes down.
mk_stub() {
    # ${2-...}, NOT ${2:-...}: an explicitly EMPTY body is the silent-reader
    # case and must not be quietly replaced by the default, which is precisely
    # how this case first passed for the wrong reason.
    local path="$SCRATCH/$1.sh" body="${2-$ANSWER_TEXT}" rc="${3:-0}"
    {
        echo '#!/usr/bin/env bash'
        echo "pwd > \"$SCRATCH/stub-cwd.txt\""
        echo "cat > \"$SCRATCH/stub-stdin.txt\""
        printf 'cat <<'"'"'STUBEOF'"'"'\n%s\nSTUBEOF\n' "$body"
        echo "exit $rc"
    } > "$path"
    chmod +x "$path"
    printf '%s' "$path"
}

echo "=== cold-open: the harness, driven by a stub reader ==="

# ---------------------------------------------------------------------------
# (a) --brief — the verbatim prompt, and nothing run
# ---------------------------------------------------------------------------
R="$(mk_repo brief)"
OUT="$("$BASH_BIN" "$CO" --brief "$R" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'front-door surface  : sha256:'; then
    ok "--brief prints the front-door fingerprint the gate will demand"
else
    bad "--brief should print the surface fingerprint (rc=$RC)"
fi
FIRST_LINE="$(head -1 "$PROMPT")"
if printf '%s' "$OUT" | grep -qF "$FIRST_LINE"; then
    ok "--brief prints the SHIPPED prompt verbatim — a cold open with an improvised question is not reproducible"
else
    bad "--brief should print the shipped prompt verbatim"
fi
if [ -z "$(ls -A "$R/docs/cold-open" 2>/dev/null)" ]; then
    ok "--brief files nothing — printing the question is not answering it"
else
    bad "--brief should not file a transcript"
fi

# ---------------------------------------------------------------------------
# (b) --run — how the reader is actually invoked
# ---------------------------------------------------------------------------
R="$(mk_repo run)"
STUB="$(mk_stub good)"
OUT="$("$BASH_BIN" "$CO" --run "$R" --reader-cmd "$STUB" --reader "stub" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF 'filed docs/cold-open/'; then
    ok "--run with an arbitrary reader-cmd files a transcript — the reader is a SEAM, not a vendor"
else
    bad "--run should file a transcript with a stub reader (rc=$RC): $OUT"
fi
if [ -f "$SCRATCH/stub-cwd.txt" ] && [ "$(cat "$SCRATCH/stub-cwd.txt")" = "$(cd "$R" && pwd -P)" ]; then
    ok "the reader runs IN the repository — it has to be looking at the thing it is describing"
else
    bad "the reader should run with the repository as its cwd"
fi
if [ -f "$SCRATCH/stub-stdin.txt" ] && grep -qF "$FIRST_LINE" "$SCRATCH/stub-stdin.txt"; then
    ok "the reader gets the verbatim prompt on stdin"
else
    bad "the reader should receive the prompt on stdin"
fi
if grep -qF "$R" "$SCRATCH/stub-stdin.txt"; then
    ok "...with the repository path substituted, so the reader knows what to look at"
else
    bad "the prompt should name the repository"
fi

T="$(ls "$R/docs/cold-open"/*.md 2>/dev/null | head -1)"
for field in Surface-fingerprint Prompt-fingerprint Reader Run-by Date; do
    if grep -q "^- \*\*$field:\*\* .\+" "$T"; then
        ok "the transcript carries **$field:**"
    else
        bad "the transcript is missing **$field:**"
    fi
done
if grep -qF "$(cd "$ENGINE_ROOT" && shasum -a 256 scripts/lib/cold-open-prompt.md | awk '{print $1}')" "$T"; then
    ok "the transcript stamps the PROMPT's hash — change a question and every transcript stops counting, because nobody has answered the new one"
else
    bad "the transcript should stamp the prompt hash"
fi
if grep -qF '## What the reader answered' "$T" && grep -qF 'Where do I start' "$T"; then
    ok "the reader's own words are in the transcript — the transcript IS the product"
else
    bad "the transcript should contain the reader's answer"
fi
if grep -q '^| the entry point | `CEO-QUEUE.md` | yes |' "$T"; then
    ok "the checked-claims table records that the reader came away with the entry point"
else
    bad "the checked-claims table should record the entry point claim"
fi

# ---------------------------------------------------------------------------
# (c) A DIVERGENCE is recorded, not punished
# ---------------------------------------------------------------------------
R="$(mk_repo diverge)"
STUB="$(mk_stub blind "$(printf 'I could not find anything at all in here.\nThere is no queue that I can see and I would have given up.\nI looked for a starting point and there was none.\nI am recording that plainly because guessing would be worse.')")"
"$BASH_BIN" "$CO" --run "$R" --reader-cmd "$STUB" --reader "stub" >/dev/null 2>&1; RC=$?
T="$(ls "$R/docs/cold-open"/*.md 2>/dev/null | head -1)"
if [ "$RC" -eq 0 ] && [ -n "$T" ] && grep -q '^| the entry point | `CEO-QUEUE.md` | no |' "$T"; then
    ok "a reader who MISSED the entry point is recorded as a 'no' and the transcript is still filed — the finding is the product, not a failure"
else
    bad "a divergence should be recorded, not refused (rc=$RC)"
fi

# ---------------------------------------------------------------------------
# (d) NOTHING is filed when nothing was read
# ---------------------------------------------------------------------------
R="$(mk_repo readerfails)"
STUB="$(mk_stub broken "irrelevant" 1)"
OUT="$("$BASH_BIN" "$CO" --run "$R" --reader-cmd "$STUB" --reader "stub" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && [ -z "$(ls -A "$R/docs/cold-open" 2>/dev/null)" ]; then
    ok "a reader that FAILS files nothing — an empty transcript would satisfy the gate while proving nobody read anything"
else
    bad "a failing reader should file nothing and exit 2 (rc=$RC)"
fi

R="$(mk_repo readersilent)"
STUB="$(mk_stub silent "")"
OUT="$("$BASH_BIN" "$CO" --run "$R" --reader-cmd "$STUB" --reader "stub" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && [ -z "$(ls -A "$R/docs/cold-open" 2>/dev/null)" ]; then
    ok "a reader that says NOTHING files nothing"
else
    bad "a silent reader should file nothing (rc=$RC)"
fi

# ---------------------------------------------------------------------------
# (e) The page must be settled before anyone is asked to read it
# ---------------------------------------------------------------------------
R="$(mk_repo staleview)"
printf 'hand-edited nonsense\n' > "$R/CEO-QUEUE.md"
STUB="$(mk_stub good2)"
OUT="$("$BASH_BIN" "$CO" --run "$R" --reader-cmd "$STUB" --reader "stub" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'missing or stale'; then
    ok "reading a STALE page is refused — a transcript about a document nobody has seen is a fresh-looking lie"
else
    bad "a stale view should block --run (rc=$RC): $OUT"
fi

# ---------------------------------------------------------------------------
# (f) --check, before and after
# ---------------------------------------------------------------------------
R="$(mk_repo check)"
"$BASH_BIN" "$CO" --check "$R" >/dev/null 2>&1
if [ "$?" -eq 1 ]; then
    ok "--check exits 1 when no reader has seen the current front door"
else
    bad "--check should exit 1 with no transcript"
fi
STUB="$(mk_stub good3)"
"$BASH_BIN" "$CO" --run "$R" --reader-cmd "$STUB" --reader "stub" >/dev/null 2>&1
"$BASH_BIN" "$CO" --check "$R" >/dev/null 2>&1
if [ "$?" -eq 0 ]; then
    ok "--check exits 0 once a current transcript is on file"
else
    bad "--check should exit 0 after a reading"
fi
printf '# A repo\n\nA different front page entirely. [CEO-QUEUE.md](CEO-QUEUE.md).\n' > "$R/README.md"
"$BASH_BIN" "$CO" --check "$R" >/dev/null 2>&1
if [ "$?" -eq 1 ]; then
    ok "--check goes red again the moment the front door changes"
else
    bad "--check should go red when the front door changes"
fi

# ---------------------------------------------------------------------------
# (g) --record — a human reading counts identically
# ---------------------------------------------------------------------------
R="$(mk_repo record)"
HUMAN="$SCRATCH/human.md"
printf '%s\n' "$ANSWER_TEXT" > "$HUMAN"
OUT="$("$BASH_BIN" "$CO" --record "$R" --from "$HUMAN" --reader "a person, over coffee" 2>&1)"; RC=$?
T="$(ls "$R/docs/cold-open"/*.md 2>/dev/null | head -1)"
if [ "$RC" -eq 0 ] && grep -qF 'a person, over coffee' "$T"; then
    ok "--record files a HUMAN reading with the same stamps — the offline path is a first-class path, not a bypass"
else
    bad "--record should file a human reading (rc=$RC)"
fi
OUT="$("$BASH_BIN" "$CO" --record "$R" --from "$HUMAN" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF -- '--reader'; then
    ok "--record without --reader is refused — the one thing the machine cannot check is the one thing it must at least record"
else
    bad "--record should require --reader (rc=$RC)"
fi

# ---------------------------------------------------------------------------
# (h) FAIL-CLOSED, and the default reader is genuinely cold
# ---------------------------------------------------------------------------
TMPENG="$(mktemp -d -t cotest-eng.XXXXXX)"
mkdir -p "$TMPENG/scripts/lib"
cp "$CO" "$TMPENG/scripts/"
cp "$ENGINE_ROOT/scripts/lib/ceo-queue.sh" "$ENGINE_ROOT/scripts/lib/ceo-queue.py" \
   "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" "$TMPENG/scripts/lib/"
OUT="$("$BASH_BIN" "$TMPENG/scripts/cold-open.sh" --brief "$R" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -qF 'verbatim prompt is missing'; then
    ok "a missing prompt file is a LOUD refusal — without a fixed question there is no reproducible exercise"
else
    bad "a missing prompt should fail closed (rc=$RC)"
fi
rm -rf "$TMPENG"

for flag in -- --safe-mode --strict-mcp-config; do
    :
done
if grep -qF -- '--safe-mode' "$CO"; then
    ok "the default reader runs with --safe-mode: no CLAUDE.md, no plugins, no hooks, no skills, no memory — a reader that loaded this project's own doctrine would not be cold"
else
    bad "the default reader must disable customisations, or it is not a cold reader"
fi
if grep -qF -- '--tools Read,Glob,Grep' "$CO"; then
    ok "the default reader is READ-ONLY — it is here to report what it found, not to fix it"
else
    bad "the default reader should be read-only"
fi
if [ -x "$CO" ] && [ -x "$RENDER" ]; then
    ok "cold-open.sh and ceo-queue-render.sh are executable"
else
    bad "the harness scripts must be executable"
fi

# ---------------------------------------------------------------------------
# (i) The adoption path MENTIONS it — the defect that shipped once already
# ---------------------------------------------------------------------------
# The engine once shipped this whole mechanism with nothing in the onboarding
# path naming it, so every adopter got machinery that could never fire. That is
# not a documentation nicety; it is the difference between shipped and shipped
# working, and it gets an assertion.
for doc in ONBOARDING-RUNBOOK.md skills/bootstrap-interview/SKILL.md; do
    if grep -qF 'ceo-queue-init.sh' "$ENGINE_ROOT/$doc" 2>/dev/null; then
        ok "$doc names ceo-queue-init.sh — an adopter is told the queue exists"
    else
        bad "$doc does NOT name ceo-queue-init.sh — adopters would receive inert enforcement again"
    fi
done

echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    printf '  %s/%s cases passed\n' "$PASS" "$TOTAL"
    exit 0
fi
printf '  %s/%s cases passed — %s FAILED\n' "$PASS" "$TOTAL" "$FAIL"
exit 1
