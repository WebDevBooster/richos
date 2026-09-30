#!/usr/bin/env python3
"""cpu_guard_live.py (the controller launchd runs) and cpu_guard_live_deploy.py."""
import hashlib
import json
import time
import os
from pathlib import Path
import plistlib
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import cpu_guard_live as L  # noqa: E402
import cpu_guard_live_deploy as D  # noqa: E402


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
            chosen, rates, protected = watch.sample(rows, now, host_busy=100)
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
            chosen, _, _ = watch.sample({10: self.row(), 30: self.row(10 if now == 0 else 1, now * 4.5)}, now,
                                        host_busy=100)
        self.assertEqual(chosen, [30])

    def test_a_job_over_the_core_limit_is_left_alone_while_the_host_has_room(self):
        # P5-22: four cores for a minute on a host that is 40 percent busy is healthy
        # work, not a runaway. The same job on a saturated host is still stopped.
        self.root(40, 'session')
        for busy, expected in ((40, []), (79.9, []), (100, [50])):
            watch = L.Watch()
            chosen = []
            for now in range(0, 62, 2):
                rows = {40: self.row(), 50: self.row(40, now * 4.0, name='rustc')}
                chosen, _, _ = watch.sample(rows, now, host_busy=busy)
            self.assertEqual(chosen, expected, busy)

    def test_a_brief_host_spike_does_not_stop_a_long_running_job(self):
        self.root(40, 'session')
        watch = L.Watch()
        chosen = []
        for now in range(0, 62, 2):
            rows = {40: self.row(), 50: self.row(40, now * 4.0, name='rustc')}
            chosen, _, _ = watch.sample(rows, now, host_busy=100 if now in (30, 32) else 30)
            self.assertEqual(chosen, [], now)

    def test_the_rule_is_the_same_in_both_controllers(self):
        import cpu_guard
        self.assertEqual((L.BUILD_ROLE, L.BUILD_WINDOW, L.WINDOW, L.JOB_CORES),
                         (cpu_guard.BUILD_ROLE, cpu_guard.BUILD_WINDOW, cpu_guard.WINDOW, cpu_guard.JOB_CORES))


