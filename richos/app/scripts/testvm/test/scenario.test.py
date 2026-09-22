#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
HERE=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(HERE))
import reserve
from scenario import Failure, TurnBudget, run


class ScenarioTests(unittest.TestCase):
    def test_failed_dependency_does_not_stop_independent_work(self):
        with tempfile.TemporaryDirectory() as tmp:
            called=[]
            def fail(*_):raise Failure('product failure','visible defect')
            def ok(step,budget):called.append(step['id']);return {'ok':True}
            manifest={'name':'test','steps':[{'id':'a','action':'fail'},{'id':'b','action':'ok','requires':['a']},{'id':'c','action':'ok'}]}
            result=run(manifest,{'fail':fail,'ok':ok},Path(tmp)/'report.json',{})
            self.assertEqual([x['outcome'] for x in result['steps']],['product failure','prerequisite unavailable','PASS'])
            self.assertEqual(called,['c'])
    def test_recovery_cannot_exceed_budget(self):
        b=TurnBudget()
        for _ in range(6):b.take()
        with self.assertRaises(Failure):b.take()
        self.assertEqual(b.used,6)
    def test_release_lock_caller_is_held_and_released(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker=Path(tmp)/'ready'
            command=[sys.executable,str(HERE/'reserve.py'),'--state-dir',tmp,'--release-lock','--max-load','10000','--']
            first=subprocess.Popen(command+[sys.executable,'-c',f'import pathlib,time;pathlib.Path({str(marker)!r}).touch();time.sleep(30)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    if marker.exists():break
                    time.sleep(.02)
                self.assertTrue(marker.exists())
                second=subprocess.run(command+[sys.executable,'-c','pass'],capture_output=True)
                self.assertEqual(second.returncode,75)
                # CEO ruling §77: a test run is admitted while a release command holds the lock.
                cpu_only=[sys.executable,str(HERE/'reserve.py'),'--state-dir',tmp,'--max-load','10000','--']
                admitted=subprocess.run(cpu_only+[sys.executable,'-c','pass'],capture_output=True,text=True)
                self.assertEqual(admitted.returncode,0,admitted.stderr)
                self.assertIn('no lock taken',admitted.stderr)
            finally:
                first.terminate();first.wait(timeout=12)
            third=subprocess.run(command+[sys.executable,'-c','pass'],capture_output=True)
            self.assertEqual(third.returncode,0)
    def test_cpu_admitted_run_never_touches_release_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            state=Path(tmp)/'nightly'
            with patch('reserve.cpu_busy_percent',return_value=20):
                with reserve.reservation(state) as held:self.assertIsNone(held)
            self.assertFalse(state.exists())
            state.mkdir();lock=state/'release.lock';lock.write_text('')
            before=lock.stat()
            with open(lock,'a') as other:
                import fcntl
                fcntl.flock(other,fcntl.LOCK_EX|fcntl.LOCK_NB)
                with patch('reserve.cpu_busy_percent',return_value=20):
                    with reserve.reservation(state):pass
                with self.assertRaises(BlockingIOError):
                    with reserve.reservation(state,release_lock=True):self.fail('admitted')
            after=lock.stat()
            self.assertEqual((before.st_ino,before.st_size,before.st_mtime_ns),(after.st_ino,after.st_size,after.st_mtime_ns))
    def test_guest_lock_admits_one_walk_at_a_time(self):
        with tempfile.TemporaryDirectory() as tmp, patch('reserve.cpu_busy_percent',return_value=20):
            guest=Path(tmp)/'testvm'/'guest.lock'
            with reserve.reservation(lock=guest) as held:
                self.assertEqual(held,guest.resolve())
                with self.assertRaisesRegex(BlockingIOError,'guest.lock'):
                    with reserve.reservation(lock=guest):self.fail('admitted')
            with reserve.reservation(lock=guest):pass
    def test_unavailable_cpu_measurement_refuses_without_a_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch('reserve.cpu_busy_percent',side_effect=BlockingIOError('CPU measurement unavailable')):
                with self.assertRaisesRegex(BlockingIOError,'unavailable'):
                    with reserve.reservation(tmp):self.fail('admitted')
    def test_high_load_with_idle_cpu_does_not_block(self):
        with tempfile.TemporaryDirectory() as tmp, patch('reserve.os.getloadavg',return_value=(20,20,20)), patch('reserve.cpu_busy_percent',return_value=40):
            with reserve.reservation(tmp):pass
    def test_busy_cpu_refuses_and_releases_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch('reserve.cpu_busy_percent',return_value=95):
                with self.assertRaisesRegex(BlockingIOError,'95.0% busy'):
                    with reserve.reservation(tmp):self.fail('admitted')
                with self.assertRaisesRegex(BlockingIOError,'95.0% busy'):
                    with reserve.reservation(tmp,release_lock=True):self.fail('admitted')
            with patch('reserve.cpu_busy_percent',return_value=20):
                with reserve.reservation(tmp,release_lock=True):pass
    def test_cpu_parse_uses_second_sample_and_fails_closed(self):
        good=subprocess.CompletedProcess([],0,'CPU usage: 1% user, 1% sys, 98% idle\nCPU usage: 30% user, 10% sys, 60.00% idle','')
        with patch('reserve.subprocess.run',return_value=good):self.assertEqual(reserve.cpu_busy_percent(),40)
        for output in ('', 'CPU usage: 20% user, 10% sys, 70% idle'):
            with patch('reserve.subprocess.run',return_value=subprocess.CompletedProcess([],0,output,'')):
                with self.assertRaises(BlockingIOError):reserve.cpu_busy_percent()
    def test_cpu_timeout_fails_closed(self):
        with patch('reserve.subprocess.run',side_effect=subprocess.TimeoutExpired('top',5)):
            with self.assertRaises(BlockingIOError):reserve.cpu_busy_percent()

    def test_admission_wait_rechecks_cpu_and_records_delay(self):
        with patch('reserve.cpu_busy_percent',side_effect=[90,20]),patch('reserve.time.monotonic',side_effect=[0,1,4]),patch('reserve.time.sleep') as sleep,patch('reserve.os.getloadavg',return_value=(20,20,20)):
            sample=reserve.cpu_admission(wait_seconds=10)
            self.assertEqual(sample,{'cpu_busy_percent':20,'load':20,'admission_wait_seconds':4})
            sleep.assert_called_once_with(2)
    def test_admission_wait_is_bounded(self):
        with patch('reserve.cpu_busy_percent',return_value=90),patch('reserve.time.monotonic',side_effect=[0,1,4]),patch('reserve.time.sleep'):
            with self.assertRaises(BlockingIOError):reserve.cpu_admission(wait_seconds=3)
    def test_invalid_admission_cannot_loop_forever(self):
        for seconds in (float('nan'),float('inf'),-1):
            with self.assertRaises(ValueError):reserve.cpu_admission(wait_seconds=seconds)

    def test_delta_refusal_precedes_turn_budget_and_guest_access(self):
        from types import SimpleNamespace
        spec=importlib.util.spec_from_file_location('delta_walk_test',HERE/'delta-walk.py')
        delta=importlib.util.module_from_spec(spec);spec.loader.exec_module(delta)
        walk=object.__new__(delta.Walk);walk.a=SimpleNamespace(admission_wait_seconds=0)
        budget=TurnBudget()
        with patch.object(delta,'cpu_admission',side_effect=BlockingIOError('CPU measurement unavailable')),patch.object(walk,'ax') as guest_access:
            with self.assertRaises(Failure):walk.capture('test','mac',budget)
            self.assertEqual(budget.used,0);guest_access.assert_not_called()

    def test_ax_timeout_reaps_child_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            pidfile=Path(tmp)/'pid'
            child=f'import subprocess,time,pathlib; p=subprocess.Popen(["sleep","30"]);pathlib.Path({str(pidfile)!r}).write_text(str(p.pid));time.sleep(30)'
            result=subprocess.run([sys.executable,str(HERE/'ax-deadline.py'),'2',sys.executable,'-c',child],input=b'',capture_output=True,timeout=4)
            self.assertEqual(result.returncode,124)
            pid=int(pidfile.read_text())
            state=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'),state)


if __name__=='__main__':unittest.main()
