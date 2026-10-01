#!/usr/bin/env python3
"""steps-walk.py - drive the app booted in this run's guest through a JSON list of steps.

Run by run-walk.py, which holds one guest slot for this run only, boots the guest, runs this
and removes the clone (run-walk.py passes the owned VM name as the first argument):

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE_TAR --report REPORT -- \\
      steps-walk.py --steps steps.json --out DIR

A step is an object with "op" and its arguments. Every step is recorded in <out>/steps.json with
its exit status, its output and the clock, so a walk's evidence is one file and not a transcript.

  tree   [app]                         ax.sh VM tree, written to <out>/<name>.tree
  shot   name [ocr]                    shot.sh VM <out>/<name>.png (a black frame fails)
  ax     args[]                        ax.sh VM <args...>  (find / click / focus / type)
  guest  command                       guest.sh VM <command>, output recorded
  wait   seconds                       sleep (a plain pause; prefer "until")
  until  args[] contains seconds       repeat ax.sh VM <args...> until its output contains the text
  keys   text                          guest.sh osascript keystroke into the frontmost app
  push   src dest                      guest.sh VM --push src dest (a fixture file into the guest)
  handfile mode path [to]              hand-file.sh VM paste|drag path [--to x,y]

"allow_fail": true records a failing step and carries on; otherwise the first failure stops the walk
(exit 1). The final exit is 0 only when every step that was not allowed to fail passed.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent


def run(args, timeout=120):
    try:
        r = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
        return r.returncode, (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired as e:
        return 124, f'timeout after {timeout}s: {e}'


def step_run(vm, step, out):
    op = step['op']
    if op == 'tree':
        cmd = [str(HERE / 'ax.sh'), vm, 'tree'] + (['--app', step['app']] if step.get('app') else [])
        code, text = run(cmd)
        (out / f"{step['name']}.tree").write_text(text + '\n')
        return code, f"{len(text.splitlines())} lines"
    if op == 'shot':
        cmd = [str(HERE / 'shot.sh'), vm, str(out / f"{step['name']}.png")] + (['--ocr'] if step.get('ocr') else [])
        return run(cmd)
    if op == 'ax':
        return run([str(HERE / 'ax.sh'), vm] + step['args'])
    if op == 'guest':
        return run([str(HERE / 'guest.sh'), vm, step['command']])
    if op == 'keys':
        return run([str(HERE / 'guest.sh'), vm, 'osascript', '-e',
                    f'tell application "System Events" to keystroke "{step["text"]}"'])
    if op == 'push':
        return run([str(HERE / 'guest.sh'), vm, '--push', step['src'], step['dest']])
    if op == 'handfile':
        return run([str(HERE / 'hand-file.sh'), vm, step['mode'], step['path']] + (['--to', step['to']] if step.get('to') else []))
    if op == 'wait':
        time.sleep(step['seconds'])
        return 0, ''
    if op == 'until':
        deadline = time.monotonic() + step.get('seconds', 30)
        text = ''
        while time.monotonic() < deadline:
            code, text = run([str(HERE / 'ax.sh'), vm] + step['args'])
            if code == 0 and step['contains'] in text:
                return 0, text[:400]
            time.sleep(2)
        return 1, f"never saw {step['contains']!r}; last: {text[:400]}"
    return 2, f'unknown op {op!r}'


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--steps', required=True, type=Path)
    p.add_argument('--out', required=True, type=Path)
    a = p.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    steps = json.loads(a.steps.read_text())
    record, failed = [], False
    for i, step in enumerate(steps):
        started = time.strftime('%H:%M:%SZ', time.gmtime())
        code, text = step_run(a.vm, step, a.out)
        record.append({'i': i, 'step': step, 'at': started, 'exit': code, 'output': text[:2000]})
        print(f'{i:02d} {started} {step["op"]} exit={code} {text[:160]!r}', flush=True)
        (a.out / 'steps.json').write_text(json.dumps(record, indent=2) + '\n')
        if code and not step.get('allow_fail'):
            failed = True
            break
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
