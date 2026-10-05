#!/usr/bin/env python3
"""worker-approve-walk.py — a back-end WORKER's command that needs approval is an Approve on its job's row.

Run by run-walk.py, which holds one guest slot for this run only, boots the guest and removes the clone:

  run-walk.py --bundle ZIP --home EMPTY_DIR --engine ENGINE --report REPORT -- \\
      worker-approve-walk.py --out DIR --expect-sha SHA [--within SECONDS]

run-walk.py passes the owned VM name as the first argument. `--steps a,b,c` runs a subset, still
as one run under run-walk.py.

THE QUESTION (esc-20261005T150541Z-ee581ad7). The back end launches its worker in the background
and its own turn ends at once, so the worker's commands arrive between the lease's turns. On app
93ce176f9 (walks walk-d20296d51c3d and walk-0c7e08bf738c) a worker's pandoc call was refused on
the spot, never reached the permission desk, and no Approve button appeared on its job's row; the
back-end lead's own pandoc, inside its turn, was approved there in S2's walk 3. This walk is the
real-app check of the fix (permissions.rs `grant`).

It is output-walk.py's `backend-worker` step (cc/echo-opus-out2b, not on main when this was
written) cut down to the one question: the same CommandWalk base, the same typed task shape with
pandoc kept, the same press of `Approve <assignment title>` (work-summary.js) and the same story
of the back-end session's tool calls.

WHAT IT DOES, in the guest, never on the host's screen (CEO ruling §65):
  identity        the running app says it was built from --expect-sha
  first-run       adopt-walk.py's: company "Acme" with a folder that is a Git repository
  connect         command-walk.py's: that folder connected as a repository
  tools           pandoc and typst (pandoc's PDF engine) installed in the guest with Homebrew
  worker-approve  typed: add notes.md to the Acme repository, make notes.pdf from it with
                  /opt/homebrew/bin/pandoc --pdf-engine=/opt/homebrew/bin/typst, commit both and land them. While the job is open, when
                  its row offers `Approve <title>`, a screenshot is taken and it is pressed (at most
                  --approvals times). PASS needs all of: at least one press; a WORKER's (agent_id)
                  Bash call running pandoc that has a PostToolUse (the command ran) after the first
                  press; and notes.pdf on disk in the worker's worktree or the Acme folder. Whether
                  the worker's pandoc was raised after the lead's turn had ended (the case the fix is
                  about) is read off the hook record's order and reported.

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

_spec = importlib.util.spec_from_file_location('command_walk', HERE / 'command-walk.py')
command_walk = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(command_walk)
StepFailed = command_walk.StepFailed
OPEN = command_walk.OPEN

STEPS = ['identity', 'first-run', 'connect', 'tools', 'worker-approve']
# output-walk.py's worker task at 93ce176f9, the wording proven to reach a back-end WORKER, and the
# exact command whose approval never reached Approve in walks 4 and 5. The first run of this walk
# (walk-4906754a47cf) used `pandoc notes.md -o notes.html` instead: the provider let that run without
# asking, so it never reached the desk and proved nothing about Approve. The PDF form with an
# explicit --pdf-engine is the one the provider asks about.
WORKER_TASK = ('Please add a file named notes.md whose whole content is the line "Notes for the walk test." '
               'to the Acme repository and commit it. Then, in the same folder, make notes.pdf from it '
               'with the shell command /opt/homebrew/bin/pandoc notes.md -o notes.pdf '
               '--pdf-engine=/opt/homebrew/bin/typst, commit notes.pdf too, and land both files.')
MADE = 'notes.pdf'


class WorkerApproveWalk(command_walk.CommandWalk):
    def lines(self, path, timeout=60):
        text = guest(self.vm, 'cat ' + shlex.quote(path) + ' 2>/dev/null || true', timeout)
        out = []
        for line in text.splitlines():
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
        return out

    def callbacks(self, session):
        return [row.get('callback', {}) for row in
                self.lines(self.data + '/engine-state/evidence/' + session + '/callbacks.jsonl', 120)]

    def tools(self):
        guest(self.vm, 'eval "$(/opt/homebrew/bin/brew shellenv)" && brew install pandoc typst >/tmp/worker-approve-brew.log 2>&1', 1200)
        version = guest(self.vm, '/opt/homebrew/bin/pandoc --version | head -1 && /opt/homebrew/bin/typst --version', 60).strip()
        self.facts['pandoc'] = version
        self.save()
        return {'pandoc': version}

    def story(self, sessions):
        """Every tool call of the back-end sessions, in hook order, and how each ended (output-walk.py's
        work_story). A PreToolUse with no PostToolUse is a call that was refused or never returned."""
        calls = []
        for session in sessions:
            for c in self.callbacks(session):
                event, tool = c.get('hook_event_name'), c.get('tool_name')
                if event in ('PreToolUse', 'PostToolUse', 'PostToolUseFailure') and tool:
                    ti = c.get('tool_input') or {}
                    out = c.get('tool_response', c.get('error'))
                    calls.append({'event': event, 'tool': tool, 'id': c.get('tool_use_id'), 'agent': c.get('agent_id'),
                                  'input': str(ti.get('command') or ti.get('file_path') or ti.get('name') or ti)[:300],
                                  'result': None if event == 'PreToolUse' else str(out)[:600]})
                elif event in ('SubagentStop', 'Stop'):
                    calls.append({'event': event, 'agent': c.get('agent_id'),
                                  'last': str(c.get('last_assistant_message', ''))[:600]})
        return calls

    def worker_approve(self):
        if not self.facts.get('thread'):
            raise StepFailed('first-run must have run (no thread on record)')
        sent = self.send(WORKER_TASK)
        end = time.monotonic() + self.a.within
        presses, record, ran = [], None, []
        while time.monotonic() < end:
            record = self.ours(sent)
            if record and record.get('state') not in OPEN:
                break
            sessions = [record['work_session']] if record and record.get('work_session') else []
            calls = self.story(sessions)
            ran = [c for c in calls if c['event'] == 'PostToolUse' and c['tool'] == 'Bash' and c.get('agent')
                   and 'pandoc' in c['input']]
            if ran and self.exists_made():
                break
            if record and len(presses) < self.a.approvals:
                pressed = self.approve_with_shot(record.get('title', ''), 'approve-%d.png' % (len(presses) + 1))
                if pressed:
                    presses.append(pressed | {'state': record.get('state')})
                    self.facts['approvals'] = presses
                    self.save()
            time.sleep(3)
        if record:
            record = self.by_id(record.get('id')) or record
        sessions = [record['work_session']] if record and record.get('work_session') else []
        calls = self.story(sessions)
        worker_pandoc_pre = [i for i, c in enumerate(calls) if c['event'] == 'PreToolUse' and c['tool'] == 'Bash'
                             and c.get('agent') and 'pandoc' in c['input']]
        lead_stops = [i for i, c in enumerate(calls) if c['event'] == 'Stop']
        ran = [c for c in calls if c['event'] == 'PostToolUse' and c['tool'] == 'Bash' and c.get('agent')
               and 'pandoc' in c['input']]
        made = self.where_made()
        evidence = {
            'sent_between_guest_ms': [round(v) for v in sent],
            'assignment': {k: (record or {}).get(k) for k in ('id', 'kind', 'state', 'title', 'detail', 'work_session',
                                                              'obligation_id')},
            'notices': ((record or {}).get('notices') or [])[-6:],
            'approvals_pressed': presses,
            'worker_pandoc_ran': ran,
            'worker_pandoc_raised_after_a_lead_turn_ended':
                bool(worker_pandoc_pre and lead_stops and lead_stops[0] < worker_pandoc_pre[0]),
            'made_on_disk': made,
        }
        (self.out / 'worker-approve-observed.json').write_text(json.dumps(evidence, indent=2) + '\n')
        (self.out / 'worker-approve-story.json').write_text(json.dumps({'calls': calls}, indent=2) + '\n')
        if not record:
            raise StepFailed('no assignment was registered after the task was sent')
        if not presses and ran:
            raise StepFailed("the worker's pandoc ran without asking for approval, so this run did not reach "
                             'the Approve path at all')
        if not presses:
            raise StepFailed('no Approve button appeared on the job row (job %s)' % (record or {}).get('state'))
        if not ran:
            raise StepFailed("the worker's pandoc command never ran (no PostToolUse for it)")
        if not made:
            raise StepFailed('%s is on disk in neither the worker worktree nor the Acme folder' % MADE)
        return {'approvals_pressed': len(presses), 'worker_pandoc_ran': len(ran), 'made_on_disk': made,
                'raised_after_a_lead_turn_ended': evidence['worker_pandoc_raised_after_a_lead_turn_ended'],
                'state': (record or {}).get('state')}

    def approve_with_shot(self, title, shot):
        """command-walk.py's approve_if_asked, with a screenshot of the row taken while it offers
        `Approve <title>`, before the press. None when the row offers no Approve."""
        label = 'Approve ' + title
        if not self.present(label):
            try:
                self.press('Open the work summary')
            except StepFailed:
                return None
            if not self.present(label):
                return None
        self.shot(shot)
        self.press(label)
        return {'guest_ms': round(self.clock()), 'label': label, 'screenshot': shot}

    def where_made(self):
        found = guest(self.vm, 'find ' + shlex.quote(self.company) + ' '
                      + shlex.quote(self.data + '/engine-state/target-worktrees')
                      + ' -name ' + shlex.quote(MADE) + ' -type f 2>/dev/null || true', 60)
        return [line for line in found.splitlines() if line.strip()]

    def exists_made(self):
        return bool(self.where_made())


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('vm')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--expect-sha', required=True, help='the commit the bundle under test was built from')
    p.add_argument('--within', type=float, default=900, help='seconds for the worker command to run')
    p.add_argument('--approvals', type=int, default=6, help='most Approve presses in the run')
    p.add_argument('--steps', default=','.join(STEPS))
    a = p.parse_args()
    a.task = WORKER_TASK
    steps = a.steps.split(',')
    unknown = [s for s in steps if s not in STEPS]
    if unknown:
        p.error('unknown step(s): ' + ', '.join(unknown))
    walk = WorkerApproveWalk(a)
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
    try:
        report['logs_kept'] = walk.keep_logs()
    except (StepFailed, RuntimeError, subprocess.TimeoutExpired, OSError) as exc:
        report['logs_kept'] = 'the guest logs could not be copied: ' + str(exc)
    (a.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
