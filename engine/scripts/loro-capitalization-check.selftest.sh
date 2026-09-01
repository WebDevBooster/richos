#!/usr/bin/env bash
#
# loro-capitalization-check.selftest.sh — checks for the by-hand tool next door.
#
# THE FILE NAME IS DELIBERATE. It is `.selftest.sh`, NOT `.test.sh`, because
# run-all-tests.sh discovers suites with `find -name '*.test.sh'` anywhere under
# the engine. Named the ordinary way, this would join the engine's suite
# inventory and the machinery would start depending on a tool that is
# DELIBERATELY UNREGISTERED by CEO ruling 2026-09-01 ("using a guard just for
# that is probably overkill"). Do not rename it. Run it by hand:
#
#   scripts/loro-capitalization-check.selftest.sh
#
# Four halves, and B is the one that matters most.
#
#   A. FIRM findings — the two shapes that measured 0% false positive are found,
#      in markdown and in source comments, and set exit 1.
#   B. QUIET — every case here is a REAL SITE from the 2026-09-01 sweep that the
#      tool must NOT report: the sentence-case heading, the mid-sentence generic
#      use, the hyphenated command name, the path, the fenced block, the inline
#      span, the blockquote (including behind a comment lead), the abbreviation,
#      the numbered heading, the code line, the captured-evidence path, the
#      already-capital word, and the line-initial word after a wrap. The tool's
#      whole claim is that it declines what it cannot adjudicate.
#   C. MAYBE — the 60%-false-positive shape is reported as MAYBE and does NOT
#      set exit 1, and --firm-only drops it entirely.
#   D. NOT REGISTERED — the ruling itself, asserted. If any of these fail,
#      somebody wired the tool up and should not have.
#
# Exit 0 = all cases pass; exit 1 = at least one failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TOOL="$SCRIPT_DIR/loro-capitalization-check.sh"
CORPUS="$SCRIPT_DIR/loro-capitalization.corpus.md"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t loro-caps-selftest.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ — $2}"; FAIL=$((FAIL + 1)); }

N=0
# subject <relative-path> <text> -> prints the absolute path it wrote
subject() {
    N=$((N + 1))
    local f="$SANDBOX/case$N/$1"
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$2" > "$f"
    printf '%s' "$f"
}

# firm <name> <rel-path> <text> — must report FIRM and exit 1
firm() {
    local name="$1" f out rc
    f="$(subject "$2" "$3")"
    out="$("$TOOL" "$f" 2>&1)"; rc=$?
    if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q '^FIRM'; then ok "$name"
    else bad "$name" "rc=$rc out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
}

# quiet <name> <rel-path> <text> — must report nothing at all and exit 0
quiet() {
    local name="$1" f out rc
    f="$(subject "$2" "$3")"
    out="$("$TOOL" "$f" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qE '^(FIRM|MAYBE)'; then ok "$name"
    else bad "$name" "rc=$rc out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
}

# maybe <name> <rel-path> <text> — must report MAYBE and still exit 0
maybe() {
    local name="$1" f out rc
    f="$(subject "$2" "$3")"
    out="$("$TOOL" "$f" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q '^MAYBE'; then ok "$name"
    else bad "$name" "rc=$rc out=$(printf '%s' "$out" | head -2 | tr '\n' ' ')"; fi
}

echo "=== A. FIRM — the two 0%-false-positive shapes ==="

firm "A1. sentence start after a period"        "a.md"  "Rich thinks and acts. loro remembers and learns."
firm "A2. heading that OPENS with the word"     "a.md"  "# loro architecture — beyond Karpathy's LLM Wiki"
firm "A3. heading opening with it, emphasized"  "a.md"  "## **loro** is the memory under every thread"
# The real shape from wiki/loro-architecture.md:46 — the sentence ends inside a
# bold run, so the closer is '**' and not whitespace. Missing this cost eight
# true positives when it was measured.
firm "A4. sentence ending inside a bold run"    "a.md"  "9. **Push, not just pull.** loro feeds an attention engine."
firm "A5. rustdoc comment prose in a .rs file"  "a.rs"  "//! NOT siloed conversations. loro is the shared memory."
firm "A6. block-comment prose in a .js file"    "a.js"  " * THE GAP THIS CLOSES. loro had no writer at all."
firm "A7. a shell comment is prose too"         "a.sh"  "# A thin slice means it does not know. loro refuses to guess."

echo
echo "=== B. QUIET — every one of these is a real site it must not touch ==="

