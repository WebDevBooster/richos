#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent

def load(name):
    spec = importlib.util.spec_from_file_location(name, HERE / 'lib' / (name + '.py'))
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module

daily = load('daily-workspace-cleanup')
tx = load('worktree-transactions')
SID = 'daily-test-session'
AID = 'abcdef123456'

class Cleanup(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='richos-daily-', dir='/private/tmp' if os.path.isdir('/private/tmp') else None)
        self.root = Path(self.tmp.name).resolve(); self.repo = self.root / 'repo'; self.work = self.root / 'worker'
        self.env = patch.dict(os.environ, {'RICHOS_WORKTREE_TX_DIR': str(self.root/'tx'),
            'RICHOS_WORKTREE_LEDGER': str(self.root/'ledger.jsonl'), 'CLAUDE_CONFIG_DIR':str(self.root/'profile'),
            'GIT_CONFIG_GLOBAL':'/dev/null', 'GIT_CONFIG_SYSTEM':'/dev/null'})
        self.env.start(); self.repo.mkdir()
        self.git(self.repo,'init','-b','main'); self.git(self.repo,'config','user.name','Fixture'); self.git(self.repo,'config','user.email','fixture@example.invalid')
        (self.repo/'file').write_text('base\n'); self.git(self.repo,'add','file'); self.git(self.repo,'commit','-m','base')
        self.git(self.repo,'worktree','add','-b','worker',str(self.work))
        (self.work/'file').write_text('delivered\n'); self.git(self.work,'commit','-am','delivery')
        self.git(self.repo,'merge','--ff-only','worker')
        self.main = self.git(self.repo,'rev-parse','main').strip()
        self.record={'record':'transaction','session_id':SID,'agent_id':AID,'teammate':'worker',
            'sealed':True,'terminal':{'ingress':'SubagentStop','ts':'fixture'},'start_cwd':str(self.repo),
            'state':'sealed','members':[{'class':'hand-rolled','repo':str(self.repo),'path':str(self.work),
                'branch':'worker','state':'bound','cleanup_policy':'integrated-daily'}]}
        tx.atomic_write_json(tx.tx_path(SID,AID), self.record)

    def tearDown(self):
        self.env.stop(); self.tmp.cleanup()

    def git(self, repo,*args):
        r=subprocess.run(['git','-C',str(repo),*args],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr); return r.stdout

    def run_cleanup(self):
        with tx.tx_lock(SID,AID):
            return daily.reconcile(tx,tx.load_tx(SID,AID),0)

    def assert_kept(self):
        self.assertTrue(self.work.is_dir());self.assertEqual(self.git(self.repo,'rev-parse','worker').strip(),self.git(self.work,'rev-parse','HEAD').strip())
        self.assertEqual(self.git(self.repo,'rev-parse','main').strip(),self.main)

    def test_integrated_without_task_receipt_reclaims_worktree_and_branch(self):
        result=self.run_cleanup();self.assertEqual(result['members'][0]['daily_cleanup']['phase'],'complete')
        self.assertFalse(self.work.exists());self.assertNotIn('refs/heads/worker',self.git(self.repo,'show-ref'))
        self.assertEqual(self.git(self.repo,'rev-parse','main').strip(),self.main)
        self.assertEqual(self.git(self.repo,'status','--porcelain'),'')

    def test_dirty_staged_untracked_and_ignored_refuse(self):
        for kind in ('dirty','staged','untracked','ignored'):
            with self.subTest(kind=kind):
                if kind in ('dirty','staged'):
                    (self.work/'file').write_text('unfinished\n')
                    if kind=='staged':self.git(self.work,'add','file')
                else:
                    (self.work/'extra').write_text('unfinished\n')
                    if kind=='ignored':
                        (self.repo/'.git/info/exclude').write_text('extra\n')
                with self.assertRaises(Exception):self.run_cleanup()
                self.assert_kept();self.git(self.work,'reset','--hard','HEAD')
                if (self.work/'extra').exists():(self.work/'extra').unlink()

    def test_unintegrated_refuses(self):
        (self.work/'file').write_text('later\n');self.git(self.work,'commit','-am','later')
        with self.assertRaises(Exception):self.run_cleanup()
        self.assert_kept()

    def test_active_reservation_refuses(self):
        other=dict(self.record,agent_id='abcdef999999',terminal=None)
        tx.atomic_write_json(tx.tx_path(SID,other['agent_id']),other)
        with self.assertRaisesRegex(Exception,'reservation'):self.run_cleanup()
        self.assert_kept()

    def test_unsupported_competing_terminal_ingress_remains_reserved(self):
        other=dict(self.record,agent_id='abcdef999999',terminal={'ingress':'TaskCompleted'})
        tx.atomic_write_json(tx.tx_path(SID,other['agent_id']),other)
        with self.assertRaisesRegex(Exception,'reservation'):self.run_cleanup()
        self.assert_kept()

    def test_locked_worktree_refuses(self):
        self.git(self.repo,'worktree','lock',str(self.work))
        with self.assertRaisesRegex(Exception,'unlocked'):self.run_cleanup()
        self.assert_kept()

    def test_native_checkout_remains_platform_owned(self):
        self.record['members'][0].update({'class':'native','cleanup_owner':'claude-code'})
        self.record['members'][0].pop('cleanup_policy') # Previously sealed native record.
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        result=self.run_cleanup(); self.assertTrue(self.work.is_dir())
        self.assertEqual(result['members'][0]['cleanup_policy'],'integrated-daily')
        self.assertEqual(result['members'][0]['state'],'platform-pending')
        self.git(self.repo,'worktree','remove',str(self.work))
        result=self.run_cleanup();self.assertEqual(result['members'][0]['daily_cleanup']['phase'],'complete')
        self.assertNotIn('refs/heads/worker',self.git(self.repo,'show-ref'))

    def test_interruption_after_worktree_removal_replays(self):
        def crash(point):
            if point=='after-worktree-remove':raise RuntimeError('fixture crash')
        with patch.object(daily,'_checkpoint',crash):
            with self.assertRaisesRegex(RuntimeError,'fixture crash'):self.run_cleanup()
        self.assertFalse(self.work.exists());self.assertIn('refs/heads/worker',self.git(self.repo,'show-ref'))
        self.assertEqual(self.run_cleanup()['members'][0]['daily_cleanup']['phase'],'complete')

    def test_interruption_after_branch_delete_replays(self):
        def crash(point):
            if point=='after-branch-delete':raise RuntimeError('fixture crash')
        with patch.object(daily,'_checkpoint',crash):
            with self.assertRaisesRegex(RuntimeError,'fixture crash'):self.run_cleanup()
        self.assertFalse(self.work.exists());self.assertNotIn('refs/heads/worker',self.git(self.repo,'show-ref'))
        self.assertEqual(self.run_cleanup()['members'][0]['daily_cleanup']['phase'],'complete')

    def test_recreated_path_after_remove_is_held(self):
        def crash(point):
            if point=='after-worktree-remove':raise RuntimeError('fixture crash')
        with patch.object(daily,'_checkpoint',crash):
            with self.assertRaises(RuntimeError):self.run_cleanup()
        self.work.mkdir();(self.work/'new').write_text('new owner\n')
        with self.assertRaises(Exception):self.run_cleanup()
        self.assertEqual((self.work/'new').read_text(),'new owner\n')
        self.assertIn('refs/heads/worker',self.git(self.repo,'show-ref'))

    def test_terminal_ingress_keeps_dirty_path_and_reconciler_reports_hold(self):
        (self.work/'file').write_text('unfinished\n')
        tx.terminalize(SID,AID)
        self.assertTrue(self.work.exists())
        self.assertFalse(any(self.root.glob('*.richos-terminal-*')))
        spec=importlib.util.spec_from_file_location('daily_reconciler',HERE/'reconcile-terminal-worktrees.py')
        rec=importlib.util.module_from_spec(spec);spec.loader.exec_module(rec)
        rec.reconcile_transaction(tx.load_tx(SID,AID))
        result=tx.load_tx(SID,AID)
        self.assertTrue(result['members'][0]['blocked'])
        self.assertEqual(tx.metrics()['terminal_pending_cleanup'],1)
        self.assertEqual((self.work/'file').read_text(),'unfinished\n')

    def test_native_ingress_proof_survives_platform_removal_and_dispatches(self):
        self.record['members'][0].update({'class':'native','cleanup_owner':'claude-code'})
        tx.atomic_write_json(tx.tx_path(SID,AID),self.record)
        tx.terminalize(SID,AID)
        self.assertIn('daily_cleanup',tx.load_tx(SID,AID)['members'][0])
        self.git(self.repo,'worktree','remove',str(self.work))
        tx.observe_platform_native(SID,AID,0)
        self.assertEqual(tx.metrics()['terminal_pending_cleanup'],1)
        spec=importlib.util.spec_from_file_location('daily_reconciler',HERE/'reconcile-terminal-worktrees.py')
        rec=importlib.util.module_from_spec(spec);spec.loader.exec_module(rec)
        rec.reconcile_transaction(tx.load_tx(SID,AID))
        self.assertEqual(tx.load_tx(SID,AID)['members'][0]['daily_cleanup']['phase'],'complete')
        self.assertEqual(tx.metrics()['terminal_pending_cleanup'],0)
        self.assertEqual(self.git(self.repo,'for-each-ref','--format=%(refname)'), 'refs/heads/main\n')

    def test_actual_native_live_lock_vetoes_old_terminal_fact(self):
        reason='claude agent agent-'+AID+' (pid '+str(os.getpid())+' start fixture)'
        self.git(self.repo,'worktree','lock','--reason',reason,str(self.work))
        with self.assertRaisesRegex(Exception,'native owner is live'):self.run_cleanup()
        self.assert_kept()

    def test_branch_reserved_elsewhere_is_retained(self):
        second=self.root/'other-checkout'
        self.git(self.repo,'worktree','add','--force',str(second),'worker')
        with self.assertRaisesRegex(Exception,'reserved'):self.run_cleanup()
        self.assertFalse(self.work.exists());self.assertTrue(second.exists())
        self.assertIn('refs/heads/worker',self.git(self.repo,'show-ref'))

    def test_malformed_ledger_and_unbound_preparation_refuse(self):
        ledger=self.root/'ledger.jsonl'
        ledger.write_text('{not-json}\n')
        with self.assertRaises(Exception):self.run_cleanup()
        self.assert_kept()
        ledger.write_text(json.dumps({'event':'prepared','session_id':'new-session','teammate':'new',
            'repo':str(self.repo),'worktree':str(self.work),'branch':'worker'})+'\n')
        with self.assertRaisesRegex(Exception,'preparation'):self.run_cleanup()
        self.assert_kept()

    def test_changed_branch_after_remove_is_held(self):
        def crash(point):
            if point=='after-worktree-remove':raise RuntimeError('fixture crash')
        with patch.object(daily,'_checkpoint',crash):
            with self.assertRaises(RuntimeError):self.run_cleanup()
        base=self.git(self.repo,'rev-parse','main^').strip()
        self.git(self.repo,'update-ref','refs/heads/worker',base)
        with self.assertRaises(Exception):self.run_cleanup()
        self.assertEqual(self.git(self.repo,'rev-parse','worker').strip(),base)

if __name__=='__main__':unittest.main()
