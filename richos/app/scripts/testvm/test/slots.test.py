#!/usr/bin/env python3
"""slots.py: two guest slots, each held only while one run executes, offline.

No guest and no CPU sample: the running-guest count and the CPU/memory admission are
replaced, in process and in every child process driven here, so the suite answers the same
on an idle Mac and a busy one. Every slot file lives under a temporary TESTVM_ROOT."""
import contextlib
import fcntl
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import slots  # noqa: E402

# A child process that runs slots.main() with the guest count and admission replaced.
# GUESTS is a JSON list of running guest names; ADMIT=refuse makes every sample refuse.
DRIVER = textwrap.dedent(f"""
    import json, os, sys
    sys.path.insert(0, {str(HERE)!r})
    import slots
    slots.running_guests = lambda: json.loads(os.environ.get('FAKE_GUESTS', '[]'))
    def admit(*a, **k):
        if os.environ.get('FAKE_ADMIT') == 'refuse':
            raise BlockingIOError('total CPU is 95.0% (limit 80%)')
        return {{}}
    slots.reserve.cpu_admission = admit
    sys.argv = ['slots.py'] + sys.argv[1:]
    try:
        sys.exit(slots.main())
    except BlockingIOError as exc:
        print(str(exc), file=sys.stderr); sys.exit(75)
    except ValueError as exc:
        print('slots.py: ' + str(exc), file=sys.stderr); sys.exit(2)
""")


def quiet():
    return contextlib.redirect_stderr(io.StringIO())


