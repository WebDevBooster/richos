#!/usr/bin/env bash
#
# reference-ledger.mutation.sh — PROVES THE REFERENCE-LEDGER SUITE CAN FAIL.
#
# guard-reference-ledger.test.sh is 39 green ticks, and a suite that cannot go
# red is a suite that proves nothing. Each mutant below removes ONE property of
# the guard — a property somebody could plausibly delete while "simplifying the
# rules" — and requires:
#
#   1. guard-reference-ledger.test.sh FAILS, and
#   2. it fails AT THE NAMED CASE, so the red is caused by the removal and not
#      by some unrelated breakage the mutation happened to cause.
#
# THE MUTANTS ARE THE DESIGN DECISIONS, not the code's surface. Every one of
# them leaves the guard still refusing something obvious, still passing its
# easy cases, and quietly broken in the direction ceo-decisions §66 cares
# about — which is the only kind of regression worth a harness.
#
# THREE OF THEM ARE DEFECTS THIS GUARD ACTUALLY HAD, caught by measurement
# before it shipped and named as such below: read-veto-unquantified,
# read-only-bare and weak-paths-strong. They are not hypotheses.
#
# NO BACKTICK APPEARS IN THIS FILE, deliberately — case Z3 of
# host-display-power.mutation.sh is the precedent, and this harness edits a
# file whose own python blocks live inside command substitutions where a lone
# backtick opens one. Where a mutation needs one it is written as \x60.
#
# Run directly: scripts/hooks/reference-ledger.mutation.sh
# Exit 0 = every property is load-bearing; exit 1 = at least one is not.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t reference-ledger-mutation.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required" >&2; exit 1; }

cat >"$SANDBOX/mutate.py" <<'PYEOF'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
old = old.replace("\\n", "\n")
new = new.replace("\\n", "\n")
with open(path, encoding="utf-8") as fh:
    src = fh.read()
if old not in src:
    sys.stderr.write("MUTATION TARGET ABSENT — the source has drifted:\n  %s\n" % old)
    sys.exit(3)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(src.replace(old, new, 1))
PYEOF

# shellcheck source=../lib/stopwatch.sh
. "$ENGINE_ROOT/scripts/lib/stopwatch.sh"
# shellcheck source=../lib/mutation-pool.sh
. "$ENGINE_ROOT/scripts/lib/mutation-pool.sh"
mut_pool_init
MUT_WALL_T0="$(sw_now_ms)"

_mutant_body() {
    local name="$1" want="$2" rel="$3" old="$4" new="$5" why="$6"
    local dir="$SANDBOX/$name"
    mkdir -p "$dir/scripts/hooks" "$dir/hooks" "$dir/.claude"
    cp "$ENGINE_ROOT/scripts/hooks/guard-reference-ledger.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-reference-ledger.test.sh" \
       "$ENGINE_ROOT/scripts/hooks/adoption-ledger.surfaces" \
       "$dir/scripts/hooks/"
    # THE WHOLE lib/, not a named list. This guard reaches resolve-roots.sh,
    # unevaluated-notice.sh and whatever those reach in turn; a typed list of
    # libraries is the stale inventory this engine keeps finding in itself, and
    # a missing one here would make every mutant "fail" for the wrong reason.
    cp -R "$ENGINE_ROOT/scripts/lib" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/hooks/hooks.json" "$dir/hooks/" 2>/dev/null || true
    cp "$ENGINE_ROOT/orchestration.config" "$dir/"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        return 1
    fi

    RICHOS_MUTATION_INNER=1 bash "$dir/scripts/hooks/guard-reference-ledger.test.sh" \
        >"$dir/out.txt" 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '  FAIL  %s — the suite still PASSED without this property.\n' "$name"
        printf '          %s\n' "$why"
        return 1
    fi
    if ! grep -q "FAIL  $want" "$dir/out.txt"; then
        printf '  FAIL  %s — the suite went red, but NOT at %s (so the red is unrelated).\n' "$name" "$want"
        grep '  FAIL' "$dir/out.txt" | sed 's/^/          /'
        return 1
    fi
    printf '  PASS  %s — removing it turns %s red\n' "$name" "$want"
    return 0
}

mutant() {
    mut_pool_submit "$1" _mutant_body "$@"
}

echo "=== the reference-ledger guard: every property, proven load-bearing by removing it ==="

G="scripts/hooks/guard-reference-ledger.sh"

# --- 1. IT BLOCKS AT ALL ---------------------------------------------------
mutant refuses-to-refuse "A1 " "$G" \
    '    echo "(hook: scripts/hooks/guard-reference-ledger.sh)"\n} >&2\nexit 2' \
    '    echo "(hook: scripts/hooks/guard-reference-ledger.sh)"\n} >&2\nexit 0' \
    "the guard would find the surface, print the ledger row and the CEO's sentence, and dispatch the rebuild anyway — a warning wearing a guard's clothes."

# --- 2. THE SURFACES ARE DATA ---------------------------------------------
# The whole design. If the rows stop being read, adding an area becomes a code
# change and nobody will make it.
mutant surfaces-file-ignored "A1 " "$G" \
    'AREAS = [r for r in rows if r.get("area")]' \
    'AREAS = []' \
    "the data file would decide nothing and the guard would be silent forever — green, wired, and protecting nothing, which is the one failure mode this engine calls worse than no guard."

# --- 3. THE BUILD SECTION IS WHAT MAKES IT A BUILD -------------------------
mutant every-heading-is-a-build "C4 " "$G" \
    '        if BUILD_RE.match(title):' \
    '        if True:' \
    "every section of every prompt would be read for signals, so Ray's VM walk and Reed's adoption read are refused — and a guard that refuses the research it exists to promote gets switched off in a day."

