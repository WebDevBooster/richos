#!/usr/bin/env python3
"""fake-claude-fill-first.pl keeps a lease's evidence and holds only the user's own turn.

No guest: the fake runs here with RICHOS_FILL_FIRST_DIR pointing into a temporary folder.
Three things the 2026-10-05 round-16 walk needed and did not have:
  1. a lease (--session-id) writes its own evidence journal at start, as Claude Code's
     SessionStart hook does, so the app can read it and a turn end is not refused;
  2. an "[INTERNAL ..." turn (the handoff summary, the re-prime of a new lease) answers at
     once even while the slow file exists, because the app installs a lease only after its
     priming answers;
  3. with the agents file present, the first user turn journals one background agent per
     line, in the rows app_workers.rs reads, and answers with reply.txt.
The journal is checked the way app_workers.rs status() reads it: schema 1, this session's
id on every row, three SubagentStart rows each with an async_launched PostToolUse."""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

FAKE = Path(__file__).resolve().parents[1] / 'fake-claude-fill-first.pl'
SESSION = 'walk-session-1'
failed = 0


def check(ok, what, detail=''):
    global failed
    print(('  ok    ' if ok else '  FAIL  ') + what + ('' if ok else f'  {detail}'))
    failed += 0 if ok else 1


def user(text):
    return json.dumps({'type': 'user', 'message': {'role': 'user', 'content': [{'type': 'text', 'text': text}]}}) + '\n'


ONBOARDING = {'mcp__richos_onboarding__save_company_notes', 'mcp__richos_onboarding__decline_onboarding'}
inits = []


def answers(proc):
    """The text of the next assistant row the fake prints; the init frames before it are kept."""
    while True:
        line = proc.stdout.readline()
        if not line:
            return None
        row = json.loads(line)
        if row.get('type') == 'system' and row.get('subtype') == 'init':
            inits.append(row)
        if row.get('type') == 'assistant':
            return row['message']['content'][0]['text']


with tempfile.TemporaryDirectory() as root:
    root = Path(root)
    walk = root / 'fill-first'
    walk.mkdir()
    data = root / 'com.richos.app'
    profile = data / 'engine-profiles' / 'profile-1'
    profile.mkdir(parents=True)
    env = {**os.environ, 'RICHOS_FILL_FIRST_DIR': str(walk)}
    args = ['perl', str(FAKE), '--print', '--session-id', SESSION, '--plugin-dir', str(profile),
            '--plugin-dir', str(data / 'rich-skills')]
    proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
    journal = data / 'engine-state' / 'evidence' / SESSION / 'callbacks.jsonl'

    # 2: an internal turn is never held: its answer arrives while the slow file still exists
    # (a held turn would not answer until the file is gone, which only this test removes).
    (walk / 'slow').touch()
    proc.stdin.write(user('[INTERNAL RE-PRIME — do not mention this message; respond only "ready"]\n\nbody'))
    proc.stdin.flush()
    check(answers(proc) == 'ready' and (walk / 'slow').exists(), 'an internal turn answers "ready" while the slow file exists')
    check(journal.exists() and (journal.parent / '.lock').exists(), 'the lease wrote its evidence journal and lock at start')

    # 3: the user's turn journals the agents, is held while slow exists, and answers reply.txt.
    (walk / 'agents').write_text('Mark\nAndy\nTom\n')
    (walk / 'reply.txt').write_text('On it. I have three people on it.\n')
    proc.stdin.write(user('Keep going on the outbox and the pairing screens.'))
    proc.stdin.flush()
    while 'walk-agent-3' not in journal.read_text():  # waits for the fact; a hang is the runner's to catch
        time.sleep(0.05)
    rows = [json.loads(line) for line in journal.read_text().splitlines()]
    check(all(r.get('schema') == 1 and r['callback'].get('session_id') == SESSION for r in rows),
          'every row is schema 1 with this session id', rows)
    starts = {r['callback']['agent_id']: r['callback'].get('agent_type') for r in rows
              if r['callback'].get('hook_event_name') == 'SubagentStart'}
    launched = {r['callback']['tool_response']['agentId'] for r in rows
                if r['callback'].get('hook_event_name') == 'PostToolUse' and r['callback'].get('tool_name') == 'Agent'
                and r['callback']['tool_response'].get('status') == 'async_launched'}
    check(sorted(starts.values()) == ['Andy', 'Mark', 'Tom'], 'three agents started, one per line', starts)
    check(set(starts) == launched, 'each started agent was launched in the background', (starts, launched))
    (walk / 'slow').unlink()
    check(answers(proc) == 'On it. I have three people on it.', 'the user turn answers with reply.txt')
    # 4: every turn reports Claude Code's inventory first, or the app refuses a company turn
    # (native.rs ensure_onboarding_tools_loaded reads both exact tool names from system/init).
    check(len(inits) == 2 and all(ONBOARDING <= set(i.get('tools', [])) and i.get('permissionMode') == 'auto' for i in inits),
          'each turn reports the onboarding tools in a system/init frame before it answers', inits)

    # A second user turn adds no second set of agents.
    proc.stdin.write(user('How are they doing?'))
    proc.stdin.flush()
    answers(proc)
    again = [json.loads(line) for line in journal.read_text().splitlines()]
    check(sum(r['callback'].get('hook_event_name') == 'SubagentStart' for r in again) == 3, 'the agents are journaled once per lease')
    proc.stdin.close()
    proc.wait()

    # A process that is not a lease (no --session-id, as the quota probe) writes no evidence.
    probe = subprocess.run(['perl', str(FAKE), '--print'], input='', text=True, env=env, capture_output=True)
    check(probe.returncode == 0 and sorted(p.name for p in (data / 'engine-state' / 'evidence').iterdir()) == [SESSION],
          'a process without --session-id writes no evidence')

print('fake-claude-fill-first:', 'FAILED' if failed else 'all passed')
sys.exit(1 if failed else 0)
