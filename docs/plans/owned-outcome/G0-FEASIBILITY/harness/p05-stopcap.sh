#!/usr/bin/env bash
# P05: Stop hook that always blocks (exit 2, ignores stop_hook_active) — how many consecutive blocks does the host honor?
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad
rm -rf "$S/out/p05-marks" "$S/out/p05-stop.jsonl"; mkdir -p "$S/envA5"
T0=$(date +%s)
"$S/run-claude.sh" default "$S/envA5" -p 'Reply with the single word READY.' --model haiku --output-format json --setting-sources "" --settings "$S/settings/stopcap.json" --session-id $(uuidgen | tr A-Z a-z) --permission-prompts none < /dev/null > "$S/out/p05.json" 2> "$S/out/p05.err"
echo "p05 exit $? in $(( $(date +%s) - T0 ))s"
python3 -c "import json;d=json.load(open('$S/out/p05.json'));print('result:',repr(d.get('result'))[:300]);print('turns:',d.get('num_turns'),'is_error:',d.get('is_error'),'cost:',d.get('total_cost_usd'))"
echo "stderr: $(head -c 800 "$S/out/p05.err")"
echo "stop hook invocations: $(wc -l < "$S/out/p05-stop.jsonl")"
python3 -c "
import json
for i,l in enumerate(open('$S/out/p05-stop.jsonl')):
    p=json.loads(l)['payload']; print(i+1, 'stop_hook_active=',p.get('stop_hook_active'))
"
