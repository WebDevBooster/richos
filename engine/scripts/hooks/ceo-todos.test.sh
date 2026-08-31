#!/usr/bin/env bash
#
# ceo-todos.test.sh — regression tests for the CEO-TODOs mechanism:
# scripts/lib/ceo-todos.sh, scripts/lib/ceo-todos.py, the CLI
# scripts/ceo-todos-lint.sh, and the guard that runs them at every commit
# (scripts/hooks/guard-ceo-todos-commits.sh).
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
#   (a) STAND-DOWN — a repository with no .ceo-todos is untouched. This is the
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
# Run directly: scripts/hooks/ceo-todos.test.sh
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

GUARD="$SCRIPT_DIR/guard-ceo-todos-commits.sh"
LINT="$ENGINE_ROOT/scripts/ceo-todos-lint.sh"
BASH_BIN="$(command -v bash)"

PASS=0
FAIL=0
SCRATCH="$(mktemp -d -t cqtest.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

for f in "$GUARD" "$LINT" "$ENGINE_ROOT/scripts/lib/ceo-todos.sh" "$ENGINE_ROOT/scripts/lib/ceo-todos.py"; do
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
    # A COMPLETE surface, not just a record: an entry point named at the head of
    # a README. Every fixture starts REACHABLE so that a case which fails does
    # so for the reason it is testing — and so the reachability cases below have
    # something real to break.
    printf '# A repo\n\nStart at [CEO-TODOs.md](CEO-TODOs.md).\n' > "$repo/README.md"
    if [ "$#" -ge 2 ]; then
        printf '%s\n' "$2" > "$repo/.ceo-todos"
    else
        {
            echo 'TODO_RECORD="wiki/open-items.md"'
            echo 'TODO_VIEW="CEO-TODOs.md"'
            echo 'ROOT_README="README.md"'
            echo 'CEO_SECTIONS="1 2"'
            echo 'PREPARER_SECTION="3"'
            echo 'ARTIFACT_ROOTS="repo=. nowhere=../no-such-sibling-repository"'
        } > "$repo/.ceo-todos"
    fi
    printf '%s' "$repo"
}

