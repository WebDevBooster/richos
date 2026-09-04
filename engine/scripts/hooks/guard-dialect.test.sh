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
echo "=== V. VENDORED MATERIAL — whose prose is this? ==="
#
# WHY THIS SECTION EXISTS, IN ONE INCIDENT AND THREE DIRECTIONS.
#
# On 2026-08-30 this guard rewrote fourteen lines across TWO vendored,
# MIT-licensed skills — `engine/skills/copywriting/references/natural-
# transitions.md` (4 lines) and `engine/skills/landing-page-taste/SKILL.md`
# (10 lines), commit 06f4a8221a61. Neither is ours to correct. It was found by
# accident, six weeks later, by a publication audit.
#
# The guard was not wrong; it had no way to be right. It exempts `vendor/` and
# `third_party/` by NAME, and this engine vendors into `engine/skills/<name>/`,
# which looks exactly like the skills we wrote. So the answer now comes from a
# recorded FACT — `.richos/vendored-material`, read through
# scripts/lib/vendored-material.sh — and never from a guess.
#
# The defect is a ONE-WAY DOOR, which is sharper than "it edits vendored
# files", and all three directions are pinned here:
#
#   1. it must not silently EDIT vendored prose            (V1, V8, V9)
#   2. RE-VENDORING VERBATIM from upstream must SUCCEED    (V10) — the repair
#      was blocked by the same guard that caused the damage
#   3. QUOTING a foreign spelling to DOCUMENT the difference must be possible
#      (V5, V12) — an engineer was refused twice trying to write exactly that
#      notice, and had to phrase the prose around the block
#
# And the exemption is NARROW, which is the half that keeps it honest: material
# recorded as `origin=richos` is STILL CHECKED (V2). A registry that exempted
# everything it named would be an off switch with an inventory attached.

TABX=$'\t'
mkvendrepo() { # <dir> <registry-line...>
    local d="$1"; shift
    mkdir -p "$d/.richos" "$d/engine/skills/vendored/references" \
             "$d/engine/skills/mine" "$d/engine/skills/unregistered" "$d/docs"
    printf 'DIALECT_TARGET="en-US"\n' >"$d/orchestration.config"
    printf '%s\n' "$@" >"$d/.richos/vendored-material"
}

VS="$SANDBOX/vendrepo"
mkvendrepo "$VS" \
    'REDISTRIBUTABLE_PATHS="engine/skills"' \
    "engine/skills/vendored${TABX}third-party${TABX}MIT${TABX}Someone${TABX}up/stream${TABX}abc123${TABX}2026-01-01 x${TABX}certain${TABX}verbatim${TABX}docs/x.md" \
    "engine/skills/mine${TABX}richos${TABX}AGPL-3.0-only${TABX}RichOS${TABX}-${TABX}-${TABX}2026-01-01 x${TABX}high${TABX}verbatim${TABX}docs/x.md"

BRITISH="Emphasising the point, and the colour of the behaviour."

case_exit "V1. a file recorded as third-party is left alone"    0 Write "$VS/engine/skills/vendored/references/natural.md" "$BRITISH"
case_exit "V2. a file recorded as origin=richos is STILL checked" 2 Write "$VS/engine/skills/mine/SKILL.md" "$BRITISH"
case_exit "V3. an UNRECORDED path under skills/ is still checked" 2 Write "$VS/engine/skills/unregistered/SKILL.md" "$BRITISH"
case_exit "V4. an ungoverned path is still checked"             2 Write "$VS/docs/note.md" "$BRITISH"
case_exit "V5. a MODIFICATIONS notice INSIDE a vendored dir is exempt" 0 Write "$VS/engine/skills/vendored/MODIFICATIONS.md" "$BRITISH"

# THE SOFT RULE IS SUPPRESSED TOO, and that is a separate assertion from the
# blocking one. `the queue` on a line mentioning the CEO is REPORTED, never
# blocked — so on a vendored file the exit code is 0 either way and only the
# stderr distinguishes them. Narrating at every write about wording in a
# document nobody here may change is the cries-wolf half of the same defect.
SOFTQ="The CEO looked at the queue this morning."
run_stderr() { # <tool> <path> <text> -> stderr on stdout
    payload "$@" | "$HOOK" 2>&1 >/dev/null
}
[ -z "$(run_stderr Write "$VS/engine/skills/vendored/references/soft.md" "$SOFTQ")" ] \
    && ok "V13. a vendored file draws no CEO-TODOs note either" \
    || bad "V13. a vendored file draws no CEO-TODOs note either" "it narrated about somebody else's document"
[ -n "$(run_stderr Write "$VS/engine/skills/mine/soft.md" "$SOFTQ")" ] \
    && ok "V14. ...and our own file still draws one (the note is not simply gone)" \
    || bad "V14. our own file still draws the CEO-TODOs note" "the suppression is unconditional, so V13 proves nothing"

