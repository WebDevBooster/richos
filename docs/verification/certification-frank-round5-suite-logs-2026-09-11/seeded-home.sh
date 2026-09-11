#!/usr/bin/env bash
# seeded-home.sh <label> <suite> — run a suite with HOME = a scratch home SEEDED WITH COPIES of the operator's
# record (ledger, fallback log, teams, transactions, sessions, .gitconfig). The copy is the witness: if the
# suite reaches "the record" it reaches the copy. The real record is witnessed too (run-suite.sh's canary).
set -uo pipefail
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/b7869424-972c-4693-80f8-5e034a119d86/scratchpad/r5
LABEL="$1"; SUITE="$2"
SH="$SP/seeded-home-$LABEL"; rm -rf "$SH"; mkdir -p "$SH/.claude/state"
cp "$HOME/.claude/state/worktree-ledger.jsonl" "$SH/.claude/state/"
cp "$HOME/.claude/worker-events.jsonl" "$SH/.claude/"
cp -R "$HOME/.claude/teams" "$SH/.claude/teams"
cp -R "$HOME/.claude/state/worktree-transactions" "$SH/.claude/state/worktree-transactions"
[ -d "$HOME/.claude/sessions" ] && cp -R "$HOME/.claude/sessions" "$SH/.claude/sessions"
[ -f "$HOME/.gitconfig" ] && cp "$HOME/.gitconfig" "$SH/.gitconfig"
HOME="$SH" python3 "$SP/record-baseline.py" > "$SP/suites/$LABEL.copy-before.txt"
# run-suite.sh moves HOME to $SP/home; override by exporting HOME after — so call the suite here directly,
# with the same real-record witness.
ENGINE=/Users/alex/ab/richos-wt/frank-fable-cert5/engine
unset CLAUDE_CONFIG_DIR
. "$ENGINE/scripts/lib/record-canary.sh"
rc_baseline "$SP/suites/$LABEL.record-before.txt"
REAL_HOME="$HOME"; export HOME="$SH"
cd "$ENGINE" || exit 99
S=$(date +%s); bash "$SUITE" > "$SP/suites/$LABEL.log" 2>&1; RC=$?; E=$(date +%s)
export HOME="$REAL_HOME"
TOUCHED="$(rc_escaped "$SP/suites/$LABEL.record-before.txt")"
HOME="$SH" python3 "$SP/record-baseline.py" > "$SP/suites/$LABEL.copy-after.txt"
if [ -n "$TOUCHED" ]; then T="RECORD-TOUCHED"; else T="record-untouched"; fi
printf '%s\trc=%s\twall=%ss\t%s\t%s\t%s\tSEEDED-COPY-HOME\n' "$LABEL" "$RC" "$((E - S))" "$(date -u +%FT%TZ)" "$(git -C "$ENGINE" rev-parse --short HEAD)" "$T" >> "$SP/RESULTS.tsv"
printf '%s rc=%s wall=%ss real:%s\n' "$LABEL" "$RC" "$((E - S))" "$T"
echo "--- the COPY before/after (diff of counts; empty = the suite never reached the copy):"
diff <(grep -v '^2026' "$SP/suites/$LABEL.copy-before.txt") <(grep -v '^2026' "$SP/suites/$LABEL.copy-after.txt") && echo "copy unchanged"
tail -n 3 "$SP/suites/$LABEL.log"
