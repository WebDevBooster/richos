#!/usr/bin/env bash
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad
T0=$(date +%s)
"$S/run-claude.sh" "$S/cfg1" "$S/envA" -p 'Reply with exactly the word OK and nothing else.' --model haiku --output-format json --setting-sources "" > "$S/out/probe-auth.json" 2> "$S/out/probe-auth.err"
RC=$?
echo "exit $RC in $(( $(date +%s) - T0 ))s"
head -c 1200 "$S/out/probe-auth.json"; echo; echo ---ERR---; head -c 1200 "$S/out/probe-auth.err"; echo
ls -la "$S/cfg1"
