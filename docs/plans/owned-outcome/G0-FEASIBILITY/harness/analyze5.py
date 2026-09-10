#!/usr/bin/env python3
"""Raw screen windows: q08 teammate permission dialog (appearance and resolution) and q08b after the /exit keystrokes."""
import json, re, sys, glob, os
S = '/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad'
O = S + '/out'; PROJ = os.path.expanduser('~/.claude/projects')
def window(tag, a, b, pat=None):
    evs = [json.loads(l) for l in open(f'{O}/{tag}.events.jsonl')]
    for e in evs:
        if e['kind'] == 'out' and a <= e['rel_ms'] <= b:
            s = re.sub(r'\s+', ' ', e['text']).strip()
            if s and (pat is None or re.search(pat, s, re.I)): print(f'   @rel {e["rel_ms"]}: {s[:420]}')
print('=== q08: 14.0-20.0 s (dialog appears)'); window('q08', 14000, 20000)
print('=== q08: 20-128 s, chunks mentioning proceed/allow/Yes/No/worker/timeout/auto'); window('q08', 20000, 128000, r'proceed|allow|Yes|No,|worker|time|auto|classif')
print('=== q08: 128-140 s (dialog resolves)'); window('q08', 128000, 140000)
print('=== q08b: 5-16 s, chunks mentioning proceed/allow/from the worker'); window('q08b', 5000, 16800, r'proceed|allow|from the|Bash command')
print('=== q08b: after /exit keystrokes 16.8-24 s'); window('q08b', 16800, 24000)
print('=== q08b: 55-62 s (just before SIGKILL)'); window('q08b', 55000, 62300)
# lead transcript records around the q08 resolution
sid = open(f'{O}/q08.sid').read().strip()
p = glob.glob(f'{PROJ}/*scratchpad-env-q08/{sid}.jsonl')[0]
print('=== q08 lead transcript: every record with timestamp between 07:05:40 and 07:05:50, or mentioning permission')
for l in open(p):
    if not l.strip(): continue
    r = json.loads(l); t = r.get('timestamp', '')
    if ('07:05:4' in t) or re.search(r'permission|allow|deny|decision', l, re.I) and r.get('type') not in ('attachment',):
        print('   ', t[11:23], r.get('type'), json.dumps(r)[:600])
