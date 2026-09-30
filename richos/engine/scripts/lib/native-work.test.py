#!/usr/bin/env python3
"""native-work.py admission order, with stand-in budgets (no build, no device, no wait).

P5-21: a standalone native build took the one compiler lane and THEN waited for a
machine worker, while proof workers hold a worker and THEN wait for the lane.
Two opposite orders over two resources is a circular wait. Every caller now takes
the worker first, the lane second, and releases in the reverse order.
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


if __name__ == '__main__':
    unittest.main(verbosity=1)
