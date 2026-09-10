#!/usr/bin/env python3
"""Second-round pty probe definitions: MessageDisplay hang observed to timeout (q03b), team handoff (q08),
exit/cancel with a live teammate child (q08b: /exit, q08c: pty close = terminal gone)."""
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

settings = {}
settings['q03b'] = {"hooks": merge(stopmark('q03b'), {"MessageDisplay": [{"hooks": [cmd('md-filter.sh', f'{O}/q03b-md.jsonl', 'hang')]}]})}
team_hooks = lambda tag: merge(stopmark(tag), rec(tag, 'TeammateIdle'), rec(tag, 'SubagentStart'), rec(tag, 'SubagentStop'), rec(tag, 'TaskCompleted'), rec(tag, 'SessionEnd'), rec(tag, 'UserPromptSubmit'))
for tag in ['q08', 'q08b', 'q08c']:
    settings[tag] = {"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"},
                     "permissions": {"allow": ["Bash(sleep:*)", "Bash(echo:*)", "Bash(cat:*)", "Bash(ls:*)", "Bash(touch:*)", "Bash(mkdir:*)", "Bash(pwd:*)"]},
                     "hooks": team_hooks(tag)}
for k, v in settings.items():
    json.dump(v, open(f'{SET}/{k}.json', 'w'), indent=1)

ASK_PROSE = 'I need you to ask me a question. In plain text (do not use any tool), ask me which filename I should use for the output, offering two options, and then stop and wait for my answer.'
def brief(marker, secs):
    return (f'Brief for worker-a (G0 handoff probe). Working directory: the current one. Reproduction: run `ls "{S}/dir with spaces"` once and report its exit code. '
            f'Then run exactly `sleep {secs}` with the Bash tool (this is the marker command; do not shorten it). Then create the file worker-done-{marker}.txt in the current directory with the single line WORKER DONE. '
            f'Negative constraint: do NOT modify BACKLOG.md. Handoff: reply with one line WORKER DONE {marker} and stop.')
def lead_prompt(marker, secs):
    return (f'Spawn exactly one teammate named worker-a using the general-purpose agent type, with this brief passed verbatim as its prompt: """{brief(marker, secs)}""" '
            f'After spawning it, end your turn immediately with the single line SPAWNED (do not wait, do not poll). When worker-a reports back, reply with one line LEAD SAW: <its exact final line>.')
def steps_common(prompt):
    return [{"expect": r"for\s*shortcuts|for\s*agents", "timeout": 30, "required": False}, {"sleep": 2.0},
            {"mark": "prompt-send"}, {"send": prompt}, {"sleep": 1.0}, {"send": "\r"}]
allsteps = {}
allsteps['q03b'] = steps_common(ASK_PROSE) + [{"waitfile": f"{O}/q03b-marks/stop-1", "timeout": 150}, {"mark": "stop-1"}, {"sleep": 40}, {"mark": "exit"}, {"exit": "/exit", "timeout": 45}]
# q08: full handoff — lead idles (stop-1) while worker sleeps 25 s; worker returns; lead's second turn (stop-2)
allsteps['q08'] = steps_common(lead_prompt('A', 25)) + [
    {"waitfile": f"{O}/q08-marks/stop-1", "timeout": 120}, {"mark": "lead-idle-1"},
    {"shell": f"ls {os.path.expanduser('~')}/.claude/teams/ ; for d in {os.path.expanduser('~')}/.claude/teams/session-*/; do echo == $d; cat $d/config.json; done; pgrep -fl 'sleep 25' || echo no-sleep-25"},
    {"waitfile": f"{O}/q08-marks/stop-2", "timeout": 120}, {"mark": "lead-idle-2"}, {"sleep": 3},
    {"shell": f"ls {S}/env-q08; pgrep -fl 'sleep 25' || echo no-sleep-25"},
    {"mark": "exit"}, {"exit": "/exit", "timeout": 45},
    {"shell": f"sleep 2; pgrep -fl 'sleep 25' || echo no-sleep-25-after-exit; ls {os.path.expanduser('~')}/.claude/teams/"}]
# q08b: /exit while worker is inside sleep 240 — does the child die, does the worker's work continue?
allsteps['q08b'] = steps_common(lead_prompt('B', 240)) + [
    {"waitfile": f"{O}/q08b-marks/stop-1", "timeout": 120}, {"mark": "lead-idle-1"}, {"sleep": 6},
    {"shell": "pgrep -fl 'sleep 240' || echo no-sleep-240"},
    {"mark": "exit"}, {"exit": "/exit", "timeout": 45},
    {"shell": f"sleep 3; pgrep -fl 'sleep 240' || echo no-sleep-240-after-exit; ls {S}/env-q08b"},
    {"shell": "sleep 20; pgrep -fl 'sleep 240' || echo no-sleep-240-after-23s"}]
# q08c: terminal disappears (pty master closed) while worker is inside sleep 250
allsteps['q08c'] = steps_common(lead_prompt('C', 250)) + [
    {"waitfile": f"{O}/q08c-marks/stop-1", "timeout": 120}, {"mark": "lead-idle-1"}, {"sleep": 6},
    {"shell": "pgrep -fl 'sleep 250' || echo no-sleep-250"},
    {"mark": "exit"}, {"exit": "closepty", "timeout": 45},
    {"shell": f"sleep 3; pgrep -fl 'sleep 250' || echo no-sleep-250-after-close; pgrep -fl 'versions/2.1.267' | grep -v pgrep || echo no-claude-procs; ls {S}/env-q08c"},
    {"shell": "sleep 20; pgrep -fl 'sleep 250' || echo no-sleep-250-after-23s"}]
# q09c: Ctrl-C twice while the Stop hook is still sleeping (40 s hook, Ctrl-C at +9 s after send)
settings['q09c'] = {"hooks": {"Stop": [{"hooks": [cmd('record.sh', f'{O}/q09c-stop.jsonl', '0', '""', '40', timeout=60)]}]}}
json.dump(settings['q09c'], open(f'{SET}/q09c.json', 'w'), indent=1)
allsteps['q09c'] = steps_common('Reply with the single word PONG and nothing else.') + [{"sleep": 9}, {"mark": "exit"}, {"exit": "ctrlc", "timeout": 60}]
for k, v in allsteps.items():
    json.dump(v, open(f'{ST}/{k}.json', 'w'), indent=1)
os.makedirs(f'{S}/dir with spaces', exist_ok=True)
open(f'{S}/dir with spaces/present.txt', 'w').write('present\n')
print('generated', sorted(settings), sorted(allsteps))