quiet "B1.  mid-sentence generic use"           "b.md"  "Add this to loro before the next session."
quiet "B2.  sentence-case heading, not first"   "b.md"  "## What loro is"
quiet "B3.  sentence-case heading, numbered"    "b.md"  "### 8.3 loro compiler and writer: use, do not absorb"
quiet "B4.  the word after a dash in a heading" "b.md"  "## Defect 4 — loro had no writer"
quiet "B5.  already capital"                    "b.md"  "It ranks. Loro does not guess."
quiet "B6.  ALL CAPS rendered UI string"        "b.md"  "The chrome reads: LORO · 14 MONTHS · 7,500 MEMORIES"
quiet "B7.  a path token"                       "b.md"  "Terms come from loro/entities.json at load."
quiet "B8.  inline code span"                   "b.md"  "It ranks. \`loro\` is the corpus root name."
quiet "B9.  fenced code block"                  "b.md"  "before
\`\`\`js
const x = 1; // done. loro next
\`\`\`
after"
quiet "B10. blockquote — not ours to re-case"   "b.md"  "He wrote:
> The wall holds. loro keeps scopes.
and that settles it."
# loro/lib/privacy.js quotes wiki/loro-architecture.md this way. Without the
# comment-lead half of the blockquote rule this was a measured false positive.
quiet "B11. blockquote BEHIND a comment lead"   "b.js"  " * > Company memory is sensitive. loro keeps memory SCOPES."
quiet "B12. hyphenated command name"            "b.md"  "It ranks. loro-context compile --topic x"
quiet "B13. hyphenated compound in a comment"   "b.js"  " * 5. loro-CORRECTION      P1 seam (identity pass)"
quiet "B14. an identifier with an underscore"   "b.sh"  "# It ranks. LORO_CORPUS is read once."
quiet "B15. a CODE line is not prose"           "b.js"  "  ['Pointer', 'A mirror is a POINTER. loro indexes it.'],"
quiet "B16. an object key in a code line"       "b.js"  "const DESKS = {
  loro: { available: null },
};"
quiet "B17. abbreviation 'e.g.'"                "b.md"  "the generic sense, e.g. loro as a category noun"
quiet "B18. abbreviation 'i.e.'"                "b.md"  "the memory layer, i.e. loro, is not the ledger"
quiet "B19. captured evidence under raw/"       "wiki/raw/p.md" "It ranks. loro does not guess."
quiet "B20. a captured cold-open transcript"    "docs/cold-open/p.md" "It ranks. loro does not guess."
quiet "B21. a fixture directory"                "loro/test/fixtures/p.md" "It ranks. loro does not guess."
quiet "B22. a .txt file (captured output)"      "docs/verification/o.txt" "second half. loro's writer is done"
quiet "B23. declared 'loro-caps-exempt: why'"   "b.md"  "It ranks. loro does not guess.  <!-- loro-caps-exempt: verbatim from the CEO's own message -->"
# THE SHAPE IT DELIBERATELY DOES NOT ATTEMPT, asserted so that "it does not
# catch this" stays a decision rather than becoming a bug report.
quiet "B24. a line-initial word after a WRAP"   "b.md"  "dense meshes where the
loro is thick (Customers, Product)"

# A BARE marker exempts nothing — the escape hatch must not become an off switch
# anyone can type.
firm  "B25. a BARE 'loro-caps-exempt:' exempts nothing" "b.md" "It ranks. loro does not guess.  <!-- loro-caps-exempt: -->"

echo
echo "=== C. MAYBE — the 60%-false-positive shape never sets a failing exit ==="

maybe "C1. a bullet opening with the word"      "c.md"  "- loro references"
maybe "C2. a table cell opening with the word"  "c.md"  "| loro corpus, journals, config | data (the user's) |"

C3F="$(subject "c.md" "- loro references")"
OUT="$("$TOOL" --firm-only "$C3F" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^MAYBE'; then
    ok "C3. --firm-only drops the MAYBE shape entirely"
else
    bad "C3. --firm-only drops the MAYBE shape entirely" "rc=$RC"
fi

echo
echo "=== D. NOT REGISTERED — CEO ruling 2026-09-01, asserted ==="

if ! grep -rq 'loro-capitalization' "$ENGINE_ROOT/hooks/hooks.json"; then
    ok "D1. absent from the plugin surface (hooks/hooks.json)"
else
    bad "D1. absent from the plugin surface (hooks/hooks.json)" "somebody registered it — the CEO ruled it should not be"
fi

if ! grep -rq 'loro-capitalization' "$ENGINE_ROOT/.claude/settings.local.json"; then
    ok "D2. absent from the seated surface (.claude/settings.local.json)"
else
    bad "D2. absent from the seated surface (.claude/settings.local.json)" "somebody registered it"
fi

if ! grep -rq 'loro-capitalization' "$ENGINE_ROOT/scripts/hooks/contract-integrity-probe.sh" \
                                     "$ENGINE_ROOT/scripts/hooks/contract-integrity.test.sh" \
                                     "$ENGINE_ROOT/scripts/hooks/engine-status.test.sh" \
                                     "$ENGINE_ROOT/scripts/demo.sh" 2>/dev/null; then
    ok "D3. absent from the probe, the meta-suite, the sandbox lists and the demo"
else
    bad "D3. absent from the probe, the meta-suite, the sandbox lists and the demo" "the machinery now depends on an unregistered tool"
fi

if ! grep -q 'LORO_CAPS' "$ENGINE_ROOT/orchestration.config"; then
    ok "D4. no orchestration.config switch — nothing to turn on"
else
    bad "D4. no orchestration.config switch" "a switch implies a guard behind it"
fi

if [ ! -e "$SCRIPT_DIR/hooks/loro-capitalization-check.sh" ] && \
   [ ! -e "$SCRIPT_DIR/hooks/guard-loro-capitalization.sh" ]; then
    ok "D5. the tool does not live in scripts/hooks/"
else
    bad "D5. the tool does not live in scripts/hooks/" "a file in hooks/ reads as a hook"
fi

if [ -f "$CORPUS" ] && grep -q '0.0%' "$CORPUS"; then
    ok "D6. the measured corpus ships beside the tool"
else
    bad "D6. the measured corpus ships beside the tool"
fi

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\n  %d/%d cases passed\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '\n  %d/%d cases passed, %d FAILED\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