# --- 4. THE READ VETO ------------------------------------------------------
# WANT F2, NOT C2, AND THE REASON IS A FINDING: Reed's read is kept out by the
# BUILD-SECTION conjunct as well — its headings are "What to read" and "What to
# deliver", neither of which names files to edit — so removing the read veto
# alone does not reach it. The two conjuncts each cover a case the other
# misses, which is the whole argument for having both.
mutant no-read-veto "F2 " "$G" \
    'if IS_READ:\n    print("CLEAN"); sys.exit(0)' \
    'if False:\n    print("CLEAN"); sys.exit(0)' \
    "Reed's read, which COMMISSIONED the ledger and names every area in it, would be refused for not citing the document it was sent to write."

# --- 5. THE READ VETO IS QUANTIFIED ---------------------------------------
# A DEFECT THIS GUARD HAD. Measured on the real delivery brief.
mutant read-veto-unquantified "F1 " "$G" \
    '    r"\b(?:fix|change|modify|edit) nothing\b",' \
    '    r"\bdo not touch\b",' \
    "a build brief that says 'you do not touch the host keychain' about ONE file, while commissioning changes to six others, exempts itself — and that sentence is in the very brief §66 is about."

# --- 6. read-only IS NOT A READ ON ITS OWN --------------------------------
# A DEFECT THIS GUARD HAD, from the same brief, one line further down.
mutant read-only-bare "F1 " "$G" \
    '    r"\bread-only (?:read|task|dispatch|brief|audit|walk|pass|job)\b",' \
    '    r"\bread-only\b",' \
    "'(Rich read 6 attribute lines for that service, read-only; nothing deleted)' — a parenthesis about what the LEAD already did — would exempt the whole dispatch."

# --- 7. WEAK PATHS ARE WEAK -----------------------------------------------
# A DEFECT THIS GUARD HAD. Fires were 32 with this treated as strong, 11 with it
# treated as weak, and the eleven include everything the thirty-two did.
mutant weak-paths-strong "D1 " "$G" \
    '    topical = any(rx.search(blob) for rx in term_res) if weak else False' \
    '    topical = True' \
    "twelve phone briefs about button focus, scroll position and splash placement would each be refused for naming app/ui/phone.js, and a guard that fires on twelve innocents to catch one gets waived by habit."

# --- 8. A BACKTICKED PATH IS THE SIGNAL, NOT A QUOTATION ------------------
mutant code-spans-stripped "A1 " "$G" \
    '            for p in paths:\n                if p.lower() in low:' \
    '            low = re.sub(r"\x60[^\x60\x0a]*\x60", " ", low)\n            for p in paths:\n                if p.lower() in low:' \
    "every path in every Scope section is written in code quotes, so stripping them makes the guard blind to exactly the lines that name the files about to be edited. This is the OPPOSITE of the prose guards and the divergence is deliberate."

# --- 9. A BARE MARKER EXEMPTS NOTHING -------------------------------------
mutant bare-marker-exempts "E1 " "$G" \
    'if BARE_RE.search(blob):\n    print("BARE")' \
    'if BARE_RE.search(blob):\n    print("CLEAN"); sys.exit(0)' \
    "typing the word 'reference:' with nothing after it would exempt any dispatch, which converts the whole mechanism into a five-character ritual."

# --- 10. THE CITATION MUST NAME THE REFERENCE -----------------------------
mutant ledger-name-not-required "E3 " "$G" \
    '            if [ "$REF_NAMES_DOC" -eq 0 ]; then\n                REF_WHY=' \
    '            if false; then\n                REF_WHY=' \
    "a bare section number would pass, so the next reader cannot tell WHICH document answered this and has to find it again — which is the work the ledger exists to stop."

# --- 11. THE CITATION MUST NAME A SECTION ---------------------------------
mutant section-not-required "E2 " "$G" \
    '            elif [ -z "$REF_CITE" ]; then' \
    '            elif false; then' \
    "naming the document without a row would pass. A 200-line ledger is not an answer; a row is, and being made to find the row is most of the value."

# --- 12. THE SECTION MUST EXIST -------------------------------------------
mutant citation-unchecked "E5 " "$G" \
    '                if grep -qE "^#{1,6}' \
    '                if true; then :; elif grep -qE "^#{1,6}' \
    "a citation of a section that is not in the ledger would be accepted. The three briefs this guard exists for were CONFIDENT, not careless — the day before, one of them asserted a CEO ruling that says the opposite — and only a citation that must open the file cannot be written from memory."

# --- 13. AN ARGUED ABSENCE IS ARGUED --------------------------------------
mutant none-reason-unmeasured "E4b" "$G" \
    '            if [ "${REF_LEN:-0}" -lt 41 ]; then' \
    '            if false; then' \
    "'reference: none' with nothing after it would exempt anything, so the hatch becomes an off switch anybody can type, and the log that makes waiving visible fills with the word none."

mut_pool_drain
mut_pool_require_submissions "$(basename "$0")"
PASS=$(( PASS + MUT_POOL_PASS ))
FAIL=$(( FAIL + MUT_POOL_FAIL ))
mut_pool_report_line "$(( $(sw_now_ms) - MUT_WALL_T0 ))"
mut_pool_cleanup

echo
if [ "$FAIL" -eq 0 ]; then
    printf '\n  %d/%d properties proven load-bearing\n' "$PASS" "$((PASS + FAIL))"
    exit 0
fi
printf '\n  %d/%d properties proven load-bearing, %d NOT\n' "$PASS" "$((PASS + FAIL))" "$FAIL"
exit 1
