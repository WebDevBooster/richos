#!/usr/bin/env bash
# run-suite.sh <label> [K=V ...] <suite-path-relative-to-engine> [suite args]
# One process, foreground. HOME moved to a scratch home (operator's .gitconfig copied in).
# The REAL record is witnessed per run through record-canary.sh, captured BEFORE HOME moves.
set -uo pipefail
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/b7869424-972c-4693-80f8-5e034a119d86/scratchpad/r5
ENGINE=/Users/alex/ab/richos-wt/frank-fable-cert5/engine
LABEL="$1"; shift
while [ "$#" -gt 0 ] && printf '%s' "$1" | grep -Eq '^[A-Z_][A-Z0-9_]*='; do export "$1"; shift; done
SUITE="$1"; shift
mkdir -p "$SP/suites" "$SP/home/.claude"
[ -f "$HOME/.gitconfig" ] && cp "$HOME/.gitconfig" "$SP/home/.gitconfig"
unset CLAUDE_CONFIG_DIR
. "$ENGINE/scripts/lib/record-canary.sh"      # captures the REAL paths now
rc_baseline "$SP/suites/$LABEL.record-before.txt"
B_HEALTHY="$RC_HEALTHY"
python3 "$SP/record-baseline.py" > "$SP/suites/$LABEL.counts-before.txt" 2>&1
REAL_HOME="$HOME"
export HOME="$SP/home"
cd "$ENGINE" || exit 99
LOG="$SP/suites/$LABEL.log"
S=$(date +%s)
case "$SUITE" in
    *.py) python3 "$SUITE" "$@" > "$LOG" 2>&1; RC=$? ;;
    *)    bash "$SUITE" "$@" > "$LOG" 2>&1; RC=$? ;;
esac
E=$(date +%s)
export HOME="$REAL_HOME"
TOUCHED="$(rc_escaped "$SP/suites/$LABEL.record-before.txt")"
python3 "$SP/record-baseline.py" > "$SP/suites/$LABEL.counts-after.txt" 2>&1
if [ -n "$TOUCHED" ]; then T="RECORD-TOUCHED"; else T="record-untouched"; fi
HEAD="$(git -C "$ENGINE" rev-parse --short HEAD)"
printf '%s\trc=%s\twall=%ss\t%s\t%s\t%s\thealthy=%s\n' "$LABEL" "$RC" "$((E - S))" "$(date -u +%FT%TZ)" "$HEAD" "$T" "$B_HEALTHY" >> "$SP/RESULTS.tsv"
printf '%s rc=%s wall=%ss %s\n' "$LABEL" "$RC" "$((E - S))" "$T"
[ -n "$TOUCHED" ] && printf 'TOUCHED:\n%s\n' "$TOUCHED"
tail -n 4 "$LOG"
exit "$RC"