class Slots(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / 'testvm'
        self.env = patch.dict(os.environ, {'TESTVM_ROOT': str(self.root)})
        self.env.start()
        os.environ.pop('TESTVM_SLOTS', None)
        os.environ.pop(slots.ENV, None)

    def tearDown(self):
        self.env.stop()
        self.tmp.cleanup()

    def hold(self, **kw):
        kw.setdefault('guests', lambda: [])
        kw.setdefault('admit', lambda: {})
        return slots.guest_slot(root=self.root, **kw)

    @staticmethod
    def finish(proc, timeout=30):
        out, err = proc.communicate(timeout=timeout)
        return proc.returncode, out, err

    def child(self, *args, env=None, **kw):
        e = dict(os.environ, TESTVM_ROOT=str(self.root), **(env or {}))
        return subprocess.Popen([sys.executable, '-c', DRIVER, *args], env=e, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)

    # --- two at once, the third waits or refuses ------------------------------------
    def test_two_runs_hold_two_slots_at_once_and_a_third_is_refused_naming_both(self):
        with quiet(), self.hold(purpose='walk A') as a, self.hold(purpose='walk B') as b:
            self.assertEqual({a.name, b.name}, {'guest.lock', 'guest-2.lock'})
            with self.assertRaisesRegex(BlockingIOError, 'every slot is executing a run') as caught:
                with self.hold():
                    self.fail('a third run was admitted')
            self.assertIn('walk A', str(caught.exception))
            self.assertIn('walk B', str(caught.exception))
        with quiet(), self.hold() as again:
            self.assertEqual(again.name, 'guest.lock')

    def test_slot_one_is_the_old_guest_lock_so_an_older_checkout_still_counts(self):
        old = self.root / 'guest.lock'
        self.root.mkdir(parents=True)
        with old.open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)      # what reserve.reservation(lock=...) does
            with quiet(), self.hold() as mine:
                self.assertEqual(mine.name, 'guest-2.lock')
                with self.assertRaisesRegex(BlockingIOError, 'older checkout'):
                    with self.hold():
                        self.fail('admitted beside an older checkout and another run')

    def test_the_running_guest_count_refuses_even_with_a_slot_free(self):
        with quiet(), self.assertRaisesRegex(BlockingIOError, r'2 guest\(s\) already running \(walk-a, gui\)'):
            with self.hold(guests=lambda: ['walk-a', 'gui']):
                self.fail('a third guest was admitted')
        with quiet(), self.hold(guests=lambda: ['walk-a']):
            pass

    def test_a_refused_cpu_sample_releases_the_slot_before_waiting(self):
        seen = []
        calls = {'n': 0}

        def admit():
            calls['n'] += 1
            if calls['n'] == 1:
                raise BlockingIOError('total CPU is 95.0% (limit 80%)')
            return {}

        def sleep(seconds):
            seen.append((seconds, [slots.is_held(p) for p in slots.slot_paths(self.root)]))
        now = iter(range(0, 1000, 1))
        with quiet(), self.hold(admit=admit, wait_seconds=120, sleep=sleep, clock=lambda: next(now)):
            pass
        self.assertEqual(len(seen), 1)
        self.assertEqual(seen[0][0], 30, 'CPU samples stay at least 30 s apart (reserve.py)')
        self.assertEqual(seen[0][1], [False, False], 'no slot is held while this caller waits for the CPU')

    def test_one_slot_can_be_asked_for_and_three_cannot(self):
        with patch.dict(os.environ, {'TESTVM_SLOTS': '1'}), quiet(), self.hold():
            with self.assertRaises(BlockingIOError):
                with self.hold():
                    self.fail('admitted a second run with one slot')
        for bad in ('3', '0', 'two'):
            with patch.dict(os.environ, {'TESTVM_SLOTS': bad}), self.assertRaises(ValueError):
                with self.hold():
                    pass

    # --- held only for the run: released the instant it ends --------------------------
    def test_a_caller_arriving_between_runs_gets_a_slot_at_once(self):
        """The CEO's measurement, offline: A runs, ends, and is 'thinking'; B arrives."""
        rc, _, err = self.finish(self.child('run', '--', sys.executable, '-c', 'pass'))
        self.assertEqual(rc, 0, err)
        self.assertIn('slot released', err)
        self.assertEqual([slots.is_held(p) for p in slots.slot_paths(self.root)], [False, False])
        began = time.monotonic()
        rc, _, err = self.finish(self.child('run', '--', sys.executable, '-c', 'pass'))
        self.assertEqual(rc, 0, err)
        self.assertLess(time.monotonic() - began, 5)
        self.assertIn('waited 0s', err)

    def test_a_waiting_caller_takes_the_slot_as_soon_as_a_run_ends(self):
        gate = Path(self.tmp.name) / 'end'
        wait_for_gate = ('import pathlib,time\n'
                         f'while not pathlib.Path({str(gate)!r}).exists(): time.sleep(0.05)')
        a = self.child('run', '--purpose', 'run A', '--', sys.executable, '-c', wait_for_gate)
        b = self.child('run', '--purpose', 'run B', '--', sys.executable, '-c', wait_for_gate)
        deadline = time.monotonic() + 20
        while not all(slots.is_held(p) for p in slots.slot_paths(self.root)) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(all(slots.is_held(p) for p in slots.slot_paths(self.root)))
        rc, _, err = self.finish(self.child('run', '--', sys.executable, '-c', 'pass'))
        self.assertEqual(rc, 75, err)
        self.assertIn('every slot is executing a run', err)
        c = self.child('run', '--wait', '60', '--', sys.executable, '-c', 'pass')
        time.sleep(1)
        self.assertIsNone(c.poll(), 'it waits while both slots execute')
        ended = time.monotonic()
        gate.touch()
        for p in (a, b):
            rc, _, err = self.finish(p)
            self.assertEqual(rc, 0, err)
        rc, _, err = self.finish(c)
        self.assertEqual(rc, 0, err)
        self.assertLess(time.monotonic() - ended, slots.SLOT_POLL_SECONDS + 5)
        self.assertIn('slot waiting: every slot is executing a run', err)

    def test_the_child_sees_its_slot_and_its_exit_code_passes_through(self):
        show = f'import os,sys; print(os.environ["{slots.ENV}"]); sys.exit(7)'
        rc, out, _ = self.finish(self.child('run', '--', sys.executable, '-c', show))
        self.assertEqual(rc, 7)
        self.assertEqual(out.strip(), str(self.root / 'guest.lock'))
        self.assertFalse(slots.is_held(self.root / 'guest.lock'))

    def test_status_shows_who_holds_what(self):
        gate = Path(self.tmp.name) / 'end'
        a = self.child('run', '--purpose', 'walk seven', '--', sys.executable, '-c',
                       f'import pathlib,time\nwhile not pathlib.Path({str(gate)!r}).exists(): time.sleep(0.05)')
        deadline = time.monotonic() + 20
        while not slots.is_held(self.root / 'guest.lock') and time.monotonic() < deadline:
            time.sleep(0.05)
        status = self.child('status')
        out = status.communicate(timeout=30)[0]
        gate.touch()
        self.finish(a)
        self.assertIn('guest.lock: held by pid', out)
        self.assertIn('walk seven', out)
        self.assertIn('guest-2.lock: free', out)

    # --- run.sh's gate: a guest boots only inside a slot of its own -----------------
    def test_check_refuses_outside_a_slot_and_passes_for_a_descendant_of_the_holder(self):
        rc, _, err = self.finish(self.child('check'))
        self.assertEqual(rc, 1)
        self.assertIn('no guest slot is held', err)
        rc, _, err = self.finish(self.child('run', '--', sys.executable, '-c', DRIVER, 'check'))
        self.assertEqual(rc, 0, err)

    def test_check_refuses_a_slot_somebody_else_holds(self):
        gate = Path(self.tmp.name) / 'end'
        a = self.child('run', '--', sys.executable, '-c',
                       f'import pathlib,time\nwhile not pathlib.Path({str(gate)!r}).exists(): time.sleep(0.05)')
        deadline = time.monotonic() + 20
        while not slots.is_held(self.root / 'guest.lock') and time.monotonic() < deadline:
            time.sleep(0.05)
        rc, _, err = self.finish(self.child('check', env={slots.ENV: str(self.root / 'guest.lock')}))
        self.assertEqual(rc, 1)
        self.assertIn('held by another run', err)
        gate.touch()
        self.finish(a)
        rc, _, err = self.finish(self.child('check', env={slots.ENV: str(self.root / 'guest.lock')}))
        self.assertEqual(rc, 1)
        self.assertIn('is not held', err)
        rc, _, err = self.finish(self.child('check', env={slots.ENV: str(Path(self.tmp.name) / 'mine.lock')}))
        self.assertEqual(rc, 1)
        self.assertIn('not one of this root', err)

    # --- a guest never outlives its slot ---------------------------------------------
    def test_a_guest_still_recorded_against_the_slot_is_stopped_before_release(self):
        calls = []

        def fake_run(args, **kw):
            calls.append((args, [slots.is_held(p) for p in slots.slot_paths(self.root)]))
            return subprocess.CompletedProcess(args, 0)
        with patch('slots.subprocess.run', side_effect=fake_run), quiet():
            with self.hold() as slot:
                mine = self.root / 'run' / 'walk-left'
                mine.mkdir(parents=True)
                (mine / 'slot').write_text(str(slot) + '\n')
                other = self.root / 'run' / 'walk-other'
                other.mkdir(parents=True)
                (other / 'slot').write_text(str(self.root / 'guest-2.lock') + '\n')
        self.assertEqual([c[0][1:] for c in calls], [['walk-left']])
        self.assertTrue(calls[0][0][0].endswith('stop.sh'))
        self.assertEqual(calls[0][1], [True, False], 'stopped while the slot was still held')

    def test_the_holder_record_is_cleared_on_release(self):
        with quiet(), self.hold(purpose='walk X') as slot:
            self.assertEqual(json.loads(slot.read_text())['purpose'], 'walk X')
        self.assertEqual(slot.read_text(), '')


if __name__ == '__main__':
    unittest.main(verbosity=1)
