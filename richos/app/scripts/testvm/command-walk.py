#!/usr/bin/env python3
"""command-walk.py — a background assignment runs a real tool command and reports its result.

Run by run-walk.py, which boots the guest, holds <TESTVM_ROOT>/guest.lock and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      command-walk.py --out DIR --expect-sha SHA [--within SECONDS]

run-walk.py passes the owned VM name as the first argument. `--steps a,b,c` runs a subset against
a guest someone is already holding (hold-walk.py).

THE QUESTION (esc-20260927T093052Z-85f3303f). The CEO's §50: work runs in the background and its
results come back when they land. Before this walk's fix, a task the back end carried out itself
— a command he asked to have run — was reported as "It stopped before it finished. No work was
started, so nothing was landed." seconds after the command had started, and the back end's own
report of what it printed was thrown away. This walk asks for one real command on a fresh
install and checks that its result reaches him.

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65):
  identity   the running app says it was built from --expect-sha
  first-run  adopt-walk.py's: memory setup declined, company "Acme" registered with a folder that
             is a Git repository, the business questions declined
  connect    that folder connected through Settings > Connected repositories (a company folder
             alone is not consent: `entity.rs` `connected_repositories`)
  watch      adopt-watch.py started in the guest (assignment states on the guest's clock)
  task       typed into the Mac's composer: run `git log --oneline` in the Acme repository yourself
             and tell me exactly what it prints
  observe    within --within seconds the assignment reaches a closed state. If the provider asks
             him to approve the command, Approve is pressed once per request, from the Under the
             hood panel, well inside the call's 300 s deadline. PASS needs all of: the assignment
             is a task and is `settled`; its last notice carries the repository's own HEAD short
             sha AND subject, read in the guest with git; no notice on it says "No work was
             started"; the back end's own hook evidence has a Bash PostToolUse running git.
             Evidence is written to --out.

Exit 0 when every step passes. Every app instance is quit by run-walk.py's stop.sh (CEO §54).
"""
import argparse
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from relaunch import guest  # noqa: E402

_spec = importlib.util.spec_from_file_location('adopt_walk', HERE / 'adopt-walk.py')
adopt_walk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(adopt_walk)
StepFailed = adopt_walk.StepFailed

STEPS = ['identity', 'first-run', 'connect', 'watch', 'task', 'observe']
TASK = ('Please run git log --oneline in my Acme repository yourself, with your shell tool, '
        'and tell me exactly what it prints.')
OPEN = {'registered', 'preparing', 'running', 'blocked', 'waiting-for-screen', 'waiting-for-quota'}


