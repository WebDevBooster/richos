#!/usr/bin/env bash
#
# stopwatch.test.sh — PROVE THE CLOCK BEFORE ANY NUMBER IS QUOTED FROM IT.
#
# A broken clock does not fail. It returns a number, and the number gets put in
# a table, and the table gets put in a plan. That is the entire history of this
# engine's cost estimates: `date +%s%3N` on BSD returns the literal string
# `17889976023N`, which is all-but-digits, parses under arithmetic, and is wrong
# by a factor of ten. Nothing anywhere would have gone red.
#
# So the properties pinned here are the ones whose violation is SILENT:
#
#   S1-S3  The plausibility check rejects the two epochs that are the right
#          shape and the wrong scale — a ten-digit SECOND epoch (durations come
#          out 1000x too small) and a sixteen-digit MICROsecond one (1000x too
#          large) — and the BSD literal-N string.
#
#          S1b EXISTS BECAUSE S1 PASSED FOR THE WRONG REASON, and it was caught
#          by watching this suite go red rather than by reading it. The real BSD
#          string `17889976023N` is TWELVE characters, so the WIDTH check
#          rejects it and the digit check never runs: deleting the digit check
#          outright left every case green. The digit check is load-bearing only
#          for a string that is thirteen characters AND not all digits, so S1b
#          is exactly that. Two checks, two inputs, each of which only one of
#          them can reject — otherwise "both properties hold" is one property
#          and a passenger.
#   S4-S6  Every method that claims to work returns thirteen digits, and the
#          selected method measures a KNOWN sleep to within a tolerance. A clock
#          that returns plausible constants would pass S1-S3 and fail here.
#   S7     `$EPOCHREALTIME` is parsed correctly in both radix conventions, and
#          when it is short. This is the bash >= 5 path, which is the one CI
#          takes and the one the operator's bash 3.2.57 never exercises — so it
#          is tested from a literal rather than from the live builtin.
#   S8     sw_fmt renders a missing measurement as `?`, never as 0.0s. A
#          suite whose timing was lost must not read as one that took no time.
#   S9     sw_init is idempotent and never fails, because a runner that aborts
#          because it could not find a clock has turned an instrument into a
#          gate.
#
# Everything here is arithmetic on strings plus one real sleep. No sandbox is
# needed and nothing is written anywhere.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '          %s\n' "$2"; FAIL=$((FAIL + 1)); }

# shellcheck source=stopwatch.sh
. "$SCRIPT_DIR/stopwatch.sh"

echo "=== stopwatch: a clock that names its own precision ==="

# --- S1-S3: the plausibility check rejects wrong-scale and non-numeric --------
# The real thing BSD `date +%s%3N` prints. Twelve characters, so it is the
# WIDTH check that rejects this one — see the header note on S1b.
if _sw_plausible_ms "17889976023N"; then
    bad "S1. BSD-literal-N-rejected" "accepted '17889976023N' — the BSD date trap"
else
    ok "S1. BSD-literal-N-rejected"
fi

# Thirteen characters and NOT all digits: the only shape the digit check alone
# can reject. Without it this is accepted, and `$(( ))` on it either errors or
# silently truncates depending on the shell.
if _sw_plausible_ms "1788997602N29"; then
    bad "S1b. 13-char-non-digit-rejected" \
        "accepted '1788997602N29' — right width, not a number: the digit check is not load-bearing"
else
    ok "S1b. 13-char-non-digit-rejected"
fi

if _sw_plausible_ms "1788997602"; then
    bad "S2. second-epoch-rejected" "accepted a 10-digit second epoch: every duration would be 1000x too small"
else
    ok "S2. second-epoch-rejected"
fi

if _sw_plausible_ms "1788997602829123"; then
    bad "S3. microsecond-epoch-rejected" "accepted a 16-digit microsecond epoch: every duration would be 1000x too large"
else
    ok "S3. microsecond-epoch-rejected"
fi

# The positive control for S1-S3. A check that rejects EVERYTHING passes those
# three for the wrong reason, which is this project's own recorded failure mode.
if _sw_plausible_ms "1788997602829"; then
    ok "S3b. NEGATIVE-CONTROL-a-real-13-digit-ms-epoch-is-accepted"
else
    bad "S3b. NEGATIVE-CONTROL-a-real-13-digit-ms-epoch-is-accepted" \
        "rejected a valid millisecond epoch — S1-S3 were passing because nothing is accepted"
fi

# --- S4: init picks a method and says which ---------------------------------
SW_METHOD=""
if sw_init && [ -n "$SW_METHOD" ]; then
    ok "S4. init-selects-a-named-method ($SW_METHOD)"
else
    bad "S4. init-selects-a-named-method" "SW_METHOD empty after sw_init"
fi

# --- S5: the selected method returns thirteen digits ------------------------
NOW="$(sw_now_ms)"
if _sw_plausible_ms "$NOW"; then
    ok "S5. selected-method-returns-13-digit-ms"
else
    bad "S5. selected-method-returns-13-digit-ms" "sw_now_ms returned '$NOW' via method '$SW_METHOD'"
fi

