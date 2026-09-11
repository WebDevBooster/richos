#!/usr/bin/env bash
# ci-shape.sh <label> <suite> [args] — CI's shape: a FRESH empty HOME (only .gitconfig), the record canary
# sourced with CLAUDE_CONFIG_DIR=<that home>/.claude so "none of the three paths exists" and the witness is
# exact. Whatever the suite creates under that home is what CI saw. The REAL record is never in reach.
set -uo pipefail
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/b7869424-972c-4693-80f8-5e034a119d86/scratchpad/r5
ENGINE=/Users/alex/ab/richos-wt/frank-fable-cert5/engine
LABEL="$1"; shift; SUITE="$1"; shift
H="$SP/ci-home-$LABEL"; rm -rf "$H"; mkdir -p "$H"
[ -f "$HOME/.gitconfig" ] && cp "$HOME/.gitconfig" "$H/.gitconfig"
REAL_HOME="$HOME"
export HOME="$H"
export CLAUDE_CONFIG_DIR="$H/.claude"
. "$ENGINE/scripts/lib/record-canary.sh"
rc_baseline "$SP/suites/$LABEL.ci-record-before.txt"
cd "$ENGINE" || exit 99
S=$(date +%s); bash "$SUITE" "$@" > "$SP/suites/$LABEL.log" 2>&1; RC=$?; E=$(date +%s)
TOUCHED="$(rc_escaped "$SP/suites/$LABEL.ci-record-before.txt")"
export HOME="$REAL_HOME"
if [ -n "$TOUCHED" ]; then T="RECORD-TOUCHED"; else T="record-untouched"; fi
printf '%s\trc=%s\twall=%ss\t%s\t%s\t%s\tCI-SHAPE\n' "$LABEL" "$RC" "$((E - S))" "$(date -u +%FT%TZ)" "$(git -C "$ENGINE" rev-parse --short HEAD)" "$T" >> "$SP/RESULTS.tsv"
printf '%s rc=%s wall=%ss %s\n' "$LABEL" "$RC" "$((E - S))" "$T"
[ -n "$TOUCHED" ] && printf '%s\n' "$TOUCHED" | head -20
echo "--- what exists under the fresh home's .claude afterwards:"; find "$H/.claude" -maxdepth 3 2>/dev/null | head -20
tail -n 2 "$SP/suites/$LABEL.log"
