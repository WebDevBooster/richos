"""Real-hook checks for JSON larger than Linux's per-argument/env limit.

Override RICHOS_LIFECYCLE_PAYLOAD_TEST_ROOT to exercise an older engine.
No hook is mocked and every persistent store is isolated below a temporary HOME.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ENGINE = Path(os.environ.get('RICHOS_LIFECYCLE_PAYLOAD_TEST_ROOT', Path(__file__).resolve().parents[2]))
BASH = shutil.which('bash')
SID = 'feedface-0000-4000-8000-000000000000'
PADDING = 'context\n' * 25000


class PayloadTransport(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='lifecycle-payload-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.entity = self.root / 'entity'
        self.entity.mkdir()
        (self.entity / 'orchestration.config').write_text('')
        (self.root / 'home').mkdir()
        self.team = self.root / 'teams' / ('session-' + SID[:8])
        self.team.mkdir(parents=True)
        self.env = {'PATH': os.environ['PATH'], 'HOME': str(self.root / 'home'),
                    'LANG': 'C', 'LC_ALL': 'C', 'TMPDIR': str(self.root),
                    'RICHOS_ENTITY_ROOT': str(self.entity), 'CLAUDE_PROJECT_DIR': str(self.entity),
                    'RICHOS_WORKTREE_LEDGER': str(self.root / 'ledger.jsonl'),
                    'RICHOS_WORKTREE_TX_DIR': str(self.root / 'tx'),
                    'WORKER_EVENTS_TEAMS_DIR': str(self.root / 'teams'),
                    'TEAMMATE_IDLE_TEAMS_DIR': str(self.root / 'teams'),
                    'TASK_COMPLETED_TEAMS_DIR': str(self.root / 'teams')}
        subprocess.run(['git', 'init', '-q', str(self.entity)], env=self.env, check=True)

    def run_hook(self, name, data):
        raw = data if isinstance(data, str) else json.dumps(data)
        result = subprocess.run([BASH, str(ENGINE / 'scripts/hooks' / name)], input=raw,
                                text=True, capture_output=True, env=self.env,
                                cwd=self.entity, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def payload(self, event, aid='agent-large', large=True, **extra):
        return {'hook_event_name': event, 'session_id': SID, 'agent_id': aid,
                'cwd': str(self.entity), 'context': PADDING if large else '', **extra}

    def test_large_start_records_platform_identity(self):
        self.run_hook('record-subagent-start.sh', self.payload('SubagentStart'))
        record = self.root / 'tx' / SID / 'starts/agent-large.json'
        self.assertTrue(record.exists(), 'large start fact disappeared')
        self.assertEqual(json.loads(record.read_text())['agent_id'], 'agent-large')

    def test_large_terminal_event_persists_pending_claim(self):
        self.run_hook('record-subagent-start.sh', self.payload('SubagentStart', large=False))
        self.run_hook('terminalize-agent-worktrees.sh', self.payload('SubagentStop'))
        claim = self.root / 'tx' / SID / 'pending-terminal/agent-large.json'
        self.assertTrue(claim.exists(), 'large terminal event disappeared')
        self.assertIn('SubagentStop', claim.read_text())

    def test_large_handoffs_preserve_both_ledger_and_team_event(self):
        for hook, event, logfile in (
                ('worker-ended-handoff.sh', 'SubagentStop', 'worker-events.jsonl'),
                ('teammate-idle-handoff.sh', 'TeammateIdle', 'idle-events.jsonl'),
                ('task-completed-handoff.sh', 'TaskCompleted', 'task-events.jsonl')):
            with self.subTest(hook=hook):
                self.run_hook(hook, self.payload(event, aid=event, task_id='task-large'))
                rows = [json.loads(line) for line in (self.root / 'ledger.jsonl').read_text().splitlines()]
                self.assertTrue(any(r.get('signal') == event and r.get('agent_id') == event for r in rows))
                record = json.loads((self.team / logfile).read_text().splitlines()[-1])
                self.assertEqual(record['event'], 'WorkerRunEnded' if event == 'SubagentStop' else event)
                self.assertEqual(record['session_id'], SID)

    def test_large_ruled_question_extraction_is_complete(self):
        data = {'tool_input': {'questions': [{'question': 'Should we delete the ACP adapter?'}]},
                'context': PADDING}
        result = subprocess.run([BASH, '-c', 'source "$1"; p="$(cat)"; cr_questions_of "$p"',
                                 '_', str(ENGINE / 'scripts/lib/ceo-ruled.sh')],
                                input=json.dumps(data), text=True, capture_output=True,
                                env=self.env, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '0\tShould we delete the ACP adapter?\n')

    def test_large_ask_notice_retains_attribution(self):
        (self.entity / '.ceo-todos').write_text('TODO_RECORD="wiki/open-items.md"\nTODO_VIEW="CEO-TODOs.md"\nROOT_README="README.md"\nCEO_SECTIONS="1 2"\nPREPARER_SECTION="3"\nARTIFACT_ROOTS="q=."\n')
        (self.entity / 'wiki').mkdir()
        (self.entity / 'wiki/open-items.md').write_text('# Open items\n\n## 1. Waiting on the CEO\n\n### 1.1 READY-FOR-CEO — Apple signing and developer enrollment\n\n- **Open:** `q/wiki/signing.md`\n- **Time:** 15 minutes\n- **Done:** a ruling recorded\n- **Unblocks:** microphone grants\n\n## 2. Waiting on the CEO\n\nNothing.\n\n## 3. Buildable now\n\nNothing.\n')
        (self.entity / 'wiki/signing.md').write_text('Signing worksheet')
        (self.entity / 'README.md').write_text('# Record')
        (self.entity / 'CEO-TODOs.md').write_text('# View')
        (self.entity / 'orchestration.config').write_text('CEO_TODOS_REPOS="."\n')
        data = self.payload('PostToolUse', tool_name='AskUserQuestion', tool_input={
            'questions': [{'question': 'Should we choose individual Apple signing and developer enrollment?'}]})
        self.run_hook('notice-ceo-asks.sh', data)
        ledger = self.entity / '.claude/state/ceo-asks.jsonl'
        self.assertTrue(ledger.exists(), 'large question was not witnessed')
        record = json.loads(ledger.read_text().splitlines()[-1])
        self.assertEqual(record['session_id'], SID)
        self.assertEqual(record['agent_id'], 'agent-large')

    def test_large_prose_still_reports_existing_ruling(self):
        (self.entity / 'decisions.md').write_text('# Decisions\n\n## 16. Delete the ACP adapter (CEO, 2026-08-31)\n\n**His words:** "Delete it." The ACP adapter goes.\n')
        (self.entity / 'orchestration.config').write_text('CEO_RULINGS_PATHS="decisions.md"\n')
        data = self.payload('Stop', last_assistant_message='Should we delete the ACP adapter?')
        output = self.run_hook('notice-ceo-ruled-prose.sh', data)
        self.assertIn('YOU ASKED HIM SOMETHING THE RECORD ALREADY RULES', output)

    def test_malformed_lifecycle_payloads_keep_nonblocking_contract(self):
        for hook in ('record-subagent-start.sh', 'terminalize-agent-worktrees.sh',
                     'worker-ended-handoff.sh', 'teammate-idle-handoff.sh', 'task-completed-handoff.sh'):
            with self.subTest(hook=hook):
                self.run_hook(hook, '{"broken":')
        self.assertFalse((self.root / 'ledger.jsonl').exists())
        self.assertFalse(any(self.team.iterdir()))


if __name__ == '__main__':
    unittest.main()
