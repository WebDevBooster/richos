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
  task       typed into the Mac's composer: run the harmless test command `git log --oneline`
             yourself in my Acme folder, and tell me when it has finished and what it printed
  observe    within --within seconds the assignment reaches a closed state. If the provider asks
             him to approve the command, Approve is pressed once per request, from the Under the
             hood panel, well inside the call's 300 s deadline. PASS needs all of: the assignment
             is a task and is `settled`; its last notice carries the repository's own HEAD short
             sha AND subject, read in the guest with git; no notice on it says "No work was
             started"; the back end's own hook evidence has a Bash PostToolUse running git.
             Evidence is written to --out.

FOUR MORE STEPS, run with --steps (esc-20260927T093052Z-85f3303f's leftovers):
  background     "start `sleep N && git log --oneline` in the background and tell me when it has
                 finished": PASS needs the back end's own hook record to show the command run with
                 run_in_background; the assignment seen `running` with "A command it started is
                 still running." while he already had its first words; then `settled` as
                 answered, with a LATER notice carrying the head's short sha and subject, raised
                 no earlier than N seconds after the send (the finish cannot be reported before
                 the command could end). Evidence: background-observed.json.
  deadline       checks the running app was launched with RICHOS_PERMISSION_DEADLINE_MS=--deadline-ms
                 (permissions.rs: it can only shorten the shipping 300 s), so a late approval takes
                 seconds to reach. Launch it so: TESTVM_APP_ENV=RICHOS_PERMISSION_DEADLINE_MS=20000
                 in run-walk.py's environment (run.sh, lib.sh app_env_args).
  late-approval  a command that needs his approval (`date +%s > /tmp/richos-late-approval.txt`);
                 NOTHING is pressed until the assignment is `blocked` -- the call has returned at
                 its deadline and the turn has ended -- then Approve is pressed once. PASS needs the
                 command's own output (its start, in whole guest seconds) within --late-bound
                 seconds of the press, and the assignment closed `settled`. The 2026-09-27
                 diagnosis measured (133.479, 137.542] s on the build before 76e977dc. Evidence:
                 late-approval-observed.json.
  relaunch       relaunch.py after a first run (bgdone2 item 3), observed: one relaunch, then every
                 5 s up to --relaunch-within seconds the recorded pid, every process of the app's
                 executable with its parent, the recorded pid's windows, and whether the composer is
                 back. PASS when it is. Evidence: relaunch-observed.json, relaunch-app.log, and on a
                 miss relaunch-tree.txt and relaunch.png.

Exit 0 when every step passes. Every app instance is quit by run-walk.py's stop.sh (CEO §54).
"""
import argparse
import importlib.util
import json
import os
import re
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
command = adopt_walk.command

STEPS = ['identity', 'first-run', 'connect', 'watch', 'task', 'observe']
MORE_STEPS = ['background', 'deadline', 'late-approval', 'relaunch']
# The pane's words while an assignment waits on its command (work_host.rs COMMAND_STILL_RUNNING_DETAIL).
STILL_RUNNING = 'A command it started is still running.'
BACKGROUND_TASK = ('Please start this harmless test command in the background for me with your shell tool, in '
                   'my Acme folder, and tell me when it has finished and what it printed: sleep {seconds} && '
                   'git log --oneline')
LATE_FILE = '/tmp/richos-late-approval.txt'
LATE_TASK = ('Please run this harmless test command for me yourself with your shell tool, in my Acme folder, '
             'and tell me when it has finished: date +%s > ' + LATE_FILE)
# Worded as a job to be done, the way the escalation's walk and the 2026-09-27 diagnosis worded
# theirs (both registered as a `task`). "Tell me exactly what it prints" alone was registered
# as a `check` on the first proof run (the question path, which already reported answers) and
# did not exercise the task path this walk exists for.
TASK = ('Please run this harmless test command for me yourself with your shell tool, in my Acme '
        'folder, and tell me when it has finished and what it printed: git log --oneline')
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
                  '                        "background":bool(c.get("tool_input",{}).get("run_in_background")),\n'
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


    def ours(self, sent):
        thread = self.facts.get('thread')
        rows = [r for r in self.records() if r.get('thread_id') == thread and r.get('registered_at_ms', 0) >= sent[0]]
        return max(rows, key=lambda r: r.get('registered_at_ms', 0)) if rows else None

    def send(self, text):
        before = self.clock()
        self.type_into(text, '--role', 'AXTextArea', '--title', 'Message to Rich')
        self.press('Send')
        return [before, self.clock()]

    def head(self):
        head = guest(self.vm, 'git -C ' + shlex.quote(self.company) + ' log -1 --format=%h%x09%s').split('\t')
        return head[0].strip(), head[1].strip()

    def background(self):
        if not self.facts.get('thread'):
            raise StepFailed('first-run must have run (no thread on record)')
        short, subject = self.head()
        sent = self.send(BACKGROUND_TASK.format(seconds=self.a.command_seconds))
        end = time.monotonic() + self.a.within + self.a.command_seconds
        pressed, record, waiting = 0, None, None
        while time.monotonic() < end:
            record = self.ours(sent)
            if record and record.get('state') not in OPEN:
                break
            if (waiting is None and record and record.get('state') == 'running'
                    and record.get('detail') == STILL_RUNNING and record.get('notices')):
                waiting = {'guest_ms': round(self.clock()), 'notices': record['notices']}
            if record and pressed < self.a.approvals and self.approve_if_asked(record.get('title', '')):
                pressed += 1
            time.sleep(2)
        commands = self.evidence_commands()
        evidence = {'sent_between_guest_ms': [round(v) for v in sent], 'command_seconds': self.a.command_seconds,
                    'repository_head': {'short': short, 'subject': subject}, 'approvals_pressed': pressed,
                    'seen_waiting_on_its_command': waiting, 'assignment': record, 'back_end_bash': commands}
        (self.out / 'background-observed.json').write_text(json.dumps(evidence, indent=2) + '\n')
        if not record:
            raise StepFailed('no assignment was registered after the task was sent')
        failures = background_verdict(record, short, subject, commands, sent, self.a.command_seconds, waiting)
        if failures:
            raise StepFailed('; '.join(failures))
        notices = record['notices']
        return {'state': record['state'], 'first_words': notices[0]['text'], 'report': notices[-1]['text'],
                'report_after_send_s': round((notices[-1]['raised_at_ms'] - sent[0]) / 1000, 3),
                'waiting_seen_at_guest_ms': waiting['guest_ms'], 'approvals_pressed': pressed}

    def deadline(self):
        # Read off the running app's own environment rather than trusted from the command
        # line: the walk is only a late-approval proof if the app under test has the knob.
        # (A relaunch with it was tried first, on 2026-09-27; the composer never came back
        # within 90 s, undiagnosed, so the knob is set at the first launch instead.)
        state = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm'))) / 'run' / self.vm
        pid = (state / 'app.pid').read_text().strip()
        if not pid.isdigit():
            raise StepFailed('the recorded app pid is not a number')
        environment = guest(self.vm, 'ps -E -ww -p ' + pid + ' -o command=')
        want = f'RICHOS_PERMISSION_DEADLINE_MS={self.a.deadline_ms}'
        if want not in environment.split():
            raise StepFailed(f'the app (pid {pid}) was not launched with {want}: run it with TESTVM_APP_ENV={want}')
        self.facts['deadline_ms'] = self.a.deadline_ms
        self.save()
        return {'app_pid': int(pid), 'deadline_ms': self.a.deadline_ms}

    def app_rows(self):
        """Every process in the guest running this payload's app executable: pid, parent, path."""
        rows = []
        for line in guest(self.vm, 'ps -axo pid=,ppid=,comm=').splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3 and self.payload in parts[2] and parts[2].endswith('/richos-tauri'):
                rows.append({'pid': int(parts[0]), 'ppid': int(parts[1]), 'exe': parts[2][len(self.payload):]})
        return rows

    def windows_of(self, pid):
        script = f'tell application "System Events" to count windows of (first process whose unix id is {pid})'
        text = guest(self.vm, 'osascript -e ' + shlex.quote(script) + ' 2>&1 || true')
        return int(text) if text.strip().isdigit() else text.strip()[:200]

    def relaunch(self):
        """relaunch.py after a first run, observed rather than assumed (bgdone2 item 3: in vm-run-2
        of 2026-09-27 the composer did not come back within 90 s, and that guest was deleted).

        One relaunch, then a sample every 5 s for up to --relaunch-within seconds of: the pid the
        harness recorded, every process of this payload's executable with its parent, the recorded
        pid's window count, whether the composer is on screen, and the relaunch log's tail. PASS
        when the composer is back. Either way the samples are relaunch-observed.json, and a miss
        adds relaunch-tree.txt and relaunch.png."""
        from relaunch import relaunch
        state = Path(os.environ.get('TESTVM_ROOT', str(Path.home() / '.richos-testvm'))) / 'run' / self.vm
        observed = {'before': {'recorded_pid': (state / 'app.pid').read_text().strip(), 'rows': self.app_rows()}}
        began = time.monotonic()
        launched = relaunch(self.vm)
        observed['relaunched'] = launched
        observed['samples'] = []
        back = None
        end = time.monotonic() + self.a.relaunch_within
        while time.monotonic() < end:
            pid = (state / 'app.pid').read_text().strip()
            sample = {'t': round(time.monotonic() - began, 1), 'recorded_pid': pid, 'rows': self.app_rows(),
                      'windows': self.windows_of(pid) if pid.isdigit() else None,
                      'composer': self.present('Message to Rich', role='AXTextArea')}
            observed['samples'].append(sample)
            (self.out / 'relaunch-observed.json').write_text(json.dumps(observed, indent=2) + '\n')
            if sample['composer']:
                back = sample['t']
                break
            time.sleep(5)
        log = guest(self.vm, 'tail -c 20000 ' + shlex.quote(launched['log']) + ' 2>/dev/null || true', 60)
        (self.out / 'relaunch-app.log').write_text(log + '\n')
        if back is None:
            try:
                (self.out / 'relaunch-tree.txt').write_text(
                    command([HERE / 'ax.sh', self.vm, 'tree', '--depth', '6'], 60))
            except StepFailed as exc:
                (self.out / 'relaunch-tree.txt').write_text('tree could not be read: ' + str(exc) + '\n')
            self.shot('relaunch.png')
            raise StepFailed(f'the composer was not back within {self.a.relaunch_within:.0f} s of the relaunch; '
                             'see relaunch-observed.json, relaunch-app.log, relaunch-tree.txt, relaunch.png')
        return {'composer_back_after_s': back, 'recorded_pid': observed['samples'][-1]['recorded_pid'],
                'windows': observed['samples'][-1]['windows'], 'log': launched['log']}

    def file_epoch(self):
        text = guest(self.vm, 'cat ' + shlex.quote(LATE_FILE) + ' 2>/dev/null || true').strip()
        return int(text) if text.isdigit() else None

    def late_approval(self):
        if not self.facts.get('deadline_ms'):
            raise StepFailed('the deadline step must have run: a late approval needs the call to end first')
        guest(self.vm, 'rm -f ' + shlex.quote(LATE_FILE))
        sent = self.send(LATE_TASK)
        record, blocked = None, None
        end = time.monotonic() + self.a.within
        while time.monotonic() < end:
            record = self.ours(sent)
            if self.file_epoch() is not None:
                raise StepFailed('the command ran before anything was approved: the late path was not exercised')
            if record and record.get('state') == 'blocked':
                blocked = {'guest_ms': round(self.clock()), 'detail': record.get('detail')}
                break
            if record and record.get('state') not in OPEN:
                break
            time.sleep(2)
        if not blocked:
            (self.out / 'late-approval-observed.json').write_text(json.dumps({'assignment': record}, indent=2) + '\n')
            raise StepFailed('the assignment never reached `blocked` (its call returned and its turn ended): '
                             + json.dumps(record and {k: record.get(k) for k in ('state', 'detail')}))
        press_before = self.clock()
        if not self.approve_if_asked(record.get('title', '')):
            raise StepFailed('the assignment was blocked and no Approve was offered for it')
        press_after = self.clock()
        pressed, epoch = 1, None
        end = time.monotonic() + self.a.within
        while time.monotonic() < end:
            epoch = epoch or self.file_epoch()
            record = self.ours(sent)
            if epoch is not None and record and record.get('state') not in OPEN:
                break
            if (record and record.get('state') == 'blocked' and pressed < self.a.approvals
                    and self.approve_if_asked(record.get('title', ''))):
                pressed += 1
            time.sleep(1)
        evidence = late_evidence(sent, blocked, press_before, press_after, epoch, pressed, record)
        (self.out / 'late-approval-observed.json').write_text(json.dumps(evidence, indent=2) + '\n')
        failures = late_verdict(evidence, self.a.late_bound)
        if failures:
            raise StepFailed('; '.join(failures))
        return {k: evidence[k] for k in ('blocked_after_send_s', 'started_after_press_s', 'approvals_pressed', 'final_state')}


def late_evidence(sent, blocked, press_before, press_after, epoch, pressed, record):
    """What the late-approval step saw, with the press-to-start bounds worked out.

    The press is known only between two guest-clock reads either side of the click, and the
    command's start only to the whole second `date +%s` wrote, so the delay lies in
    (epoch*1000 - press_after, (epoch+1)*1000 - press_before]."""
    started = None
    if epoch is not None:
        started = [round((epoch * 1000 - press_after) / 1000, 3), round(((epoch + 1) * 1000 - press_before) / 1000, 3)]
    return {'sent_between_guest_ms': [round(v) for v in sent], 'blocked': blocked,
            'blocked_after_send_s': round((blocked['guest_ms'] - sent[0]) / 1000, 3),
            'press_between_guest_ms': [round(press_before), round(press_after)], 'command_epoch_s': epoch,
            'started_after_press_s': started, 'approvals_pressed': pressed,
            'final_state': record and record.get('state'), 'final_detail': record and record.get('detail'),
            'assignment': record}


def late_verdict(evidence, bound):
    """Why this late approval did NOT reach its command promptly ([] = it did)."""
    failures = []
    started = evidence.get('started_after_press_s')
    if started is None:
        failures.append('the approved command never ran')
    elif started[1] > bound:
        failures.append(f'the approved command started up to {started[1]} s after the press (bound {bound} s)')
    if evidence.get('final_state') != 'settled':
        failures.append(f"the assignment ended {evidence.get('final_state')}: {evidence.get('final_detail')}")
    return failures


def background_verdict(record, short, subject, commands, sent, seconds, waiting):
    """Why this closed assignment does NOT show a background command's finish reported ([] = it does).

    Separate from the guest so the rules can be tested on records (test/command-walk.test.py)."""
    notices = record.get('notices') or []
    failures = []
    # `git -C "<folder>" log` is the same command (measured on the first proof run, 2026-09-27).
    if not any(c.get('background') and re.search(r'\bgit\b.*\blog\b', c.get('command', '')) for c in commands):
        failures.append('the back end did not run the command in the background, so this was not exercised: '
                        + json.dumps(commands))
    if record.get('kind') != 'task':
        failures.append(f"registered as a {record.get('kind')}, not a task")
    if record.get('state') != 'settled' or record.get('detail') != 'Answered.':
        failures.append(f"ended {record.get('state')}: {record.get('detail')}")
    if not waiting:
        failures.append('never seen waiting on its command with its first words already said')
    if len(notices) < 2:
        failures.append(f'{len(notices)} notice(s): the finish was not reported after the start')
    else:
        last = notices[-1]
        said = last.get('text', '')
        if not short or not subject or short not in said or subject not in said:
            failures.append(f"the last notice does not carry the command's result ({short} {subject}): {said!r}")
        if last.get('raised_at_ms', 0) < sent[0] + seconds * 1000:
            failures.append(f"the report was raised {(last.get('raised_at_ms', 0) - sent[0]) / 1000:.3f} s after the "
                            f'send, before a {seconds} s command could have ended')
    if any('No work was started' in n.get('text', '') for n in notices):
        failures.append('he was told "No work was started"')
    return failures


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
    p.add_argument('--command-seconds', type=int, default=45, help='how long the background command sleeps')
    p.add_argument('--deadline-ms', type=int, default=20000, help='the shortened permission deadline (1000-300000)')
    p.add_argument('--late-bound', type=float, default=30, help='seconds from the late Approve to the command')
    p.add_argument('--relaunch-within', type=float, default=120, help='seconds for the composer to come back')
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS + MORE_STEPS]
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
