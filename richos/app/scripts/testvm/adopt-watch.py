#!/usr/bin/env python3
"""adopt-watch.py — runs IN THE TEST GUEST: every change of every assignment, every prompt and
every intake record, on the guest's own clock, written as one JSON line each.

  python3 adopt-watch.py <app-data-dir> <out.jsonl> [--seconds N] [--every-ms M]

Pushed into the guest and started by adopt-walk.py. It reads, it never writes anything but its
own output, and it never records the words of a prompt: prompts are recorded by their turn,
thread, source and intake id; intake records by their kind, id, thread and channel; assignments
by their id, thread, kind, state, the app's two timestamps and the app's own status sentence
(`detail`, which can quote the assignment's title — a walk's fixture text, never his).

Why a poller at 100 ms rather than a single read at the end: the question is ORDER on one clock
(the phone's words arrive, the turn ends, the assignment is Registered, then it leaves Registered
without a typed message in between), and a final read would show only where things ended.
"""
import argparse
import json
from pathlib import Path
import time


def read_json_lines(path, offset):
    """New complete lines of `path` since `offset`, and the new offset."""
    try:
        with open(path, 'rb') as f:
            f.seek(offset)
            data = f.read()
    except FileNotFoundError:
        return [], offset
    end = data.rfind(b'\n')
    if end < 0:
        return [], offset
    rows = []
    for line in data[:end].split(b'\n'):
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows, offset + end + 1


def main():
    p = argparse.ArgumentParser()
    p.add_argument('data')
    p.add_argument('out')
    p.add_argument('--seconds', type=float, default=1800)
    p.add_argument('--every-ms', type=float, default=100)
    a = p.parse_args()
    data = Path(a.data)
    assignments = data / 'engine-state' / 'assignments'
    ledger = data / 'conversation-ledger.jsonl'
    intake = data / 'intake.jsonl'
    seen = {}
    offsets = {ledger: 0, intake: 0}
    deadline = time.time() + a.seconds
    with open(a.out, 'a', buffering=1) as out:
        def emit(row):
            row['t_ms'] = round(time.time() * 1000)
            out.write(json.dumps(row, sort_keys=True) + '\n')
        emit({'kind': 'watch-start', 'data': str(data)})
        while time.time() < deadline:
            for path in sorted(assignments.glob('*/*.json')) if assignments.is_dir() else []:
                try:
                    record = json.loads(path.read_text())
                except (OSError, ValueError):
                    continue
                key = record.get('id') or path.stem
                state = record.get('state')
                if seen.get(key) != state:
                    seen[key] = state
                    emit({'kind': 'assignment', 'id': key, 'thread': record.get('thread_id'),
                          'assignment_kind': record.get('kind'), 'state': state,
                          'registered_at_ms': record.get('registered_at_ms'),
                          'updated_at_ms': record.get('updated_at_ms'), 'detail': record.get('detail')})
            rows, offsets[ledger] = read_json_lines(ledger, offsets[ledger])
            for row in rows:
                event = row.get('event')
                if event in ('PromptReceived', 'TurnCompleted', 'TurnFailed', 'TurnInterrupted', 'TurnStopped',
                             'ThreadCreated'):
                    emit({'kind': 'ledger', 'event': event, 'turn': row.get('turn_id'),
                          'thread': row.get('thread_id'), 'source': row.get('source'),
                          'intake_id': row.get('intake_id'), 'at': row.get('at')})
            rows, offsets[intake] = read_json_lines(intake, offsets[intake])
            for row in rows:
                emit({'kind': 'intake', 'record': row.get('record'), 'id': row.get('id'),
                      'thread': row.get('thread_id'), 'channel': row.get('channel'),
                      'through': row.get('through')})
            time.sleep(a.every_ms / 1000)
        emit({'kind': 'watch-end'})


if __name__ == '__main__':
    main()
