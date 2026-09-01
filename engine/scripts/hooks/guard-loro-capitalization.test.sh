#!/usr/bin/env bash
#
# guard-loro-capitalization.test.sh — regression tests for
# scripts/hooks/guard-loro-capitalization.sh.
#
# Four halves, and B is the one that matters most.
#
#   A. POSITIVES — the two shapes that measured 0% false positive really do
#      block, across all four tool shapes, in markdown and in source comments.
#   B. NEGATIVES — it does NOT fire on the sentence-case heading, the
#      mid-sentence generic use, the hyphenated command name, the path, the
#      fenced block, the inline span, the blockquote (including one behind a
#      comment lead), the abbreviation, the numbered heading, the code line,
#      the captured evidence path, or the word already capitalized. EVERY ONE
#      OF THESE IS A REAL SITE FROM THE 2026-09-01 SWEEP, not an invention: the
#      guard's whole claim is that it declines what it cannot adjudicate, and
#      this section is where that claim is checked.
#   C. THE LIST SHAPE — reported, never blocked, because it measured 60% false
#      positive. A report alongside a block still exits 2.
#   D. CONFIGURATION AND FAILURE MODES — LORO_CAPS unset is a silent no-op,
#      LORO_CAPS set to anything but `on` is a silent no-op, a malformed
#      payload fails open, a non-Write tool is ignored.
#   E. WIRING — registered on both surfaces, and its corpus is on disk.
#
# NOTE: this file is itself exempt from the guard by basename (see the guard's
# header) — it has to be, since it is made of the shapes the guard rejects.
#
# Run directly: scripts/hooks/guard-loro-capitalization.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Declare the governed repository rather than inheriting the launching
# session's — same reasoning as guard-dialect.test.sh: run from a session seated
# elsewhere, the guard would resolve THAT repository, find no adoption marker,
# stand down, and every case below would pass by never running.
RICHOS_ENTITY_ROOT="$ENGINE_ROOT"
export RICHOS_ENTITY_ROOT
unset CLAUDE_PROJECT_DIR

HOOK="$SCRIPT_DIR/guard-loro-capitalization.sh"
CORPUS="$SCRIPT_DIR/loro-capitalization.corpus.md"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t guard-loro-caps-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; FAIL=$((FAIL + 1)); }

# payload <tool> <file_path> <text...>
payload() {
    python3 -c '
import json, sys
tool, fp = sys.argv[1], sys.argv[2]
vals = sys.argv[3:]
ti = {"file_path": fp}
if tool == "Write":
    ti["content"] = vals[0]
elif tool == "Edit":
    ti["old_string"] = "x"; ti["new_string"] = vals[0]
elif tool == "MultiEdit":
    ti["edits"] = [{"old_string": "x", "new_string": v} for v in vals]
elif tool == "NotebookEdit":
    ti = {"notebook_path": fp, "new_source": vals[0]}
print(json.dumps({"tool_name": tool, "tool_input": ti}))
' "$@"
}

# case_exit <name> <expected-exit> <tool> <file_path> <text...>
case_exit() {
    local name="$1" want="$2"; shift 2
    local json rc
    json="$(payload "$@")"
    printf '%s' "$json" | "$HOOK" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq "$want" ] && ok "$name" || bad "$name" "expected exit $want, got $rc"
}

# case_msg <name> <needle> <tool> <file_path> <text...>
case_msg() {
    local name="$1" needle="$2"; shift 2
    local json out
    json="$(payload "$@")"
    out="$(printf '%s' "$json" | "$HOOK" 2>&1 >/dev/null)"
    printf '%s' "$out" | grep -qF "$needle" && ok "$name" \
        || bad "$name" "stderr did not mention \"$needle\""
}

MD="/tmp/loro-caps-subject.md"

echo "=== A. POSITIVES — the two 0%-false-positive shapes block ==="

