#!/usr/bin/env python3
"""Per-probe analysis of pty captures: what reached the screen, what the ledgers say, what the transcript stored."""
import json, os, re, sys, glob
S = '/private/tmp/claude-501/-Users-alex-ab-femcboost/d0eef867-5636-46b7-a2bd-53dfd26564be/scratchpad'
O = S + '/out'
PROJ = os.path.expanduser('~/.claude/projects')

def screen_between(tag):
    """Screen text emitted between the prompt-send mark and the exit mark, with rel_ms of first sightings."""
    evs = [json.loads(l) for l in open(f'{O}/{tag}.events.jsonl')]
    t_send = next((e['rel_ms'] for e in evs if e['kind'] == 'mark' and e['label'] == 'prompt-send'), 0)
    t_exit = next((e['rel_ms'] for e in evs if e['kind'] == 'mark' and e['label'] == 'exit'), 10**9)
    chunks = [(e['rel_ms'], e['text']) for e in evs if e['kind'] == 'out' and t_send <= e['rel_ms'] <= t_exit]
    return chunks, evs

def first_sighting(chunks, pattern):
    rx = re.compile(pattern, re.I)
    acc = ''
    for t, txt in chunks:
        acc += txt
        if rx.search(acc):
            return t
    return None

def transcript_text(tag):
    sid = open(f'{O}/{tag}.sid').read().strip()
    paths = glob.glob(f'{PROJ}/*scratchpad-env-{tag}/{sid}.jsonl')
    if not paths: return None, sid
    out = []
    for l in open(paths[0]):
        try: r = json.loads(l)
        except Exception: continue
        if r.get('type') == 'assistant':
            for c in r['message'].get('content', []):
                if c.get('type') == 'text': out.append(('text', c['text']))
                elif c.get('type') == 'tool_use': out.append(('tool_use', c['name'], json.dumps(c.get('input'))[:300]))
        elif r.get('type') == 'user':
            c = r['message'].get('content')
            if isinstance(c, list):
                for x in c:
                    if x.get('type') == 'tool_result':
                        out.append(('tool_result', str(x.get('content'))[:300]))
    return out, sid

def ledger(tag, name):
    p = f'{O}/{tag}-{name}.jsonl'
    if not os.path.exists(p): return None
    return [json.loads(l) for l in open(p)]

def main(tags):
    for tag in tags:
        print('=' * 100); print('PROBE', tag)
        chunks, evs = screen_between(tag)
        joined = ''.join(t for _, t in chunks)
        flat = re.sub(r'\s+', ' ', joined)
        for label, pat in [('question-mark-line', r'which (filename|file name)|filename (should|would|do)|alpha\.txt|beta\.txt'),
                           ('withheld-marker', r'WITHHELD BY G0 FILTER'),
                           ('askuserquestion-dialog', r'Enter to select|Esc to cancel|esc to cancel|Type something|❯\s*1\.|1\.\s*alpha'),
                           ('tool-refused-line', r'TOOL-REFUSED'),
                           ('permission-dialog', r'Do you want to proceed|Yes, and don|Allow|Bash command|touch g0-perm'),
                           ('denied-line', r'DENIED'),
                           ('hook-error-notice', r'hook error|hook failed|MessageDisplay')]:
            t = first_sighting(chunks, pat)
            print(f'  screen: {label:24s} first seen at rel_ms={t}')
        for name in ['md', 'pretool', 'permreq', 'permissiondenied', 'stop', 'teammateidle', 'subagentstart', 'subagentstop']:
            L = ledger(tag, name)
            if L is not None:
                print(f'  ledger {name}: {len(L)} rows')
                if name == 'md':
                    for r in L[:12]:
                        p = r['payload']; print('     md delta:', json.dumps(p.get('delta'))[:160], 'final=', p.get('final'), 'idx=', p.get('index'))
                if name in ('pretool', 'permreq', 'permissiondenied'):
                    for r in L[:3]:
                        p = r['payload']; print('     ', name, 'tool=', p.get('tool_name'), 'input=', json.dumps(p.get('tool_input'))[:200], 'keys=', sorted(p.keys()))
        tr, sid = transcript_text(tag)
        print('  transcript', sid, ':')
        if tr is None: print('     (no transcript found)')
        else:
            for item in tr[:8]: print('     ', item[0], '|', (item[1] if len(item) == 2 else item[1] + ' ' + item[2])[:260].replace('\n', ' / '))
        # screen excerpt: last 900 chars of the between-window, whitespace-collapsed
        print('  screen excerpt (collapsed):', flat[-900:])
        ex = [e for e in evs if e['kind'] in ('exited', 'exit-timeout', 'sigkill')]
        print('  exit:', ex)

if __name__ == '__main__':
    main(sys.argv[1:])
