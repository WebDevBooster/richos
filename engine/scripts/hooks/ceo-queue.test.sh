#!/usr/bin/env bash
#
# ceo-queue.test.sh — regression tests for the CEO-queue mechanism:
# scripts/lib/ceo-queue.sh, scripts/lib/ceo-queue.py, the CLI
# scripts/ceo-queue-lint.sh, and the guard that runs them at every commit
# (scripts/hooks/guard-ceo-queue-commits.sh).
#
# ONE suite for all four files on purpose. They are one subject — a predicate
# and its chokepoints — and splitting them would create several places to
# remember to update, which is the defect class the mechanism exists to remove.
#
# ===========================================================================
# EVERYTHING HERE RUNS ON FIXTURES, AND THAT IS A DESIGN DECISION
# ===========================================================================
# The record this mechanism was built for lives in a SEPARATE PRIVATE
# REPOSITORY that a CI runner cannot see and must never be given. So CI proves
# the PREDICATE against synthetic records — valid and invalid — and the real
# record is checked locally, and at every commit, by the guard.
#
# The trap that creates is obvious and is closed by name below: a suite that
# silently no-ops when its subject is absent is the exact defect. There is no
# case here that is skipped when something is missing. "The record is absent"
# is itself asserted, as its own distinguishable outcome (rc 3 from the CLI, a
# loud block from the guard) that can never be mistaken for a pass.
#
# Covers:
#   (a) STAND-DOWN — a repository with no .ceo-queue is untouched. This is the
#       precision floor: get it wrong and the guard fires in every repository
#       on the machine.
#   (b) THE REAL FAILURE — the item as it was actually written ("a real
#       recorded call, >= 10 min, human-verified transcript") is REFUSED, in
#       both the table shape it lived in and as a well-formed block, so the
#       refusal cannot be an artifact of one format.
#   (c) THE FIX — the same item, prepared, with an artifact that resolves on
#       disk, PASSES.
#   (d) THE ARTIFACT RULE — a path that does not exist fails even when all four
#       fields are present; an absolute path, an unknown prefix and two paths
#       in one field all fail; a declared root that is not on this machine is
#       SKIPPED and NAMED, never blocked and never invisible.
#   (e) THE TWO STATES — BLOCKED-ON-RICH in a CEO section is refused with the
#       destination named; in the preparer's section it is not the lint's
#       business at all.
#   (f) NO SILENT NO-OP — a missing CEO section, a missing record and a
#       reverted-to-table section are all loud. A lint with nothing to check
#       never reports clean.
#   (g) POSITIVE CONTROLS — a valid record passes, section-3 rows carrying no
#       fields at all are untouched, and a different markdown file in the same
#       repository is not read. A guard that blocks legitimate work gets
#       switched off, and then protects nothing.
#   (h) EVERY COMMIT — a commit that does not touch the record still catches a
#       PRE-EXISTING bad row, and says so rather than blaming this commit.
#   (i) FAIL-CLOSED conventions, matching the hook family.
#   (j) REGISTRATION on both surfaces, plus the probe's oracle and Layer R.
#
# Run directly: scripts/hooks/ceo-queue.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Declare the root under test, for the reason scan-secrets.test.sh states: run
# from a session seated elsewhere the guard would resolve THAT repository, find
# no adoption marker, stand down, and every case below would pass by never
# running.
RICHOS_ENTITY_ROOT="$ENGINE_ROOT"
export RICHOS_ENTITY_ROOT
unset CLAUDE_PROJECT_DIR

GUARD="$SCRIPT_DIR/guard-ceo-queue-commits.sh"
LINT="$ENGINE_ROOT/scripts/ceo-queue-lint.sh"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
SCRATCH="$(mktemp -d -t cqtest.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$GUARD" "$LINT" "$ENGINE_ROOT/scripts/lib/ceo-queue.sh" "$ENGINE_ROOT/scripts/lib/ceo-queue.py"; do
    [ -f "$f" ] || { echo "FATAL: missing $f" >&2; exit 1; }
done