case_exit "A1. Write: sentence start after a period"           2 Write "$MD" "Rich thinks and acts. loro remembers and learns."
case_exit "A2. Edit: sentence start"                           2 Edit  "$MD" "It is the memory primitive. loro builds on it."
case_exit "A3. MultiEdit: one dirty edit among clean ones"     2 MultiEdit "$MD" "a slice of loro is compiled" "The wall holds. loro keeps scopes." "still clean"
case_exit "A4. NotebookEdit: sentence start"                   2 NotebookEdit "/tmp/x.ipynb" "The compiler ranks. loro does not guess."
case_exit "A5. heading that OPENS with the word"               2 Write "$MD" "# loro architecture — beyond Karpathy's LLM Wiki"
case_exit "A6. heading opening with the word, emphasized"      2 Write "$MD" "## **loro** is the memory under every thread"
# The real shape from wiki/loro-architecture.md:46 — the sentence ends inside a
# bold run, so the closer is '**' and not whitespace. Missing this cost eight
# true positives when it was measured.
case_exit "A7. sentence ending inside a bold run"              2 Write "$MD" "9. **Push, not just pull.** loro feeds an attention engine."
case_exit "A8. rustdoc comment prose in a .rs file"            2 Write "/tmp/x.rs" "//! NOT siloed conversations. loro is the shared memory."
case_exit "A9. block-comment prose in a .js file"              2 Write "/tmp/x.js" " * THE GAP THIS CLOSES. loro had no writer at all."
case_exit "A10. a shell comment is prose too"                  2 Write "/tmp/x.sh" "# A thin slice means it does not know. loro refuses to guess."

case_msg  "A11. the block names the file it refused"           "$MD"                  Write "$MD" "It ranks. loro does not guess."
case_msg  "A12. the block names the declared-exemption route"  "loro-caps-exempt:"    Write "$MD" "It ranks. loro does not guess."
case_msg  "A13. the block says WHICH shape fired (sentence)"   "starts a sentence"    Write "$MD" "It ranks. loro does not guess."
case_msg  "A14. the block says WHICH shape fired (heading)"    "opens a heading"      Write "$MD" "# loro writer"
case_msg  "A15. the block cites the rule page"                 "wiki/loro-concept.md" Write "$MD" "# loro writer"

echo
echo "=== B. NEGATIVES — every one of these is a real site it must not touch ==="

