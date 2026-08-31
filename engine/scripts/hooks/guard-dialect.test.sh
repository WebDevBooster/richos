#!/usr/bin/env bash
#
# guard-dialect.test.sh — regression tests for scripts/hooks/guard-dialect.sh.
#
# Three halves, and the second is the one that matters most.
#
#   A. POSITIVES — the guard actually blocks, across all four tool shapes, for
#      spelling and for the `CEO queue` collocation, with the suggestion
#      re-cased to what was written.
#   B. NEGATIVES — the guard does NOT fire on code identifiers, CSS custom
#      properties, URLs and paths, fenced code, inline code spans, blockquotes,
#      captured-evidence paths, vendor legal files, the legacy `.ceo-queue`
#      file name, rename narration, or the American words that merely LOOK
#      British (`analyses`, `dialogue`, `practice`, `cancellation`,
#      `controlled`). Getting these right matters more than catching every last
#      word: a guard that cries wolf is switched off within a day.
#   C. CONFIGURATION AND FAILURE MODES — blank DIALECT_TARGET is a silent
#      no-op, a foreign DIALECT_TARGET is an announced no-op, a missing
#      dictionary is fail-closed, a malformed payload is fail-open, and a
#      missing python3 is fail-closed.
#
# NOTE: this file is itself exempt from the guard by basename (see the guard's
# header) — it has to be, since it is made of the words the guard rejects.
#
# Run directly: scripts/hooks/guard-dialect.test.sh
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Declare the governed repository rather than inheriting the launching
# session's — same reasoning as scan-secrets.test.sh: run from a session seated
# elsewhere, the guard would resolve THAT repository, find no adoption marker,
# stand down, and every case below would pass by never running.
RICHOS_ENTITY_ROOT="$ENGINE_ROOT"
export RICHOS_ENTITY_ROOT
unset CLAUDE_PROJECT_DIR

HOOK="$SCRIPT_DIR/guard-dialect.sh"
DICT="$ENGINE_ROOT/scripts/lib/dialect-en-US.dict"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t guard-dialect-test.XXXXXX)" && pwd -P)"
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

MD="/tmp/dialect-subject.md"

echo "=== A. POSITIVES — it blocks ==="

case_exit "A1. Write: 'colour' in prose is blocked"            2 Write "$MD" "The colour of the button is wrong."
case_exit "A2. Edit: 'behaviour' is blocked"                   2 Edit  "$MD" "This is the expected behaviour."
case_exit "A3. MultiEdit: one dirty edit among clean ones"     2 MultiEdit "$MD" "all clean here" "the licence says so" "also clean"
case_exit "A4. NotebookEdit: 'defence' is blocked"             2 NotebookEdit "/tmp/x.ipynb" "the only defence available"
case_exit "A5. 'judgement' is blocked"                         2 Write "$MD" "offered as engineering judgement rather than fact"
case_exit "A6. 'whilst' is blocked"                            2 Write "$MD" "whilst the deploy runs"
case_exit "A7. 'towards' is blocked"                           2 Write "$MD" "one step towards the answer"
case_exit "A8. 'analysed' is blocked"                          2 Write "$MD" "we analysed the payload"
case_exit "A9. 'catalogue' is blocked"                         2 Write "$MD" "a catalogue of failures"
case_exit "A10. 'artefacts' is blocked"                        2 Write "$MD" "applies to artefacts, not promises"
case_exit "A11. 'organisation' is blocked"                     2 Write "$MD" "the organisation of the record"
case_exit "A12. 'grey' in a .md file is blocked"               2 Write "$MD" "a grey line under the header"

case_msg  "A13. suggestion is re-cased: Colour -> Color"       "Colour -> Color"   Write "$MD" "Colour is a product decision."
case_msg  "A14. suggestion is re-cased: LICENCE -> LICENSE"    "LICENCE -> LICENSE" Write "$MD" "THE LICENCE OF RECORD"
case_msg  "A15. the block names the file it refused"           "$MD"               Write "$MD" "the colour is wrong"
case_msg  "A16. the block names the declared-exemption route"  "dialect-exempt:"   Write "$MD" "the colour is wrong"