class CommandWalk(adopt_walk.Walk):
    def connect(self):
        self.press('Settings', role='AXPopUpButton')
        self.press('Connected repositories', role='AXMenuItem')
        self.wait_for('Company', role='AXPopUpButton')
        self.ax('click', '--title', 'Company', '--role', 'AXPopUpButton', '--first')
        self.ax('click', '--title', 'Acme', '--role', 'AXMenuItem', '--first')
        self.type_into(self.company, '--role', 'AXTextField', '--title', 'Repository folder')
        self.press('Connect repository')
        registry = self.data + '/entities.json'
        end = time.monotonic() + 30
        while time.monotonic() < end:
            value = json.loads(guest(self.vm, 'cat ' + shlex.quote(registry)))
            connected = [p for e in value.get('entities', []) for p in e.get('connected_repositories', [])]
            if connected:
                self.press('Close')
                self.facts['connected'] = connected
                self.save()
                return {'connected': connected}
            time.sleep(1)
        raise StepFailed('the repository was not connected within 30 s: ' + json.dumps(value))

    def task(self):
        before = self.clock()
        self.type_into(self.a.task, '--role', 'AXTextArea', '--title', 'Message to Rich')
        self.press('Send')
        self.facts['sent_ms'] = [before, self.clock()]
        self.save()
        return {'sent_between_guest_ms': [round(v) for v in self.facts['sent_ms']]}

    def records(self):
        script = ('import json,glob,sys\n'
                  'rows=[]\n'
                  'for p in glob.glob(sys.argv[1]+"/engine-state/assignments/*/*.json"):\n'
                  '    try: rows.append(json.load(open(p)))\n'
                  '    except Exception: pass\n'
                  'print(json.dumps(rows))\n')
        return json.loads(guest(self.vm, 'python3 -c ' + shlex.quote(script) + ' ' + shlex.quote(self.data), 60))

    def approve_if_asked(self, title):
        """One press of this assignment's Approve, when the panel offers one. Returns whether it pressed."""
        label = 'Approve ' + title
        if not self.present(label):
            try:
                self.press('Open the work summary')
            except StepFailed:
                return False
            if not self.present(label):
                return False
        self.press(label)
        return True

    def evidence_commands(self):
        script = ('import json,glob,sys\n'
                  'out=[]\n'
                  'for p in glob.glob(sys.argv[1]+"/engine-state/evidence/*/callbacks.jsonl"):\n'
                  '    for l in open(p):\n'
                  '        try: c=json.loads(l).get("callback",{})\n'
                  '        except Exception: continue\n'
                  '        if c.get("hook_event_name")=="PostToolUse" and c.get("tool_name")=="Bash" and not c.get("agent_id"):\n'
                  '            r=c.get("tool_response") or {}\n'
                  '            out.append({"command":c.get("tool_input",{}).get("command",""),\n'
                  '                        "stdout":(r.get("stdout","") if isinstance(r,dict) else str(r))[:2000]})\n'
                  'print(json.dumps(out))\n')
        return json.loads(guest(self.vm, 'python3 -c ' + shlex.quote(script) + ' ' + shlex.quote(self.data), 60))

    def observe(self):
        thread, sent = self.facts.get('thread'), self.facts.get('sent_ms')
        if not thread or not sent:
            raise StepFailed('first-run and task must have run (no thread or no send time on record)')
        head = guest(self.vm, 'git -C ' + shlex.quote(self.company) + ' log -1 --format=%h%x09%s').split('\t')
        short, subject = head[0].strip(), head[1].strip()
        end = time.monotonic() + self.a.within
        pressed, record = 0, None
        while time.monotonic() < end:
            ours = [r for r in self.records() if r.get('thread_id') == thread and r.get('registered_at_ms', 0) >= sent[0]]
            record = max(ours, key=lambda r: r.get('registered_at_ms', 0)) if ours else None
            if record and record.get('state') not in OPEN:
                break
            if record and pressed < self.a.approvals and self.approve_if_asked(record.get('title', '')):
                pressed += 1
            time.sleep(3)
        commands = self.evidence_commands()
        evidence = {'repository_head': {'short': short, 'subject': subject}, 'approvals_pressed': pressed,
                    'assignment': record, 'back_end_bash': commands}
        (self.out / 'observed.json').write_text(json.dumps(evidence, indent=2) + '\n')
        if not record:
            raise StepFailed('no assignment was registered after the task was sent')
        if record.get('state') in OPEN:
            raise StepFailed(f"the assignment was still {record.get('state')} after {self.a.within:g} s")
        failures = verdict(record, short, subject, commands)
        if failures:
            raise StepFailed('; '.join(failures))
        return {'state': record['state'], 'kind': record['kind'], 'notice': record['notices'][-1]['text'],
                'head': f'{short} {subject}', 'approvals_pressed': pressed,
                'command': next(c['command'] for c in commands if 'git' in c['command'])}


def verdict(record, short, subject, commands):
    """Why this closed assignment does NOT show a command run and its result reported ([] = it does).

    Separate from the guest so the rules can be tested on records (test/command-walk.test.py)."""
    notices = record.get('notices') or []
    said = notices[-1].get('text', '') if notices else ''
    failures = []
    if record.get('kind') != 'task':
        failures.append(f"registered as a {record.get('kind')}, not a task, so the task path was not exercised")
    if record.get('state') != 'settled':
        failures.append(f"ended {record.get('state')}: {record.get('detail')}")
    if any('No work was started' in n.get('text', '') for n in notices):
        failures.append('he was told "No work was started"')
    if not short or not subject or short not in said or subject not in said:
        failures.append(f"the last notice does not carry the command's result ({short} {subject}): {said!r}")
    if not any('git' in c.get('command', '') and short and short in c.get('stdout', '') for c in commands):
        failures.append('no Bash PostToolUse by the back end ran git and printed the head: ' + json.dumps(commands))
    return failures


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True, help='the commit the bundle under test was built from')
    p.add_argument('--task', default=TASK)
    p.add_argument('--within', type=float, default=240, help='seconds for the assignment to close')
    p.add_argument('--approvals', type=int, default=3, help='most Approve presses on this assignment')
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = CommandWalk(a)
    report = {'vm': a.vm, 'expect_sha': a.expect_sha, 'steps': []}
    ok = True
    for step in steps:
        began = time.monotonic()
        row = {'step': step}
        try:
            row['evidence'] = getattr(walk, step.replace('-', '_'))()
            row['outcome'] = 'PASS'
        except (StepFailed, RuntimeError, subprocess.TimeoutExpired, ValueError, KeyError) as exc:
            row['outcome'] = 'FAIL'
            row['detail'] = str(exc)
            ok = False
        row['seconds'] = round(time.monotonic() - began, 1)
        report['steps'].append(row)
        (a.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f"{step}: {row['outcome']}" + (f" — {row.get('detail')}" if row['outcome'] != 'PASS' else ''), flush=True)
        if not ok:
            break
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
