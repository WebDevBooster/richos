#!/usr/bin/env python3
"""A step ax.sh itself refuses (a bad role, a missing matcher) fails the walk at once; it is not
polled until its deadline while the walk keeps its guest and slot (2026-10-04)."""
import importlib.util
import sys
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / 'steps-walk.py'
spec = importlib.util.spec_from_file_location('steps_walk', TOOL)
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
calls = []
sw.run = lambda args, timeout=120: (calls.append(args) or (1, '[testvm] ERROR: find needs something to match'))
sw.time.sleep = lambda s: None
code, text = sw.step_run('vm', {'op': 'until', 'args': ['find'], 'contains': 'x', 'seconds': 30}, Path('.'))
ok = code != 0 and len(calls) == 1 and 'not retried' in text
print(('  ok    ' if ok else '  FAIL  ') + 'an until step whose ax.sh request is refused fails after one call', (code, len(calls), text))
print(f'steps-walk-refused.test.py: {0 if ok else 1} failed')
sys.exit(0 if ok else 1)
