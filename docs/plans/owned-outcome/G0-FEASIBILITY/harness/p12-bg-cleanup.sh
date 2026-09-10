#!/usr/bin/env bash
# P12: the session that q08h moved to the background (id 690ff24e): read its log, stop it, watch the daemon retire.
for v in $(env | cut -d= -f1 | grep -E '^(CLAUDE|ANTHROPIC)'); do unset "$v"; done
echo "--- logs 690ff24e (stripped tail):"
/Users/alex/.local/share/claude/versions/2.1.267 logs 690ff24e 2>&1 | python3 -c "import sys,re;t=sys.stdin.read();t=re.sub(r'\x1b\[[0-9;?<>]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[=>78]|\r','',t);print(re.sub(r'\s+',' ',t)[-1600:])"
echo "--- stop 690ff24e:"; /Users/alex/.local/share/claude/versions/2.1.267 stop 690ff24e 2>&1 | head -c 300; echo
sleep 3
echo "--- agents after:"; /Users/alex/.local/share/claude/versions/2.1.267 agents --json 2>&1 | python3 -c "import json,sys;[print(' ',a.get('kind'),a.get('id'),a.get('status'),a.get('state'),a.get('name')) for a in json.load(sys.stdin)]"
sleep 15
echo "--- daemon/pty-host after 18 s:"; ps -axo pid,ppid,etime,command | grep -E 'claude daemon|bg-pty-host' | grep -v grep | cut -c1-120; echo "(end)"