# --- S6: it measures a KNOWN interval -------------------------------------
# 1.0s slept, and the assertion is a WINDOW rather than an equality: a loaded
# machine can overshoot, and a clock that is merely a plausible constant
# undershoots to zero. The lower bound is what catches a frozen clock; the
# upper bound is generous because this suite runs alongside up to nine other
# concurrent mutants. `date-s-COARSE` has one-second granularity, so it is
# given the wider floor it honestly has instead of being failed for it.
SW_T0="$(sw_now_ms)"
sleep 1
SW_D=$(( $(sw_now_ms) - SW_T0 ))
if [ "$SW_METHOD" = "date-s-COARSE" ]; then
    SW_LO=0; SW_HI=3000
else
    SW_LO=900; SW_HI=6000
fi
if [ "$SW_D" -ge "$SW_LO" ] && [ "$SW_D" -le "$SW_HI" ]; then
    ok "S6. measures-a-known-1s-sleep (${SW_D}ms, window ${SW_LO}-${SW_HI})"
else
    bad "S6. measures-a-known-1s-sleep" \
        "a 1s sleep measured ${SW_D}ms via '$SW_METHOD' — outside ${SW_LO}-${SW_HI}ms"
fi

# --- S7: the bash >= 5 EPOCHREALTIME parse, in every form it arrives in -----
# Tested from literals BECAUSE the operator's bash cannot produce them. This is
# the CI path; leaving it to be exercised only on the runner is how a
# portability defect gets found by a red run instead of by a test.
#
# AND THE FIRST VERSION OF THIS CASE WAS ITSELF THAT DEFECT. It built its
# fixture with `EPOCHREALTIME="$1"`, which is a silent no-op on bash >= 5
# because the name is a dynamic variable there — so on the runner it compared
# the LIVE clock against these literals and went red on all five, while passing
# on the desk where the name is ordinary and the subject is dead. The value is
# passed as an argument now, and the last block below is a negative control on
# the fixture rather than on the parser.
S7_OK=1
S7_WHY=""
_s7() { # <input> <expected>
    local got
    # PASSED, NEVER ASSIGNED. `EPOCHREALTIME` is a dynamic variable in bash >= 5
    # and assigning to it is a silent no-op, so the previous form built no
    # fixture at all on the runner: it compared the LIVE clock against these
    # literals and S7 was red for every one of them. It passed on the operator's
    # bash 3.2 only because there the name is an ordinary variable — and there
    # the code path under test does not exist. A fixture that only works on the
    # host where the subject is dead is not a fixture.
    got="$(_sw_epochrealtime_ms "$1")"
    if [ "$got" != "$2" ]; then
        S7_OK=0
        S7_WHY="$S7_WHY '$1' -> '$got' (wanted '$2');"
    fi
}
_s7 "1788997602.829123" "1788997602829"
_s7 "1788997602.000001" "1788997602000"
_s7 "1788997602,829123" "1788997602829"     # comma radix under some locales
_s7 "1788997602.9"      "1788997602900"     # short fraction, right-padded
_s7 "1788997602"        "1788997602000"     # no fraction at all
# NEGATIVE CONTROL for the fixture itself, not for the parser: if the argument
# were ever ignored again, every case above would silently compare against the
# live clock and this one would too — but this one says so, because a clock
# reading can never equal a literal from 2026. It is the case that would have
# turned "S7 is red on Linux" into "the fixture is a no-op on Linux".
_s7_arg_check="$(_sw_epochrealtime_ms "1500000000.500000")"
if [ "$_s7_arg_check" != "1500000000500" ]; then
    S7_OK=0
    S7_WHY="$S7_WHY the supplied value was IGNORED (got '$_s7_arg_check') — the fixture is a no-op, not the parser wrong;"
fi
if [ "$S7_OK" -eq 1 ]; then
    ok "S7. EPOCHREALTIME-parsed-in-every-form"
else
    bad "S7. EPOCHREALTIME-parsed-in-every-form" "$S7_WHY"
fi

# --- S8: a missing measurement is `?`, never 0.0s ---------------------------
S8_OK=1
S8_WHY=""
_s8() { # <input> <expected>
    local got
    got="$(sw_fmt "$1")"
    if [ "$got" != "$2" ]; then S8_OK=0; S8_WHY="$S8_WHY '$1' -> '$got' (wanted '$2');"; fi
}
_s8 ""         "?"
_s8 "N"        "?"
_s8 "17889N"   "?"
_s8 "0"        "0.0s"
_s8 "999"      "0.9s"
_s8 "1266"     "1.2s"
_s8 "61500"    "1m01.5s"
_s8 "3723400"  "62m03.4s"
if [ "$S8_OK" -eq 1 ]; then
    ok "S8. fmt-renders-a-lost-measurement-as-question-mark"
else
    bad "S8. fmt-renders-a-lost-measurement-as-question-mark" "$S8_WHY"
fi

# --- S9: init is idempotent and never fails --------------------------------
S9_FIRST="$SW_METHOD"
if sw_init && [ "$SW_METHOD" = "$S9_FIRST" ]; then
    ok "S9. init-is-idempotent"
else
    bad "S9. init-is-idempotent" "a second sw_init changed the method to '$SW_METHOD' or failed"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
    echo "=== stopwatch: $FAIL failed, $PASS passed ==="
    exit 1
fi
echo "=== stopwatch: all $PASS properties hold (clock=$SW_METHOD) ==="
exit 0
