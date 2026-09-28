#!/usr/bin/env python3
"""cpu_guard_live.py: the controller launchd runs."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import cpu_guard_live as L  # noqa: E402


class LiveRuleTests(unittest.TestCase):
    """The same per-process rule as cpu_guard.py, in the controller that actually runs."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cpu-guard-live-')
        self.addCleanup(self.tmp.cleanup)
        state = patch.object(L, 'STATE', Path(self.tmp.name))
        state.start()
        self.addCleanup(state.stop)
        env = patch.dict(os.environ, {'RICHOS_TEST_DEVICES_DIR': str(Path(self.tmp.name) / 'devices')})
        env.start()
        self.addCleanup(env.stop)

    def row(self, parent=0, cpu=0, birth='birth', name='test'):
        return dict(parent=parent, cpu=cpu, birth=birth, name=name)

    def root(self, pid, role):
        L.write_json(L.STATE / 'roots' / ('%s.json' % pid), dict(pid=pid, birth='birth', role=role, label='test'))

    def test_release_build_compiler_keeps_its_cores_but_a_runaway_is_still_stopped(self):
        # Run 20260928T190111Z-40a16163: rustc at 4.52 cores under the nightly's build
        # supervisor, stopped after 10 s by THIS controller (the one launchd runs).
        self.root(10, 'release-build')
        self.root(40, 'session')
        watch = L.Watch()
        stopped = {}
        for now in range(0, 604, 2):
            rows = {10: self.row(), 20: self.row(10), 30: self.row(20, now * 4.5, name='rustc'),
                    40: self.row(), 50: self.row(40, now * 4.5, name='rustc')}
            chosen, rates, protected = watch.sample(rows, now)
            for pid in chosen:
                stopped.setdefault(pid, now)
        self.assertEqual(stopped.get(50), 12)
        self.assertEqual(stopped.get(30), 602)
        self.assertIn(10, protected)
        with patch.object(L, 'processes', return_value=rows), patch.object(os, 'kill'):
            watch.stop(30, rows, protected, rates)
        self.assertEqual(L.read_json(L.STATE / 'alert.json')['sustained_seconds'], 600.0)

    def test_a_process_that_leaves_the_build_tree_is_judged_by_the_ordinary_window(self):
        self.root(10, 'release-build')
        watch = L.Watch()
        for now in range(0, 14, 2):
            chosen, _, _ = watch.sample({10: self.row(), 30: self.row(10 if now == 0 else 1, now * 4.5)}, now)
        self.assertEqual(chosen, [30])

    def test_the_rule_is_the_same_in_both_controllers(self):
        import cpu_guard
        self.assertEqual((L.BUILD_ROLE, L.BUILD_WINDOW, L.WINDOW, L.JOB_CORES),
                         (cpu_guard.BUILD_ROLE, cpu_guard.BUILD_WINDOW, cpu_guard.WINDOW, cpu_guard.JOB_CORES))


if __name__ == '__main__':
    unittest.main()
