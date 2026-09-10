#!/usr/bin/env python3
"""Round three: q08d = terminal closes while a worker's background shell child is running; q09d = three Ctrl-C presses during a running Stop hook."""
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
base = json.load(open(f'{SET}/q08c.json'))
q08d = {"env": base["env"], "permissions": base["permissions"], "hooks": merge(stopmark('q08d'), rec('q08d', 'TeammateIdle'), rec('q08d', 'SubagentStart'), rec('q08d', 'SubagentStop'), rec('q08d', 'SessionEnd'))}
json.dump(q08d, open(f'{SET}/q08d.json', 'w'), indent=1)
q09d = {"hooks": {"Stop": [{"hooks": [cmd('record.sh', f'{O}/q09d-stop.jsonl', '0', '""', '40', timeout=60)]}]}}
json.dump(q09d, open(f'{SET}/q09d.json', 'w'), indent=1)
def brief(marker, secs):
    return (f'Brief for worker-a (G0 handoff probe). Working directory: the current one. Run exactly `sleep {secs}` with the Bash tool in the foreground (this is the marker command; do not shorten it and do not background it). '
            f'Then create the file worker-done-{marker}.txt in the current directory with the single line WORKER DONE. Negative constraint: do NOT modify BACKLOG.md. Handoff: reply with one line WORKER DONE {marker} and stop.')
def lead_prompt(marker, secs):
    return (f'Spawn exactly one teammate named worker-a using the general-purpose agent type, with this brief passed verbatim as its prompt: """{brief(marker, secs)}""" '
            f'After spawning it, end your turn immediately with the single line SPAWNED (do not wait, do not poll). When worker-a reports back, reply with one line LEAD SAW: <its exact final line>.')
common = [{"expect": r"for\s*shortcuts|for\s*agents", "timeout": 30, "required": False}, {"sleep": 2.0}, {"mark": "prompt-send"}]
q08d_steps = common + [{"send": lead_prompt('D', 260)}, {"sleep": 1.0}, {"send": "\r"},
    {"waitfile": f"{O}/q08d-marks/stop-1", "timeout": 120}, {"mark": "lead-idle-1"},
    {"waitshell": "pgrep -f 'sleep 260' >/dev/null", "timeout": 90},
    {"shell": "ps -axo pid,ppid,command | grep -E 'sleep 260' | grep -v grep"},
    {"mark": "exit"}, {"exit": "closepty", "timeout": 45},
    {"shell": "sleep 3; pgrep -fl 'sleep 260' || echo no-sleep-260-after-close; pgrep -fl 'versions/2.1.267' | grep -v -E 'pgrep|bg-pty|daemon' || echo no-claude-procs"},
    {"shell": f"sleep 15; pgrep -fl 'sleep 260' || echo no-sleep-260-after-18s; ls {S}/env-q08d"}]
json.dump(q08d_steps, open(f'{ST}/q08d.json', 'w'), indent=1)
q09d_steps = common + [{"send": "Reply with the single word PONG and nothing else."}, {"sleep": 1.0}, {"send": "\r"}, {"sleep": 9}, {"mark": "exit"},
    {"send": "\x03"}, {"sleep": 0.5}, {"send": "\x03"}, {"sleep": 0.5}, {"exit": "ctrlc", "timeout": 30}]
json.dump(q09d_steps, open(f'{ST}/q09d.json', 'w'), indent=1)
print('generated q08d q09d')
