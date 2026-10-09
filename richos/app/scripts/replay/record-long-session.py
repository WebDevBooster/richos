#!/usr/bin/env python3
"""Record one long, work-host-shaped `claude` session for the replay tests.

  record-long-session.py OUT.jsonl [--claude PATH] [--model MODEL] [--cwd DIR] [--seconds N]

Runs `claude` as the app's work lease runs it (the stream-json flags of `native.rs`
`child_args`) and talks to it the way the work host does (`work_host.rs` `run_one`), so the
capture replays against the real host message for message (`richos_core::replay`):

  A  a command started in the background; the turn ends while it runs (45 s);
  B  his next job on the same back end, while A's command still runs, told to leave A's
     finish out of its answer;
  A' the moment the provider's `task_notification` says A's command ended, OUTSIDE any turn
     of ours, the report request in the host's own words;
  C  a background command that ends INSIDE the same turn (a foreground `sleep 12` keeps the
     turn open), folded into that turn's answer;
  D  another background command (30 s); the turn ends while it runs;
  D' its report request, the moment its notification arrives outside any turn.

So the session holds the shape all six RichOS incidents of 2026-09/10 had (Sage, richos-hq
`docs/research/2026-10-08-t3-code-v2-video-ideas-for-richos.md`): a command that finishes after
the agent's turn has ended, twice, with a job in between and a folded finish beside them.

The `initialize` reply (which carries the account) is never written; a marker stands in for
it. Every other line is kept, `stream_event` deltas included. Before it goes into RichOS the
capture is scrubbed with `scrub-capture.py`.

Exit 0 with a one-line JSON summary when the session took that shape; 1 when it did not (a
finish folded where it should have come outside a turn, or the other way round): that capture
is not the one the tests need, and nothing should be done with it but record again.
"""
import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time
import uuid

# The host's own words (work_host.rs COMMAND_ENDED_HEAD / COMMAND_ENDED_TAIL and
# still_running_for_others), so the model answers what the host really asks.
ENDED_HEAD = ('What you started in the background for this assignment has ended — that is this app '
              'telling you, from the provider\'s own notice, not a guess:')
ENDED_TAIL = ('Its output is in the file named when it started. Give him your report on this assignment now, '
              'in plain words: what ran, how it ended, and what it printed that matters to him. If he asked '
              'what it printed, quote the printed lines themselves, as they are, then say what they mean; a '
              'description of them is not what he asked for. This is the report he will read, so make it '
              'complete, and leave out reviews, lands and closing the assignment: the app closes it from this '
              'report. Nothing about the assignment has changed and your seat is the same one.')

BACKGROUND = ('Use the Bash tool with run_in_background set to true to run exactly this command: {cmd}. Do not '
              'wait for it and do not check on it. End your turn right after starting it with one short sentence '
              'saying it has started.')
# job -> (his title for it, the command it backgrounds or None, what the back end is told)
JOBS = {
    'A': ('start the long marker', 'sleep 45; echo long-marker-a',
          BACKGROUND.format(cmd='sleep 45; echo long-marker-a')),
    'B': ('print the second marker', None,
          'Use the Bash tool to run exactly this command in the foreground: echo long-marker-b. Then tell me in '
          'one sentence what it printed.\n\nCommands you started in the background for his other requests are '
          'still running: "sleep 45; echo long-marker-a" (for "start the long marker"). If you are told one of '
          'them has ended while you work on this, leave it out of this report entirely: this app will ask you '
          'for that request\'s report on its own.'),
    'C': ('fold the short marker', 'sleep 4; echo long-marker-c',
          'Use the Bash tool with run_in_background set to true to run exactly this command: sleep 4; echo '
          'long-marker-c. Then, without waiting for it and without checking on it, use the Bash tool to run '
          'exactly this command in the foreground: sleep 12. Then tell me in one sentence what the background '
          'command printed.'),
    'D': ('start the last marker', 'sleep 30; echo long-marker-d',
          BACKGROUND.format(cmd='sleep 30; echo long-marker-d')),
}
# (kind, job): a job is sent when the previous step has ended; a report the moment its job's
# background command is reported ended.
STEPS = [('job', 'A'), ('job', 'B'), ('report', 'A'), ('job', 'C'), ('job', 'D'), ('report', 'D')]
# Where each background finish must land for this to be the capture the tests need.
WANT = {'A': 'outside', 'C': 'folded', 'D': 'outside'}
# The provider's `command_lifecycle` states that end a message's turn, spelled as it sends them.
TERMINAL = ('completed', 'cancelled', 'discarded', 'refused')  # dialect-exempt: the vendor's own wire values


def child_args(session, model):
    return ['--print', '--input-format=stream-json', '--output-format=stream-json', '--include-partial-messages',
            '--verbose', '--setting-sources', '', '--no-session-persistence', '--disallowed-tools',
            'AskUserQuestion', '--session-id', session, '--permission-prompt-tool', 'stdio', '--model', model]