# The view is a PROJECTION. Every fixture regenerates it after writing the
# record, exactly as a person is expected to — so a stale-view failure in a case
# that is not about staleness would be the fixture's fault, not the predicate's.
sync_view() {
    "$BASH_BIN" "$ENGINE_ROOT/scripts/ceo-todos-render.sh" "$1" >/dev/null 2>&1 || true
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
    sync_view "$repo"
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

echo "=== ceo-todos: the predicate, the CLI and the commit guard ==="

# ---------------------------------------------------------------------------
# (a) STAND-DOWN — the precision floor
# ---------------------------------------------------------------------------
R="$(mk_repo standdown)"
rm -f "$R/.ceo-todos"
write_record "$R" '### 2.1 READY-FOR-CEO — nothing here is valid'
run_guard "$R"
if [ "$GRC" -eq 0 ]; then
    ok "a repository with no .ceo-todos is untouched, however bad its record"
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
rm -f "$R/.ceo-todos"
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
  'TODO_RECORD="wiki/open-items.md"
CEO_SECTIONS=""|CEO_SECTIONS is empty' \
  'TODO_RECORD="wiki/open-items.md"
CEO_SECTIONS="1 3"
PREPARER_SECTION="3"|BOTH' \
  'TODO_RECORD="/etc/passwd"|repository-relative' \
  'TODO_RECORD="wiki/open-items.md"
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
# (k) THE 2026-08-29 RENAME — a legacy declaration is READ, ENFORCED, AND LOUD
# ---------------------------------------------------------------------------
# "queue" was the British word and the CEO removed it. The rename's real hazard
# is not the spelling: `.ceo-queue` was STRICT-PARSED, so a clean cut would make
# every un-migrated repository's guard stand down SILENTLY — the exact failure
# class this mechanism exists to remove. So the old name still works, still
# blocks, and still says so. These cases hold that contract in place; without
# them the alias is one tidy-up commit away from becoming a silent switch-off.
LEGACY_DECL='QUEUE_RECORD="wiki/open-items.md"
QUEUE_VIEW="CEO-TODOs.md"
ROOT_README="README.md"
CEO_SECTIONS="1 2"
PREPARER_SECTION="3"
ARTIFACT_ROOTS="repo=."'

R="$(mk_repo legacyname "$LEGACY_DECL")"
mv "$R/.ceo-todos" "$R/.ceo-queue"
write_record "$R" '### 2.1 READY-FOR-CEO — anything

- **Open:** `repo/docs/prepared.md`
- **Time:** 5 minutes
- **Done:** a ruling is recorded on the decisions page
- **Unblocks:** the next thing
'
run_lint "$R"
if [ "$LRC" -eq 0 ]; then
    ok "a pre-rename .ceo-queue is still READ and still enforced — no silent stand-down"
else
    bad "a legacy .ceo-queue declaration should still be enforced (rc=$LRC): $LOUT"
fi
if printf '%s' "$LOUT" | grep -qF 'LEGACY-DECLARATION-NAME' \
   && printf '%s' "$LOUT" | grep -qF 'git mv .ceo-queue .ceo-todos'; then
    ok "...and a CLEAN verdict still names the legacy file and the exact rename command"
else
    bad "a clean run over a legacy declaration must still print the migration notice: $LOUT"
fi
if printf '%s' "$LOUT" | grep -qF 'LEGACY-DECLARATION-KEYS' \
   && printf '%s' "$LOUT" | grep -qF 'QUEUE_RECORD'; then
    ok "...and the legacy KEY names are translated and named, not silently accepted"
else
    bad "legacy QUEUE_RECORD/QUEUE_VIEW keys must be reported: $LOUT"
fi
run_guard "$R"
if [ "$GRC" -eq 0 ] && printf '%s' "$GOUT" | grep -qF 'LEGACY-DECLARATION-NAME'; then
    ok "...and the COMMIT GUARD enforces the legacy declaration and prints the notice too"
else
    bad "the commit guard must enforce a legacy declaration and say so (rc=$GRC): $GOUT"
fi

# The same repository, now failing: a legacy declaration must still BLOCK.
write_record "$R" '### 2.2 READY-FOR-CEO — a row with no fields at all'
run_guard "$R"
if [ "$GRC" -eq 2 ]; then
    ok "...and an unprepared item under the legacy name is still REFUSED, not waved through"
else
    bad "a legacy declaration must still block an unprepared item (rc=$GRC): $GOUT"
fi

# Both files present: two declarations are two answers. Refuse, never guess.
R="$(mk_repo legacyboth)"
cp "$R/.ceo-todos" "$R/.ceo-queue"
write_record "$R" ''
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'BOTH'; then
    ok "carrying BOTH .ceo-todos and .ceo-queue is BROKEN — the mechanism never picks one quietly"
else
    bad "both declarations present should refuse as ambiguous (rc=$GRC): $GOUT"
fi

# init must not write a second declaration beside a legacy one — that is the
# ambiguity above, manufactured by the tool that is supposed to help.
R2="$(mk_repo legacyinit)"
mv "$R2/.ceo-todos" "$R2/.ceo-queue"
IOUT="$("$BASH_BIN" "$ENGINE_ROOT/scripts/ceo-todos-init.sh" "$R2" 2>&1)"; IRC=$?
if [ "$IRC" -eq 2 ] && printf '%s' "$IOUT" | grep -qF 'git -C'; then
    ok "ceo-todos-init.sh REFUSES a repo that already declares under the old name, and gives the rename"
else
    bad "init should refuse beside a legacy declaration and print the rename (rc=$IRC): $IOUT"
fi

# ---------------------------------------------------------------------------
# (m) THE ENTRY POINT — prepared is half; reachable is the other half
# ---------------------------------------------------------------------------
# The defect these replay: nine PREPARED items, a green lint, a firing guard —
# and the CEO could not find any of it, because the only new file was a dotfile
# and the items were buried in a 173-line record. Every criterion in that
# landing was internal. These are the criteria that are not.
RENDER="$ENGINE_ROOT/scripts/ceo-todos-render.sh"
COLDOPEN="$ENGINE_ROOT/scripts/cold-open.sh"
INIT="$ENGINE_ROOT/scripts/ceo-todos-init.sh"

DECL_NO_VIEW='TODO_RECORD="wiki/open-items.md"
CEO_SECTIONS="1 2"
PREPARER_SECTION="3"
ARTIFACT_ROOTS="repo=."'

R="$(mk_repo noview "$DECL_NO_VIEW")"
write_record "$R" ''
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'NO-ENTRY-POINT-DECLARED'; then
    ok "TODOs with NO declared entry point are refused — TODOs nobody can find are TODOs nobody has"
else
    bad "TODOs with no TODO_VIEW should be refused (rc=$GRC)"
fi

R="$(mk_repo noviewfile)"
write_record "$R" ''
rm -f "$R/CEO-TODOs.md"
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'ENTRY-POINT-MISSING'; then
    ok "a declared entry point that is not on disk is refused"
else
    bad "a missing entry point should be refused (rc=$GRC)"
fi

# THE REAL FAILURE, REPLAYED: change the record, forget to regenerate the page.
# This is the exact gap that was flagged in a commit message and shipped past.
R="$(mk_repo staleview)"
write_record "$R" ''
git -C "$R" add -A >/dev/null 2>&1
sed -i.bak 's/A decision that is prepared/A decision that is prepared, retitled/' "$R/wiki/open-items.md"
rm -f "$R/wiki/open-items.md.bak"
git -C "$R" add wiki/open-items.md >/dev/null 2>&1
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'ENTRY-POINT-STALE'; then
    ok "THE STALENESS GAP: a record edited without regenerating the page is REFUSED at commit"
else
    bad "a stale entry point should be refused (rc=$GRC): $GOUT"
fi
# ...and the same commit passes the moment the page is regenerated. A gate with
# no green path is a gate people route around.
sync_view "$R"
git -C "$R" add -A >/dev/null 2>&1
run_guard "$R"
if [ "$GRC" -eq 0 ]; then
    ok "regenerating the page clears the refusal — the fix the message names actually works"
else
    bad "a regenerated page should pass (rc=$GRC): $GOUT"
fi

# The STAGED view is judged, not the worktree copy: the bytes that land.
R="$(mk_repo stagedview)"
write_record "$R" ''
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
printf 'hand-edited nonsense\n' > "$R/CEO-TODOs.md"
git -C "$R" add CEO-TODOs.md >/dev/null 2>&1
sync_view "$R"                     # worktree is fine again; the INDEX is not
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'ENTRY-POINT-STALE'; then
    ok "the STAGED page is judged, not the worktree copy — a fixed worktree cannot smuggle a stale blob"
else
    bad "a staged stale view should be refused (rc=$GRC)"
fi

DECL_DOTFILE='TODO_RECORD="wiki/open-items.md"
TODO_VIEW=".ceo-todos.md"
CEO_SECTIONS="1 2"
PREPARER_SECTION="3"
ARTIFACT_ROOTS="repo=."'
R="$(mk_repo dotview "$DECL_DOTFILE")"
write_record "$R" ''
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'ENTRY-POINT-IS-A-DOTFILE'; then
    ok "a DOTFILE entry point is refused — the CEO's actual complaint, as a check"
else
    bad "a dotfile entry point should be refused (rc=$GRC)"
fi

R="$(mk_repo notinreadme)"
write_record "$R" ''
printf '# A repo\n\nNothing here points anywhere.\n' > "$R/README.md"
sync_view "$R"
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'ENTRY-POINT-NOT-DISCOVERABLE'; then
    ok "an entry point the root README does not name is refused — a search is not an entry point"
else
    bad "an undiscoverable entry point should be refused (rc=$GRC)"
fi

R="$(mk_repo buriedinreadme)"
write_record "$R" ''
{ printf '# A repo\n'; for i in $(seq 1 60); do printf 'filler line %s\n' "$i"; done
  printf 'see CEO-TODOs.md\n'; } > "$R/README.md"
sync_view "$R"
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'ENTRY-POINT-NOT-DISCOVERABLE'; then
    ok "naming the entry point at README line 61 does not count as naming it"
else
    bad "a buried pointer should be refused (rc=$GRC)"
fi

R="$(mk_repo twoviews)"
write_record "$R" ''
cp "$R/CEO-TODOs.md" "$R/CEO-TODOs-COPY.md"
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'MULTIPLE-ENTRY-POINTS'; then
    ok "a COPY of the generated page at the top level is refused — one list, one page"
else
    bad "a second generated page should be refused (rc=$GRC)"
fi

# ---------------------------------------------------------------------------
# (n) THE COLD OPEN — the machine enforces that it happened, never its verdict
# ---------------------------------------------------------------------------
DECL_COLD='TODO_RECORD="wiki/open-items.md"
TODO_VIEW="CEO-TODOs.md"
CEO_SECTIONS="1 2"
PREPARER_SECTION="3"
ARTIFACT_ROOTS="repo=."
COLD_OPEN_DIR="docs/cold-open"'

# file_transcript <repo> <answer-text> — via the real --record path, so the
# fingerprints are stamped by the harness and never typed by this suite.
file_transcript() {
    local repo="$1" body="$2" ans
    ans="$(mktemp -t cq-answer.XXXXXX)"
    printf '%s\n' "$body" > "$ans"
    "$BASH_BIN" "$COLDOPEN" --record "$repo" --from "$ans" --reader "a stub reader (test)" >/dev/null 2>&1
    local rc=$?
    rm -f "$ans"
    return $rc
}

LONG_ANSWER='## 1. What is this repository
I could not tell you what this repository is for. The front page talks about a
product and never says what I am supposed to do with any of it.
## 2. Where do I start
I genuinely could not work it out. I opened the README and it told me nothing
actionable, so I guessed, and I would probably have given up at this point.
## 5. What confused me
All of it. This surface is bad and I would not use it again.'

R="$(mk_repo coldnever "$DECL_COLD")"
write_record "$R" ''
mkdir -p "$R/docs/cold-open"
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'COLD-OPEN-NEVER-RUN'; then
    ok "declaring a cold open and never doing one is refused, and says nobody has read it from outside"
else
    bad "a never-run cold open should be refused (rc=$GRC)"
fi

# THE LINE THE MACHINE DOES NOT CROSS. This transcript says the surface is
# incomprehensible and that the reader would have given up. It satisfies the
# gate completely. A gate that demanded a favourable verdict would get one every
# time, and the finding — the only output worth having — would be the one that
# costs its author a blocked commit.
if file_transcript "$R" "$LONG_ANSWER"; then
    run_guard "$R"
    if [ "$GRC" -eq 0 ]; then
        ok "a transcript reporting the surface is BAD satisfies the gate — it enforces that a reader was asked, never what he said"
    else
        bad "an unfavourable transcript should still satisfy the gate (rc=$GRC): $GOUT"
    fi
else
    bad "--record failed to file a transcript"
fi

# Change the front door; the same transcript now describes a page that is gone.
printf '# A repo\n\nA COMPLETELY DIFFERENT front page. Start at [CEO-TODOs.md](CEO-TODOs.md).\n' > "$R/README.md"
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'COLD-OPEN-STALE'; then
    ok "changing the front door makes every existing transcript stale — identity or refuse, applied to a judgment"
else
    bad "a changed front door should invalidate the transcript (rc=$GRC)"
fi

R="$(mk_repo coldempty "$DECL_COLD")"
write_record "$R" ''
file_transcript "$R" 'nothing' >/dev/null 2>&1
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qE 'COLD-OPEN-(TRANSCRIPT-MALFORMED|NEVER-RUN)'; then
    ok "an empty transcript does not satisfy the gate — it would prove nobody read anything"
else
    bad "an empty transcript should not satisfy the gate (rc=$GRC)"
fi

R="$(mk_repo coldnotdeclared)"
write_record "$R" ''
run_guard "$R"
if [ "$GRC" -eq 0 ] && printf '%s' "$GOUT" | grep -qF 'COLD-OPEN-NOT-DECLARED'; then
    ok "NOT declaring a cold open never blocks — and every clean pass says out loud that nobody outside has read it"
else
    bad "an undeclared cold open should pass while printing the limit (rc=$GRC): $GOUT"
fi

# ---------------------------------------------------------------------------
# (o) THE RENDERER — one parse, deterministic, and reachable by an adopter
# ---------------------------------------------------------------------------
R="$(mk_repo renderdet)"
write_record "$R" ''
A="$("$BASH_BIN" "$RENDER" --stdout "$R" 2>/dev/null)"
B="$("$BASH_BIN" "$RENDER" --stdout "$R" 2>/dev/null)"
if [ -n "$A" ] && [ "$A" = "$B" ]; then
    ok "the render is deterministic — byte-comparison is only a gate if the same input gives the same bytes"
else
    bad "the render is not deterministic"
fi

printf 'hand-edited\n' > "$R/CEO-TODOs.md"
"$BASH_BIN" "$RENDER" --check "$R" >/dev/null 2>&1
if [ "$?" -eq 1 ]; then
    ok "--check reports a stale page as exit 1 and writes nothing"
else
    bad "--check should exit 1 on a stale page"
fi

# THE FRESH ADOPTER. For one release the engine shipped this whole mechanism
# with no declaration, no template and no mention in the runbook — so every
# adopter received enforcement that could never fire, and nothing told them.
# This is that customer, and the assertion is that one command hands them a
# working, lint-clean TODO list with a page on it.
FRESH="$SCRATCH/freshadopter"
mkdir -p "$FRESH"
git -C "$FRESH" init -q
printf '# Some company\n\nWe do things.\n' > "$FRESH/README.md"
IOUT="$("$BASH_BIN" "$INIT" "$FRESH" --no-cold-open 2>&1)"; IRC=$?
if [ "$IRC" -eq 0 ] && [ -f "$FRESH/.ceo-todos" ] && [ -f "$FRESH/CEO-TODOs.md" ]; then
    ok "a FRESH ADOPTER gets a working TODO list from one command — declaration, record and a page"
else
    bad "ceo-todos-init.sh should give a fresh repo a working TODO list (rc=$IRC): $IOUT"
fi
if head -40 "$FRESH/README.md" | grep -qF 'CEO-TODOs.md'; then
    ok "...and their root README points at it, so the page is reachable and not merely present"
else
    bad "init should point the root README at the entry point"
fi
if grep -qF 'Nothing is waiting on you' "$FRESH/CEO-TODOs.md"; then
    ok "...and an EMPTY list still renders a real page, so the surface exists from minute one"
else
    bad "an empty list should still render a page"
fi
run_lint "$FRESH"
if [ "$LRC" -eq 0 ]; then
    ok "...and it is lint-clean immediately — the machinery is live, not inert"
else
    bad "a freshly initialized repo should be lint-clean (rc=$LRC): $LOUT"
fi
IOUT="$("$BASH_BIN" "$INIT" "$FRESH" --no-cold-open 2>&1)"; IRC=$?
if [ "$IRC" -eq 2 ] && printf '%s' "$IOUT" | grep -qF 'already declares'; then
    ok "init REFUSES to overwrite an existing declaration rather than silently replacing it"
else
    bad "init should refuse to clobber an existing declaration (rc=$IRC)"
fi

for f in reference/ceo-todos/ceo-todos.example reference/ceo-todos/open-items.md \
         reference/ceo-todos/cold-open-README.md scripts/lib/cold-open-prompt.md; do
    if [ -f "$ENGINE_ROOT/$f" ]; then
        ok "the engine ships $f — an adopter cannot switch this on without it"
    else
        bad "$f is MISSING from the engine — adopters would get enforcement with no way to enable it"
    fi
done

# ---------------------------------------------------------------------------
# (p) THE DONE-CHECK — an item that can notice it is already finished
# ---------------------------------------------------------------------------
# THE FAILURE THIS CLOSES, 2026-08-31: the app icon was made and landed, and
# item 2.6 of the real record went on asking the CEO to supply the artwork that
# already existed. He found it himself. The guard was green throughout and was
# not wrong — "supply the artwork" is perfectly well-formed while the artwork
# exists. Form is not currency.
#
# The four cases the fix has to satisfy are the first four below, in order.

DC_ITEM_SATISFIED='### 2.6 READY-FOR-CEO — Supply the app icon artwork

- **Open:** `repo/docs/prepared.md`
- **Time:** 20 minutes
- **Done:** a 1024x1024 PNG is handed over and the generator accepts it
- **Unblocks:** the packaged app stops shipping the default Tauri icon
- **Done-check:** `exists repo/docs/artwork.png`
'

# 1 — SATISFIED, still sitting in the CEO's section.
R="$(mk_repo dcsatisfied)"
printf 'the artwork, made and landed hours ago\n' > "$R/docs/artwork.png"
write_record "$R" "$DC_ITEM_SATISFIED"
run_guard "$R"
if [ "$GRC" -eq 2 ] \
   && printf '%s' "$GOUT" | grep -qF 'DONE-ALREADY-SATISFIED' \
   && printf '%s' "$GOUT" | grep -qF 'item 2.6' \
   && printf '%s' "$GOUT" | grep -qF 'repo/docs/artwork.png'; then
    ok  "p1. THE 2026-08-31 FAILURE: an item whose Done condition already holds is REFUSED, by id"
else
    bad "p1. a satisfied Done condition in a CEO section should block, naming the item (rc=$GRC): $GOUT"
fi

# 2 — the same item removed. The only two answers the refusal offers are
#     "close it" and "the check is wrong"; this is the first one.
R="$(mk_repo dcremoved)"
printf 'the artwork, made and landed hours ago\n' > "$R/docs/artwork.png"
write_record "$R" '_Nothing here._'
run_guard "$R"
if [ "$GRC" -eq 0 ]; then
    ok  "p2. ...and removing that item from the section is all it takes to proceed"
else
    bad "p2. the record without the finished item should pass (rc=$GRC): $GOUT"
fi

# 3 — UNAUTOMATABLE: silent, WITH A POSITIVE PROBE. This case is the one that
#     rots quietest: the correct outcome is silence, and silence is also what a
#     checker that never ran produces. So the assertion is not "it passed" — it
#     is "it passed AND the census says the evaluator looked at it".
R="$(mk_repo dcmanual)"
write_record "$R" '### 2.1 READY-FOR-CEO — Verify the podcast reference transcript

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** every one of the 30 windows carries either OK or a written correction, handed back
- **Unblocks:** the first computable word error rate, and with it decision 1.3
- **Done-check:** `manual "he must read along to the audio; no file state distinguishes done from not-started"`
'
run_guard "$R"
if [ "$GRC" -eq 0 ] \
   && printf '%s' "$GOUT" | grep -qF 'manual' \
   && printf '%s' "$GOUT" | grep -q 'Done-checks: [1-9][0-9]* evaluated'; then
    ok  "p3. an unautomatable item is SILENT — and the census proves the silence is a decision, not a checker that never ran"
else
    bad "p3. a manual Done-check should pass and still be counted (rc=$GRC): $GOUT"
fi

# 3b — THE POSITIVE PROBE, PROVED POSITIVE. The same assertion must be capable
#      of failing: a record whose only item declares nothing must NOT report an
#      evaluation. Without this, case 3 would pass against a census hard-coded
#      to say a comforting number.
R="$(mk_repo dcnocensus)"
write_record "$R" '### 2.1 READY-FOR-CEO — An item that declares no end state at all

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** somebody eventually notices this is finished
- **Unblocks:** the measurement downstream of it
'
run_lint "$R"
if [ "$LRC" -eq 0 ] \
   && printf '%s' "$LOUT" | grep -q 'Done-checks: 0 evaluated' \
   && printf '%s' "$LOUT" | grep -qF 'DONE-NOT-MACHINE-CHECKED' \
   && printf '%s' "$LOUT" | grep -qF '2.1'; then
    ok  "p4. ...and a record with no Done-checks reports ZERO evaluated and names every item that carries none"
else
    bad "p4. an unchecked record should report 0 evaluated and name the items (rc=$LRC): $LOUT"
fi

# 4 — BROKEN: a check that cannot run is LOUD, and specifically is never
#     allowed to read as "not done yet". That collapse is the whole failure
#     class: it turns a typo into a permanently green check.
R="$(mk_repo dcbroken)"
write_record "$R" '### 2.1 READY-FOR-CEO — Its check points at a page that was renamed

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** the ruling is written on the decisions page
- **Unblocks:** the measurement downstream of it
- **Done-check:** `contains repo/docs/page-that-was-renamed.md "^RULED:"`
'
run_guard "$R"
if [ "$GRC" -eq 2 ] \
   && printf '%s' "$GOUT" | grep -qF 'DONE-CHECK-BROKEN' \
   && printf '%s' "$GOUT" | grep -qF "not done yet"; then
    ok  "p5. a Done-check that cannot be evaluated BLOCKS, and says in words that it is not 'not done yet'"
else
    bad "p5. an unevaluable Done-check should block loudly (rc=$GRC): $GOUT"
fi

# --- the four verbs, both answers each -------------------------------------
dc_case() {
    # dc_case <name> <done-check-expr> <expected: block|pass> <label>
    local name="$1" expr="$2" want="$3" label="$4" repo
    repo="$(mk_repo "$name")"
    printf 'RULED: individual enrollment.\n' > "$repo/docs/decided.md"
    printf 'Status: OPEN, nobody has ruled.\n' > "$repo/docs/undecided.md"
    mkdir -p "$repo/docs/adirectory"
    write_record "$repo" "### 2.1 READY-FOR-CEO — A verb under test

- **Open:** \`repo/docs/prepared.md\`
- **Time:** 30 minutes
- **Done:** the end state described by the check beside this line
- **Unblocks:** the measurement downstream of it
- **Done-check:** $expr
"
    run_guard "$repo"
    if [ "$want" = "block" ]; then
        [ "$GRC" -eq 2 ] && { ok "$label"; return; }
        bad "$label — expected a block, got rc=$GRC: $GOUT"
    else
        [ "$GRC" -eq 0 ] && { ok "$label"; return; }
        bad "$label — expected a pass, got rc=$GRC: $GOUT"
    fi
}

dc_case dcexistsyes  '`exists repo/docs/decided.md`'                        block "p6. exists: the file is there, so the item is finished and is refused"
dc_case dcexistsno   '`exists repo/docs/not-written-yet.md`'                pass  "p7. exists: the file is not there, so the item is correctly still open"
dc_case dccontyes    '`contains repo/docs/decided.md "^RULED:"`'            block "p8. contains: the ruling is on the page, so the item is finished and is refused"
dc_case dccontno     '`contains repo/docs/undecided.md "^RULED:"`'          pass  "p9. contains: the ruling is not on the page yet, so the item stays open"
dc_case dclacksyes   '`lacks repo/docs/decided.md "OPEN"`'                  block "p10. lacks: the OPEN marker is gone, so the item is finished and is refused"
dc_case dclacksno    '`lacks repo/docs/undecided.md "OPEN"`'                pass  "p11. lacks: the OPEN marker is still there, so the item stays open"

# --- every way of writing it wrong is LOUD ---------------------------------
dc_case dcnoverb     '`frobnicate repo/docs/decided.md`'                    block "p12. an unknown verb is refused, never ignored"
dc_case dcrun        '`run "scripts/generate-app-icons.sh in.png"`'         block "p13. there is NO verb that runs a command, and asking for one is refused by name"
dc_case dcnotick     'exists repo/docs/decided.md'                          block "p14. an expression that is not in one backticked span is refused"
dc_case dctwotick    '`exists repo/docs/decided.md` and `exists repo/docs/undecided.md`' block "p15. two backticked spans in one check are refused — one item, one check"
dc_case dcbadre      '`contains repo/docs/decided.md "([unclosed"`'         block "p16. a pattern that is not a valid regular expression is refused, not silently unmatched"
dc_case dcabs        '`exists /etc/hosts`'                                  block "p17. an absolute path is refused; it would be wrong on any other machine"
dc_case dcdotdot     '`exists repo/../../../etc/hosts`'                     block "p18. a path that walks out of its declared root is refused"
dc_case dcbareroot   '`exists repo`'                                        block "p19. a bare repository root is not a thing to check"
dc_case dcunkpfx     '`exists elsewhere/docs/decided.md`'                   block "p20. an undeclared artifact prefix is refused, naming what is declared"
dc_case dcbaremanual '`manual`'                                             block "p21. a bare \`manual\` is refused: it must say WHY, or it is a way to switch the check off"
dc_case dcdir        '`contains repo/docs/adirectory "x"`'                  block "p22. a directory is not a file this check can read"
dc_case dcargs       '`contains repo/docs/decided.md "a" "b"`'              block "p23. contains takes exactly one pattern"

# The refusal for `run` has to explain itself, or the next person writes it again.
R="$(mk_repo dcrunwords)"
write_record "$R" '### 2.1 READY-FOR-CEO — A check that wants to run a program

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** the generator prints OK and exits 0
- **Unblocks:** the measurement downstream of it
- **Done-check:** `run "scripts/generate-app-icons.sh in.png"`
'
run_guard "$R"
if printf '%s' "$GOUT" | grep -qF 'no verb that runs a command'; then
    ok  "p24. ...and it says WHY there is no such verb, so the next person does not rediscover it"
else
    bad "p24. the run refusal should explain itself: $GOUT"
fi

# --- an absent root is SKIPPED and NAMED, exactly as an artifact path is ----
R="$(mk_repo dcabsentroot)"
write_record "$R" '### 2.1 READY-FOR-CEO — Its end state lives in a repository nobody cloned

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** the protocol is filled in on a machine we do not have
- **Unblocks:** the measurement downstream of it
- **Done-check:** `exists nowhere/docs/protocol.md`
'
run_guard "$R"
if [ "$GRC" -eq 0 ]; then
    run_lint "$R"
    if printf '%s' "$LOUT" | grep -qF 'not on this machine' \
       && printf '%s' "$LOUT" | grep -q 'Done-checks: 1 evaluated'; then
        ok  "p25. a Done-check under a root nobody cloned is SKIPPED and NAMED, never a block and never invisible"
    else
        bad "p25. an absent-root Done-check should be named in the verdict: $LOUT"
    fi
else
    bad "p25. an absent-root Done-check must not block (rc=$GRC): $GOUT"
fi

# --- the near-miss key, which is how this mechanism would actually die ------
R="$(mk_repo dctypo)"
printf 'the artwork, made and landed hours ago\n' > "$R/docs/artwork.png"
write_record "$R" '### 2.6 READY-FOR-CEO — Supply the app icon artwork

- **Open:** `repo/docs/prepared.md`
- **Time:** 20 minutes
- **Done:** a 1024x1024 PNG is handed over and the generator accepts it
- **Unblocks:** the packaged app stops shipping the default Tauri icon
- **Done-Check:** `exists repo/docs/artwork.png`
'
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'UNKNOWN-FIELD'; then
    ok  "p26. a near-miss key ('Done-Check') is REFUSED — silently ignoring it would switch the check off under a green verdict"
else
    bad "p26. an unknown item field should be refused (rc=$GRC): $GOUT"
fi

# --- DONE_CHECK_REQUIRED — the owner's decision, and a visible one ---------
DECL_REQUIRED='TODO_RECORD="wiki/open-items.md"
TODO_VIEW="CEO-TODOs.md"
ROOT_README="README.md"
CEO_SECTIONS="1 2"
PREPARER_SECTION="3"
ARTIFACT_ROOTS="repo=."
DONE_CHECK_REQUIRED="1"'

R="$(mk_repo dcrequired "$DECL_REQUIRED")"
write_record "$R" '### 2.1 READY-FOR-CEO — An item that declares no end state at all

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** somebody eventually notices this is finished
- **Unblocks:** the measurement downstream of it
'
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'DONE-CHECK-MISSING'; then
    ok  "p27. DONE_CHECK_REQUIRED=1 turns the notice into a refusal"
else
    bad "p27. with DONE_CHECK_REQUIRED=1 a missing check should block (rc=$GRC): $GOUT"
fi

R="$(mk_repo dcnotrequired)"
write_record "$R" '### 2.1 READY-FOR-CEO — An item that declares no end state at all

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** somebody eventually notices this is finished
- **Unblocks:** the measurement downstream of it
'
run_guard "$R"
if [ "$GRC" -eq 0 ] && printf '%s' "$GOUT" | grep -qF 'DONE-NOT-MACHINE-CHECKED'; then
    ok  "p28. ...and by DEFAULT it is a notice on every verdict, so this shipped without wedging any existing record"
else
    bad "p28. the default must not block, and must still say so (rc=$GRC): $GOUT"
fi

R="$(mk_repo dcbadflag "$(printf '%s\n' "$DECL_REQUIRED" | sed 's/DONE_CHECK_REQUIRED="1"/DONE_CHECK_REQUIRED="sometimes"/')")"
write_record "$R" '### 2.1 READY-FOR-CEO — Anything at all

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** a ruling recorded on the decisions page
- **Unblocks:** the measurement downstream of it
'
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'DONE_CHECK_REQUIRED'; then
    ok  "p29. an unreadable DONE_CHECK_REQUIRED is a BROKEN declaration, never a quiet 'off'"
else
    bad "p29. a bad DONE_CHECK_REQUIRED should be refused (rc=$GRC): $GOUT"
fi

# --- a pattern that will not finish is refused, not waited on --------------
# A guard that hangs blocks every commit in the repository until somebody kills
# it, and then somebody removes the guard. This case costs the suite the bound
# itself (a few seconds) and is worth it.
R="$(mk_repo dctimeout)"
python3 -c "open('$R/docs/pathological.md','w').write('a'*40 + 'c')"
write_record "$R" '### 2.1 READY-FOR-CEO — Its check backtracks forever

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** the page carries the marker
- **Unblocks:** the measurement downstream of it
- **Done-check:** `contains repo/docs/pathological.md "^(a+)+b$"`
'
run_guard "$R"
if [ "$GRC" -eq 2 ] && printf '%s' "$GOUT" | grep -qF 'did not finish'; then
    ok  "p30. a pattern that will not finish is REFUSED within a stated bound, not waited on forever"
else
    bad "p30. a pathological pattern should be bounded and refused (rc=$GRC): $GOUT"
fi

# --- the CEO's page says which items can close themselves ------------------
R="$(mk_repo dcrender)"
printf 'Status: OPEN, nobody has ruled.\n' > "$R/docs/undecided.md"
write_record "$R" '### 2.1 READY-FOR-CEO — One that closes itself

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** the ruling is written on the decisions page
- **Unblocks:** the measurement downstream of it
- **Done-check:** `lacks repo/docs/undecided.md "OPEN"`

### 2.2 READY-FOR-CEO — One that nobody can check for him

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** he has read along to the audio and marked every window
- **Unblocks:** the measurement downstream of it
- **Done-check:** `manual "he must read along to the audio; no file state distinguishes done from not-started"`
'
VIEW="$(cat "$R/CEO-TODOs.md" 2>/dev/null || true)"
if printf '%s' "$VIEW" | grep -qF 'Closes itself when:' \
   && printf '%s' "$VIEW" | grep -qF 'Nobody can check this one for you:'; then
    ok  "p31. the CEO's own page distinguishes an item that will close itself from one that will not"
else
    bad "p31. the view should gloss both kinds of check: $VIEW"
fi

# BACKWARD COMPATIBILITY, and it is load-bearing rather than tidy: every
# repository that already has a record has a committed view, and the commit
# guard refuses a view that is not byte-current. If this change had altered the
# rendering of an item that carries no Done-check, landing the engine would have
# refused the next commit in every one of those repositories.
R="$(mk_repo dcrendercompat)"
write_record "$R" '### 2.1 READY-FOR-CEO — An item written before any of this existed

- **Open:** `repo/docs/prepared.md`
- **Time:** 30 minutes
- **Done:** the ruling is written on the decisions page
- **Unblocks:** the measurement downstream of it
'
if ! grep -qF 'Closes itself' "$R/CEO-TODOs.md" \
   && ! grep -qF 'Nobody can check' "$R/CEO-TODOs.md"; then
    run_guard "$R"
    if [ "$GRC" -eq 0 ]; then
        ok  "p32. an item with no Done-check renders exactly as before, so this engine does not wedge an existing record"
    else
        bad "p32. a pre-existing record must still pass (rc=$GRC): $GOUT"
    fi
else
    bad "p32. the renderer must add nothing for an item that carries no Done-check"
fi

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
cp "$ENGINE_ROOT/scripts/lib/resolve-roots.sh" "$ENGINE_ROOT/scripts/lib/resolve-main-checkout.sh" "$ENGINE_ROOT/scripts/lib/seat-jurisdiction.sh" "$TMPENG/scripts/lib/"
rc=0
out="$(printf '{"tool_name":"Bash","cwd":"/tmp","tool_input":{"command":"git commit -m x"}}' \
       | "$BASH_BIN" "$TMPENG/scripts/hooks/guard-ceo-todos-commits.sh" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qF "ceo-todos.sh is missing"; then
    ok "a missing predicate library is a LOUD refusal, never a quiet skip"
else
    bad "missing predicate library should block loudly (rc=$rc)"
fi
rm -rf "$TMPENG"

# ---------------------------------------------------------------------------
# (l) REGISTRATION — both surfaces, or the engine ships a guard nobody loads
# ---------------------------------------------------------------------------
G=guard-ceo-todos-commits.sh
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
if grep -q "guard-ceo-todos-commits" "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" 2>/dev/null \
   && grep -q "guard-ceo-todos-commits \\\\" "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" 2>/dev/null; then
    ok "$G listed among Layer R's root-resolving hooks"
else
    bad "$G NOT listed in Layer R's rooted-hook set — its bootstrap would go unchecked"
fi
for lib in scripts/lib/ceo-todos.sh scripts/lib/ceo-todos.py scripts/lib/cold-open-prompt.md; do
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
