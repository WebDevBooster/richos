#!/usr/bin/env bash
# P06/P07: explicit permission denial (settings deny rule) — plain, and with a PreToolUse hook returning "allow" for the same call.
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad
mkdir -p "$S/envA6" "$S/envA7"
PROMPT='Run exactly this shell command with the Bash tool and nothing else: touch g0-denied.txt . If the tool refuses, do not retry or work around it; reply with one line REFUSED: <reason>. If it succeeds reply RAN.'
run() { local L="$1" SET="$2" SID="$3" WD="$4"; local T0=$(date +%s)
  "$S/run-claude.sh" default "$WD" -p "$PROMPT" --model haiku --output-format json --setting-sources "" --settings "$SET" --session-id "$SID" --permission-prompts none < /dev/null > "$S/out/$L.json" 2> "$S/out/$L.err"
  echo "$L exit $? in $(( $(date +%s) - T0 ))s"
  python3 -c "import json;d=json.load(open('$S/out/$L.json'));print('  result:',repr(d.get('result'))[:300]);print('  permission_denials:',d.get('permission_denials'))"
  echo "  file created: $([ -f "$WD/g0-denied.txt" ] && echo YES || echo NO)"
}
run p06-deny-plain    "$S/settings/deny-plain.json"    $(uuidgen | tr A-Z a-z) "$S/envA6"
run p07-deny-override "$S/settings/deny-override.json" $(uuidgen | tr A-Z a-z) "$S/envA7"
for f in p06-permdenied p06-pretool p07-permdenied p07-pretool; do
  if [ -f "$S/out/$f.jsonl" ]; then echo "$f: $(wc -l < "$S/out/$f.jsonl") rows"; else echo "$f: ABSENT"; fi
done
echo "--- p07 pretool payload:"; head -c 900 "$S/out/p07-pretool.jsonl"; echo
echo "--- p06 permdenied payload:"; head -c 900 "$S/out/p06-permdenied.jsonl"; echo