def report_request(job):
    title, command, _ = JOBS[job]
    return ('This is about his earlier request "%s", which you are carrying on this same seat. %s "%s" '
            '(Background command completed (exit code 0)). %s' % (title, ENDED_HEAD, command, ENDED_TAIL))


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    p.add_argument('out')
    p.add_argument('--claude', default=os.path.expanduser('~/.local/bin/claude'))
    p.add_argument('--model', default='haiku')
    p.add_argument('--cwd', default=None, help='the working folder (default: a new empty one beside OUT)')
    p.add_argument('--seconds', type=float, default=600, help='the whole session is ended after this')
    a = p.parse_args(argv[1:])
    cwd = a.cwd or os.path.join(os.path.dirname(os.path.abspath(a.out)), 'session-cwd')
    os.makedirs(cwd, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if k not in ('ANTHROPIC_API_KEY', 'CLAUDECODE')}
    proc = subprocess.Popen([a.claude] + child_args(str(uuid.uuid4()), a.model), cwd=cwd, env=env,
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                            bufsize=1)
    began = time.time()
    out = open(a.out, 'w')
    lock = threading.Lock()
    frames = queue.Queue()

    def record(obj):
        with lock:
            out.write(json.dumps(obj) + '\n')
            out.flush()

    def send(obj, expect=None):
        row = {'t': round(time.time() - began, 3), 'sent': obj}
        if expect:
            row['expect'] = {'contains': expect}
        with lock:
            proc.stdin.write(json.dumps(obj) + '\n')
            proc.stdin.flush()
            out.write(json.dumps(row) + '\n')
            out.flush()

    def reader():
        for line in proc.stdout:
            try:
                f = json.loads(line)
            except ValueError:
                continue
            t = round(time.time() - began, 3)
            if f.get('type') == 'control_response' and f.get('response', {}).get('request_id') == 'init_1':
                record({'t': t, 'frame': {'type': 'control_response',
                                          'redacted': 'initialize reply not recorded (account details)'}})
            else:
                record({'t': t, 'frame': f})
            if f.get('type') == 'control_request' and f.get('request', {}).get('subtype') == 'can_use_tool':
                send({'type': 'control_response', 'response': {'subtype': 'success', 'request_id': f['request_id'],
                      'response': {'behavior': 'allow', 'updatedInput': f['request'].get('input', {})}}})
            frames.put(f)
        frames.put(None)

    threading.Thread(target=reader, daemon=True).start()
    threading.Thread(target=lambda: (time.sleep(a.seconds), proc.poll() is None and proc.kill()), daemon=True).start()

    state = {'running': None, 'job': None}
    ended = set()    # our messages whose turn has ended
    owner = {}       # background task id -> job
    finish = {}      # job -> 'outside' | 'folded'

    def pump(until, deadline):
        while not until():
            remaining = deadline - time.time()
            if remaining <= 0:
                return False
            try:
                f = frames.get(timeout=min(remaining, 1.0))
            except queue.Empty:
                continue
            if f is None:
                return False
            ty, sub = f.get('type'), f.get('subtype')
            if ty == 'command_lifecycle':
                if f.get('state') == 'started':
                    state['running'] = f.get('command_uuid')
                elif f.get('state') in TERMINAL:
                    ended.add(f.get('command_uuid'))
                    if state['running'] == f.get('command_uuid'):
                        state['running'] = None
            elif ty == 'system' and sub == 'task_started' and f.get('is_backgrounded') and state['job']:
                owner[f.get('task_id')] = state['job']
            elif ty == 'system' and sub == 'task_notification' and f.get('task_id') in owner:
                finish[owner[f['task_id']]] = 'folded' if state['running'] else 'outside'
        return True

    def user(text, expect=None):
        u = str(uuid.uuid4())
        send({'type': 'user', 'uuid': u, 'message': {'role': 'user', 'content': [{'type': 'text', 'text': text}]}},
             expect)
        return u

    send({'type': 'control_request', 'request_id': 'init_1', 'request': {'subtype': 'initialize', 'hooks': {}}})
    deadline = began + a.seconds
    ok = True
    for kind, job in STEPS:
        if kind == 'job':
            state['job'] = job
            u = user(JOBS[job][2])
        else:
            if not pump(lambda: job in finish, deadline):
                ok = False
                break
            state['job'] = None
            u = user(report_request(job), expect='has ended')
        if not pump(lambda: u in ended, deadline):
            ok = False
            break
    # Anything still on its way after the last turn.
    pump(lambda: False, min(deadline, time.time() + 3))
    try:
        proc.stdin.close()
    except OSError:
        pass
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    record({'t': round(time.time() - began, 3), 'exit': proc.returncode})
    out.close()
    shaped = ok and all(finish.get(job) == where for job, where in WANT.items())
    print(json.dumps({'shaped': shaped, 'steps_completed': ok, 'finishes': finish, 'want': WANT,
                      'seconds': round(time.time() - began, 1), 'exit': proc.returncode}))
    return 0 if shaped else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv))
