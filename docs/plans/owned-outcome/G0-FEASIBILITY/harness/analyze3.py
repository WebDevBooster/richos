#!/usr/bin/env python3
"""Round-two evidence: shell-step outputs, team-event ledgers, screen tails around exit, and teammate transcripts."""
import json, os, re, sys, glob
S = '/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad'
O = S + '/out'; PROJ = os.path.expanduser('~/.claude/projects')
def collapse(s): return re.sub(r'[ \t]+', ' ', re.sub(r'\n{2,}', '\n', s))
for tag in sys.argv[1:]:
    print('=' * 100); print('PROBE', tag)
    evs = [json.loads(l) for l in open(f'{O}/{tag}.events.jsonl')]
    t_exit = next((e['rel_ms'] for e in evs if e['kind'] == 'exit-request'), None)
    for e in evs:
        if e['kind'] == 'shell':
            print(f'  [shell @rel {e["rel_ms"]}] rc={e["rc"]} $ {e["cmd"][:100]}'); print('     ', e['out'].strip().replace('\n', '\n      ')[:2500])
        elif e['kind'] in ('waitfile', 'exit-request', 'exited', 'exit-timeout', 'sigkill', 'mark', 'send', 'pty-closed'):
            print(f'  [{e["kind"]} @rel {e["rel_ms"]}] {e.get("label", e.get("how", e.get("path", e.get("text", ""))))!s:.90}')
    for name in ['teammateidle', 'subagentstart', 'subagentstop', 'taskcompleted', 'sessionend', 'userpromptsubmit', 'stop', 'md']:
        p = f'{O}/{tag}-{name}.jsonl'
        if os.path.exists(p):
            rows = [json.loads(l) for l in open(p)]
            print(f'  ledger {name}: {len(rows)} rows')
            for r in rows[:6]:
                pl = r['payload']; t0 = evs[0]['ts_ms']
                keep = {k: (v if len(json.dumps(v)) < 220 else json.dumps(v)[:220]) for k, v in pl.items() if k not in ('transcript_path', 'cwd', 'session_id', 'hook_event_name', 'permission_mode', 'scratchpad_dir')}
                print(f'     @rel {r["ts_ms"]-t0}: {json.dumps(keep)[:700]}')
    # screen text emitted after the exit request (what the user would have seen)
    if t_exit is not None:
        after = ''.join(e['text'] for e in evs if e['kind'] == 'out' and e['rel_ms'] >= t_exit - 1500)
        print('  screen from 1.5 s before exit-request (collapsed):', collapse(after)[-1800:])
    # teammate transcripts (in-process teammates are stored as subagent transcripts under the lead's session dir)
    sid = open(f'{O}/{tag}.sid').read().strip()
    for p in sorted(glob.glob(f'{PROJ}/*scratchpad-env-{tag}/{sid}/**/*.jsonl', recursive=True)) + sorted(glob.glob(f'{PROJ}/*scratchpad-env-{tag}/{sid}-*.jsonl')):
        print('  sub-transcript:', p.replace(PROJ, '~/.claude/projects'))
        rows = [json.loads(l) for l in open(p) if l.strip()]
        first_user = next((r for r in rows if r.get('type') == 'user'), None)
        if first_user:
            c = first_user['message'].get('content'); txt = c if isinstance(c, str) else json.dumps(c)
            print('     first user msg (brief) len=', len(txt), ':', txt[:400].replace('\n', ' / '))
            print('     brief contains path-with-spaces:', 'dir with spaces' in txt, '| contains negative constraint:', 'do NOT modify BACKLOG.md' in txt)
        last_ts = [r.get('timestamp') for r in rows if r.get('timestamp')]
        print('     rows:', len(rows), 'first ts:', last_ts[0] if last_ts else None, 'last ts:', last_ts[-1] if last_ts else None)
        for r in rows:
            if r.get('type') == 'assistant':
                for c in r['message'].get('content', []):
                    if c.get('type') == 'tool_use': print('     tool_use:', c['name'], json.dumps(c.get('input'))[:120], '@', r.get('timestamp'))
                    elif c.get('type') == 'text': print('     text:', c['text'][:160].replace('\n', ' / '), '@', r.get('timestamp'))
