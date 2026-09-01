#!/usr/bin/env bash
set -uo pipefail
SP=/private/tmp/claude-501/-Users-alex-ab-femcboost/374e6f14-2ac1-4f4a-bed0-160f79d64a7b/scratchpad
BIN=/Users/alex/ab/richos-wt/echo-opus-in1/app/target/debug/examples/company_choice_roundtrip
cd /
echo "############ launchd-like environment, cwd $(pwd) ############"
bash "$SP/launchd-env.sh" /usr/bin/env
echo "############ the run ############"
bash "$SP/launchd-env.sh" "$BIN" /Users/alex/.claude/richos-engine richos