case_exit "A17. 'CEO queue' is blocked"                        2 Write "$MD" "13 items are in the CEO queue right now."
case_exit "A18. \"CEO's queue\" is blocked"                    2 Write "$MD" "It sat in the CEO's queue for a week."
case_msg  "A19. the queue block names CEO-TODOs as the fix"    "CEO-TODOs"         Write "$MD" "13 items are in the CEO queue."

echo
echo "=== B. NEGATIVES — it does not cry wolf ==="

case_exit "B1. clean American prose passes"                    0 Write "$MD" "The color of the button is fine and the behavior is correct."
case_exit "B2. American 'license' is never flagged"            0 Write "$MD" "the license of record is a documentation page"
case_exit "B3. camelCase identifier 'colourPicker'"            0 Write "/tmp/x.js" "const colourPicker = makeThing();"
case_exit "B4. snake_case identifier 'text_colour'"            0 Write "/tmp/x.py" "text_colour = 3"
case_exit "B5. CSS custom property '--brand-colour'"           0 Write "/tmp/x.js" "el.style.setProperty('--brand-colour', v)"
case_exit "B6. a path token containing 'licence'"              0 Write "$MD" "see docs/reference/licence-snapshots/page.txt for the capture"
case_exit "B7. a URL containing 'licence'"                     0 Write "$MD" "fetched from https://example.com/legal/licence today"
case_exit "B8. inline code span \`colour\`"                    0 Write "$MD" "the CSS token is \`colour\` in that vendor's theme"
case_exit "B9. blockquote line (quoted external material)"     0 Write "$MD" "He wrote:
> the colour of it is not our judgement to make
and that settles it."
case_exit "B10. fenced code block"                             0 Write "$MD" "before
\`\`\`js
const colour = 1; // behaviour
\`\`\`
after"
case_exit "B11. declared 'dialect-exempt: <reason>'"           0 Write "$MD" "the colour of it   <!-- dialect-exempt: verbatim from the vendor's own page -->"
case_exit "B12. a BARE 'dialect-exempt:' exempts nothing"      2 Write "$MD" "the colour of it   <!-- dialect-exempt: -->"
case_exit "B13. 'grey' in a .css file is a legal CSS color"    0 Write "/tmp/x.css" "a { color: grey; }"
case_exit "B14. 'grey' in a .scss file"                        0 Write "/tmp/x.scss" "\$line: grey;"
case_exit "B15. captured evidence under wiki/raw/"             0 Write "/tmp/wiki/raw/page.md" "the colour of the licence"
case_exit "B16. captured transcript under docs/cold-open/"     0 Write "/tmp/docs/cold-open/2026-08-31.md" "not part of the 13-item queue; the behaviour is odd"
# Found by using the guard: the first captured page it met lived in
# `licence-snapshots/`, and a bare-segment match would have "corrected" a
# vendor's own legal page.
case_exit "B16b. a QUALIFIED evidence dir: license-snapshots/" 0 Write "/tmp/docs/reference/license-snapshots/page.txt" "the licence of record, as they wrote it"
case_exit "B16c. ...but 'raw-notes/' is still prose, not raw"  2 Write "/tmp/docs/raw-notes/thoughts.md" "the colour of it"
case_exit "B17. a .log run output"                             0 Write "/tmp/out/run.log" "recognised: colour behaviour licence"
case_exit "B18. a .jsonl corpus"                               0 Write "/tmp/data/rows.jsonl" "{\"t\":\"colour\"}"
case_exit "B19. anything under node_modules/"                  0 Write "/tmp/node_modules/pkg/readme.md" "the colour option"
case_exit "B20. vendor LICENSE.md"                             0 Write "/tmp/LICENSE.md" "This licence is granted under..."
case_exit "B21. vendor NOTICE"                                 0 Write "/tmp/NOTICE" "licence terms, unmodified"
case_exit "B22. package-lock.json"                             0 Write "/tmp/package-lock.json" "{\"licence\": \"x\"}"
case_exit "B23. the guard's own dictionary"                    0 Write "$DICT" "colour	color"
case_exit "B24. legacy '.ceo-queue' file name (identifier)"    0 Write "$MD" "a pre-rename .ceo-queue is still read"
case_exit "B25. 'ceo_queue' identifier"                        0 Write "/tmp/x.py" "ceo_queue = load()"
case_exit "B26. rename narration: 'called the CEO queue'"      0 Write "$MD" "It was called the CEO queue; it is now CEO-TODOs."
case_exit "B27. rename narration: 'renamed the CEO queue'"     0 Write "$MD" "the instruction that also renamed the CEO queue"
case_exit "B28. 'analyses' is already American"                0 Write "$MD" "three analyses of the same page"
case_exit "B29. 'dialogue' is American too"                    0 Write "$MD" "a dialogue between the two of them"
case_exit "B30. 'practice' the noun"                           0 Write "$MD" "common practice in this repository"
case_exit "B31. 'cancellation' keeps its double L"             0 Write "$MD" "a cancellation policy"
case_exit "B32. 'controlled' keeps its double L"               0 Write "$MD" "a controlled rollout"
case_exit "B33. 'surprise'/'advertise' are -ise in both"       0 Write "$MD" "no surprise; we advertise nothing"
case_exit "B34. a non-Write/Edit tool is ignored"              0 Bash  "$MD" "the colour is wrong"
# The lead flagged this one live on 2026-08-31, and it is the failure mode that
# would discredit the guard fastest: "correcting" a word that was already right.
case_exit "B36. 'enrollment'/'enrolled' are ALREADY American"  0 Write "$MD" "Apple Developer enrollment; he enrolled last year"
case_exit "B37. ...but British 'enrolment' is blocked"         2 Write "$MD" "the enrolment is pending"

# Malformed payload: FAIL OPEN, matching guard-main-checkout-writes.sh.
printf '%s' 'not json at all {{{' | "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "B35. malformed payload fails OPEN (exit 0)" \
             || bad "B35. malformed payload fails OPEN (exit 0)"

echo
echo "=== C. THE 'queue' COLLOCATION — reported, never blocked ==="

case_exit "C1. 'the queue' near CEO is REPORTED, not blocked"  0 Write "$MD" "The CEO reads it first; nothing unprepared sits in the queue."
case_msg  "C2. ...and the report says why it was not blocked"  "not blocked"        Write "$MD" "The CEO reads it first; nothing unprepared sits in the queue."
case_exit "C3. 'his queue' with no CEO/TODO context is clean"  0 Write "$MD" "the worker drains his queue every second"
case_exit "C4. a hard finding + a soft one still exits 2"      2 Write "$MD" "The CEO queue is grey."

echo
echo "=== D. CONFIGURATION AND FAILURE MODES ==="

# D1/D2 — a sandbox entity root whose orchestration.config declares (or does
# not declare) a dialect. The engine root is left alone.
mk_entity() {   # mk_entity <dir> <config-lines>
    mkdir -p "$1"
    printf '%s\n' "$2" > "$1/orchestration.config"
}

ENT_BLANK="$SANDBOX/entity-blank"
mk_entity "$ENT_BLANK" 'DIALECT_TARGET=""'
RICHOS_ENTITY_ROOT="$ENT_BLANK" payload Write "$MD" "the colour is wrong" \
    | RICHOS_ENTITY_ROOT="$ENT_BLANK" "$HOOK" >"$SANDBOX/d1.out" 2>"$SANDBOX/d1.err"
D1_RC=$?
if [ "$D1_RC" -eq 0 ] && [ ! -s "$SANDBOX/d1.err" ]; then
    ok "D1. blank DIALECT_TARGET is a SILENT no-op (exit 0, no stderr)"
else
    bad "D1. blank DIALECT_TARGET is a SILENT no-op (exit 0, no stderr)" "rc=$D1_RC stderr=$(cat "$SANDBOX/d1.err")"
fi

ENT_FR="$SANDBOX/entity-fr"
mk_entity "$ENT_FR" 'DIALECT_TARGET="fr-FR"'
RICHOS_ENTITY_ROOT="$ENT_FR" payload Write "$MD" "the colour is wrong" \
    | RICHOS_ENTITY_ROOT="$ENT_FR" "$HOOK" >"$SANDBOX/d2.out" 2>"$SANDBOX/d2.err"
D2_RC=$?
if [ "$D2_RC" -eq 0 ] && grep -qF 'fr-FR' "$SANDBOX/d2.err"; then
    ok "D2. a foreign DIALECT_TARGET is an ANNOUNCED no-op, never a pretend enforcement"
else
    bad "D2. a foreign DIALECT_TARGET is an ANNOUNCED no-op" "rc=$D2_RC stderr=$(cat "$SANDBOX/d2.err")"
fi

ENT_ALLOW="$SANDBOX/entity-allow"
mk_entity "$ENT_ALLOW" 'DIALECT_TARGET="en-US"
DIALECT_SCAN_ALLOWLIST="Colour Party"'
payload Write "$MD" "the Colour Party is a proper noun" \
    | RICHOS_ENTITY_ROOT="$ENT_ALLOW" "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "D3. DIALECT_SCAN_ALLOWLIST exempts a literal substring" \
             || bad "D3. DIALECT_SCAN_ALLOWLIST exempts a literal substring"

ENT_PATHS="$SANDBOX/entity-paths"
mk_entity "$ENT_PATHS" 'DIALECT_TARGET="en-US"
DIALECT_EXEMPT_PATHS="/imported/"'
payload Write "/tmp/imported/doc.md" "the colour is wrong" \
    | RICHOS_ENTITY_ROOT="$ENT_PATHS" "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "D4. DIALECT_EXEMPT_PATHS exempts a path substring" \
             || bad "D4. DIALECT_EXEMPT_PATHS exempts a path substring"

# D5 — a governed repository with no dictionary is FAIL-CLOSED, never a quiet
# pass. DIALECT_TARGET is declared, so this repository believes it is governed.
EMPTY_ENGINE="$SANDBOX/empty-engine"
mkdir -p "$EMPTY_ENGINE/scripts/lib"
payload Write "$MD" "the colour is wrong" \
    | RICHOS_ENGINE_ROOT="$EMPTY_ENGINE" "$HOOK" >/dev/null 2>&1
[ $? -eq 2 ] && ok "D5. a missing dictionary is FAIL-CLOSED (exit 2)" \
             || bad "D5. a missing dictionary is FAIL-CLOSED (exit 2)"

# D6 — no python3 on PATH: fail closed, like every sibling.
BINLESS="$SANDBOX/binless"
mkdir -p "$BINLESS"
payload Write "$MD" "the colour is wrong" > "$SANDBOX/d6.json"
env PATH="$BINLESS" /bin/bash "$HOOK" < "$SANDBOX/d6.json" >/dev/null 2>&1
[ $? -eq 2 ] && ok "D6. a missing python3 is FAIL-CLOSED (exit 2)" \
             || bad "D6. a missing python3 is FAIL-CLOSED (exit 2)"

echo
echo "=== E. STRUCTURE — the guard is wired, hashed, and single-sourced ==="

grep -q '\. "\$_RR_LIB"' "$HOOK" \
    && ok "E1. guard-dialect.sh sources the root-resolution contract" \
    || bad "E1. guard-dialect.sh sources the root-resolution contract"

grep -q 'guard-dialect\.sh' "$ENGINE_ROOT/hooks/hooks.json" \
    && ok "E2. registered on the plugin surface (hooks/hooks.json)" \
    || bad "E2. registered on the plugin surface (hooks/hooks.json)"

grep -q 'guard-dialect\.sh' "$ENGINE_ROOT/.claude/settings.local.json" \
    && ok "E3. registered on the seated surface (.claude/settings.local.json)" \
    || bad "E3. registered on the seated surface (.claude/settings.local.json)"

grep -q 'dialect-en-US\.dict' "$ENGINE_ROOT/scripts/hooks/install.sh" \
    && ok "E4. the dictionary is sidecar-hashed by install.sh" \
    || bad "E4. the dictionary is sidecar-hashed by install.sh"

# E5 — ONE vocabulary. A second word list anywhere in the engine is the defect
# scripts/lib/registered-hooks.sh exists to describe, one domain over.
DUP="$(grep -rlE '^(colour|behaviour|licence)\b' "$ENGINE_ROOT/scripts" 2>/dev/null \
        | grep -v 'dialect-en-US.dict' | grep -v 'guard-dialect' || true)"
[ -z "$DUP" ] && ok "E5. the vocabulary lives in exactly one file" \
              || bad "E5. the vocabulary lives in exactly one file" "also in: $DUP"

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\n  %d/%d cases passed\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '\n  %d/%d cases passed, %d FAILED\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
