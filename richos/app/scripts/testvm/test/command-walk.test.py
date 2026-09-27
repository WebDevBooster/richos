#!/usr/bin/env python3
"""command-walk.py's verdict, offline. The live walk is its own proof.

The failing record is the one the test VM wrote on 2026-09-27 (bundle 1.2.0-dev.39da4129,
esc-20260927T093052Z-85f3303f): the back end ran the command he asked for, said so, and the
assignment ended `failed` with "No work was started, so nothing was landed." 3.6-4.1 s after the command started.
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



class RelaunchRows(unittest.TestCase):
    """The relaunch step's process listing: this payload's app executable only, with parents."""

    def test_only_this_payloads_app_executable_is_listed(self):
        payload = '/Users/admin/testvm/walk-x'
        table = ('  101     1 /Users/admin/testvm/walk-x/RichOS.app/Contents/MacOS/richos-tauri\n'
                 '  102   101 /Users/admin/testvm/walk-x/RichOS.app/Contents/MacOS/richos-tauri\n'
                 '  103     1 /Users/admin/testvm/walk-y/RichOS.app/Contents/MacOS/richos-tauri\n'
                 '  104     1 /Users/admin/testvm/walk-x/engine/runtime/python3\n')
        probe = walk.CommandWalk.__new__(walk.CommandWalk)
        probe.vm, probe.payload = 'vm', payload
        original = walk.guest
        walk.guest = lambda vm, cmd, *rest: table
        try:
            rows = probe.app_rows()
        finally:
            walk.guest = original
        self.assertEqual(rows, [{'pid': 101, 'ppid': 1, 'exe': '/RichOS.app/Contents/MacOS/richos-tauri'},
                                {'pid': 102, 'ppid': 101, 'exe': '/RichOS.app/Contents/MacOS/richos-tauri'}])

    def test_the_step_is_offered(self):
        self.assertIn('relaunch', walk.MORE_STEPS)

SENT = [1_000_000.0, 1_000_900.0]
BACKGROUND = [{'command': 'cd "/Users/admin/testvm/walk-x/home/Acme" && sleep 45 && git log --oneline',
               'background': True, 'stdout': ''}]
WAITING = {'guest_ms': 1_010_000, 'notices': [{'kind': 'answer', 'text': "I've started it."}]}


def finished(**over):
    value = {'kind': 'task', 'state': 'settled', 'detail': 'Answered.', 'notices': [
        {'kind': 'answer', 'text': "I've started it; I'll tell you when it finishes.", 'raised_at_ms': 1_008_000},
        {'kind': 'answer', 'text': f'It finished and printed {SHORT} {SUBJECT}.', 'raised_at_ms': 1_047_000}]}
    value.update(over)
    return value


class BackgroundVerdict(unittest.TestCase):
    def test_a_finish_reported_after_the_command_could_end_passes(self):
        self.assertEqual(walk.background_verdict(finished(), SHORT, SUBJECT, BACKGROUND, SENT, 45, WAITING), [])

    def test_the_2026_09_27_shape_fails_the_started_words_as_the_only_report(self):
        # The VM's record: one notice, "it has started", and the assignment closed on it.
        started_only = finished(notices=[{'kind': 'answer', 'text': "I've started your test command.",
                                          'raised_at_ms': 1_008_000}])
        failures = walk.background_verdict(started_only, SHORT, SUBJECT, BACKGROUND, SENT, 45, None)
        self.assertTrue(any('not reported after the start' in f for f in failures), failures)
        self.assertTrue(any('never seen waiting' in f for f in failures), failures)

    def test_a_report_raised_before_the_command_could_end_fails(self):
        early = finished()
        early['notices'][-1]['raised_at_ms'] = 1_030_000
        failures = walk.background_verdict(early, SHORT, SUBJECT, BACKGROUND, SENT, 45, WAITING)
        self.assertTrue(any('before a 45 s command could have ended' in f for f in failures), failures)

    def test_git_dash_c_log_is_the_same_command(self):
        # The first proof run's back end wrote it this way, and the walk refused its own pass.
        measured = [{'command': 'sleep 45 && git -C "/Users/admin/testvm/walk-9021a655830f/home/Acme" log --oneline',
                     'background': True, 'stdout': ''}]
        self.assertEqual(walk.background_verdict(finished(), SHORT, SUBJECT, measured, SENT, 45, WAITING), [])

    def test_a_command_run_in_the_foreground_is_not_this_path(self):
        foreground = [dict(BACKGROUND[0], background=False)]
        failures = walk.background_verdict(finished(), SHORT, SUBJECT, foreground, SENT, 45, WAITING)
        self.assertTrue(any('not run the command in the background' in f for f in failures), failures)

    def test_a_last_notice_without_the_head_fails(self):
        vague = finished()
        vague['notices'][-1]['text'] = 'It finished.'
        self.assertTrue(walk.background_verdict(vague, SHORT, SUBJECT, BACKGROUND, SENT, 45, WAITING))


class LateApproval(unittest.TestCase):
    BLOCKED = {'guest_ms': 1_030_000, 'detail': 'The work has run and stopped at a step that is yours to decide.'}

    def evidence(self, epoch, state='settled'):
        return walk.late_evidence(SENT, self.BLOCKED, 1_100_000.0, 1_101_000.0, epoch, 1, {'state': state, 'detail': ''})

    def test_the_press_to_start_bounds_are_the_clock_reads_and_the_whole_second(self):
        # The command wrote 1105 (seconds): it started in [1_105_000, 1_106_000) ms, the press
        # was between 1_100_000 and 1_101_000 ms, so the delay is in (4.0, 6.0] s.
        self.assertEqual(self.evidence(1105)['started_after_press_s'], [4.0, 6.0])
        self.assertEqual(walk.late_verdict(self.evidence(1105), 30), [])

    def test_the_diagnosis_measurement_fails(self):
        # (133.479, 137.542] s, the build before 76e977dc: the upper bound is over any sane bound.
        failures = walk.late_verdict(self.evidence(1100 + 136), 30)
        self.assertTrue(any('started up to' in f for f in failures), failures)

    def test_a_command_that_never_ran_or_a_job_that_failed_fails(self):
        self.assertTrue(any('never ran' in f for f in walk.late_verdict(self.evidence(None), 30)))
        self.assertTrue(any('ended failed' in f for f in walk.late_verdict(self.evidence(1105, 'failed'), 30)))


if __name__ == '__main__':
    unittest.main()
