#!/usr/bin/env bash
# Time the Stop-event instruments. These already execute at every turn end in
# production, so running them once more is exactly what production does.
# EXCLUDED deliberately (they mutate lifecycle/ref state, not read-only):
#   observe-created-refs.sh, workspace-lifecycle.sh, snapshot-*.sh
set -uo pipefail
WT=/Users/alex/ab/richos-wt/zach-opus-landgate1
H="$WT/engine/scripts/hooks"
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/b7d89f44-e47a-4f64-a551-b41bd8468250/scratchpad
cd /Users/alex/ab/richos

PAYLOAD='{"session_id":"timing-probe","transcript_path":"/dev/null","cwd":"/Users/alex/ab/richos","hook_event_name":"Stop","stop_hook_active":false}'

STOP_INSTRUMENTS="
guard-agent-state-claims.sh
notice-ceo-inputs-unheld.sh
notice-ceo-ruled-prose.sh
notice-ceo-unasked.sh
notice-escalations.sh
notice-hook-staleness.sh
notice-inflight-acks.sh
notice-mechanical-findings.sh
notice-protected-ref-moves.sh
notice-unasked-deferral.sh
notice-unlanded-branches.sh
notice-unstarted-rows.sh
notice-waiver-repetition.sh
turn-manifest.sh
"

printf '%-36s %8s %8s %6s\n' "instrument (Stop)" "best_ms" "worst_ms" "exit"
printf '%s\n' "------------------------------------------------------------------"
for s in $STOP_INSTRUMENTS; do
  [ -f "$H/$s" ] || { printf '%-36s %8s\n' "$s" "MISSING"; continue; }
  best=999999; worst=0; ex=0
  for i in 1 2 3; do
    t0=$(python3 -c 'import time;print(int(time.time()*1000))')
    printf '%s' "$PAYLOAD" | bash "$H/$s" >/dev/null 2>&1
    ex=$?
    t1=$(python3 -c 'import time;print(int(time.time()*1000))')
    d=$(( t1 - t0 ))
    [ "$d" -lt "$best" ] && best=$d
    [ "$d" -gt "$worst" ] && worst=$d
  done
  printf '%-36s %8s %8s %6s\n' "$s" "$best" "$worst" "$ex"
done
