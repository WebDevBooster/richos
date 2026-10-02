#!/usr/bin/env python3
"""native-work.py admission order and core allowance, with stand-in budgets (no build, no
device, no wait).

P5-21: a standalone native build took the one compiler lane and THEN waited for a
machine worker, while proof workers hold a worker and THEN wait for the lane.
Two opposite orders over two resources is a circular wait. Every caller now takes
the worker first, the lane second, and releases in the reverse order.

CORES (2026-10-02): every native build ran on one core whatever the Mac had free. A build
now gets the cores free at admission below 60 percent total CPU, shared by the admitted
machine workers, never fewer than one (native-work.py's docstring has the rule).
"""
import importlib.util
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import cpu_guard  # noqa: E402
import worker_tokens  # noqa: E402

spec = importlib.util.spec_from_file_location('native_work', HERE / 'native-work.py')
N = importlib.util.module_from_spec(spec)
spec.loader.exec_module(N)


class Events:
    def __init__(self):
        self.log = []


class FakeBudget:
    events = None

    def __init__(self, directory, shared=None, runner=False, resource=None, **_):
        self.label = resource or 'worker'

    def acquire(self, free=None, **_):
        FakeBudget.events.log.append(('acquire', self.label))
        label = self.label

        class Token:
            def release(self):
                FakeBudget.events.log.append(('release', label))
        return Token()


class AdmissionOrder(unittest.TestCase):
    def run_build(self, command, env=None):
        FakeBudget.events = Events()
        with patch.object(sys, 'platform', 'linux'), \
                patch.dict(os.environ, env or {}, clear=False), \
                patch.object(cpu_guard, 'require_managed_ancestor'), \
                patch.object(cpu_guard, 'register'), \
                patch.object(worker_tokens, 'Budget', FakeBudget), \
                patch.object(worker_tokens, 'machine_directory', return_value='/nonexistent/machine-workers-v1'), \
                patch.object(worker_tokens, 'init'), \
                patch.object(worker_tokens, 'run_command', return_value=0):
            code = N.run(command)
        self.assertEqual(code, 0)
        return FakeBudget.events.log

    def test_the_worker_is_taken_before_the_compiler_lane_and_released_after_it(self):
        log = self.run_build(['swift', 'build'])
        self.assertEqual(log, [('acquire', 'worker'), ('acquire', 'native-build'),
                               ('release', 'native-build'), ('release', 'worker')])

    def test_a_prebuilt_ui_test_takes_a_worker_but_no_lane(self):
        log = self.run_build(['xcodebuild', 'test-without-building'])
        self.assertEqual(log, [('acquire', 'worker'), ('release', 'worker')])

    def test_a_failed_worker_admission_leaves_no_lane_held(self):
        FakeBudget.events = Events()

        class Refusing(FakeBudget):
            def acquire(self, free=None, **_):
                if self.label == 'worker':
                    raise TimeoutError('worker admission timed out')
                return super().acquire(free)
        with patch.object(sys, 'platform', 'linux'), \
                patch.object(cpu_guard, 'require_managed_ancestor'), \
                patch.object(worker_tokens, 'Budget', Refusing), \
                patch.object(worker_tokens, 'machine_directory', return_value='/nonexistent/machine-workers-v1'), \
                patch.object(worker_tokens, 'init'):
            with self.assertRaises(TimeoutError):
                N.run(['swift', 'build'])
        self.assertEqual(FakeBudget.events.log, [])        # the lane was never taken first


class CoreAllowance(unittest.TestCase):
    """The rule itself: cpus, total CPU percent busy at admission, admitted workers."""

    def test_one_build_alone_on_a_quiet_mac_gets_many_cores(self):
        self.assertEqual(N.allowance(10, 5.0, 1), 5)      # this Mac: 10 cores, 5 percent busy
        self.assertEqual(N.allowance(10, 0.0, 1), 6)
        self.assertEqual(N.allowance(16, 5.0, 1), 8)

    def test_four_at_once_share_the_free_cores(self):
        alone, each = N.allowance(16, 5.0, 1), N.allowance(16, 5.0, 4)
        self.assertEqual(each, 2)
        self.assertLessEqual(4 * each, alone)              # together never more than one alone
        self.assertEqual(N.allowance(10, 5.0, 4), 1)
        self.assertEqual(N.allowance(10, 5.0, 2), 2)

    def test_a_busy_mac_gets_one_core(self):
        for busy in (59.0, 60.0, 75.0, 79.9, 95.0):
            self.assertEqual(N.allowance(10, busy, 1), 1, busy)
        self.assertEqual(N.allowance(10, 40.0, 1), 2)

    def test_an_unmeasured_host_gets_one_core(self):
        self.assertEqual(N.allowance(10, None, 1), 1)

    def test_the_most_any_build_gets_leaves_the_ceo_headroom_below_the_admission_line(self):
        for cpus in (1, 4, 8, 10, 16, 24, 64):
            top = N.allowance(cpus, 0.0, 1)
            self.assertGreaterEqual(top, 1)
            if cpus >= 2:
                self.assertLessEqual(top, cpus * (N.DEFAULT_MAX_CPU - N.CEO_HEADROOM_PERCENT) / 100)
        self.assertEqual(N.DEFAULT_MAX_CPU - N.CEO_HEADROOM_PERCENT, 60)