# FAIL CLOSED when the registry is declared and unreadable. A guard that cannot
# tell whose bytes these are must not answer — carrying on is precisely how the
# 2026-08-30 edit happened.
VB="$SANDBOX/vendrepo-broken"
mkvendrepo "$VB" \
    'REDISTRIBUTABLE_PATHS="engine/skills"' \
    "engine/skills/vendored${TABX}third-party${TABX}MIT${TABX}S${TABX}u${TABX}r${TABX}2026${TABX}certain${TABX}verbatim"
case_exit "V6. a DECLARED but unreadable registry is fail-closed" 2 Write "$VB/engine/skills/vendored/references/x.md" "The colour is wrong."
case_msg  "V7. ...and it says the registry is why"              "DECLARED BUT UNREADABLE" Write "$VB/engine/skills/vendored/references/x.md" "The colour is wrong."

# THE FAIL-CLOSED IS AN `exit`, NOT A "TREAT IT AS OURS". The difference is
# invisible on a blocking finding — both spellings refuse — and it is the whole
# behavior on a REPORTING one: with the registry unreadable, a soft CEO-TODOs
# note about a file that may not be ours must not be emitted at all. V6 cannot
# see this and neither can V7; without this case the fail-closed branch is
# untested.
case_exit "V15. a broken registry also refuses a REPORTING verdict" \
    2 Write "$VB/engine/skills/vendored/references/x.md" "The CEO looked at the list this morning, and the queue was long."

# --- THE REAL FILES, IN THE REAL TREE -------------------------------------
# A mutation sandbox is a copy of scripts/ and hooks/ with no repository above
# it, so the shipped registry is absent there and these would go red for a
# reason unrelated to any mutated property.
if [ -n "${RICHOS_MUTATION_INNER:-}" ]; then
    echo "  (V8-V12 skipped inside a mutation sandbox — they are about the SHIPPED tree)"
else
    REPO_TOP="$(cd "$ENGINE_ROOT/.." && pwd)"
    case_exit "V8. THE DAMAGED FILE accepts upstream's own spelling" \
        0 Write "$REPO_TOP/engine/skills/copywriting/references/natural-transitions.md" "$BRITISH"
    case_exit "V9. the SECOND damaged file (landing-page-taste) too" \
        0 Write "$REPO_TOP/engine/skills/landing-page-taste/SKILL.md" "$BRITISH"

    # RE-VENDORING VERBATIM. Not the same assertion as V8: this is the WHOLE
    # upstream file, the bytes the 2026-08-30 sweep replaced, fetched from the
    # commit that replaced them. Before this change the repair was refused by
    # the guard that caused the damage.
    UP="$SANDBOX/upstream-natural-transitions.md"
    if git -C "$REPO_TOP" show 06f4a8221a61^:engine/skills/copywriting/references/natural-transitions.md >"$UP" 2>/dev/null \
       && [ -s "$UP" ]; then
        UPJSON="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Write", "tool_input": {
    "file_path": sys.argv[1],
    "content": open(sys.argv[2], encoding="utf-8").read()}}))' \
            "$REPO_TOP/engine/skills/copywriting/references/natural-transitions.md" "$UP")"
        printf '%s' "$UPJSON" | "$HOOK" >/dev/null 2>&1
        [ $? -eq 0 ] && ok "V10. RE-VENDORING the file VERBATIM from upstream succeeds" \
                     || bad "V10. RE-VENDORING the file VERBATIM from upstream succeeds" \
                            "the guard that caused the divergence still forbids the repair"
    else
        bad "V10. RE-VENDORING the file VERBATIM from upstream succeeds" \
            "could not read 06f4a8221a61^ — the check would have passed by never running"
    fi

    case_exit "V11. a RichOS-authored skill in the real tree is still blocked" \
        2 Write "$REPO_TOP/engine/skills/rich-lander/SKILL.md" "$BRITISH"

    # DOCUMENTING THE DIVERGENCE, in the tree's own legal record. The third
    # direction, and the one that was refused twice.
    case_exit "V12. quoting a foreign spelling in the notices document is possible" \
        0 Write "$REPO_TOP/docs/legal/THIRD-PARTY-NOTICES.md" "Upstream writes Emphasising; our copy writes Emphasizing."
fi

echo
if [ -z "${RICHOS_MUTATION_INNER:-}" ] && [ -x "$SCRIPT_DIR/guard-dialect.mutation.sh" ]; then
    # THE HARNESS RUNS FROM THE SUITE IT MUTATES. It did not until now, and
    # nothing else ran it either: run-all-tests.sh discovers *.test.sh, and
    # contract-integrity.test.sh names three harnesses, not this one. A harness
    # nobody runs proves nothing about anything.
    echo "=== running the mutation harness ==="
    "$SCRIPT_DIR/guard-dialect.mutation.sh" || FAIL=$((FAIL + 1))
    echo
fi

if [ "$FAIL" -eq 0 ]; then
    printf '\n  %d/%d cases passed\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '\n  %d/%d cases passed, %d FAILED\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
