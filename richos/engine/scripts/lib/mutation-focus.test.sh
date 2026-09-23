#!/usr/bin/env bash
#
# mutation-focus.test.sh — `mutation_focus` (scripts/lib/mutation-harness.sh) makes a
# mutant cheaper WITHOUT making its verdict easier to get.
#
# Two modes, and for each the case that must still be refused:
#
#   stop-at-want       F1 the run is stopped at the named FAIL line: PASS, fast, the
#                         suite's tail never reached, its EXIT trap ran, and nothing it
#                         started is left running;
#                      F2 a mutant whose named line never appears is judged exactly as
#                         before: the suite still passed, so the mutant FAILS.
#   want-as-argument   F3 the suite is handed the want and runs only that case: PASS;
#                      F4 a want that selects no case is refused by the unmutated control;
#                      F5 a case that fails when run alone is refused by the control, so
#                         its red can never be credited to a mutation;
#                      F6 the mutated run must still go red AT the want: a mutation the
#                         focused case does not notice FAILS.
#   F0 a harness that declares nothing runs every mutant against the whole suite, as
#      before (the suite sees no argument, and runs to its end).
#
# Fixture: a fake engine built the way mutation-harness.test.sh builds one (the copy
# list is read from mutation_copy_engine itself), with the REAL library files.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
SANDBOX="$(cd "$(mktemp -d -t mutation-focus-test.XXXXXX)" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT
# Scratch and the scratch ledger inside the sandbox: test data never touches live data,
# and a fixture engine under the real $TMPDIR would be refused as a copy source.
export TMPDIR="$SANDBOX/tmp"
export CLAUDE_CONFIG_DIR="$SANDBOX/claude"
mkdir -p "$TMPDIR" "$CLAUDE_CONFIG_DIR/state"
export RICHOS_MUTANT_JOBS=2

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '          %s\n' "$2"; FAIL=$((FAIL + 1)); }

echo "=== mutation-focus: a cheaper mutant is not an easier one ==="

FAKE_ENG="$SANDBOX/fake-engine"
REQUIRED_DIRS="$(awk '/^mutation_copy_engine\(\)/{f=1; next} f && /^}/{exit} f' \
        "$ENGINE_ROOT/scripts/lib/mutation-harness.sh" \
    | sed -nE 's#^[[:space:]]*cp -R "\$src/([A-Za-z0-9._-]+)" "\$dir/([A-Za-z0-9._-]+)" \|\| return 1[[:space:]]*$#\1#p')"
