#!/usr/bin/env python3
"""Exact-phrase timelines: when did specific sentences first reach the raw pty stream, relative to hook ledger timestamps."""
import json, re, sys, os
S = '/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad'
O = S + '/out'
def nospace(s): return re.sub(r'\s+', '', s)
def timeline(tag, phrases):
    evs = [json.loads(l) for l in open(f'{O}/{tag}.events.jsonl')]
    t0 = evs[0]['ts_ms']
    acc = ''; seen = {}
    for e in evs:
        if e['kind'] != 'out': continue
        acc += nospace(e['text'])
        for p in phrases:
            if p not in seen and nospace(p) in acc: seen[p] = (e['rel_ms'], e['ts_ms'])
    return t0, seen, acc
for tag in sys.argv[1:]:
    print('=' * 90); print(tag)
    phrases = ['should I use for the output?', 'would you prefer for the output?', 'would you like me to use for the output?', 'Which would you prefer?',
               'WITHHELD BY G0 FILTER', 'output.txt', 'result.txt', 'result.md', 'different filename in mind',
               'Do you want to proceed?', 'Yes, and always allow', 'Denied by PermissionRequest hook', 'Esc to cancel', 'Which filename should I use for the output? ❯', '1. alpha.txt', 'hook error', 'hook failed']
    t0, seen, acc = timeline(tag, phrases)
    for p, (rel, ts) in sorted(seen.items(), key=lambda x: x[1][0]): print(f'  first on screen rel_ms={rel:6d} abs_ms={ts}: {p!r}')
    for name in ['md', 'permreq', 'pretool', 'stop']:
        p = f'{O}/{tag}-{name}.jsonl'
        if os.path.exists(p):
            for l in open(p):
                r = json.loads(l); pl = r['payload']
                extra = json.dumps(pl.get('delta'))[:70] if name == 'md' else pl.get('tool_name', '')
                print(f'  ledger {name:8s} invoked rel_ms={r["ts_ms"]-t0:6d} abs_ms={r["ts_ms"]} {extra}')
    for e in [json.loads(l) for l in open(f'{O}/{tag}.events.jsonl')]:
        if e['kind'] in ('mark', 'waitfile', 'exit-request', 'exited', 'exit-timeout', 'send'):
            print(f'  event rel_ms={e["rel_ms"]:6d} {e["kind"]} {e.get("label", e.get("how", e.get("text", "")))!s:.60}')
