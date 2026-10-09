#!/usr/bin/env python3
"""review-walk.py's verdict (slice 4's pass list), offline, on receipts shaped like app.py's.
The live walk is its own proof; this pins the rules that read its evidence."""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('review_walk', HERE / 'review-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)

BRIEF = walk.USER_WORDS_LABEL + '\n\n<<<USER-WORDS-ABCD1234\n' + walk.JOB + '\nUSER-WORDS-ABCD1234>>>\n\n# duty'


def worker(rid, continuation=None, integrated=False):
    r = {'id': rid * 12, 'name': 'builder-sonnet-' + rid, 'request': {'role': 'worker', 'teammate': 'builder'},
         'status': 'integrated' if integrated else 'run-ended', '_brief': '# duty\n\nthe brief'}
    if continuation:
        r['continuation'] = {'worker_id': continuation * 12}
    if integrated:
        r['integration'] = {'verified': True}
    return r


def reviewer(rid, of, verdict, brief=BRIEF):
    return {'id': rid * 12, 'name': 'frank-opus-' + rid, 'request': {'role': 'reviewer', 'teammate': 'frank'},
            'review_target': {'worker_id': of * 12}, '_brief': brief,
            'review_observation': {'valid': True, 'report': {'verdict': verdict}}}


def rows(**change):
    out = [worker('a'), reviewer('b', 'a', 'changes-requested'), worker('c', continuation='a', integrated=True),
           reviewer('d', 'c', 'passed')]
    for i, r in change.get('replace', {}).items():
        out[i] = r
    return out


class Verdict(unittest.TestCase):
    def outcomes(self, receipts, record=None, landed="'hello-world'"):
        v = walk.judge(receipts, record or {'state': 'settled'}, landed, [])
        return {l['line'][0]: l['outcome'] for l in v['lines']}

    def test_the_whole_loop_passes(self):
        self.assertEqual(set(self.outcomes(rows()).values()), {'PASS'})

    def test_a_reviewer_brief_without_the_users_words_fails_line_1(self):
        got = self.outcomes(rows(replace={1: reviewer('b', 'a', 'changes-requested', brief='# duty\n\n' + walk.JOB)}))
        self.assertEqual(got['1'], 'FAIL')

    def test_a_first_review_that_passed_the_planted_defect_fails_line_2(self):
        self.assertEqual(self.outcomes(rows(replace={1: reviewer('b', 'a', 'passed')}))['2'], 'FAIL')

    def test_a_coordinator_who_fixed_it_before_any_review_fails_line_2(self):
        """Run 4 (walk-c9eeb4b4e680): the coordinator ran the work itself, continued it before any
        review, and the one review passed. The loop under test never ran."""
        got = self.outcomes([worker('a'), worker('c', continuation='a', integrated=True), reviewer('d', 'c', 'passed')])
        self.assertEqual(got['2'], 'FAIL')

    def test_no_continuation_fails_lines_3_to_5(self):
        got = self.outcomes([worker('a'), reviewer('b', 'a', 'changes-requested')])
        self.assertEqual((got['3'], got['4'], got['5']), ('FAIL', 'FAIL', 'FAIL'))

    def test_a_recheck_that_still_asks_for_changes_fails_line_4(self):
        self.assertEqual(self.outcomes(rows(replace={3: reviewer('d', 'c', 'changes-requested')}))['4'], 'FAIL')

    def test_a_landing_without_the_fix_fails_line_5(self):
        self.assertEqual(self.outcomes(rows(), landed="'-hello-world-'")['5'], 'FAIL')
        self.assertEqual(self.outcomes(rows(replace={2: worker('c', continuation='a')}))['5'], 'FAIL')

    def test_an_assignment_left_open_fails_line_6(self):
        self.assertEqual(self.outcomes(rows(), record={'state': 'running'})['6'], 'FAIL')


if __name__ == '__main__':
    unittest.main()