class DeployTests(unittest.TestCase):
    """Replace the running controller only from a known one, prove the swap, undo a failure."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cpu-guard-deploy-')
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.state = root / 'state'
        runtime = self.state / 'runtime'
        runtime.mkdir(parents=True)
        self.legacy = b'# fixture legacy controller\nimport sys\nsys.exit(0)\n'
        (runtime / 'cpu_guard.py').write_bytes(self.legacy)
        shutil.copyfile(HERE / 'cpu_policy.py', runtime / 'cpu_policy.py')
        self.plist = root / 'agent.plist'
        self.plist.write_bytes(plistlib.dumps({'ProgramArguments': [
            '/usr/bin/python3', '-B', str(runtime / 'cpu_guard.py'), 'watch', '/engine']}))
        for name, value in (('LEGACY_SHA256', hashlib.sha256(self.legacy).hexdigest()),
                            ('POLICY_SHA256', D.sha256(runtime / 'cpu_policy.py'))):
            p = patch.object(D, name, value)
            p.start()
            self.addCleanup(p.stop)
        p = patch.object(D.Live, 'committed', return_value='f' * 40)
        p.start()
        self.addCleanup(p.stop)
        self.candidate = HERE / 'cpu_guard_live.py'
        self.restarts = []
        self.next_pid = 1000

    def heartbeat(self, controller):
        self.next_pid += 1
        beat = {'at': time.time(), 'ok': True, 'pid': self.next_pid}
        if controller:
            beat['controller'] = controller
        (self.state / 'heartbeat.json').write_text(json.dumps(beat))

    def live(self, behavior=None):
        def restart():
            self.restarts.append(D.sha256(self.state / 'runtime/cpu_guard.py'))
            (behavior or (lambda running: self.heartbeat(None if running == D.LEGACY_SHA256 else running)))(
                self.restarts[-1])
        return D.Live(self.state, self.plist, self.candidate, restart=restart, wait=0.5)

    def test_deploys_the_candidate_over_the_legacy_controller_and_records_it(self):
        message = self.live().deploy()
        candidate = D.sha256(self.candidate)
        self.assertEqual(D.sha256(self.state / 'runtime/cpu_guard.py'), candidate)
        self.assertEqual(self.restarts, [candidate])
        backup = self.state / 'runtime-backups' / ('cpu_guard-%s.py' % D.LEGACY_SHA256[:12])
        self.assertEqual(backup.read_bytes(), self.legacy)
        record = json.loads((self.state / 'live-runtime.json').read_text())
        self.assertEqual((record['sha256'], record['source_revision']), (candidate, 'f' * 40))
        self.assertIn('deployed', message)
        self.assertIn('already running', self.live().deploy())
        self.assertEqual(len(self.restarts), 1)

    def test_a_candidate_that_never_reports_is_taken_out_again(self):
        # The new controller never writes a heartbeat; the legacy one does after the put-back.
        live = self.live(lambda running: self.heartbeat(None) if running == D.LEGACY_SHA256 else None)
        with self.assertRaisesRegex(SystemExit, 'FAILED.*put back and is running'):
            live.deploy()
        self.assertEqual((self.state / 'runtime/cpu_guard.py').read_bytes(), self.legacy)
        self.assertFalse((self.state / 'live-runtime.json').exists())

    def test_an_unknown_running_controller_or_plist_is_refused_untouched(self):
        (self.state / 'runtime/cpu_guard.py').write_bytes(b'# somebody else\n')
        with self.assertRaisesRegex(SystemExit, 'neither the legacy controller'):
            self.live().deploy()
        self.assertEqual((self.state / 'runtime/cpu_guard.py').read_bytes(), b'# somebody else\n')
        (self.state / 'runtime/cpu_guard.py').write_bytes(self.legacy)
        self.plist.write_bytes(plistlib.dumps({'ProgramArguments': ['/usr/bin/python3', '-B', '/elsewhere.py', 'watch']}))
        with self.assertRaisesRegex(SystemExit, 'does not run'):
            self.live().deploy()
        self.assertEqual(self.restarts, [])

    def test_a_candidate_that_does_not_load_under_launchds_interpreter_is_refused_untouched(self):
        # launchd runs /usr/bin/python3 (3.9 on this Mac), not the shell's python3.
        self.plist.write_bytes(plistlib.dumps({'ProgramArguments': [
            '/usr/bin/false', '-B', str(self.state / 'runtime/cpu_guard.py'), 'watch', '/engine']}))
        with self.assertRaisesRegex(SystemExit, 'does not load under /usr/bin/false'):
            self.live().deploy()
        self.assertEqual((self.state / 'runtime/cpu_guard.py').read_bytes(), self.legacy)
        self.assertEqual(self.restarts, [])
        self.assertEqual(sorted(p.name for p in (self.state / 'runtime').iterdir()), ['cpu_guard.py', 'cpu_policy.py'])

    def test_rollback_restores_the_verified_legacy_bytes(self):
        self.live().deploy()
        self.assertIn('rolled back', self.live().rollback())
        self.assertEqual((self.state / 'runtime/cpu_guard.py').read_bytes(), self.legacy)
        self.assertEqual(self.restarts[-1], D.LEGACY_SHA256)
        self.assertIn('rolled_back_at', json.loads((self.state / 'live-runtime.json').read_text()))
        self.assertIn('already running', self.live().rollback())

    def test_status_names_what_runs_and_changes_nothing(self):
        status = self.live().status()
        self.assertEqual(status['running_is'], 'legacy controller (9154bf51)')
        self.assertEqual(self.restarts, [])


if __name__ == '__main__':
    unittest.main()
