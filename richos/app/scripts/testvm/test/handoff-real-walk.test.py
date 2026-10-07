#!/usr/bin/env python3
"""handoff-real-walk.py's verdict (the plan's pass list), offline, on rows shaped like handoff-watch.py's.
The live walk is its own proof; this pins the rules that read its evidence."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('handoff_real_walk', HERE / 'handoff-real-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)

T0 = 1_791_370_000_000
BASE, W1, W2, HANDOFF, S1, MERGED = 'b' * 40, '1' * 40, '2' * 40, 'h' * 40, '3' * 40, 'm' * 40


def quota(t, home, leaving, point=78):
    return {'kind': 'quota', 't_ms': t, 'value': {'accounts': [{'id': '1', 'weekly': home}, {'id': '2', 'weekly': 20}],
                                                    'leaving': leaving, 'actAt': {'seven_day': point}}}


def evidence(out, *, handoff_last=True, deleted=0, successor_on='work', stop_after_ms=150_000, presses=()):
    log = [[W2, '0', 'Summaries 11-20'], [W1, '0', 'Summaries 1-10'], [BASE, '0', 'Acme: the lib folder']]
    if handoff_last:
        log.insert(0, [HANDOFF, '0', 'RichOS handoff: 20 of 30 done; next lib/x.py'])
    rows = [
        quota(T0, 77, []),
        {'kind': 'receipt', 't_ms': T0 + 1, 'value': {'id': 'r1', 'name': 'scribe-opus-aaa', 'status': 'run-ended',
                                                     'agent_id': 'ag1', 'request': {'role': 'worker'}}},
        {'kind': 'hook', 't_ms': T0 + 2, 'event': 'SubagentStart', 'agent_id': 'ag1'},
        {'kind': 'git', 't_ms': T0 + 3, 'path': '/x/target-worktrees/s/scribe-opus-aaa', 'value': {'log': log}},
        quota(T0 + 100_000, 78, ['1']),
        {'kind': 'marker', 't_ms': T0 + 110_000, 'value': {'agent': 'ag1', 'at': T0 + 105_000, 'account': '1'}},
        {'kind': 'hook', 't_ms': T0 + 105_000 + stop_after_ms, 'event': 'SubagentStop', 'agent_id': 'ag1'},
        {'kind': 'receipt', 't_ms': T0 + 400_000, 'value': {'id': 'r2', 'name': 'scribe-opus-bbb', 'status': 'integrated',
                                                          'agent_id': 'ag2', 'continuation': {'commit': HANDOFF},
                                                          'request': {'role': 'worker', 'continue_of': 'r1'}}},
        {'kind': 'brief', 't_ms': T0 + 400_001, 'path': '/x/work-receipts/s/r2.brief',
         'text': 'continues...\n\nHandoff from the previous teammate:\nRichOS handoff: 20 of 30 done'},
        {'kind': 'receipt', 't_ms': T0 + 900_000, 'value': {'id': 'r3', 'name': 'checker-opus-ccc', 'status': 'run-ended',
                                                          'agent_id': 'ag3', 'request': {'role': 'reviewer', 'review_of': 'r2'}}},
    ]
    for label, agent in (('home', 'ag1'), (successor_on, 'ag2')):
        folder = Path(out) / 'transcripts' / label / 'projects' / 'p' / 's' / 'subagents'
        folder.mkdir(parents=True, exist_ok=True)
        (folder / ('agent-' + agent + '.jsonl')).write_text(json.dumps({'timestamp': '2026-10-07T12:00:00Z'}) + '\n')
    at_handoff = ''.join('## lib/f%d.py\nText.\n' % i for i in range(20))
    final = at_handoff + ''.join('## lib/f%d.py\nText.\n' % i for i in range(20, 30))
    return {'rows': rows, 'facts': {'cutoff': 78, 'base': BASE, 'files': 30, 'approvals': list(presses)},
            'summary': final, 'diffs': {HANDOFF: '20\t%d\tSUMMARY.md' % deleted, HANDOFF + ':summary': at_handoff},
            'record': {'state': 'settled', 'detail': 'Landed.'}, 'obligation': {'status': 'completed'}, 'out': str(out)}


class Verdict(unittest.TestCase):
    def outcomes(self, **kw):
        with tempfile.TemporaryDirectory() as out:
            v = walk.judge(evidence(out, **kw))
        return {l['line'][:1]: l['outcome'] for l in v['lines']}, v

    def test_a_clean_handoff_passes_every_line(self):
        got, v = self.outcomes()
        self.assertEqual(set(got.values()), {'PASS'}, json.dumps(v, indent=1))
        self.assertEqual(v['handoff_ms']['scribe-opus-aaa']['order_to_end_ms'], 150_000)

    def test_no_handoff_commit_last_fails_lines_2_and_3(self):
        got, _ = self.outcomes(handoff_last=False)
        self.assertEqual((got['2'], got['3']), ('FAIL', 'FAIL'))

    def test_a_successor_that_deletes_summaries_fails_line_4(self):
        self.assertEqual(self.outcomes(deleted=3)[0]['4'], 'FAIL')

    def test_a_successor_on_home_fails_line_3(self):
        self.assertEqual(self.outcomes(successor_on='home')[0]['3'], 'FAIL')

    def test_an_approve_press_fails_line_5(self):
        self.assertEqual(self.outcomes(presses=[{'guest_ms': 1}])[0]['5'], 'FAIL')

    def test_over_five_minutes_is_a_finding(self):
        got, _ = self.outcomes(stop_after_ms=301_000)
        self.assertEqual((got['6'], got['+']), ('PASS', 'FAIL'))


if __name__ == '__main__':
    unittest.main()
