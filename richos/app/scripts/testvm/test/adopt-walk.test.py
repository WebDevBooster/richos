#!/usr/bin/env python3
"""adopt-walk.py's verdict and hold-walk.py's hand-back, offline. The live walk is its own proof.

The rows below are the shape adopt-watch.py writes, with the timings of the 2026-09-26 walk
(bundle 1.2.0-dev.98c3aef5): the phone's words at +0, the task registered inside the turn at
+11 446 ms, the turn completed at +13 247, the assignment Preparing 8 ms later.
"""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

HERE = Path(__file__).resolve().parent.parent


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / file)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


walk = module('adopt_walk', 'adopt-walk.py')
T0 = 1_790_426_110_247
THREAD = 'thr_fixture'


def rows(*, typed=None, left_early=False, never_left=False, no_assignment=False):
    out = [
        {'kind': 'ledger', 'event': 'PromptReceived', 'turn': 'turn_phone', 'thread': THREAD, 'source': 'text',
         'intake_id': 1, 'at': T0, 't_ms': T0 + 35},
        {'kind': 'intake', 'record': 'channel', 'id': 1, 'thread': THREAD, 'channel': 'phone', 't_ms': T0 + 45},
        {'kind': 'ledger', 'event': 'PromptReceived', 'turn': 'turn_prime', 'thread': THREAD,
         'source': 'internal', 'intake_id': None, 'at': T0 + 59, 't_ms': T0 + 153},
        {'kind': 'ledger', 'event': 'TurnCompleted', 'turn': 'turn_phone', 'thread': None, 'source': None,
         'intake_id': None, 'at': T0 + 13_247, 't_ms': T0 + 13_307},
    ]
    if not no_assignment:
        out.append({'kind': 'assignment', 'id': 'a1', 'thread': THREAD, 'state': 'registered',
                    'registered_at_ms': T0 + 11_446, 'updated_at_ms': T0 + 11_446, 't_ms': T0 + 11_528,
                    'detail': 'Written down. Preparation has not started.'})
        if not never_left:
            left = T0 + (12_000 if left_early else 13_255)
            out.append({'kind': 'assignment', 'id': 'a1', 'thread': THREAD, 'state': 'preparing',
                        'registered_at_ms': T0 + 11_446, 'updated_at_ms': left, 't_ms': left + 51,
                        'detail': 'Opening the work connection.'})
    if typed == 'desk':
        out += [
            {'kind': 'ledger', 'event': 'PromptReceived', 'turn': 'turn_typed', 'thread': THREAD, 'source': 'text',
             'intake_id': 2, 'at': T0 + 12_000, 't_ms': T0 + 12_010},
            {'kind': 'intake', 'record': 'desk', 'id': 2, 'thread': THREAD, 'channel': None, 't_ms': T0 + 12_011},
        ]
    if typed == 'direct':
        out.append({'kind': 'ledger', 'event': 'PromptReceived', 'turn': 'turn_typed', 'thread': THREAD,
                    'source': 'text', 'intake_id': None, 'at': T0 + 12_000, 't_ms': T0 + 12_010})
    return sorted(out, key=lambda r: r['t_ms'])


SENT = [T0 - 11_800, T0 + 15]


class Verdict(unittest.TestCase):
    def test_the_walk_as_measured_passes_and_says_how_long_after_the_turn_it_started(self):
        evidence, failure = walk.analyze(rows(), THREAD, SENT)
        self.assertIsNone(failure)
        self.assertEqual(evidence['left_registered_ms_after_turn_end'], 8)
        self.assertEqual([p['road'] for p in evidence['prompts']], ['phone'])

    def test_a_typed_message_through_the_intake_log_fails_it(self):
        _, failure = walk.analyze(rows(typed='desk'), THREAD, SENT)
        self.assertIn('did not come from the phone', failure)
        self.assertIn('through the intake log', failure)

    def test_a_typed_message_straight_to_the_spine_fails_it(self):
        _, failure = walk.analyze(rows(typed='direct'), THREAD, SENT)
        self.assertIn('straight to the spine', failure)

    def test_work_that_never_left_registered_fails_it(self):
        _, failure = walk.analyze(rows(never_left=True), THREAD, SENT)
        self.assertIn('never left Registered', failure)

    def test_work_that_left_registered_inside_the_turn_fails_it(self):
        _, failure = walk.analyze(rows(left_early=True), THREAD, SENT)
        self.assertIn('before its turn ended', failure)

    def test_no_assignment_at_all_fails_it(self):
        _, failure = walk.analyze(rows(no_assignment=True), THREAD, SENT)
        self.assertIn('no assignment was registered', failure)

    def test_another_conversation_is_not_read_as_this_one(self):
        other = [dict(r, thread='thr_other') if r.get('thread') == THREAD else r for r in rows()]
        _, failure = walk.analyze(other, THREAD, SENT)
        self.assertIn('no assignment was registered', failure)


class HoldWalk(unittest.TestCase):
    def test_it_names_the_guest_and_hands_it_back_when_released(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'hold'
            proc = subprocess.Popen([sys.executable, str(HERE / 'hold-walk.py'), 'walk-fixture', '--out', str(out),
                                     '--minutes', '1'], stdout=subprocess.PIPE, text=True)
            deadline = time.monotonic() + 10
            while not (out / 'vm').exists() and time.monotonic() < deadline:
                time.sleep(0.1)
            self.assertEqual((out / 'vm').read_text(), 'walk-fixture\n')
            self.assertIsNone(proc.poll(), 'it must hold until released')
            (out / 'release').touch()
            self.assertEqual(proc.wait(timeout=10), 0)
            self.assertIn('released by hand', proc.stdout.read())

    def test_it_refuses_a_release_left_over_from_another_hold(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / 'hold'
            out.mkdir()
            (out / 'release').touch()
            done = subprocess.run([sys.executable, str(HERE / 'hold-walk.py'), 'walk-fixture', '--out', str(out)],
                                  capture_output=True, text=True, timeout=10)
            self.assertEqual(done.returncode, 2)
            self.assertIn('already exists', done.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=1)
