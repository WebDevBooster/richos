#!/usr/bin/env python3
"""Round five: q08g = /exit with live work, choose 'Exit and stop tasks'; q08h = choose 'Move to background and exit' then claude stop;
q11 = single session, allow-listed ls of a directory outside cwd, no keystrokes for 150 s (does the read-outside-cwd dialog resolve itself?)."""
import json, os
S = '/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad'
H = S + '/hooks'; O = S + '/out'; SET = S + '/settings'; ST = S + '/steps'
def cmd(script, *args, timeout=15):
    return {"type": "command", "command": " ".join([f"{H}/{script}"] + list(args)), "timeout": timeout}
def stopmark(tag):
    return {"Stop": [{"hooks": [cmd('stopmark.sh', f'{O}/{tag}-stop.jsonl', f'{O}/{tag}-marks', '0')]}]}
def rec(tag, event, matcher=None):
    h = {"hooks": [cmd('record.sh', f'{O}/{tag}-{event.lower()}.jsonl', '0')]}
    if matcher: h["matcher"] = matcher
    return {event: [h]}
def merge(*ds):
    out = {}
    for d in ds:
        for k, v in d.items(): out.setdefault(k, []).extend(v)
    return out
for tag in ['q08g', 'q08h']:
    st = {"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"},
          "permissions": {"allow": ["Bash(python3:*)", "Bash(echo:*)", "Bash(ls:*)", "Bash(pwd:*)"]},
          "hooks": merge(stopmark(tag), rec(tag, 'TeammateIdle'), rec(tag, 'SubagentStart'), rec(tag, 'SubagentStop'), rec(tag, 'SessionEnd'))}
    json.dump(st, open(f'{SET}/{tag}.json', 'w'), indent=1)
q11 = {"permissions": {"allow": ["Bash(ls:*)"]}, "hooks": merge(stopmark('q11'), rec('q11', 'PermissionRequest'), rec('q11', 'PermissionDenied'), rec('q11', 'PreToolUse', matcher='Bash'))}
json.dump(q11, open(f'{SET}/q11.json', 'w'), indent=1)
def brief(marker, secs):
    return (f'Brief for worker-a (G0 handoff probe). Working directory: the current one. Run exactly this command with the Bash tool in the FOREGROUND and wait for it (do not background it, do not shorten it): '
            f'python3 -c "import time; time.sleep({secs})" . Then create the file worker-done-{marker}.txt in the current directory with the single line WORKER DONE. Negative constraint: do NOT modify BACKLOG.md. Handoff: reply with one line WORKER DONE {marker} and stop.')
def lead_prompt(marker, secs):
    return (f'Spawn exactly one teammate named worker-a using the general-purpose agent type, with this brief passed verbatim as its prompt: """{brief(marker, secs)}""" '
            f'After spawning it, end your turn immediately with the single line SPAWNED (do not wait, do not poll). When worker-a reports back, reply with one line LEAD SAW: <its exact final line>.')
common = [{"expect": r"for\s*shortcuts|for\s*agents", "timeout": 30, "required": False}, {"sleep": 2.0}, {"mark": "prompt-send"}]
q08g = common + [{"send": lead_prompt('G', 290)}, {"sleep": 1.0}, {"send": "\r"},
    {"waitfile": f"{O}/q08g-marks/stop-1", "timeout": 120}, {"mark": "lead-idle-1"},
    {"waitshell": "pgrep -f 'time.sleep.290' >/dev/null", "timeout": 90},
    {"send": "/exit"}, {"sleep": 1.5}, {"send": "\r"}, {"expect": r"Background\s*work\s*is\s*running", "timeout": 15},
    {"mark": "exit"}, {"exit": "\r", "timeout": 30},
    {"shell": "sleep 3; pgrep -fl 'time.sleep.290' || echo no-child-after-exit"}]
json.dump(q08g, open(f'{ST}/q08g.json', 'w'), indent=1)
q08h = common + [{"send": lead_prompt('H', 300)}, {"sleep": 1.0}, {"send": "\r"},
    {"waitfile": f"{O}/q08h-marks/stop-1", "timeout": 120}, {"mark": "lead-idle-1"},
    {"waitshell": "pgrep -f 'time.sleep.300' >/dev/null", "timeout": 90},
    {"send": "/exit"}, {"sleep": 1.5}, {"send": "\r"}, {"expect": r"Background\s*work\s*is\s*running", "timeout": 15},
    {"send": "\x1b[B"}, {"sleep": 0.6}, {"mark": "exit"}, {"exit": "\r", "timeout": 30},
    {"shell": "sleep 4; pgrep -fl 'time.sleep.300' || echo no-child-after-exit; /Users/alex/.local/share/claude/versions/2.1.267 agents --json"},
    {"shell": "sleep 20; pgrep -fl 'time.sleep.300' || echo no-child-after-24s; /Users/alex/.local/share/claude/versions/2.1.267 agents --json"}]
json.dump(q08h, open(f'{ST}/q08h.json', 'w'), indent=1)
q11 = common + [{"send": f'Run exactly this command with the Bash tool: ls "{S}/dir with spaces" . Then reply with one line: LISTED <exit code>. Do not retry.'}, {"sleep": 1.0}, {"send": "\r"},
    {"waitfile": f"{O}/q11-marks/stop-1", "timeout": 150}, {"mark": "after-wait"}, {"sleep": 3}, {"mark": "exit"}, {"exit": "/exit", "timeout": 30}]
json.dump(q11, open(f'{ST}/q11.json', 'w'), indent=1)
print('generated q08g q08h q11')