mkdir -p "$FAKE_ENG/scripts/hooks" "$FAKE_ENG/scripts/lib" "$FAKE_ENG/hooks"
for d in $REQUIRED_DIRS; do mkdir -p "$FAKE_ENG/$d"; done
mkdir -p "$FAKE_ENG/mega-lander/tests"
printf 'PROTECTED_PATHS="app"\n' > "$FAKE_ENG/orchestration.config"
printf '0.0.0-fixture\n' > "$FAKE_ENG/VERSION"
cp "$ENGINE_ROOT"/scripts/lib/*.sh "$FAKE_ENG/scripts/lib/"
cp "$ENGINE_ROOT/scripts/lib/stop-at-line.py" "$FAKE_ENG/scripts/lib/"
printf 'RULE_A=1\nRULE_B=1\nUNUSED=1\n' > "$FAKE_ENG/mega-lander/feature.sh"

PROBE="$SANDBOX/probe"; mkdir -p "$PROBE"
export FOCUS_PROBE="$PROBE"

# A SEQUENTIAL suite: X1 is decided early, then a long tail the verdict does not need.
cat > "$FAKE_ENG/mega-lander/tests/seq.test.sh" <<'EOF'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../feature.sh"
trap 'touch "$FOCUS_PROBE/trap-ran.$$"' EXIT
printf '%s\n' "$*" > "$FOCUS_PROBE/seq-args.$$"
red=0
if [ "${RULE_A:-0}" = 1 ]; then echo "      ok   X1.1 rule A holds"; else echo "      FAIL  X1.1 rule A holds"; red=1; fi
sleep "${FOCUS_TAIL:-15}" &
echo $! > "$FOCUS_PROBE/sleeper.$$"
wait
echo "      ok   X2.1 the tail"
touch "$FOCUS_PROBE/tail-reached.$$"
exit $red
EOF

# A NAMED suite: runs only the cases whose names begin with an argument.
cat > "$FAKE_ENG/mega-lander/tests/named.test.sh" <<'EOF'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../feature.sh"
printf '%s\n' "$*" >> "$FOCUS_PROBE/named-args"
red=0; ran=0
want() { [ "$#" -eq 0 ] && return 0; for a in $ARGS; do case "$1" in "$a"*) return 0 ;; esac; done; return 1; }
ARGS="$*"
case_() { # <name> <condition>
    if [ -n "$ARGS" ]; then want "$1" || return 0; fi
    ran=$((ran + 1))
    if eval "$2"; then echo "  PASS  $1"; else echo "  FAIL  $1"; red=1; fi
}
case_ T_alpha '[ "${RULE_A:-0}" = 1 ]'
case_ T_beta  '[ "${RULE_B:-0}" = 1 ]'
# Green in the full run, red alone: an order dependence a focused run must not launder.
case_ T_alone '[ -z "$ARGS" ]'
exit $red
EOF

harness() { # <file> <suite> <focus|-> <mutant lines...>
    local f="$1" suite="$2" focus="$3"; shift 3
    {
        echo '#!/usr/bin/env bash'
        echo 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
        echo '. "$SCRIPT_DIR/../../scripts/lib/mutation-harness.sh"'
        echo "mutation_begin \"fixture\" \"$suite\""
        [ "$focus" = "-" ] || echo "mutation_focus $focus"
        printf '%s\n' "$@"
        echo 'mutation_end'
    } > "$FAKE_ENG/mega-lander/tests/$f"
}

run_h() { # <file> -> RH_RC, RH_OUT, RH_SECS
    local t0; t0="$(date +%s)"
    RH_OUT="$(bash "$FAKE_ENG/mega-lander/tests/$1" 2>&1)"; RH_RC=$?
    RH_SECS=$(( $(date +%s) - t0 ))
}

M_A='mutant rule-a X1.1 mega-lander/feature.sh "RULE_A=1" "RULE_A=0" "rule A removed"'

# --- F0: nothing declared, the whole suite runs -----------------------------------
rm -f "$PROBE"/*
harness h0.sh mega-lander/tests/seq.test.sh - "$M_A"
FOCUS_TAIL=2 run_h h0.sh
if [ "$RH_RC" -eq 0 ] && grep -q '^  PASS  rule-a' <<<"$RH_OUT" && ls "$PROBE"/tail-reached.* >/dev/null 2>&1; then
    ok "F0  with no mutation_focus the mutant runs the whole suite (its tail was reached) and passes as before"
else
    bad "F0  no mutation_focus: whole suite, as before" "rc=$RH_RC tail=$(ls "$PROBE" | tr '\n' ' ') out=$(tail -5 <<<"$RH_OUT" | tr '\n' ' ')"
fi

# --- F1: stop-at-want stops at the line ---------------------------------------------
rm -f "$PROBE"/*
harness h1.sh mega-lander/tests/seq.test.sh stop-at-want "$M_A"
FOCUS_TAIL=30 run_h h1.sh
SLEEPER="$(cat "$PROBE"/sleeper.* 2>/dev/null | head -1)"
if [ "$RH_RC" -eq 0 ] && grep -q '^  PASS  rule-a .*stopped at that line' <<<"$RH_OUT"; then
    ok "F1a stop-at-want: the mutant is proven at its named line"
else
    bad "F1a stop-at-want proves the mutant" "rc=$RH_RC out=$(tail -5 <<<"$RH_OUT" | tr '\n' ' ')"
fi
if [ "$RH_SECS" -lt 20 ] && ! ls "$PROBE"/tail-reached.* >/dev/null 2>&1; then
    ok "F1b and it did not wait for the 30 s tail (${RH_SECS} s; the tail was never reached)"
else
    bad "F1b the run stops at the line" "${RH_SECS} s; tail reached: $(ls "$PROBE"/tail-reached.* 2>/dev/null)"
fi
if ls "$PROBE"/trap-ran.* >/dev/null 2>&1; then
    ok "F1c the stopped suite's EXIT trap ran, so its own cleanup is not skipped"
else
    bad "F1c the stopped suite's EXIT trap ran" "no trap-ran marker in $PROBE"
fi
if [ -n "$SLEEPER" ] && ! kill -0 "$SLEEPER" 2>/dev/null; then
    ok "F1d the process the suite started ($SLEEPER) is gone"
else
    bad "F1d nothing the stopped suite started is left running" "sleeper pid '${SLEEPER:-none}' is still alive"
    [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null
fi

# --- F2: the line never appears, the old verdict stands -----------------------------
rm -f "$PROBE"/*
harness h2.sh mega-lander/tests/seq.test.sh stop-at-want \
    'mutant unused X1.1 mega-lander/feature.sh "UNUSED=1" "UNUSED=0" "a change the suite cannot see"'
FOCUS_TAIL=1 run_h h2.sh
if [ "$RH_RC" -ne 0 ] && grep -q '^  FAIL  unused — the suite still PASSED' <<<"$RH_OUT"; then
    ok "F2  stop-at-want: a mutant whose named line never appears still FAILS as 'the suite still PASSED'"
else
    bad "F2  a mutant the suite cannot see is not proven" "rc=$RH_RC out=$(tail -5 <<<"$RH_OUT" | tr '\n' ' ')"
fi

# --- F3-F6: want-as-argument ----------------------------------------------------------
rm -f "$PROBE"/*
harness h3.sh mega-lander/tests/named.test.sh want-as-argument \
    'mutant alpha T_alpha mega-lander/feature.sh "RULE_A=1" "RULE_A=0" "rule A removed"' \
    'mutant nosuch T_nosuch mega-lander/feature.sh "RULE_A=1" "RULE_A=0" "a want that names no case"' \
    'mutant alone T_alone mega-lander/feature.sh "RULE_A=1" "RULE_A=0" "a case that is red alone"' \
    'mutant blind T_beta mega-lander/feature.sh "RULE_A=1" "RULE_A=0" "T_beta does not read rule A"'
run_h h3.sh
if grep -q '^  PASS  alpha ' <<<"$RH_OUT" && grep -qx 'T_alpha' "$PROBE/named-args"; then
    ok "F3  want-as-argument: the suite is handed the want, runs that case, and the mutant is proven"
else
    bad "F3  want-as-argument proves a focused mutant" "args seen: $(tr '\n' '|' < "$PROBE/named-args" 2>/dev/null) out=$(grep alpha <<<"$RH_OUT" | tr '\n' ' ')"
fi
if grep -q '^  FAIL  nosuch — the focused control is not green' <<<"$RH_OUT"; then
    ok "F4  a want that selects no case is refused by the unmutated control"
else
    bad "F4  a want naming nothing is refused" "$(grep -A2 nosuch <<<"$RH_OUT" | tr '\n' ' ')"
fi
if grep -q '^  FAIL  alone — the focused control is not green' <<<"$RH_OUT"; then
    ok "F5  a case that is red when run alone is refused by the control, never credited to the mutation"
else
    bad "F5  a case red alone is refused" "$(grep -A2 alone <<<"$RH_OUT" | tr '\n' ' ')"
fi
if grep -q '^  FAIL  blind — the suite still PASSED' <<<"$RH_OUT"; then
    ok "F6  a mutation the focused case does not notice still FAILS"
else
    bad "F6  a mutation the focused case cannot see is not proven" "$(grep -A2 blind <<<"$RH_OUT" | tr '\n' ' ')"
fi
if [ "$RH_RC" -ne 0 ]; then
    ok "F7  and the harness exits non-zero because three of its four mutants are not proven"
else
    bad "F7  the harness exits non-zero with unproven mutants" "rc=0"
fi

# --- F8: an unknown mode is refused, never ignored ----------------------------------
harness h8.sh mega-lander/tests/named.test.sh no-such-mode "$M_A"
run_h h8.sh
if [ "$RH_RC" -eq 2 ] && grep -q "unknown mode 'no-such-mode'" <<<"$RH_OUT"; then
    ok "F8  an unknown mutation_focus mode is refused (exit 2), not silently treated as no focus"
else
    bad "F8  an unknown mode is refused" "rc=$RH_RC out=$(tail -3 <<<"$RH_OUT" | tr '\n' ' ')"
fi

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
