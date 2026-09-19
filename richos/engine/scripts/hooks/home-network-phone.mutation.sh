#!/usr/bin/env bash
#
# home-network-phone.mutation.sh — PROVES THE HOME-NETWORK/PHONE SUITE CAN FAIL.
#
# guard-no-home-network-phone.test.sh is 44 green ticks, and a suite that
# cannot go red is a suite that proves nothing. Each mutant below removes ONE
# property of the guard — a property somebody could plausibly delete while
# "simplifying" the regexes — and requires:
#
#   1. guard-no-home-network-phone.test.sh FAILS, and
#   2. it fails AT THE NAMED CASE, so the red is caused by the removal and not
#      by some unrelated breakage the mutation happened to cause.
#
# THE MUTANTS ARE CHOSEN FROM THE DESIGN DECISIONS THE MEASUREMENT MADE, not
# from the code's surface. Every one of them is a change that leaves the guard
# still blocking something, still passing its obvious cases, and quietly
# broken in the direction the ruling cares about — which is the only kind of
# regression worth a harness.
#
# Run directly: scripts/hooks/home-network-phone.mutation.sh
# Exit 0 = every property is load-bearing; exit 1 = at least one is not.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t home-network-phone-mutation.XXXXXX)" && pwd -P)"
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
    cp "$ENGINE_ROOT/scripts/hooks/guard-no-home-network-phone.sh" \
       "$ENGINE_ROOT/scripts/hooks/guard-no-home-network-phone.test.sh" \
       "$dir/scripts/hooks/"
    # THE WHOLE lib/, not a named list. This guard reaches resolve-roots.sh,
    # unevaluated-notice.sh, ceo-ruled.sh and whatever those reach in turn; a
    # typed list of libraries is the stale inventory this engine keeps finding
    # in itself, and a missing one here would make every mutant "fail" for the
    # wrong reason.
    cp -R "$ENGINE_ROOT/scripts/lib" "$dir/scripts/lib"
    cp "$ENGINE_ROOT/hooks/hooks.json" "$dir/hooks/" 2>/dev/null || true
    cp "$ENGINE_ROOT/.claude/settings.local.json" "$dir/.claude/" 2>/dev/null || true
    cp "$ENGINE_ROOT/orchestration.config" "$dir/"
    chmod +x "$dir/scripts/hooks/"*.sh

    if ! python3 "$SANDBOX/mutate.py" "$dir/$rel" "$old" "$new" 2>"$dir/mutate.err"; then
        printf '  FAIL  %s — the mutation did not apply\n' "$name"
        sed 's/^/          /' "$dir/mutate.err"
        return 1
    fi

    RICHOS_MUTATION_INNER=1 bash "$dir/scripts/hooks/guard-no-home-network-phone.test.sh" \
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

echo "=== the home-network/phone guard: every property, proven load-bearing by removing it ==="

G="scripts/hooks/guard-no-home-network-phone.sh"

# --- 1. IT BLOCKS AT ALL ---------------------------------------------------
mutant refuses-to-refuse "A1 " "$G" \
    '    echo "(hook: scripts/hooks/guard-no-home-network-phone.sh)"\n} >&2\nexit 2' \
    '    echo "(hook: scripts/hooks/guard-no-home-network-phone.sh)"\n} >&2\nexit 0' \
    "the guard would find every site, print the whole ruling, and let the brief through — a warning wearing a guard's clothes."

# --- 2. CONJUNCT (a) IS WHAT KEEPS IT OUT OF EVERY OTHER REPOSITORY --------
mutant no-phone-conjunct "E1 " "$G" \
    'if not (PHONE_RE.search(blob) or PHONE_PATH_RE.search(path)):\n    print("CLEAN"); sys.exit(0)' \
    'if False:\n    print("CLEAN"); sys.exit(0)' \
    "every repository on the machine would be judged on the word 'home network' alone, and a guard that fires on other people's work is a guard that gets switched off."

# --- 3. CONJUNCT (c) IS WHAT LETS THE RULING BE WRITTEN DOWN --------------
mutant no-negation-clause "D1 " "$G" \
    'if NEG_RE.search(body) and not RETAIN_RE.search(body):\n        continue' \
    'if False:\n        continue' \
    "§61 itself, and the brief that removes the At-home route, would both be refused — the guard would forbid the record of the thing it forbids."