case_exit "B1. mid-sentence generic use — the whole point"     0 Write "$MD" "Add this to loro before the next session."
case_exit "B2. sentence-case heading, word NOT first"          0 Write "$MD" "## What loro is"
case_exit "B3. sentence-case heading with a number prefix"     0 Write "$MD" "### 8.3 loro compiler and writer: use, do not absorb"
case_exit "B4. a heading where the word sits after a dash"     0 Write "$MD" "## Defect 4 — loro had no writer"
case_exit "B5. already capital — never re-cased downward"      0 Write "$MD" "It ranks. Loro does not guess."
case_exit "B6. ALL CAPS rendered UI string"                    0 Write "$MD" "The chrome reads: LORO · 14 MONTHS · 7,500 MEMORIES"
case_exit "B7. a path token"                                   0 Write "$MD" "Terms come from loro/entities.json at load."
case_exit "B8. a wrapped path at line start"                   0 Write "$MD" "see the note in
loro/README.md for the layout"
case_exit "B9. inline code span"                               0 Write "$MD" "It ranks. \`loro\` is the corpus root name."
case_exit "B10. fenced code block"                             0 Write "$MD" "before
\`\`\`js
const x = 1; // done. loro next
\`\`\`
after"
case_exit "B11. blockquote — quoted material is not ours"      0 Write "$MD" "He wrote:
> The wall holds. loro keeps scopes.
and that settles it."
# loro/lib/privacy.js quotes wiki/loro-architecture.md this way. Without the
# comment-lead half of the blockquote rule this was a measured false positive.
case_exit "B12. blockquote BEHIND a comment lead ('* > ')"     0 Write "/tmp/x.js" " * > Company memory is sensitive. loro keeps memory SCOPES."
case_exit "B13. hyphenated command name 'loro-context'"        0 Write "$MD" "It ranks. loro-context compile --topic x"
case_exit "B14. hyphenated compound 'loro-correction'"         0 Write "/tmp/x.js" " * 5. loro-CORRECTION      P1 seam (identity pass)"
case_exit "B15. an identifier with an underscore"              0 Write "/tmp/x.sh" "# It ranks. LORO_CORPUS is read once."
case_exit "B16. a CODE line in a source file is not prose"     0 Write "/tmp/x.js" "  ['Pointer', 'A mirror is a POINTER. loro indexes it.'],"
case_exit "B17. an object key in a code line"                  0 Write "/tmp/x.js" "const DESKS = {
  loro: { available: null },
};"
case_exit "B18. abbreviation 'e.g.' is not a sentence end"     0 Write "$MD" "the generic sense, e.g. loro as a category noun"
case_exit "B19. abbreviation 'i.e.' likewise"                  0 Write "$MD" "the memory layer, i.e. loro, is not the ledger"
case_exit "B20. an ordered-list marker is not a sentence end"  0 Write "$MD" "2. loro entity biasing feeds the recognizer"
case_exit "B21. captured evidence under wiki/raw/"             0 Write "/tmp/wiki/raw/page.md" "It ranks. loro does not guess."
case_exit "B22. a captured transcript under docs/cold-open/"   0 Write "/tmp/docs/cold-open/2026-09-01.md" "It ranks. loro does not guess."
case_exit "B23. a fixture directory"                           0 Write "/tmp/loro/test/fixtures/page.md" "It ranks. loro does not guess."
case_exit "B24. a .txt file (captured command output)"         0 Write "/tmp/docs/verification/out.txt" "second half. loro's writer is done"
case_exit "B25. a .log run output"                             0 Write "/tmp/out/run.log" "done. loro compiled 174 records"
case_exit "B26. the guard's own corpus file"                   0 Write "$CORPUS" "# loro capitalization — the corpus"
case_exit "B27. the guard's own implementation"                0 Write "$HOOK" "# loro is the subject of this file"
case_exit "B28. declared 'loro-caps-exempt: <reason>'"         0 Write "$MD" "It ranks. loro does not guess.  <!-- loro-caps-exempt: verbatim from the CEO's own message -->"
case_exit "B29. a BARE 'loro-caps-exempt:' exempts nothing"    2 Write "$MD" "It ranks. loro does not guess.  <!-- loro-caps-exempt: -->"
case_exit "B30. a non-Write/Edit tool is ignored"              0 Bash  "$MD" "It ranks. loro does not guess."
# THE SHAPE IT DELIBERATELY DOES NOT ATTEMPT. A paragraph start across a line
# break is a new sentence about a quarter of the time in this record and a
# mid-sentence wrap the rest. Unflagged, on purpose, and asserted here so that
# "it does not catch this" stays a decision rather than becoming a bug report.
case_exit "B31. a line-initial word after a WRAP is unflagged" 0 Write "$MD" "dense meshes where the
loro is thick (Customers, Product)"

# Malformed payload: FAIL OPEN, matching guard-dialect.sh and its siblings.
printf '%s' 'not json at all {{{' | "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "B32. malformed payload fails OPEN (exit 0)" \
             || bad "B32. malformed payload fails OPEN (exit 0)"

echo
echo "=== C. THE LIST SHAPE — 60% false positive, so reported and never blocked ==="

case_exit "C1. a bullet opening with the word is NOT blocked"  0 Write "$MD" "- loro references"
case_msg  "C2. ...and the report says why it was not blocked"  "not blocked"  Write "$MD" "- loro references"
case_msg  "C3. ...and the report gives the actual rule of thumb" "sibling items" Write "$MD" "- loro references"
case_exit "C4. a table cell opening with the word"             0 Write "$MD" "| loro corpus, journals, config | data (the user's) |"
case_exit "C5. a report alongside a block still exits 2"       2 Write "$MD" "# loro writer

- loro references"

echo
echo "=== D. CONFIGURATION AND FAILURE MODES ==="

mk_entity() {   # mk_entity <dir> <config-lines>
    mkdir -p "$1"
    printf '%s\n' "$2" > "$1/orchestration.config"
}

ENT_BLANK="$SANDBOX/entity-blank"
mk_entity "$ENT_BLANK" 'LORO_CAPS=""'
RICHOS_ENTITY_ROOT="$ENT_BLANK" payload Write "$MD" "It ranks. loro does not guess." \
    | RICHOS_ENTITY_ROOT="$ENT_BLANK" "$HOOK" >"$SANDBOX/d1.out" 2>"$SANDBOX/d1.err"
D1_RC=$?
if [ "$D1_RC" -eq 0 ] && [ ! -s "$SANDBOX/d1.err" ]; then
    ok "D1. blank LORO_CAPS is a SILENT no-op (exit 0, no stderr)"
else
    bad "D1. blank LORO_CAPS is a SILENT no-op (exit 0, no stderr)" "rc=$D1_RC stderr=$(cat "$SANDBOX/d1.err")"
fi

ENT_OFF="$SANDBOX/entity-off"
mk_entity "$ENT_OFF" 'LORO_CAPS="off"'
RICHOS_ENTITY_ROOT="$ENT_OFF" payload Write "$MD" "It ranks. loro does not guess." \
    | RICHOS_ENTITY_ROOT="$ENT_OFF" "$HOOK" >"$SANDBOX/d2.out" 2>"$SANDBOX/d2.err"
D2_RC=$?
if [ "$D2_RC" -eq 0 ] && [ ! -s "$SANDBOX/d2.err" ]; then
    ok "D2. LORO_CAPS with any value but 'on' is a SILENT no-op"
else
    bad "D2. LORO_CAPS with any value but 'on' is a SILENT no-op" "rc=$D2_RC stderr=$(cat "$SANDBOX/d2.err")"
fi

ENT_ALLOW="$SANDBOX/entity-allow"
mk_entity "$ENT_ALLOW" 'LORO_CAPS="on"
LORO_CAPS_ALLOWLIST="loro-vs-RAG"'
RICHOS_ENTITY_ROOT="$ENT_ALLOW" payload Write "$MD" "Hybrid retrieval. loro-vs-RAG is not the question. loro synthesizes." \
    | RICHOS_ENTITY_ROOT="$ENT_ALLOW" "$HOOK" >/dev/null 2>&1
D3_RC=$?
[ "$D3_RC" -eq 0 ] && ok "D3. LORO_CAPS_ALLOWLIST suppresses a line" \
                   || bad "D3. LORO_CAPS_ALLOWLIST suppresses a line" "rc=$D3_RC"

ENT_PATHS="$SANDBOX/entity-paths"
mk_entity "$ENT_PATHS" 'LORO_CAPS="on"
LORO_CAPS_EXEMPT_PATHS="design/mockups/rounds/"'
RICHOS_ENTITY_ROOT="$ENT_PATHS" payload Write "/tmp/design/mockups/rounds/round-3/NOTES.md" "It settles. loro is thick there." \
    | RICHOS_ENTITY_ROOT="$ENT_PATHS" "$HOOK" >/dev/null 2>&1
D4_RC=$?
[ "$D4_RC" -eq 0 ] && ok "D4. LORO_CAPS_EXEMPT_PATHS skips a whole write" \
                   || bad "D4. LORO_CAPS_EXEMPT_PATHS skips a whole write" "rc=$D4_RC"

ENT_ON="$SANDBOX/entity-on"
mk_entity "$ENT_ON" 'LORO_CAPS="on"'
RICHOS_ENTITY_ROOT="$ENT_ON" payload Write "$MD" "It ranks. loro does not guess." \
    | RICHOS_ENTITY_ROOT="$ENT_ON" "$HOOK" >/dev/null 2>&1
D5_RC=$?
[ "$D5_RC" -eq 2 ] && ok "D5. a bare LORO_CAPS=\"on\" entity really does enforce" \
                   || bad "D5. a bare LORO_CAPS=\"on\" entity really does enforce" "rc=$D5_RC"

echo
echo "=== E. WIRING ==="

grep -q 'guard-loro-capitalization\.sh' "$ENGINE_ROOT/hooks/hooks.json" \
    && ok "E1. registered on the plugin surface (hooks/hooks.json)" \
    || bad "E1. registered on the plugin surface (hooks/hooks.json)"

grep -q 'guard-loro-capitalization\.sh' "$ENGINE_ROOT/.claude/settings.local.json" \
    && ok "E2. registered on the seated surface (.claude/settings.local.json)" \
    || bad "E2. registered on the seated surface (.claude/settings.local.json)"

grep -q '^LORO_CAPS=' "$ENGINE_ROOT/orchestration.config" \
    && ok "E3. the switch is declared in orchestration.config" \
    || bad "E3. the switch is declared in orchestration.config"

# E4 — THE MEASUREMENT IS ON DISK. A guard whose blocking decision rests on a
# false-positive rate nobody can read is a guard whose rate nobody can dispute,
# and the numbers were the whole argument for what may block.
[ -f "$CORPUS" ] && grep -q '0.0%' "$CORPUS" \
    && ok "E4. the measured false-positive corpus ships beside the guard" \
    || bad "E4. the measured false-positive corpus ships beside the guard"

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\n  %d/%d cases passed\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '\n  %d/%d cases passed, %d FAILED\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