# --- fixtures ---------------------------------------------------------------
# mk_repo <name> [decl-body] — a throwaway git repo carrying a declaration, an
# artifact that EXISTS (docs/prepared.md) and no record yet.
mk_repo() {
    local name="$1" repo="$SCRATCH/$1"
    mkdir -p "$repo/wiki" "$repo/docs"
    git -C "$repo" init -q
    printf 'an artifact that exists on disk\n' > "$repo/docs/prepared.md"
    if [ "$#" -ge 2 ]; then
        printf '%s\n' "$2" > "$repo/.ceo-queue"
    else
        {
            echo 'QUEUE_RECORD="wiki/open-items.md"'
            echo 'CEO_SECTIONS="1 2"'
            echo 'PREPARER_SECTION="3"'
            echo 'ARTIFACT_ROOTS="repo=. nowhere=../no-such-sibling-repository"'
        } > "$repo/.ceo-queue"
    fi
    printf '%s' "$repo"
}

# A well-formed section 1 item, used as ballast so no case passes merely
# because the record was empty.
GOOD_ITEM_1='### 1.1 READY-FOR-CEO — A decision that is prepared

- **Open:** `repo/docs/prepared.md`
- **Time:** 15 minutes
- **Done:** a ruling recorded on the decisions page
- **Unblocks:** the two build items downstream of it
'

# A section 3 that carries rows with NO fields at all. Section 3 is the
# preparer'"'"'s column and the lint has no business in it; this is the positive
# control that proves so.
SECTION_3='## 3. Buildable now — nobody blocked

| # | Item | Notes |
|---|---|---|
| 3.1 | Something buildable, with no artifact, no time and no criterion | |
| 3.2 | **BLOCKED-ON-RICH (was 2.6) — something unprepared, parked here on purpose** | |
'

write_record() {
    # write_record <repo> <section-2-body>
    local repo="$1" body="$2"
    {
        printf '# Open items\n\n'
        printf '## 1. Waiting on the CEO — a decision\n\n'
        printf '%s\n' "$GOOD_ITEM_1"
        printf '## 2. Waiting on the CEO — his hands\n\n'
        printf '%s\n' "$body"
        printf '%s\n' "$SECTION_3"
    } > "$repo/wiki/open-items.md"
}

commit_payload() {
    # commit_payload <repo> [command]
    local repo="$1" cmd="${2:-git commit -m \\\"work\\\"}"
    printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$repo" "$cmd"
}

run_guard() {
    # run_guard <repo> [command] -> sets GRC and GOUT
    GOUT="$(commit_payload "$@" | "$BASH_BIN" "$GUARD" 2>&1 >/dev/null)"
    GRC=$?
    return 0
}

run_lint() {
    LOUT="$("$BASH_BIN" "$LINT" "$1" 2>&1)"
    LRC=$?
    return 0
}

echo "=== ceo-queue: the predicate, the CLI and the commit guard ==="

# ---------------------------------------------------------------------------
# (a) STAND-DOWN — the precision floor
# ---------------------------------------------------------------------------
R="$(mk_repo standdown)"
rm -f "$R/.ceo-queue"
write_record "$R" '### 2.1 READY-FOR-CEO — nothing here is valid'
run_guard "$R"
if [ "$GRC" -eq 0 ]; then
    ok "a repository with no .ceo-queue is untouched, however bad its record"
else
    bad "stand-down failed: guard fired in an undeclared repository (rc=$GRC)"
fi

R="$(mk_repo notacommit)"
write_record "$R" '### 2.1 READY-FOR-CEO — nothing here is valid'
run_guard "$R" 'git status --short'
if [ "$GRC" -eq 0 ]; then
    ok "a Bash command that is not a commit passes untouched"
else
    bad "non-commit Bash should pass (rc=$GRC)"
fi
GOUT="$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"y"}}' | "$BASH_BIN" "$GUARD" 2>&1 >/dev/null)"; GRC=$?
if [ "$GRC" -eq 0 ]; then
    ok "a non-Bash tool payload passes untouched"
else
    bad "non-Bash payload should pass (rc=$GRC)"
fi

