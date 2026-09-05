#!/usr/bin/env bash
# The live demonstration. Real hook scripts, real machine ledger, real payload
# shapes. Output is captured verbatim into the verification record.
set -uo pipefail
WT="/Users/alex/ab/richos-wt/zach-opus-e1"
E="$WT/engine"
SEAT="/Users/alex/ab/femcboost"          # Rich's actual seat, a DIFFERENT repository

hr() { printf '\n=== %s ===\n\n' "$1"; }

hr "0. the ledger before anything is raised"
echo "\$ ls -l ~/.claude/state/escalations.jsonl"
ls -l "$HOME/.claude/state/escalations.jsonl" 2>&1 || echo "(does not exist yet)"

hr "1. a teammate raises one — from a richos worktree, in ONE command"
echo "\$ engine/scripts/escalate.sh raise --title ... --state work-complete --for lead ..."
"$E/scripts/escalate.sh" raise \
  --title "Row e1 delivery proof: this escalation was raised to prove it arrives" \
  --state work-complete --for lead \
  --question "Nothing is being asked. Acknowledge this row to close the demonstration." \
  --tried "the ledger, both hooks and the installer, all under test in this branch" \
  --meanwhile "the rest of row e1 is finished and committed on zach-opus-e1" \
  --worktree "$WT" --teammate zach-opus-e1
echo "rc=$?"

hr "2. NOTHING WAS MERGED. The branch state, stated rather than assumed."
echo "\$ git -C $WT log --oneline -1"
git -C "$WT" log --oneline -1
echo "\$ git -C /Users/alex/ab/richos log --oneline -1   # main, untouched by this branch"
git -C /Users/alex/ab/richos log --oneline -1
echo "\$ git -C /Users/alex/ab/richos merge-base --is-ancestor <branch tip> HEAD ; echo \$?"
TIP="$(git -C "$WT" rev-parse HEAD)"
git -C /Users/alex/ab/richos merge-base --is-ancestor "$TIP" HEAD 2>/dev/null; echo "ancestor-of-main rc=$? (non-zero == NOT merged)"

hr "3. the ledger row — outside every repository, every worktree, every session"
echo "\$ tail -1 ~/.claude/state/escalations.jsonl"
tail -1 "$HOME/.claude/state/escalations.jsonl"

hr "4. SessionStart, run as Rich's FEMCBOOST-seated session would run it"
echo "\$ RICHOS_ENTITY_ROOT=$SEAT engine/scripts/hooks/session-start-escalations.sh </dev/null"
OUT="$(RICHOS_ENTITY_ROOT="$SEAT" "$E/scripts/hooks/session-start-escalations.sh" </dev/null 2>&1)"
printf '%s\n' "$OUT"
echo
echo "--- what the MODEL receives (hookSpecificOutput.additionalContext) ---"
printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
echo
echo "--- what the OPERATOR receives (systemMessage) ---"
printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["systemMessage"])'

hr "5. turn end, same seat"
echo "\$ echo '<Stop payload>' | RICHOS_ENTITY_ROOT=$SEAT engine/scripts/hooks/notice-escalations.sh"
printf '{"session_id":"deadbeef-1111-2222-3333-444444444444","hook_event_name":"Stop","cwd":"%s"}' "$SEAT" \
  | RICHOS_ENTITY_ROOT="$SEAT" "$E/scripts/hooks/notice-escalations.sh" 2>&1
echo
echo "(same session, second turn — a persistent condition is not repeated:)"
printf '{"session_id":"deadbeef-1111-2222-3333-444444444444","hook_event_name":"Stop","cwd":"%s"}' "$SEAT" \
  | RICHOS_ENTITY_ROOT="$SEAT" "$E/scripts/hooks/notice-escalations.sh" 2>&1
echo "(nothing above this line == correctly quiet)"

hr "6. THE NOISE AN UNACKNOWLEDGED ONE MAKES — a separate ledger, aged"
LOUD="/private/tmp/claude-501/-Users-alex-ab-femcboost/9befc211-b0af-4e74-b96a-8fcafc7d45ba/scratchpad/e1/loud.jsonl"
rm -f "$LOUD"
RICHOS_ESCALATION_LEDGER="$LOUD" "$E/scripts/escalate.sh" raise \
  --title "A premise in my brief is contradicted by the evidence" \
  --state work-complete --for ceo \
  --question "Do I follow the brief or the evidence? Only you can decide that." \
  --worktree /tmp --teammate zach-opus-p8 --no-record >/dev/null 2>&1
S="99999999-aaaa-bbbb-cccc-dddddddddddd"
for AGE in 0 90 1500 4500; do
  python3 - "$LOUD" "$AGE" <<'PY'
import json, sys
from datetime import datetime, timedelta, timezone
p, mins = sys.argv[1], int(sys.argv[2])
rows = [json.loads(l) for l in open(p, encoding="utf-8") if l.strip()]
when = (datetime.now(timezone.utc) - timedelta(minutes=mins)).replace(microsecond=0)
for r in rows:
    if r.get("event") == "Escalation":
        r["raised"] = when.isoformat().replace("+00:00", "Z")
open(p, "w", encoding="utf-8").write("".join(json.dumps(r) + "\n" for r in rows))
PY
  printf -- '--- age %s minutes, SAME session, already announced ---\n' "$AGE"
  printf '{"session_id":"%s","hook_event_name":"Stop","cwd":"%s"}' "$S" "$SEAT" \
    | RICHOS_ESCALATION_LEDGER="$LOUD" RICHOS_ENTITY_ROOT="$SEAT" "$E/scripts/hooks/notice-escalations.sh" 2>&1
  echo
done
echo "--- and a NEW session is told from scratch, whatever it has already heard ---"
printf '{"session_id":"eeeeeeee-aaaa-bbbb-cccc-dddddddddddd","hook_event_name":"Stop","cwd":"%s"}' "$SEAT" \
  | RICHOS_ESCALATION_LEDGER="$LOUD" RICHOS_ENTITY_ROOT="$SEAT" "$E/scripts/hooks/notice-escalations.sh" 2>&1

hr "7. closing the demonstration escalation on the real ledger"
ID="$(python3 "$E/scripts/lib/escalations.py" list --format json | python3 -c 'import json,sys; o=json.load(sys.stdin)["outstanding"]; print(o[0]["id"] if o else "")')"
echo "\$ engine/scripts/escalate.sh ack $ID --disposition ..."
"$E/scripts/escalate.sh" ack "$ID" --disposition "Row e1 delivery proof; nothing was asked and nothing is owed. Acknowledged so the live ledger is left with zero outstanding."
echo "rc=$?"
echo
echo "\$ engine/scripts/escalate.sh list ; echo \$?"
"$E/scripts/escalate.sh" list
echo "rc=$?  (0 == nothing outstanding)"
echo
echo "\$ RICHOS_ENTITY_ROOT=$SEAT engine/scripts/hooks/session-start-escalations.sh </dev/null"
RICHOS_ENTITY_ROOT="$SEAT" "$E/scripts/hooks/session-start-escalations.sh" </dev/null 2>&1
echo "(nothing above this line == silent again)"
