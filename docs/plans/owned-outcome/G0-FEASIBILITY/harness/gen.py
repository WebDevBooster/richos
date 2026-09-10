#!/usr/bin/env python3
"""Generates settings + step files for the interactive (pty) G0 probes. Literal absolute paths throughout."""
import json, os
S = '/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad'
H = S + '/hooks'; O = S + '/out'; SET = S + '/settings'; ST = S + '/steps'
os.makedirs(SET, exist_ok=True); os.makedirs(ST, exist_ok=True); os.makedirs(O, exist_ok=True)

def cmd(script, *args, timeout=15):
    return {"type": "command", "command": " ".join([f"{H}/{script}"] + list(args)), "timeout": timeout}

def stopmark(tag, rc=0):
    return {"Stop": [{"hooks": [cmd('stopmark.sh', f'{O}/{tag}-stop.jsonl', f'{O}/{tag}-marks', str(rc))]}]}

def rec(tag, event, rc=0, matcher=None, sleep=0, timeout=15):
    h = {"hooks": [cmd('record.sh', f'{O}/{tag}-{event.lower()}.jsonl', str(rc), '""', str(sleep), timeout=timeout)]}
    if matcher: h["matcher"] = matcher
    return {event: [h]}

def merge(*ds):
    out = {}
    for d in ds:
        for k, v in d.items():
            out.setdefault(k, []).extend(v)
    return out

settings = {}
# Q0 smoke
settings['q00'] = {"hooks": merge(stopmark('q00'))}
# Q1..Q4 MessageDisplay
for tag, mode in [('q01', 'ok'), ('q02', 'fail'), ('q03', 'hang')]:
    settings[tag] = {"hooks": merge(stopmark(tag), {"MessageDisplay": [{"hooks": [cmd('md-filter.sh', f'{O}/{tag}-md.jsonl', mode)]}]})}
settings['q04'] = {"disableAllHooks": True, "hooks": merge(stopmark('q04'), {"MessageDisplay": [{"hooks": [cmd('md-filter.sh', f'{O}/q04-md.jsonl', 'ok')]}]})}
# Q5 AskUserQuestion denied by PreToolUse; Q6 denied by settings rule (no hooks except stop marker); Q5b PreToolUse hook fails (exit 1)
settings['q05'] = {"hooks": merge(stopmark('q05'), {"PreToolUse": [{"matcher": "AskUserQuestion", "hooks": [cmd('pretool.sh', f'{O}/q05-pretool.jsonl', 'deny')]}]})}
settings['q06'] = {"permissions": {"deny": ["AskUserQuestion"]}, "hooks": merge(stopmark('q06'), rec('q06', 'PermissionDenied'))}
settings['q05b'] = {"hooks": merge(stopmark('q05b'), {"PreToolUse": [{"matcher": "AskUserQuestion", "hooks": [cmd('pretool.sh', f'{O}/q05b-pretool.jsonl', 'fail')]}]})}
# Q7 PermissionRequest slow deny (6 s) ; Q7b PermissionRequest fails (exit 1)
settings['q07'] = {"hooks": merge(stopmark('q07'), rec('q07', 'PreToolUse', matcher='Bash'), {"PermissionRequest": [{"matcher": "Bash", "hooks": [cmd('permreq.sh', f'{O}/q07-permreq.jsonl', '6', 'deny', timeout=30)]}]})}
settings['q07b'] = {"hooks": merge(stopmark('q07b'), {"PermissionRequest": [{"matcher": "Bash", "hooks": [cmd('permreq.sh', f'{O}/q07b-permreq.jsonl', '0', 'fail')]}]})}
# Q8 team handoff
settings['q08'] = {"env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"},
                   "permissions": {"allow": ["Bash(sleep:*)", "Bash(echo:*)", "Bash(cat:*)", "Bash(ls:*)"]},
                   "hooks": merge(stopmark('q08'), rec('q08', 'TeammateIdle'), rec('q08', 'SubagentStart'), rec('q08', 'SubagentStop'), rec('q08', 'TaskCompleted'), rec('q08', 'SessionEnd'))}
