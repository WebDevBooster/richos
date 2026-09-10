#!/usr/bin/env bash
# P10b: stop the background session started by P10 with its real id, verify the artifact, observe the daemon.
S=/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad
for v in $(env | cut -d= -f1 | grep -E '^(CLAUDE|ANTHROPIC)'); do unset "$v"; done
cd "$S/env-p10"
echo "--- artifact:"; ls -la "$S/env-p10"; cat "$S/env-p10/bg-done.txt" 2>/dev/null || echo "(no bg-done.txt)"
echo "--- agents before stop:"; /Users/alex/.local/share/claude/versions/2.1.267 agents --json 2>&1 | python3 -c "import json,sys;[print(' ',a.get('kind'),a.get('id'),a.get('status'),a.get('state'),a.get('name')) for a in json.load(sys.stdin)]"
echo "--- logs 4be2606e (tail):"; /Users/alex/.local/share/claude/versions/2.1.267 logs 4be2606e 2>&1 | tail -c 700; echo
T1=$(date +%s); echo "--- stop 4be2606e:"; /Users/alex/.local/share/claude/versions/2.1.267 stop 4be2606e 2>&1 | head -c 400; echo " (returned after $(( $(date +%s) - T1 ))s)"
sleep 3
echo "--- agents after stop:"; /Users/alex/.local/share/claude/versions/2.1.267 agents --json 2>&1 | python3 -c "import json,sys;[print(' ',a.get('kind'),a.get('id'),a.get('status'),a.get('state'),a.get('name')) for a in json.load(sys.stdin)]"
echo "--- daemon / pty-host / sleep processes now:"; ps -axo pid,ppid,etime,command | grep -E 'claude daemon|bg-pty-host|sleep 45$' | grep -v grep | cut -c1-140 || echo none
sleep 15
echo "--- daemon after 15 s more:"; ps -axo pid,ppid,etime,command | grep -E 'claude daemon|bg-pty-host' | grep -v grep | cut -c1-140 || echo none