class CoresReachTheBuild(unittest.TestCase):
    """run() measures, decides and hands the decision to every tool it caps."""

    def admitted(self, command, busy, held):
        FakeBudget.events = Events()
        seen = {}

        def fake_run(cmd, token, env):
            seen.update(command=cmd, env=env)
            return 0
        # A stub reserve module: the Darwin path imports it, and nothing here may sample.
        with patch.object(sys, 'platform', 'darwin'), \
                patch.dict(sys.modules, {'reserve': object()}), \
                patch.object(cpu_guard, 'require_managed_ancestor'), \
                patch.object(cpu_guard, 'healthy', return_value=True), \
                patch.object(cpu_guard, 'register'), \
                patch.object(worker_tokens, 'Budget', FakeBudget), \
                patch.object(worker_tokens, 'machine_directory', return_value='/nonexistent/machine-workers-v1'), \
                patch.object(worker_tokens, 'init'), \
                patch.object(worker_tokens, 'run_command', side_effect=fake_run), \
                patch.object(N, 'wait_for_headroom', return_value=busy), \
                patch.object(N, 'sharers', return_value=held), \
                patch.object(N.os, 'cpu_count', return_value=10):
            self.assertEqual(N.run(command), 0)
        return seen['command'], seen['env']

    def test_a_quiet_mac_gives_five_cores_to_debug_swift_and_xcode_two_to_cargo_one_to_a_jvm(self):
        swift, env = self.admitted(['swift', 'build'], 5.0, 1)
        self.assertEqual(swift[-2:], ['--jobs', '5'])      # debug: one frontend process per job
        self.assertEqual(env['SWIFTPM_MAX_CONCURRENT_OPERATIONS'], '5')
        self.assertEqual(env['CARGO_BUILD_JOBS'], '2')     # one rustc takes every job token
        self.assertTrue(env['JAVA_TOOL_OPTIONS'].endswith('-XX:ActiveProcessorCount=1'))
        xcode, _ = self.admitted(['xcodebuild', 'build'], 5.0, 1)
        self.assertEqual(xcode[xcode.index('-jobs') + 1], '5')
        self.assertEqual(xcode[xcode.index('-parallel-testing-enabled') + 1], 'NO')
        swift, _ = self.admitted(['swift', 'build', '-c', 'release'], 5.0, 1)
        self.assertEqual(swift[-2:], ['--jobs', '1'])      # release: one whole-module frontend
        xcode, _ = self.admitted(['xcodebuild', '-configuration', 'Release', 'build'], 5.0, 1)
        self.assertEqual(xcode[xcode.index('-jobs') + 1], '1')

    def test_a_jvm_keeps_one_processor_however_many_cores_are_free(self):
        # 2026-10-02: a Gradle JVM given 4 ran at 6.08 cores and the watchdog stopped it.
        gradle, env = self.admitted(['./gradlew', 'assembleRelease'], 0.0, 1)
        self.assertIn('--max-workers=1', gradle)
        self.assertIn('--no-parallel', gradle)
        self.assertIn('--no-daemon', gradle)              # the supervisor ends every daemon anyway
        self.assertIn('-Dorg.gradle.jvmargs=-Xmx1536m -XX:ActiveProcessorCount=1 -Dfile.encoding=UTF-8', gradle)
        self.assertTrue(env['JAVA_TOOL_OPTIONS'].endswith('-XX:ActiveProcessorCount=1'))

    def test_one_process_stays_under_the_watchdogs_per_process_line(self):
        self.assertLess(N.PROCESS_CORES, cpu_guard.JOB_CORES)
        self.assertEqual(N.JVM_CORES, 1)
        self.assertEqual([N.one_process(c) for c in (1, 2, 5, 6)], [1, 2, 2, 2])

    def test_four_workers_admitted_share_and_a_busy_mac_gives_one(self):
        swift, env = self.admitted(['swift', 'build'], 5.0, 4)
        self.assertEqual(swift[-2:], ['--jobs', '1'])
        self.assertEqual(env['CARGO_BUILD_JOBS'], '1')
        swift, env = self.admitted(['swift', 'build'], 75.0, 1)
        self.assertEqual(swift[-2:], ['--jobs', '1'])
        self.assertEqual(env['CARGO_BUILD_JOBS'], '1')

    def test_a_refused_override_is_refused_before_any_admission(self):
        with patch.object(sys, 'platform', 'darwin'), \
                patch.object(cpu_guard, 'require_managed_ancestor'), \
                patch.object(cpu_guard, 'healthy', return_value=True), \
                patch.object(worker_tokens, 'machine_directory') as machine:
            with self.assertRaises(ValueError):
                N.run(['./gradlew', '--max-workers=8', 'build'])
            machine.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=1)