# ---------------------------------------------------------------------------
# (b) THE REAL FAILURE, REPLAYED — the item exactly as it was written
# ---------------------------------------------------------------------------
# Verbatim shape of the item that sat for weeks looking blocked on the CEO: a
# title describing a desired state, a note, and nothing a person can act on.
R="$(mk_repo realfailure)"
write_record "$R" '### 2.1 READY-FOR-CEO — A real recorded call, >= 10 min, human-verified transcript

Every transcription measurement before this was TTS — no cross-talk, one machine, <= 11 min.
'
run_guard "$R"
if [ "$GRC" -eq 2 ] \
   && printf '%s' "$GOUT" | grep -qF 'MISSING-FIELD' \
   && printf '%s' "$GOUT" | grep -qF '**Open:**' \
   && printf '%s' "$GOUT" | grep -qF '**Time:**' \
   && printf '%s' "$GOUT" | grep -qF '**Done:**' \
   && printf '%s' "$GOUT" | grep -qF '**Unblocks:**'; then
    ok "THE REAL FAILURE: the item as written is REFUSED, naming all four missing fields"
else
    bad "the original item should be refused for all four fields (rc=$GRC)"
fi

# The same content in the TABLE shape the record actually used. A parser that
# only reads '###' blocks would see nothing here and report clean — which is
# how reverting the format would quietly reopen the whole defect.
R="$(mk_repo realfailuretable)"
{
    printf '# Open items\n\n'
    printf '## 1. Waiting on the CEO — a decision\n\n'
    printf '%s\n' "$GOOD_ITEM_1"
    printf '## 2. Waiting on the CEO — his hands\n\n'
    printf '| # | Item | Notes |\n|---|---|---|\n'
    printf '| 2.1 | **A real recorded call, >= 10 min, human-verified transcript.** | Every measurement before this was TTS. |\n\n'
    printf '%s\n' "$SECTION_3"
} > "$R/wiki/open-items.md"
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'TABLE-ROW-IN-CEO-SECTION'; then
    ok "reverting a CEO section to a markdown table is REFUSED, not silently unchecked"
else
    bad "a table row in a CEO section should be refused (rc=$GRC)"
fi

# ---------------------------------------------------------------------------
# (c) THE FIX — the same item, prepared
# ---------------------------------------------------------------------------
R="$(mk_repo fixed)"
write_record "$R" '### 2.1 READY-FOR-CEO — Verify the podcast reference transcript

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** every one of the 30 windows carries either OK or a written correction, and the file is handed back
- **Unblocks:** the first computable word error rate, and with it decision 1.3

30 windows of 60 seconds, evenly spaced across one episode.
'
run_guard "$R"
if [ "$GRC" -eq 0 ]; then
    ok "THE FIX: the prepared item, artifact resolving on disk, PASSES"
else
    bad "the prepared item should pass (rc=$GRC): $GOUT"
fi
run_lint "$R"
if [ "$LRC" -eq 0 ] && printf '%s' "$LOUT" | grep -qF '2 item(s)'; then
    ok "the CLI agrees with the guard, and counts the items it checked"
else
    bad "CLI should report 2 clean items (rc=$LRC): $LOUT"
fi

# ---------------------------------------------------------------------------
# (d) THE ARTIFACT RULE
# ---------------------------------------------------------------------------
R="$(mk_repo missingartifact)"
write_record "$R" '### 2.1 READY-FOR-CEO — Verify the podcast reference transcript

- **Open:** `repo/docs/worksheet-that-was-never-written.md`
- **Time:** 30 minutes
- **Done:** every one of the 30 windows carries either OK or a written correction, handed back
- **Unblocks:** the first computable word error rate, and with it decision 1.3
'
run_guard "$R"
if [ "$GRC" -eq 2 ] \
   && printf '%s' "$GOUT" | grep -qF 'ARTIFACT-MISSING' \
   && printf '%s' "$GOUT" | grep -qF 'BLOCKED-ON-RICH'; then
    ok "ALL FOUR FIELDS PRESENT and the artifact absent is still a refusal, and it names the fix"
else
    bad "a missing artifact should be refused even with all four fields (rc=$GRC)"
fi

R="$(mk_repo absentroot)"
write_record "$R" '### 2.1 READY-FOR-CEO — Something in a repository nobody cloned

