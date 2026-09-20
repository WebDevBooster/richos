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
HERE=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(HERE))
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
    def test_reservation_is_held_and_released(self):
        with tempfile.TemporaryDirectory() as tmp:
            marker=Path(tmp)/'ready'
            command=[sys.executable,str(HERE/'reserve.py'),'--state-dir',tmp,'--max-load','10000','--']
            first=subprocess.Popen(command+[sys.executable,'-c',f'import pathlib,time;pathlib.Path({str(marker)!r}).touch();time.sleep(30)'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    if marker.exists():break
                    time.sleep(.02)
                self.assertTrue(marker.exists())
                second=subprocess.run(command+[sys.executable,'-c','pass'],capture_output=True)
                self.assertEqual(second.returncode,75)
            finally:
                first.terminate();first.wait(timeout=12)
            third=subprocess.run(command+[sys.executable,'-c','pass'],capture_output=True)
            self.assertEqual(third.returncode,0)
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