# Q9 exit with hung SessionEnd (sleep 30, timeout 60) and Q9b hung Stop hook (sleep 40, timeout 60)
settings['q09'] = {"hooks": merge(stopmark('q09'), {"SessionEnd": [{"hooks": [cmd('record.sh', f'{O}/q09-sessionend.jsonl', '0', '""', '30', timeout=60)]}]})}
settings['q09b'] = {"hooks": {"Stop": [{"hooks": [cmd('record.sh', f'{O}/q09b-stop.jsonl', '0', '""', '40', timeout=60)]}]}}
for k, v in settings.items():
    json.dump(v, open(f'{SET}/{k}.json', 'w'), indent=1)

ASK_PROSE = 'I need you to ask me a question. In plain text (do not use any tool), ask me which filename I should use for the output, offering two options, and then stop and wait for my answer.'
ASK_TOOL = 'Use the AskUserQuestion tool to ask me which filename to use for the output (options: alpha.txt or beta.txt). If the tool is refused or unavailable, do not ask in plain text; instead reply with one line: TOOL-REFUSED: <reason>.'
ASK_TOOL_FREE = 'Use the AskUserQuestion tool to ask me which filename to use for the output (options: alpha.txt or beta.txt). If the tool is refused or unavailable, ask me the same question in plain text instead.'
TOUCH = 'Run exactly this shell command with the Bash tool: touch g0-perm.txt . If permission is denied, reply with one line DENIED and stop; do not retry.'
def steps(tag, prompt, wait='marker', extra_exit='/exit', pre=None, post=None, quiet=6, wtimeout=150):
    s = [{"expect": r"for\s*shortcuts|for\s*agents", "timeout": 30, "required": False}, {"sleep": 2.0}]
    if pre: s += pre
    s += [{"mark": "prompt-send"}, {"send": prompt}, {"sleep": 0.8}, {"send": "\r"}]
    if wait == 'marker': s += [{"waitfile": f"{O}/{tag}-marks/stop-1", "timeout": wtimeout}, {"sleep": 2.5}]
    else: s += [{"sleep": 8}, {"quiet": quiet, "timeout": wtimeout}]
    if post: s += post
    s += [{"mark": "exit"}, {"exit": extra_exit, "timeout": 45}]
    return s
allsteps = {
 'q00': steps('q00', 'Reply with the single word PONG and nothing else.'),
 'q01': steps('q01', ASK_PROSE), 'q02': steps('q02', ASK_PROSE), 'q03': steps('q03', ASK_PROSE),
 'q04': steps('q04', ASK_PROSE, wait='quiet'),
 'q05': steps('q05', ASK_TOOL), 'q05c': steps('q05c', ASK_TOOL_FREE),
 'q06': steps('q06', ASK_TOOL), 'q05b': steps('q05b', ASK_TOOL),
 'q07': steps('q07', TOUCH), 'q07b': steps('q07b', TOUCH, post=[{"sleep": 3}, {"send": "\x1b"}, {"sleep": 4}]),
 'q09': steps('q09', 'Reply with the single word PONG and nothing else.'),
 'q09b': steps('q09b', 'Reply with the single word PONG and nothing else.', wait='quiet', quiet=4, extra_exit='ctrlc'),
}
# q05c uses the q05 settings (PreToolUse deny) but a prompt that permits a prose fallback
settings['q05c'] = {"hooks": merge(stopmark('q05c'), {"PreToolUse": [{"matcher": "AskUserQuestion", "hooks": [cmd('pretool.sh', f'{O}/q05c-pretool.jsonl', 'deny')]}]})}
json.dump(settings['q05c'], open(f'{SET}/q05c.json', 'w'), indent=1)
for k, v in allsteps.items():
    json.dump(v, open(f'{ST}/{k}.json', 'w'), indent=1)
print('generated', sorted(settings), sorted(allsteps))