- **Open:** `nowhere/docs/worksheet.md`
- **Time:** 30 minutes
- **Done:** the worksheet comes back annotated in every window
- **Unblocks:** the measurement downstream of it
'
run_guard "$R"
run_lint "$R"
if [ "$GRC" -eq 0 ] && [ "$LRC" -eq 0 ] && printf '%s' "$LOUT" | grep -qF 'NOT checked'; then
    ok "a declared root that is not on this machine SKIPS and is NAMED, never blocks and never hides"
else
    bad "an absent declared root should skip-and-name (guard rc=$GRC, lint rc=$LRC): $LOUT"
fi

R="$(mk_repo badpaths)"
write_record "$R" '### 2.1 READY-FOR-CEO — An absolute path

- **Open:** `/Users/somebody/docs/worksheet.md`
- **Time:** 30 minutes
- **Done:** the worksheet comes back annotated in every window
- **Unblocks:** the measurement downstream of it

### 2.2 READY-FOR-CEO — An undeclared prefix

- **Open:** `mystery-repo/docs/worksheet.md`
- **Time:** 30 minutes
- **Done:** the worksheet comes back annotated in every window
- **Unblocks:** the measurement downstream of it

### 2.3 READY-FOR-CEO — Two things to open

- **Open:** `repo/docs/prepared.md` and `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** the worksheet comes back annotated in every window
- **Unblocks:** the measurement downstream of it
'
run_guard "$R"
if [ "$GRC" -eq 2 ] \
   && printf '%s' "$GOUT" | grep -qF 'ABSOLUTE-ARTIFACT-PATH' \
   && printf '%s' "$GOUT" | grep -qF 'UNKNOWN-ARTIFACT-PREFIX' \
   && printf '%s' "$GOUT" | grep -qF 'MULTIPLE-ARTIFACT-PATHS'; then
    ok "an absolute path, an undeclared prefix and two paths in one field are each refused"
else
    bad "malformed artifact paths should each be refused (rc=$GRC): $GOUT"
fi

# ---------------------------------------------------------------------------
# (e) THE TWO STATES
# ---------------------------------------------------------------------------
R="$(mk_repo blockedinceo)"
write_record "$R" '### 2.1 BLOCKED-ON-RICH — Nobody has prepared this yet

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** the worksheet comes back annotated in every window
- **Unblocks:** the measurement downstream of it
'
run_guard "$R"
if [ "$GRC" -eq 2 ] \
   && printf '%s' "$GOUT" | grep -qF 'BLOCKED-IN-CEO-SECTION' \
   && printf '%s' "$GOUT" | grep -qF 'section 3'; then
    ok "BLOCKED-ON-RICH inside a CEO section is refused, and the destination section is named"
else
    bad "a BLOCKED-ON-RICH item in a CEO section should be refused (rc=$GRC)"
fi

R="$(mk_repo nostate)"
write_record "$R" '### 2.1 Verify the podcast reference transcript

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** the worksheet comes back annotated in every window
- **Unblocks:** the measurement downstream of it
'
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'MALFORMED-HEADING'; then
    ok "an item heading with no state is refused, never treated as not-an-item"
else
    bad "a stateless heading should be refused (rc=$GRC)"
fi

# ---------------------------------------------------------------------------
# (f) FIELD QUALITY — a field that is filled but says nothing
# ---------------------------------------------------------------------------
R="$(mk_repo vague)"
write_record "$R" '### 2.1 READY-FOR-CEO — A time that is not a duration

- **Open:** `repo/docs/prepared.md`
- **Time:** soon
- **Done:** the worksheet comes back annotated in every window
- **Unblocks:** the measurement downstream of it

### 2.2 READY-FOR-CEO — A criterion that is not one

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** yes
- **Unblocks:** TBD
'
run_guard "$R"
if [ "$GRC" -eq 2 ] \
   && printf '%s' "$GOUT" | grep -qF 'TIME-NOT-A-DURATION' \
   && printf '%s' "$GOUT" | grep -qF 'DONE-TOO-VAGUE' \
   && printf '%s' "$GOUT" | grep -qF 'VACUOUS-FIELD'; then
    ok "'soon', 'yes' and 'TBD' fill a field without answering it, and are refused"
else
    bad "vacuous fields should be refused (rc=$GRC): $GOUT"
fi

# ---------------------------------------------------------------------------
# (g) NO SILENT NO-OP
# ---------------------------------------------------------------------------
R="$(mk_repo nosection)"
{
    printf '# Open items\n\n'
    printf '## 1. Waiting on the CEO — a decision\n\n'
    printf '%s\n' "$GOOD_ITEM_1"
    printf '%s\n' "$SECTION_3"
} > "$R/wiki/open-items.md"
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'CEO section 2'; then
    ok "deleting a declared CEO section is BROKEN, not a clean record with less to check"
else
    bad "a missing declared section should be broken (rc=$GRC): $GOUT"
fi

R="$(mk_repo norecord)"
run_guard "$R"
run_lint "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'NOT ON DISK' && [ "$LRC" -eq 3 ]; then
    ok "AN ABSENT RECORD IS ITS OWN OUTCOME — the guard blocks, the CLI exits 3, neither passes"
else
    bad "an absent record must be distinguishable (guard rc=$GRC, lint rc=$LRC)"
fi

R="$(mk_repo nodecl)"
rm -f "$R/.ceo-queue"
write_record "$R" '### 2.1 READY-FOR-CEO — anything at all'
run_lint "$R"
if [ "$LRC" -eq 2 ] && printf '%s' "$LOUT" | grep -qF 'not a pass'; then
    ok "the CLI pointed at an undeclared repository exits 2 and says so — never 0"
else
    bad "CLI on an undeclared repo should exit 2 (rc=$LRC)"
fi

# ---------------------------------------------------------------------------
# (h) POSITIVE CONTROLS — the ones that matter more than the blocks
# ---------------------------------------------------------------------------
R="$(mk_repo positive)"
write_record "$R" '### 2.1 READY-FOR-CEO — Verify the podcast reference transcript

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** every one of the 30 windows carries either OK or a written correction, handed back
- **Unblocks:** the first computable word error rate, and with it decision 1.3
'
# A second markdown file in the same repository, in the same directory, in a
# shape that would fail every rule above. It is not the declared record, so it
# is not read.
{
    printf '## 1. Waiting on the CEO — a decision\n\n'
    printf '### 1.1 — no state, no fields, no artifact, nothing\n'
} > "$R/wiki/some-other-page.md"
git -C "$R" add -A 2>/dev/null
run_guard "$R"
if [ "$GRC" -eq 0 ]; then
    ok "section-3 rows with no fields, and a different markdown file, are both untouched"
else
    bad "positive control failed (rc=$GRC): $GOUT"
fi

# ---------------------------------------------------------------------------
# (i) EVERY COMMIT, NOT ONLY THE ONES THAT TOUCH THE RECORD
# ---------------------------------------------------------------------------
R="$(mk_repo preexisting)"
write_record "$R" '### 2.1 READY-FOR-CEO — Verify the podcast reference transcript

- **Open:** `repo/docs/worksheet-that-was-never-written.md`
- **Time:** 30 minutes
- **Done:** every one of the 30 windows carries OK or a correction, handed back
- **Unblocks:** the first computable word error rate, and with it decision 1.3
'
printf 'unrelated work\n' > "$R/docs/unrelated.md"
git -C "$R" add docs/unrelated.md 2>/dev/null
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'PRE-EXISTING'; then
    ok "a commit that does not touch the record still catches a stale claim, and says PRE-EXISTING"
else
    bad "an unrelated commit should catch a pre-existing bad row (rc=$GRC): $GOUT"
fi

# The staged blob is what lands, so it is what is judged: a GOOD record in the
# index and a BAD one in the worktree must pass.
R="$(mk_repo stagedwins)"
write_record "$R" '### 2.1 READY-FOR-CEO — Verify the podcast reference transcript

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** every one of the 30 windows carries OK or a correction, handed back
- **Unblocks:** the first computable word error rate, and with it decision 1.3
'
git -C "$R" add wiki/open-items.md 2>/dev/null
printf '# Open items\n\n## 1. Waiting on the CEO — a decision\n\n### 1.1 broken\n' > "$R/wiki/open-items.md"
run_guard "$R"
if [ "$GRC" -eq 0 ]; then
    ok "the STAGED blob is judged, not the worktree copy — those are the bytes that land"
else
    bad "the staged blob should be the subject (rc=$GRC): $GOUT"
fi

# ---------------------------------------------------------------------------
# (j) BROKEN DECLARATIONS — every one BLOCKS
# ---------------------------------------------------------------------------
for decl_case in \
  'UNKNOWN_KEY="x"|unknown key' \
  'QUEUE_RECORD="wiki/open-items.md"
CEO_SECTIONS=""|CEO_SECTIONS is empty' \
  'QUEUE_RECORD="wiki/open-items.md"
CEO_SECTIONS="1 3"
PREPARER_SECTION="3"|BOTH' \
  'QUEUE_RECORD="/etc/passwd"|repository-relative' \
  'QUEUE_RECORD="wiki/open-items.md"
ARTIFACT_ROOTS="justaprefix"|<prefix>=<root>' ; do
    body="${decl_case%|*}"
    want="${decl_case##*|}"
    R="$(mk_repo "decl$$RANDOM" "$body")"
    write_record "$R" '### 2.1 READY-FOR-CEO — anything'
    run_guard "$R"
    if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF "$want"; then
        ok "broken declaration refused: $want"
    else
        bad "broken declaration should refuse naming '$want' (rc=$GRC): $GOUT"
    fi
done

# ---------------------------------------------------------------------------
# (k) FAIL-CLOSED conventions
# ---------------------------------------------------------------------------
FAKEBIN="$(mktemp -d -t cqtest-bin.XXXXXX)"
for t in bash git grep sed cat mktemp printf head cut tail rm cp; do
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

TMPENG="$(mktemp -d -t cqtest-eng.XXXXXX)"
mkdir -p "$TMPENG/scripts/hooks" "$TMPENG/scripts/lib"
cp "$GUARD" "$TMPENG/scripts/hooks/"
cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" "$TMPENG/scripts/lib/"
rc=0
out="$(printf '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"git commit -m x"}}' \
       | "$BASH_BIN" "$TMPENG/scripts/hooks/guard-ceo-queue-commits.sh" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF "ceo-queue.sh is missing"; then
    ok "a missing predicate library is a LOUD refusal, never a quiet skip"
else
    bad "missing predicate library should block loudly (rc=$rc)"
fi
rm -rf "$TMPENG"

# ---------------------------------------------------------------------------
# (l) REGISTRATION — both surfaces, or the engine ships a guard nobody loads
# ---------------------------------------------------------------------------
G=guard-ceo-queue-commits.sh
if grep -q "$G" "$ENGINE_ROOT/hooks/hooks.json" 2>/dev/null; then
    ok "$G registered in hooks/hooks.json (plugin surface)"
else
    bad "$G NOT registered in hooks/hooks.json"
fi
if grep -q "$G" "$ENGINE_ROOT/.claude/settings.local.json" 2>/dev/null; then
    ok "$G registered in .claude/settings.local.json (seated surface)"
else
    bad "$G NOT registered in .claude/settings.local.json"
fi
if grep -q "^${G}|PreToolUse" "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" 2>/dev/null; then
    ok "$G declared in the probe's BR_EXPECTED oracle, on PreToolUse"
else
    bad "$G NOT declared in the probe's managed set"
fi
if grep -q "guard-ceo-queue-commits" "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" 2>/dev/null \
   && grep -q "guard-ceo-queue-commits \\\\" "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" 2>/dev/null; then
    ok "$G listed among Layer R's root-resolving hooks"
else
    bad "$G NOT listed in Layer R's rooted-hook set — its bootstrap would go unchecked"
fi
for lib in scripts/lib/ceo-queue.sh scripts/lib/ceo-queue.py; do
    if grep -q "$lib" "$ENGINE_ROOT/scripts/hooks/install.sh" 2>/dev/null; then
        ok "$lib is sidecar-hashed by install.sh (the guard delegates its whole decision to it)"
    else
        bad "$lib NOT hashed by install.sh"
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
