#!/usr/bin/env bash
# P01..P04: intake through UserPromptSubmit — healthy hook, exit-1 hook, exit-2 hook, hooks disabled.
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad
chmod +x "$S"/hooks/*.sh
PROMPT='Handle this: finish item B1 from BACKLOG.md in this directory. Do exactly what the open item says, then reply with one line: DONE <filename>.'
run() { # run <label> <settings> <session-id> <cwd>
  local L="$1" SET="$2" SID="$3" WD="$4"; local T0=$(date +%s); echo "  session-id: $SID"
  "$S/run-claude.sh" default "$WD" -p "$PROMPT" --model haiku --output-format json --setting-sources "" --settings "$SET" --session-id "$SID" --permission-mode acceptEdits --permission-prompts none < /dev/null > "$S/out/$L.json" 2> "$S/out/$L.err"
  echo "$L exit $? in $(( $(date +%s) - T0 ))s"
  python3 -c "import json,sys;d=json.load(open('$S/out/$L.json'));print('  result:',repr(d.get('result'))[:200]);print('  is_error:',d.get('is_error'),'turns:',d.get('num_turns'),'session:',d.get('session_id'),'cost:',d.get('total_cost_usd'))" 2>/dev/null || head -c 600 "$S/out/$L.json"
  echo "  stderr: $(head -c 300 "$S/out/$L.err" | tr '\n' ' ')"
  ls "$WD" | tr '\n' ' '; echo
}
mkdir -p "$S/envA1" "$S/envA2" "$S/envA3" "$S/envA4"
for d in envA1 envA2 envA3 envA4; do cp "$S/envA/BACKLOG.md" "$S/$d/"; done
run p01-ok       "$S/settings/intake-ok.json"       $(uuidgen | tr A-Z a-z) "$S/envA1"
run p02-exit1    "$S/settings/intake-exit1.json"    $(uuidgen | tr A-Z a-z) "$S/envA2"
run p03-exit2    "$S/settings/intake-exit2.json"    $(uuidgen | tr A-Z a-z) "$S/envA3"
run p04-disabled "$S/settings/intake-disabled.json" $(uuidgen | tr A-Z a-z) "$S/envA4"
echo "--- ledgers:"
for f in p01-sessionstart p01-prompt p01-stop p01-sessionend p02-prompt-exit1 p03-prompt-exit2 p04-prompt-disabled; do
  if [ -f "$S/out/$f.jsonl" ]; then echo "$f: $(wc -l < "$S/out/$f.jsonl") rows"; else echo "$f: ABSENT"; fi
done
echo "--- p01 prompt payload:"; head -c 1500 "$S/out/p01-prompt.jsonl"; echo
echo "--- p01 stop payload keys:"; python3 -c "import json;[print(sorted(json.loads(l)['payload'].keys())) for l in open('$S/out/p01-stop.jsonl')]"
