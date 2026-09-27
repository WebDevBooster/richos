#!/usr/bin/env python3
"""reap-walk.py's grade, offline. The live walk is its own proof; these hold the grade to its rules.

The rows are the shape reap-guest.py's watcher writes: {"kind": "seen", name, pid, pgid, start,
t_ms} when a heartbeat has recorded itself, {"kind": "gone", name, pid, pgid, t_ms} when it ends.
"""
import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('reap_walk', HERE / 'reap-walk.py')
walk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(walk)

T = 1_790_501_425_212


def seen(name, pid, pgid, at):
    return {'kind': 'seen', 'name': name, 'pid': pid, 'pgid': pgid, 'start': 'Sun', 't_ms': at}


def gone(name, pid, at):
    return {'kind': 'gone', 'name': name, 'pid': pid, 'pgid': pid, 't_ms': at}


BOTH = [seen('stop-bg', 700, 690, T - 9000), seen('stop-fg', 710, 705, T - 8000)]


class Grade(unittest.TestCase):
    def test_both_ended_inside_the_bound_passes_with_the_latency(self):
        evidence, failure = walk.grade_ended(BOTH + [gone('stop-bg', 700, T + 80), gone('stop-fg', 710, T + 95)],
                                             ['stop-fg', 'stop-bg'], T, 2000, {'stop-fg': [], 'stop-bg': []})
        self.assertIsNone(failure)
        self.assertEqual(evidence['commands']['stop-bg']['ended_after_ms'], 80)

    def test_a_case_whose_pids_were_not_recorded_is_refused_never_passed(self):
        evidence, failure = walk.grade_ended(BOTH[:1] + [gone('stop-bg', 700, T + 80)], ['stop-fg', 'stop-bg'], T, 2000)
        self.assertTrue(failure.startswith('REFUSED'), failure)
        self.assertIn('stop-fg', failure)

    def test_a_command_that_ended_before_the_trigger_proves_nothing_and_is_refused(self):
        _, failure = walk.grade_ended(BOTH + [gone('stop-bg', 700, T - 5), gone('stop-fg', 710, T + 50)],
                                      ['stop-fg', 'stop-bg'], T, 2000)
        self.assertTrue(failure.startswith('REFUSED'), failure)

    def test_late_still_running_or_leaving_its_group_behind_fails(self):
        _, late = walk.grade_ended(BOTH + [gone('stop-bg', 700, T + 2500), gone('stop-fg', 710, T + 90)],
                                   ['stop-fg', 'stop-bg'], T, 2000)
        self.assertIn('past the 2000 ms bound', late)
        _, running = walk.grade_ended(BOTH + [gone('stop-fg', 710, T + 90)], ['stop-fg', 'stop-bg'], T, 2000)
        self.assertIn('still running', running)
        _, left = walk.grade_ended(BOTH + [gone('stop-bg', 700, T + 80), gone('stop-fg', 710, T + 95)],
                                   ['stop-fg', 'stop-bg'], T, 2000, {'stop-fg': ['711'], 'stop-bg': []})
        self.assertIn('survived', left)

    def test_a_recycled_pid_is_not_the_recorded_command(self):
        # A `gone` row for the same name but another pid is a different process.
        _, failure = walk.grade_ended(BOTH + [gone('stop-bg', 999, T + 80), gone('stop-fg', 710, T + 95)],
                                      ['stop-fg', 'stop-bg'], T, 2000)
        self.assertIn('still running', failure)

    def test_a_command_that_finishes_by_itself_is_never_cut_short(self):
        rows = [seen('normal-fg', 800, 800, T)]
        self.assertIsNone(walk.grade_normal(rows + [gone('normal-fg', 800, T + 8050)], 'normal-fg', T + 8000)[1])
        self.assertIn('never finished', walk.grade_normal(rows + [gone('normal-fg', 800, T + 3000)], 'normal-fg', None)[1])
        self.assertTrue(walk.grade_normal([], 'normal-fg', T)[1].startswith('REFUSED'))

    def test_ps_time_is_read_past_an_hour(self):
        self.assertAlmostEqual(walk.cpu_seconds('0:01.46'), 1.46)
        self.assertAlmostEqual(walk.cpu_seconds(' 1:02:03.50\n'), 3723.5)


if __name__ == '__main__':
    unittest.main()
