#!/usr/bin/env bash
# P10: does a `claude --bg` session run independently of the launching shell, and does `claude stop` end it?
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad
WD="$S/env-p10"; rm -rf "$WD"; mkdir -p "$WD"
cat > "$S/settings/p10.json" <<'EOF'
{"permissions": {"allow": ["Bash(sleep:*)", "Bash(echo:*)", "Bash(touch:*)"]}}
EOF
for v in $(env | cut -d= -f1 | grep -E '^(CLAUDE|ANTHROPIC)'); do unset "$v"; done
cd "$WD"
T0=$(date +%s)
OUT=$(/Users/alex/.local/share/claude/versions/2.1.267 --bg --model haiku --setting-sources "" --settings "$S/settings/p10.json" --permission-mode acceptEdits 'Run exactly `sleep 45` with the Bash tool, then create bg-done.txt containing DONE in the current directory, then reply BG DONE.' 2>&1)
RC=$?
echo "--bg returned rc=$RC after $(( $(date +%s) - T0 ))s; output:"; echo "$OUT"
ID=$(echo "$OUT" | grep -oE '[a-z0-9]{6,}' | tail -1)
echo "candidate id: $ID"
sleep 5
echo "--- claude agents --json:"; /Users/alex/.local/share/claude/versions/2.1.267 agents --json 2>&1 | head -c 2500; echo
echo "--- process tree (claude 2.1.267 processes, ppid):"; ps -axo pid,ppid,etime,command | grep 'versions/2.1.267' | grep -v grep | cut -c1-160
echo "--- my shell pid: $$  (parent: $PPID)"
sleep 12
echo "--- logs:"; /Users/alex/.local/share/claude/versions/2.1.267 logs "$ID" 2>&1 | tail -c 1200; echo
echo "--- sleep 45 child present?"; pgrep -fl 'sleep 45' || echo no-sleep-45
echo "--- stop:"; T1=$(date +%s); /Users/alex/.local/share/claude/versions/2.1.267 stop "$ID" 2>&1 | head -c 600; echo " (stop returned after $(( $(date +%s) - T1 ))s)"
sleep 3
echo "--- after stop: sleep child?"; pgrep -fl 'sleep 45' || echo no-sleep-45-after-stop
echo "--- after stop: agents --json"; /Users/alex/.local/share/claude/versions/2.1.267 agents --json 2>&1 | head -c 1500; echo
echo "--- files:"; ls -la "$WD"
