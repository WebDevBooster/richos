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



def S(user,sys_=5.0,pressure='normal',swapout=0.0):
    """A host_sample() result."""
    return {'cpu_user_percent':user,'cpu_system_percent':sys_,'cpu_idle_percent':max(0.0,100-user-sys_),
            'swapout_mb_per_s':swapout,'memory_pressure':pressure,'memory_free_percent':50,'swap_used_mb':0.0}

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
            with patch('reserve.host_sample',return_value=S(20)):
                with reserve.reservation(state) as held:self.assertIsNone(held)
            self.assertFalse(state.exists())
            state.mkdir();lock=state/'release.lock';lock.write_text('')
            before=lock.stat()
            with open(lock,'a') as other:
                import fcntl
                fcntl.flock(other,fcntl.LOCK_EX|fcntl.LOCK_NB)
                with patch('reserve.host_sample',return_value=S(20)):
                    with reserve.reservation(state):pass
                with self.assertRaises(BlockingIOError):
                    with reserve.reservation(state,release_lock=True):self.fail('admitted')
            after=lock.stat()
            self.assertEqual((before.st_ino,before.st_size,before.st_mtime_ns),(after.st_ino,after.st_size,after.st_mtime_ns))
    def test_guest_lock_admits_one_walk_at_a_time(self):
        with tempfile.TemporaryDirectory() as tmp, patch('reserve.host_sample',return_value=S(20)):
            guest=Path(tmp)/'testvm'/'guest.lock'
            with reserve.reservation(lock=guest) as held:
                self.assertEqual(held,guest.resolve())
                with self.assertRaisesRegex(BlockingIOError,'guest.lock'):
                    with reserve.reservation(lock=guest):self.fail('admitted')
            with reserve.reservation(lock=guest):pass
    def test_unavailable_cpu_measurement_refuses_without_a_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch('reserve.host_sample',side_effect=BlockingIOError('CPU measurement unavailable')):
                with self.assertRaisesRegex(BlockingIOError,'unavailable'):
                    with reserve.reservation(tmp):self.fail('admitted')
    def test_high_load_with_idle_cpu_does_not_block(self):
        with tempfile.TemporaryDirectory() as tmp, patch('reserve.os.getloadavg',return_value=(20,20,20)), patch('reserve.host_sample',return_value=S(40)):
            with reserve.reservation(tmp):pass
    def test_busy_cpu_refuses_and_releases_lock(self):
        with tempfile.TemporaryDirectory() as tmp:
            with patch('reserve.host_sample',return_value=S(95)):
                with self.assertRaisesRegex(BlockingIOError,'user CPU is 95.0%'):
                    with reserve.reservation(tmp):self.fail('admitted')
                with self.assertRaisesRegex(BlockingIOError,'user CPU is 95.0%'):
                    with reserve.reservation(tmp,release_lock=True):self.fail('admitted')
            with patch('reserve.host_sample',return_value=S(20)):
                with reserve.reservation(tmp,release_lock=True):pass
    def test_sampler_splits_user_from_system_and_reads_swap_activity(self):
        # ticks: USER, SYSTEM, IDLE, NICE. 400 user+100 nice of 1000 = 50%; system 30%.
        counters=[([1000,1000,1000,0],100),([1400,1300,1200,100],100+4096)]
        values={'hw.pagesize':16384,'kern.memorystatus_vm_pressure_level':2,'kern.memorystatus_level':41}
        def sysctl(name,value):
            if name=='vm.swapusage':value.used=3*1048576;return value
            value.value=values[name];return value
        with patch('reserve._counters',side_effect=counters),patch('reserve._sysctl',side_effect=sysctl),patch('reserve.time.sleep') as sleep:
            s=reserve.host_sample()
        sleep.assert_called_once_with(1.0)
        self.assertAlmostEqual(s['cpu_user_percent'],50);self.assertAlmostEqual(s['cpu_system_percent'],30)
        self.assertAlmostEqual(s['cpu_idle_percent'],20)
        self.assertAlmostEqual(s['swapout_mb_per_s'],64)          # 4096 pages x 16 KB in one second
        self.assertEqual((s['memory_pressure'],s['memory_free_percent'],round(s['swap_used_mb'])),('warn',41,3))
    def test_sampler_fails_closed(self):
        with patch('reserve._counters',side_effect=OSError('host_statistics failed')),patch('reserve.time.sleep'):
            with self.assertRaisesRegex(BlockingIOError,'unavailable'):reserve.host_sample()
        with patch('reserve._counters',return_value=([5,5,5,5],0)),patch('reserve.time.sleep'):
            with self.assertRaisesRegex(BlockingIOError,'did not advance'):reserve.host_sample()
    def test_live_sampler_runs_in_process_without_top(self):
        with patch('reserve.subprocess.run',side_effect=AssertionError('no subprocess per sample')),patch('reserve.subprocess.Popen',side_effect=AssertionError('no subprocess per sample')):
            s=reserve.host_sample(interval=0.2)
        self.assertAlmostEqual(s['cpu_user_percent']+s['cpu_system_percent']+s['cpu_idle_percent'],100,delta=0.01)
        self.assertIn(s['memory_pressure'],('normal','warn','critical'))
    def test_high_system_time_alone_does_not_refuse(self):
        with patch('reserve.host_sample',return_value=S(40,sys_=58)):
            self.assertEqual(reserve.cpu_admission()['cpu_busy_percent'],40)
    def test_hard_swapping_refuses(self):
        for sample,why in ((S(10,pressure='critical'),'CRITICAL'),(S(10,swapout=40.0),'swapping out 40.0 MB/s')):
            with patch('reserve.host_sample',return_value=sample):
                with self.assertRaisesRegex(BlockingIOError,why):reserve.cpu_admission()
        with patch('reserve.host_sample',return_value=S(10,pressure='warn',swapout=1.0)):
            reserve.cpu_admission()                               # warn with little swap-out is reported, not refused

    def test_admission_wait_rechecks_and_records_delay(self):
        with patch('reserve.host_sample',side_effect=[S(90),S(20)]),patch('reserve.time.monotonic',side_effect=[0,1,31]),patch('reserve.time.sleep') as sleep,patch('reserve.os.getloadavg',return_value=(20,20,20)):
            sample=reserve.cpu_admission(wait_seconds=120)
            self.assertEqual((sample['cpu_busy_percent'],sample['load'],sample['admission_wait_seconds'],sample['admission_samples']),(20,20,31,2))
            sleep.assert_called_once_with(30)                     # never spins: 30 s between samples
    def test_admission_wait_is_bounded(self):
        with patch('reserve.host_sample',return_value=S(90)),patch('reserve.time.monotonic',side_effect=[0,1,31,61]),patch('reserve.time.sleep') as sleep:
            with self.assertRaisesRegex(BlockingIOError,'after 61s and 3 sample'):reserve.cpu_admission(wait_seconds=45)
            self.assertEqual([c.args[0] for c in sleep.call_args_list],[30,14])
    def test_retry_interval_has_a_floor(self):
        for seconds in (0,5,29.9,float('nan')):
            with self.assertRaises(ValueError):reserve.cpu_admission(retry_every=seconds)
        with self.assertRaises(ValueError):reserve.cpu_admission(wait_seconds=reserve.MAX_WAIT_SECONDS+1)
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
