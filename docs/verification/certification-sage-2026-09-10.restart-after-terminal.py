"""For every sealed+terminal transaction on this machine, did the platform fire a
SubagentStart (WorkerStarted) for the SAME agent id AFTER the terminal record?
Evidence: ~/.claude/teams/session-*/worker-events.jsonl (written by the live
SubagentStart/SubagentStop hooks) against ~/.claude/state/worktree-transactions."""
import glob
import json
import os
from datetime import datetime

root = os.path.expanduser('~/.claude/state/worktree-transactions')
teams = glob.glob(os.path.expanduser('~/.claude/teams/session-*/worker-events.jsonl'))


def ts(s):
    try:
        return datetime.fromisoformat((s or '').replace('Z', '+00:00'))
    except Exception:
        return None


starts = {}
stops = {}
for f in teams:
    for line in open(f):
        try:
            r = json.loads(line)
        except Exception:
            continue
        aid = r.get('agent_id') or ''
        t = ts(r.get('timestamp'))
        if not aid or not t:
            continue
        if r.get('event') == 'WorkerStarted':
            starts.setdefault(aid, []).append(t)
        elif r.get('event') == 'WorkerRunEnded':
            stops.setdefault(aid, []).append(t)

total = 0
restarted = []
by_ingress = {}
for p in glob.glob(root + '/*/*.json'):
    try:
        t = json.load(open(p))
    except Exception:
        continue
    if t.get('record') != 'transaction' or not t.get('terminal') or t.get('kind') == 'adopted':
        continue
    term = ts(t['terminal'].get('ts'))
    if not term:
        continue
    total += 1
    ing = t['terminal'].get('ingress')
    by_ingress[ing] = by_ingress.get(ing, 0) + 1
    aid = t['agent_id']
    later_starts = [s for s in starts.get(aid, []) if (s - term).total_seconds() > 2]
    later_stops = [s for s in stops.get(aid, []) if (s - term).total_seconds() > 2]
    if later_starts:
        gap = max((s - term).total_seconds() for s in later_starts)
        restarted.append((t['session_id'][:8], t.get('teammate') or '?', aid[:10], ing,
                          t['terminal']['ts'][:19], len(later_starts), len(later_stops), round(gap / 3600, 2)))

print('terminal transactions (non-adopted):', total, by_ingress)
print('agent ids with WorkerStarted (same id) AFTER their terminal record:', len(restarted))
print('session  teammate  agent  ingress  terminal_ts  starts_after  stops_after  max_gap_h')
for r in sorted(restarted, key=lambda r: r[4]):
    print(r)
print('worker-events files scanned:', len(teams), 'ids with starts:', len(starts))
