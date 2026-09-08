#!/usr/bin/env python3
import importlib.util
from datetime import datetime
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('schedule',Path(__file__).with_name('cleanup-schedule.py'))
s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)

class ScheduleTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'schedule.json'
        self.clock=datetime(2026,9,8,4,0)
        self.calls=0
    def run_schedule(self,action=None,**kw):
        def work(allowed):
            self.calls+=1
            self.assertTrue(allowed())
        return s.scheduled(action or work,path=self.path,now=lambda:self.clock,idle=lambda:601,**kw)
    def test_once_per_due_day_and_catchup(self):
        self.assertEqual(self.run_schedule(),'completed')
        self.assertEqual(self.run_schedule(),'not-due')
        self.clock=datetime(2026,9,12,15,0)
        self.assertEqual(self.run_schedule(),'completed')
        self.assertEqual(self.calls,2)
    def test_before_four_and_clock_rollback(self):
        self.assertEqual(s.due_slot(datetime(2026,9,8,3,59),4),'2026-09-07')
        self.run_schedule();self.clock=datetime(2026,9,7,20)
        self.assertEqual(self.run_schedule(),'not-due')
    def test_active_wait_is_lightweight_and_recomputes_due_day(self):
        values=iter([1,601,601]);sleeps=[]
        def sleep(seconds):
            sleeps.append(seconds);self.clock=datetime(2026,9,9,9)
        s.scheduled(lambda allowed:self.assertTrue(allowed()),path=self.path,
                    now=lambda:self.clock,idle=lambda:next(values),sleep=sleep)
        self.assertEqual(sleeps,[60])
        self.assertEqual(json.loads(self.path.read_text())['last_completed_slot'],'2026-09-09')
    def test_activity_interrupt_and_exception_do_not_mark_complete(self):
        self.assertEqual(self.run_schedule(lambda allowed:False),'interrupted')
        self.assertFalse(self.path.exists())
        def broken(allowed):raise RuntimeError('disk failure')
        with self.assertRaises(RuntimeError):self.run_schedule(broken)
        self.assertFalse(self.path.exists())
    def test_zero_work_and_holds_count_as_one_pass(self):
        self.assertEqual(self.run_schedule(lambda allowed:0),'completed')
        self.assertEqual(self.run_schedule(),'not-due')
    def test_concurrent_entry_does_not_run_or_wait(self):
        self.assertEqual(self.run_schedule(lambda allowed:self.assertEqual(self.run_schedule(),'already-running')),'completed')
    def test_unknown_idle_never_starts_work(self):
        def stop(seconds):raise RuntimeError('waiting only')
        with self.assertRaisesRegex(RuntimeError,'waiting only'):
            s.scheduled(lambda allowed:self.fail('must not run'),path=self.path,
                        idle=lambda:float('nan'),sleep=stop)
    def test_fixture_state_and_invalid_configuration(self):
        with patch.dict(s.os.environ,{'RICHOS_WORKTREE_TX_DIR':str(Path(self.temp.name)/'tx')}):
            self.assertEqual(s.state_path(),Path(self.temp.name)/'worktree-cleanup-schedule.json')
        with self.assertRaises(ValueError):self.run_schedule(hour=24)
    def test_catchup_crossing_four_covers_current_due_day(self):
        self.clock=datetime(2026,9,8,3,59)
        def work(allowed):
            self.calls+=1
            self.assertTrue(allowed())
            self.clock=datetime(2026,9,8,4,1)
        self.assertEqual(self.run_schedule(work),'completed')
        self.assertEqual(json.loads(self.path.read_text())['last_completed_slot'],'2026-09-08')
        self.assertEqual(self.run_schedule(),'not-due')
        self.assertEqual(self.calls,1)
    def test_predictable_temporary_hardlink_is_never_truncated(self):
        victim=Path(self.temp.name)/'unrelated-file'
        victim.write_bytes(b'preserve these bytes')
        os.link(victim,str(self.path)+'.tmp')
        self.assertEqual(self.run_schedule(),'completed')
        self.assertEqual(victim.read_bytes(),b'preserve these bytes')
        self.assertEqual(Path(str(self.path)+'.tmp').read_bytes(),victim.read_bytes())
    def test_activity_after_adoption_defers_next_phase(self):
        scripts=Path(__file__).resolve().parent.parent
        spec=importlib.util.spec_from_file_location('schedule_reconciler_fixture',scripts/'reconcile-terminal-worktrees.py')
        rec=importlib.util.module_from_spec(spec);spec.loader.exec_module(rec)
        idle=iter([True,False])
        environment={'HOME':self.temp.name,
                     'RICHOS_WORKTREE_TX_DIR':str(Path(self.temp.name)/'tx'),
                     'RICHOS_WORKTREE_CAPTURE_DIR':str(Path(self.temp.name)/'captures'),
                     'RICHOS_WORKTREE_LEDGER':str(Path(self.temp.name)/'ledger.jsonl')}
        with patch.dict(os.environ,environment), patch.object(rec,'adoption_pass',return_value=0) as adoption, patch.object(rec.tx,'_managed_workspaces') as managed, patch.object(rec,'process_pending_terminals') as pending:
            self.assertIs(rec.run(300,still_idle=lambda:next(idle)),False)
            adoption.assert_called_once_with()
            managed.assert_not_called()
            pending.assert_not_called()
        self.assertFalse((Path(self.temp.name)/'tx'/'last-run.json').exists())
    def test_native_idle_parser_rejects_absent_data(self):
        result=type('Result',(),{'stdout':s.plistlib.dumps([{}])})()
        with patch.object(s.subprocess,'run',return_value=result):
            with self.assertRaises(ValueError):s.idle_seconds()

if __name__=='__main__':unittest.main()
