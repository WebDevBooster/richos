#!/usr/bin/env python3
"""Why did the worker stall, and why did /exit not end the session: transcript timestamps and post-exit screen text."""
import json, os, re, sys, glob
S = '/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad'
O = S + '/out'; PROJ = os.path.expanduser('~/.claude/projects')
for tag in sys.argv[1:]:
    print('=' * 100); print('PROBE', tag)
    sid = open(f'{O}/{tag}.sid').read().strip()
    lead = glob.glob(f'{PROJ}/*scratchpad-env-{tag}/{sid}.jsonl')
    subs = glob.glob(f'{PROJ}/*scratchpad-env-{tag}/{sid}/subagents/*.jsonl')
    for p in lead + subs:
        print('  transcript:', p.replace(PROJ, '~/.claude/projects'))
        for l in open(p):
            if not l.strip(): continue
            r = json.loads(l); t = r.get('timestamp', '')[11:23]
            if r.get('type') == 'user':
                c = r['message'].get('content')
                if isinstance(c, str): print(f'    {t} user text: {c[:140]!r}')
                else:
                    for x in c:
                        if x.get('type') == 'tool_result': print(f'    {t} tool_result: {str(x.get("content"))[:140]!r}')
                        elif x.get('type') == 'text': print(f'    {t} user text: {x["text"][:140]!r}')
            elif r.get('type') == 'assistant':
                for c in r['message'].get('content', []):
                    if c.get('type') == 'tool_use': print(f'    {t} tool_use: {c["name"]} {json.dumps(c.get("input"))[:110]}')
                    elif c.get('type') == 'text': print(f'    {t} text: {c["text"][:120]!r}')
            elif r.get('type') not in ('assistant', 'user', 'progress', 'file-history-snapshot'):
                print(f'    {t} {r.get("type")}: {json.dumps(r)[:160]}')
    evs = [json.loads(l) for l in open(f'{O}/{tag}.events.jsonl')]
    t_exit = next((e['rel_ms'] for e in evs if e['kind'] == 'exit-request'), None)
    if t_exit:
        print('  --- screen chunks after exit request mentioning exit/background/teammate/proceed/shell:')
        for e in evs:
            if e['kind'] == 'out' and e['rel_ms'] >= t_exit:
                s = re.sub(r'\s+', ' ', e['text'])
                if re.search(r'exit|background|teammate|proceed|shell|Ctrl|running|queued|Exit', s, re.I): print(f'    @rel {e["rel_ms"]}: {s[:300]}')
    print('  --- lead screen between 14 s and 135 s mentioning permission/proceed/allow/waiting:')
    for e in evs:
        if e['kind'] == 'out' and 14000 <= e['rel_ms'] <= 135000:
            s = re.sub(r'\s+', ' ', e['text'])
            if re.search(r'proceed|allow|permission|Waiting|wants to|approve', s, re.I): print(f'    @rel {e["rel_ms"]}: {s[:300]}')
