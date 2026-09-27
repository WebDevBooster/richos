#!/usr/bin/env python3
"""command-walk.py's verdict, offline. The live walk is its own proof.

The failing record is the one the test VM wrote on 2026-09-27 (bundle 1.2.0-dev.39da4129,
esc-20260927T093052Z-85f3303f): the back end ran the command he asked for, said so, and the
assignment ended `failed` with "No work was started, so nothing was landed." 3.5 s later.
"""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('command_walk', HERE / 'command-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)

SHORT, SUBJECT = 'a1b2c3d', 'init'
RAN = [{'command': 'git -C "/Users/admin/testvm/walk-x/home/Acme" log --oneline', 'stdout': f'{SHORT} {SUBJECT}'}]


def record(**over):
    value = {'kind': 'task', 'state': 'settled', 'detail': 'Answered.',
             'notices': [{'kind': 'answer', 'text': f'It printed one line: {SHORT} {SUBJECT}.'}]}
    value.update(over)
    return value


class Verdict(unittest.TestCase):
    def test_the_result_reported_on_a_settled_task_passes(self):
        self.assertEqual(walk.verdict(record(), SHORT, SUBJECT, RAN), [])

    def test_the_2026_09_27_record_fails_on_every_count_it_should(self):
        broken = record(state='failed', detail='No work was started, so nothing was landed.', notices=[
            {'kind': 'failed', 'text': 'Run the test command ... It stopped before it finished. '
                                       'No work was started, so nothing was landed.'}])
        failures = walk.verdict(broken, SHORT, SUBJECT, RAN)
        self.assertTrue(any(f.startswith('ended failed') for f in failures), failures)
        self.assertTrue(any('No work was started' in f for f in failures), failures)
        self.assertTrue(any("does not carry the command's result" in f for f in failures), failures)

    def test_a_question_does_not_count_as_the_task_path(self):
        self.assertTrue(any('not a task' in f for f in walk.verdict(record(kind='check'), SHORT, SUBJECT, RAN)))

    def test_a_notice_without_the_head_fails(self):
        said = record(notices=[{'kind': 'answer', 'text': 'I ran it and it worked.'}])
        self.assertTrue(walk.verdict(said, SHORT, SUBJECT, RAN))

    def test_a_report_with_no_command_behind_it_fails(self):
        # The words alone are not evidence: the back end's own hook record has to show git ran.
        self.assertTrue(any('PostToolUse' in f for f in walk.verdict(record(), SHORT, SUBJECT, [])))

    def test_an_unreadable_head_never_passes(self):
        self.assertTrue(walk.verdict(record(), '', '', RAN))


if __name__ == '__main__':
    unittest.main()
