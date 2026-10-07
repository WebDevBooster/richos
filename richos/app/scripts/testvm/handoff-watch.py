#!/usr/bin/env python3
"""handoff-watch.py — in the guest: everything the weekly-switch handoff writes, on the guest's clock.

  python3 handoff-watch.py <app data dir> <out.jsonl> [--seconds N] [--every S]

Pushed and started by handoff-real-walk.py. Every --every seconds (default 3) it reads the app's
own records and writes one JSON row per CHANGE, each with `t_ms` (guest epoch ms):

  marker      engine-state/handoffs/<agent>.json: the gate's order (`at`) and its use (`continued_at`)
  receipt     engine-state/work-receipts/*/*.json: name, status, role, teammate, continue_of,
              continuation, agent_id, review fields (the agent payload is left out)
  brief       engine-state/work-receipts/*/*.brief: the whole brief, once, when it first appears
  assignment  engine-state/assignments/*/*.json: state, detail, title, kind
  hook        engine-state/evidence/*/callbacks.jsonl: each SubagentStart / SubagentStop row, when seen
  quota       engine-state/claude-quota.json: each account's weekly reading, in use, leaving
  git         every workspace under engine-state/target-worktrees: HEAD and its last 60 commits

The journal rows carry no time of their own, so `t_ms` on a hook row is when this watcher first
saw it: at most --every seconds late. Read-only: it never writes into the app's data.
"""
import glob
import json
import os
import subprocess
import sys
import time


def now_ms():
    return int(time.time() * 1000)


def load(path):
    try:
        with open(path, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def git_log(path):
    try:
        head = subprocess.run(['git', '-C', path, 'rev-parse', 'HEAD'], capture_output=True, text=True,
                              timeout=20).stdout.strip()
        if not head:
            return None
        log = subprocess.run(['git', '-C', path, 'log', '-60', '--format=%H%x09%ct%x09%s'], capture_output=True,
                             text=True, timeout=20).stdout
        dirty = subprocess.run(['git', '-C', path, 'status', '--porcelain', '--untracked-files=all'],
                               capture_output=True, text=True, timeout=20).stdout
        return {'head': head, 'log': [line.split('\t', 2) for line in log.splitlines() if line],
                'dirty': len([line for line in dirty.splitlines() if line])}
    except (OSError, subprocess.SubprocessError):
        return None


def receipt_view(value):
    if not isinstance(value, dict):
        return None
    request = value.get('request') or {}
    keep = {k: value.get(k) for k in ('id', 'name', 'status', 'agent_id', 'continuation', 'review_target',
                                      'workspace_ref', 'problem', 'review', 'observed_review') if k in value}
    keep['request'] = {k: request.get(k) for k in ('role', 'teammate', 'continue_of', 'review_of', 'title',
                                                  'repo', 'obligation_id')}
    return keep


def main(argv):
    data, out = argv[1], argv[2]
    seconds = float(argv[argv.index('--seconds') + 1]) if '--seconds' in argv else 6 * 3600
    every = float(argv[argv.index('--every') + 1]) if '--every' in argv else 3
    state = os.path.join(data, 'engine-state')
    seen = {}
    hook_lines = {}
    end = time.time() + seconds

    def emit(fh, row):
        row['t_ms'] = now_ms()
        fh.write(json.dumps(row, sort_keys=True) + '\n')
        fh.flush()

    def changed(key, value):
        if seen.get(key) == value:
            return False
        seen[key] = value
        return True

    with open(out, 'a', encoding='utf-8') as fh:
        emit(fh, {'kind': 'watch-start', 'data': data})
        while time.time() < end:
            for path in sorted(glob.glob(os.path.join(state, 'handoffs', '*.json'))):
                value = load(path)
                if value is not None and changed(path, value):
                    emit(fh, {'kind': 'marker', 'path': path, 'value': value})
            for path in sorted(glob.glob(os.path.join(state, 'work-receipts', '*', '*.json'))):
                value = receipt_view(load(path))
                if value is not None and changed(path, value):
                    emit(fh, {'kind': 'receipt', 'path': path, 'value': value})
            for path in sorted(glob.glob(os.path.join(state, 'work-receipts', '*', '*.brief'))):
                if path in seen:
                    continue
                try:
                    with open(path, encoding='utf-8', errors='replace') as b:
                        text = b.read()
                except OSError:
                    continue
                seen[path] = True
                emit(fh, {'kind': 'brief', 'path': path, 'text': text})
            for path in sorted(glob.glob(os.path.join(state, 'assignments', '*', '*.json'))):
                value = load(path)
                if not isinstance(value, dict):
                    continue
                view = {k: value.get(k) for k in ('id', 'state', 'detail', 'title', 'kind', 'thread_id',
                                                  'work_session', 'obligation_id')}
                if changed(path, view):
                    emit(fh, {'kind': 'assignment', 'path': path, 'value': view})
            for path in sorted(glob.glob(os.path.join(state, 'evidence', '*', 'callbacks.jsonl'))):
                try:
                    with open(path, encoding='utf-8', errors='replace') as j:
                        lines = j.read().splitlines()
                except OSError:
                    continue
                start = hook_lines.get(path, 0)
                hook_lines[path] = len(lines)
                for line in lines[start:]:
                    try:
                        c = json.loads(line).get('callback', {})
                    except ValueError:
                        continue
                    if c.get('hook_event_name') in ('SubagentStart', 'SubagentStop'):
                        emit(fh, {'kind': 'hook', 'event': c.get('hook_event_name'), 'agent_id': c.get('agent_id'),
                                  'agent_type': c.get('agent_type'), 'session': c.get('session_id'),
                                  'last': str(c.get('last_assistant_message', ''))[:2000]})
            quota = load(os.path.join(state, 'claude-quota.json'))
            if isinstance(quota, dict):
                accounts = []
                for a in quota.get('accounts') or []:
                    weekly = next((w.get('usedPercent') for w in a.get('windows') or [] if w.get('id') == 'seven_day'), None)
                    accounts.append({'id': a.get('id'), 'label': a.get('label'), 'inUse': a.get('inUse'),
                                     'weekly': weekly, 'message': a.get('message')})
                view = {'accounts': accounts, 'leaving': quota.get('leaving'), 'actAt': quota.get('actAt'),
                        'speeds': quota.get('speeds'), 'lastSwitch': quota.get('lastSwitch')}
                if changed('quota', view):
                    emit(fh, {'kind': 'quota', 'value': view})
            for path in sorted(glob.glob(os.path.join(state, 'target-worktrees', '*', '*'))):
                if not os.path.isdir(path):
                    continue
                value = git_log(path)
                if value is not None and changed('git:' + path, value):
                    emit(fh, {'kind': 'git', 'path': path, 'value': value})
            time.sleep(every)
        emit(fh, {'kind': 'watch-end'})
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
