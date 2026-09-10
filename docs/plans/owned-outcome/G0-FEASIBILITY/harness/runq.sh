#!/usr/bin/env bash
# runq.sh <tag> [extra claude args...] — runs one interactive pty probe: fresh cwd, fresh session id, settings/<tag>.json, steps/<tag>.json
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad
TAG="$1"; shift
WD="$S/env-$TAG"; rm -rf "$WD" "$S/out/$TAG-marks"; mkdir -p "$WD"; cp "$S/envA/BACKLOG.md" "$WD/"
rm -f "$S"/out/"$TAG"-*.jsonl
SID=$(uuidgen | tr A-Z a-z)
echo "$TAG session-id: $SID cwd: $WD"
for v in $(env | cut -d= -f1 | grep -E '^(CLAUDE|ANTHROPIC)'); do unset "$v"; done
T0=$(date +%s)
python3 "$S/ptydrive.py" --out "$S/out/$TAG" --cwd "$WD" --steps "$S/steps/$TAG.json" -- --model haiku --setting-sources "" --settings "$S/settings/$TAG.json" --session-id "$SID" "$@"
echo "$TAG driver exit $? in $(( $(date +%s) - T0 ))s"
echo "$SID" > "$S/out/$TAG.sid"
grep -E '"kind": "(expect|waitfile|quiet|exit-request|exited|exit-timeout|sigkill|auto-trust-enter|abort|global-timeout)"' "$S/out/$TAG.events.jsonl" | cut -c1-200
