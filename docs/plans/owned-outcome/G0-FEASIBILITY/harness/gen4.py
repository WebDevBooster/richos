#!/usr/bin/env python3
"""Round four: q08e = terminal closes while a worker's FOREGROUND python sleep child runs; q08f = /exit with a live worker, slow keystrokes, screen kept."""
import json, os
S = '/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad'
H = S + '/hooks'; O = S + '/out'; SET = S + '/settings'; ST = S + '/steps'
def cmd(script, *args, timeout=15):
    return {"type": "command", "command": " ".join([f"{H}/{script}"] + list(args)), "timeout": timeout}
def stopmark(tag):
    return {"Stop": [{"hooks": [cmd('stopmark.sh', f'{O}/{tag}-stop.jsonl', f'{O}/{tag}-marks', '0')]}]}
def rec(tag, event):
    return {event: [{"hooks": [cmd('record.sh', f'{O}/{tag}-{event.lower()}.jsonl', '0')]}]}
def merge(*ds):
    out = {}
    for d in ds:
        for k, v in d.items(): out.setdefault(k, []).extend(v)
    return out
for tag in ['q08e', 'q08f']:
    st = {"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"},
          "permissions": {"allow": ["Bash(python3:*)", "Bash(echo:*)", "Bash(ls:*)", "Bash(pwd:*)"]},
          "hooks": merge(stopmark(tag), rec(tag, 'TeammateIdle'), rec(tag, 'SubagentStart'), rec(tag, 'SubagentStop'), rec(tag, 'SessionEnd'))}
    json.dump(st, open(f'{SET}/{tag}.json', 'w'), indent=1)
def brief(marker, secs):
    return (f'Brief for worker-a (G0 handoff probe). Working directory: the current one. Run exactly this command with the Bash tool in the FOREGROUND and wait for it (do not background it, do not shorten it): '
            f'python3 -c "import time; time.sleep({secs})" . Then create the file worker-done-{marker}.txt in the current directory with the single line WORKER DONE. Negative constraint: do NOT modify BACKLOG.md. Handoff: reply with one line WORKER DONE {marker} and stop.')
def lead_prompt(marker, secs):
    return (f'Spawn exactly one teammate named worker-a using the general-purpose agent type, with this brief passed verbatim as its prompt: """{brief(marker, secs)}""" '
            f'After spawning it, end your turn immediately with the single line SPAWNED (do not wait, do not poll). When worker-a reports back, reply with one line LEAD SAW: <its exact final line>.')
common = [{"expect": r"for\s*shortcuts|for\s*agents", "timeout": 30, "required": False}, {"sleep": 2.0}, {"mark": "prompt-send"}]
q08e = common + [{"send": lead_prompt('E', 270)}, {"sleep": 1.0}, {"send": "\r"},
    {"waitfile": f"{O}/q08e-marks/stop-1", "timeout": 120}, {"mark": "lead-idle-1"},
    {"waitshell": "pgrep -f 'time.sleep(270)' >/dev/null", "timeout": 90},
    {"shell": "ps -axo pid,ppid,command | grep -E 'time.sleep\\(270\\)' | grep -v grep"},
    {"mark": "exit"}, {"exit": "closepty", "timeout": 45},
    {"shell": "sleep 3; pgrep -fl 'time.sleep(270)' || echo no-child-after-close; pgrep -fl 'versions/2.1.267' | grep -v -E 'pgrep|bg-pty|daemon' || echo no-claude-procs"},
    {"shell": f"sleep 15; pgrep -fl 'time.sleep(270)' || echo no-child-after-18s; ls {S}/env-q08e"}]
json.dump(q08e, open(f'{ST}/q08e.json', 'w'), indent=1)
q08f = common + [{"send": lead_prompt('F', 280)}, {"sleep": 1.0}, {"send": "\r"},
    {"waitfile": f"{O}/q08f-marks/stop-1", "timeout": 120}, {"mark": "lead-idle-1"},
    {"waitshell": "pgrep -f 'time.sleep(280)' >/dev/null", "timeout": 90},
    {"mark": "exit-typed"}, {"send": "/exit"}, {"sleep": 1.5}, {"send": "\r"}, {"sleep": 6},
    {"shell": "pgrep -fl 'time.sleep(280)' || echo no-child"},
    {"mark": "exit"}, {"exit": "ctrld", "timeout": 20},
    {"shell": "sleep 3; pgrep -fl 'time.sleep(280)' || echo no-child-after"}]
json.dump(q08f, open(f'{ST}/q08f.json', 'w'), indent=1)
print('generated q08e q08f')