# --- 4. THE RETENTION VETO ------------------------------------------------
mutant no-retention-veto "A8 " "$G" \
    'if NEG_RE.search(body) and not RETAIN_RE.search(body):' \
    'if NEG_RE.search(body):' \
    "'Do not remove the At-home option' carries a removal word, so the second of the two sentences the ruling names would exempt itself."

# --- 5. CODE IS SCORED PER LINE -------------------------------------------
mutant code-scored-as-prose "B1 " "$G" \
    '    prose = (ext in PROSE_EXT) or (ext == "" and base != "")' \
    '    prose = True' \
    "the two route buttons in phone.js are adjacent, the first says 'away from home', and as one block it exempts the second — the exact markup this ruling is about would ship."

# --- 6. THE HATCH IS NOT A MARKER -----------------------------------------
# The target is the ADMISSION, not either half of the validation: a citation
# needs a section AND a quotation, so disabling one alone leaves the other
# refusing and proves nothing. This removes the requirement that the citation
# be sound at all, which is the regression worth naming.
mutant bare-marker-exempts "F6 " "$G" \
    '    if [ -z "$ACK_WHY" ]; then\n        mkdir -p "$LOG_DIR" 2>/dev/null || true' \
    '    if true; then\n        mkdir -p "$LOG_DIR" 2>/dev/null || true' \
    "a bare 'ceo-ruled-home-network: yes' would exempt anything, so the escape hatch becomes an off switch anyone can type."

# --- 7. THE CITATION MUST RESOLVE AGAINST THE RECORD ----------------------
# This is the mutant that matters most: the failure of 2026-09-19 was a
# CONFIDENT citation of a ruling that says the opposite, not a thin reason.
mutant citation-unchecked "F4 " "$G" \
    'if [ "$ACK_STATE" = "absent" ]; then' \
    'if false; then' \
    "'§99 keeps both' would be accepted exactly like '§61 keeps both' was — a citation nobody opened the file to check, which is the whole failure."

# --- 8. A WEAK SIGNAL NEEDS A SECOND --------------------------------------
mutant weak-signal-alone "E3 " "$G" \
    'if len(set(x.group(0).lower() for x in ms)) >= 2:' \
    'if len(ms) >= 1:' \
    "'sixteen' is a number word: the brief that STARTED the Tailscale path says 'sixteen taps' once, describing what exists, and would be refused for it."

# --- 9. QUOTED MATTER IS SOMEBODY ELSE'S ----------------------------------
# THE ONE THE REAL CORPUS PROVES. Measured: removing the bare-"..." stripper
# turns D1, D2 and D3 red — the whole removal brief is refused, and so is a
# sentence quoting the refused sentence. Removing the curly, emphasis-quote or
# code-span stripper changes NO verdict on any of the 269 documents, so those
# three are covered by CONSTRUCTED cases below and are named as such rather
# than sold as measured.
# The target avoids a literal \n: mutate.py expands "\n" into a real newline,
# so a needle containing a regex character class like [^"\n] can never match.
mutant quotes-not-stripped "D1 " "$G" \
    '    SPANS.append(' \
    '    pass  #' \
    "quoting a refused sentence — which is how a mistake gets recorded — would itself be refused, and so would the entire brief that removed the route."

mutant curly-not-stripped "D5 " "$G" \
    're.compile(r"“.*?”", re.DOTALL),' \
    're.compile(r"(?!x)x"),' \
    "a curly quotation whose block carries no negation would be refused; the provenance apparatus emits exactly that shape and happens to annotate it, which is luck and not a design."

mutant emphasis-quote-not-stripped "D6 " "$G" \
    're.compile(r"\*+\".*?\"\*+", re.DOTALL),' \
    're.compile(r"(?!x)x"),' \
    "this record quotes the CEO as *\"...\"*, and a ruling that reinstated the home path would be refused for quoting him saying so."

# --- 10. THE SELF-EXEMPTION -----------------------------------------------
mutant no-self-exemption "H1 " "$G" \
    'guard-no-home-network-phone.sh|guard-no-home-network-phone.test.sh|home-network-phone.mutation.sh|home-network-phone.corpus.md)\n        exit 0 ;;' \
    'guard-no-home-network-phone-NOTHING.sh)\n        exit 0 ;;' \
    "this guard could not be authored, tested or repaired, and a guard that cannot be repaired is a guard somebody deletes."

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
