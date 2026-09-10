#!/usr/bin/env python3
"""Real Git platform-owned cleanup controls, with disposable repositories only."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

HERE=Path(__file__).resolve().parent

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

tx=load('tx',HERE/'worktree-transactions.py')
r=load('reconciler',HERE.parent/'reconcile-terminal-worktrees.py')
sparse=load('sparse',HERE/'shell-worktree-sparse.py')

class Tests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='native-platform-');self.root=Path(self.temp.name).resolve()
        self.env=mock.patch.dict(os.environ,{'RICHOS_WORKTREE_TX_DIR':str(self.root/'tx'),'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1','RICHOS_WORKTREE_LEDGER':str(self.root/'ledger.jsonl'),'RICHOS_WORKSPACE_RETIRE_DIR':str(self.root/'retire')});self.env.start()
        self.repo=self.root/'repo';self.repo.mkdir();self.sid='11111111-0000-4000-8000-000000000001';self.aid='aaaaaa000001'
        self.git('init','-q','-b','main');self.git('config','user.name','Fixture');self.git('config','user.email','fixture@example.invalid')
        (self.repo/'tracked').write_text('base\n');self.git('add','.');self.git('commit','-qm','base')
        self.path=self.repo/'.claude/worktrees'/('agent-'+self.aid)
        self.git('worktree','add','-q','-b','native',str(self.path))
        self.member,error=tx._verify_native_member(str(self.path),self.aid);self.assertEqual(error,'')
        self.persist()
    def tearDown(self):self.env.stop();self.temp.cleanup()
    def git(self,*args):
        return subprocess.run(['/usr/bin/git','-C',str(self.repo),*args],check=True,capture_output=True,text=True).stdout.strip()
    def persist(self):
        tx.atomic_write_json(tx.tx_path(self.sid,self.aid),dict(record='transaction',session_id=self.sid,agent_id=self.aid,kind='native',sealed=True,state='terminal',terminal={'ingress':'SubagentStop'},members=[self.member]))
    def current(self):return tx.load_tx(self.sid,self.aid)['members'][0]
    def observe(self):return tx.observe_platform_native(self.sid,self.aid,0)['members'][0]
    def test_new_native_is_platform_owned_and_never_sparsified(self):
        self.assertEqual(self.member['cleanup_owner'],'claude-code')
        self.assertIsNone(sparse.eligible(dict(sealed=True,kind='native+external',members=[self.member]))[0])
    def test_terminal_preserves_dirty_bytes_index_lock_and_original_registration(self):
        (self.path/'tracked').write_text('staged\n');subprocess.run(['/usr/bin/git','-C',str(self.path),'add','tracked'],check=True)
        (self.path/'tracked').write_text('unstaged\n');(self.path/'unique').write_bytes(b'untracked')
        self.git('worktree','lock','--reason','platform-owned',str(self.path))
        before=self.git('worktree','list','--porcelain','-z')
        tx.terminalize(self.sid,self.aid)
        self.assertEqual(self.current()['state'],'platform-pending');self.assertNotIn('quarantine',self.current())
        self.assertEqual(self.git('worktree','list','--porcelain','-z'),before)
        self.assertEqual((self.path/'tracked').read_text(),'unstaged\n');self.assertEqual((self.path/'unique').read_bytes(),b'untracked')
        self.assertEqual(subprocess.check_output(['/usr/bin/git','-C',str(self.path),'show',':tracked']),b'staged\n')
        self.assertEqual(self.git('rev-parse',self.current()['backup_ref']),self.member['head_at_seal'])
    def test_platform_removal_closes_only_after_real_git_unregisters(self):
        self.observe();self.git('worktree','remove',str(self.path));self.git('branch','-d','native')
        with mock.patch.object(tx,'_git',wraps=tx._git) as commands:
            result=self.observe()
        self.assertEqual(result['state'],'removed')
        self.assertFalse(any('prune' in call.args or 'remove' in call.args or 'unlock' in call.args for call in commands.call_args_list))
        self.assertEqual(self.git('for-each-ref','--format=%(refname)','refs/heads/'),'refs/heads/main')
    def test_missing_directory_with_retained_registration_stays_pending(self):
        moved=self.root/'moved';self.path.rename(moved)
        self.assertEqual(self.observe()['state'],'platform-pending')
        self.assertIn(str(self.path),self.git('worktree','list','--porcelain','-z'))
    def test_remaining_dangling_link_stays_pending_after_registry_removal(self):
        self.git('worktree','remove',str(self.path));self.path.symlink_to(self.root/'missing')
        self.assertEqual(self.observe()['state'],'platform-pending')
    def test_malformed_or_failed_registry_never_proves_absence(self):
        self.git('worktree','remove',str(self.path));original=tx._git
        for result in [(0,'',''),(0,'worktree /somewhere\0\0',''),(1,'','failed'),(0,'worktree /a\0HEAD '+self.member['head_at_seal']+'\0detached\0detached\0\0','')]:
            def query(cwd,*args):return result if args[:2]==('worktree','list') else original(cwd,*args)
            with mock.patch.object(tx,'_git',side_effect=query),self.assertRaisesRegex(RuntimeError,'registry'):
                self.observe()
            self.assertNotEqual(self.current()['state'],'removed')
    def test_legacy_entrypoints_cannot_quarantine_platform_owned_member(self):
        tx.save_ref(self.sid,self.aid,0);tx.quarantine(self.sid,self.aid,0);tx.close_absent(self.sid,self.aid,0,'caller mistake')
        self.assertTrue(self.path.is_dir());self.assertEqual(self.current()['state'],'platform-pending')
    def test_reconciler_waits_for_platform_while_it_holds_its_own_lock(self):
        # ROUND 11 (2026-09-10). This case used to assert that a platform-owned
        # checkout is NEVER mutated and waits for the platform to remove it —
        # which, with the platform leaving finished agents' checkouts on disk
        # all day, meant waiting forever. What it protects is preserved
        # exactly: while CLAUDE CODE HOLDS ITS OWN LOCK nothing is touched.
        # The engine never removes that lock; when the platform releases it,
        # the very next pass reclaims a finished agent's clean workspace.
        self.git('worktree','lock','--reason','claude agent agent-'+self.aid+' (pid %d start fixture)'%os.getpid(),str(self.path))
        with mock.patch.object(r,'retry_backoff',return_value=(0,0)):
            r.reconcile_transaction(tx.load_tx(self.sid,self.aid))
            self.assertTrue(self.path.is_dir());self.assertEqual(self.current()['state'],'platform-pending')
            self.assertIn(str(self.path),self.git('worktree','list','--porcelain'))
            self.git('worktree','unlock',str(self.path))
            r.reconcile_transaction(tx.load_tx(self.sid,self.aid))
        self.assertFalse(self.path.exists());self.assertEqual(self.current()['state'],'removed')
    def test_symbolic_or_changed_recovery_ref_cannot_redirect_or_overwrite(self):
        ref=tx.backup_ref(self.sid,self.aid,'native');before=self.git('rev-parse','main')
        self.git('symbolic-ref',ref,'refs/heads/main')
        with self.assertRaisesRegex(RuntimeError,'symbolic'):self.observe()
        self.assertEqual(self.git('rev-parse','main'),before)
        self.git('symbolic-ref','--delete',ref)
        self.git('commit','--allow-empty','-qm','different');different=self.git('rev-parse','main')
        self.git('update-ref',ref,different)
        with self.assertRaisesRegex(RuntimeError,'changed'):self.observe()
        self.assertEqual(self.git('rev-parse',ref),different)
    def test_reused_registration_branch_is_not_adopted(self):
        subprocess.run(['/usr/bin/git','-C',str(self.path),'checkout','-qb','replacement'],check=True)
        with self.assertRaisesRegex(RuntimeError,'branch changed'):self.observe()
        self.assertEqual(self.current()['state'],'bound')
    def test_direct_removal_authority_cannot_claim_platform_owned_native(self):
        retirement=load('retirement',HERE/'workspace-retire.py')
        result=retirement.termination_authority(str(self.repo),str(self.repo),str(self.path),self.aid)
        self.assertFalse(result['authorized']);self.assertEqual(result['reason_code'],'platform-owned')
        self.assertTrue(self.path.is_dir())
    def test_actual_removal_helper_refuses_platform_owned_native(self):
        result=subprocess.run(['bash',str(HERE.parent/'remove-agent-worktree.sh'),'--entity-repo',str(self.repo),
            '--repo',str(self.repo),'--owner',self.aid,str(self.path)],capture_output=True,text=True)
        self.assertEqual(result.returncode,3,result.stdout+result.stderr)
        self.assertIn('platform-owned',result.stdout+result.stderr);self.assertTrue(self.path.is_dir())
    # historical-fixture-partial: cleanup_owner — complete for THIS fixture.
    # self.member comes from tx._verify_native_member (worktree-transactions.py
    # :477), whose returned dict has no cleanup_policy, and persist() writes the
    # record directly rather than through try_seal, which is the only place that
    # stamps it (worktree-transactions.py:684). So cleanup_owner is the only
    # routing key present and removing it leaves a genuinely historical member.
    # If _verify_native_member ever stamps a second routing key, R1 of the
    # cleanup-routing contract moves and this declaration is what it points at.
    def test_missing_legacy_checkout_keeps_its_registered_index(self):
        self.member.pop('cleanup_owner');self.persist()
        moved=self.root/'missing-legacy';self.path.rename(moved)
        result=tx.close_absent(self.sid,self.aid,0,'gone')['members'][0]
        self.assertEqual(result['state'],'bound');self.assertIn('registration/index',result['last_error'])
        self.assertIn(str(self.path),self.git('worktree','list','--porcelain','-z'))
    def test_incomplete_platform_inventory_refuses_direct_authority(self):
        bad=Path(tx.tx_path(self.sid,'aaaaaa000002'));bad.write_text('{')
        retirement=load('retirement',HERE/'workspace-retire.py')
        result=retirement.termination_authority(str(self.repo),str(self.repo),str(self.path),self.aid)
        self.assertEqual(result['reason_code'],'platform-ownership-unavailable')
    def test_platform_inventory_is_exact_and_removed_members_do_not_claim_reuse(self):
        self.assertTrue(tx.platform_owns_path(str(self.path)))
        self.assertFalse(tx.platform_owns_path(str(self.path)+'-other'))
        self.member['state']='removed';self.persist()
        self.assertFalse(tx.platform_owns_path(str(self.path)))
    def test_unknown_explicit_owner_is_not_a_legacy_quarantine(self):
        self.member['cleanup_owner']='future-platform';self.persist()
        tx.terminalize(self.sid,self.aid)
        self.assertTrue(self.path.is_dir());self.assertNotIn('quarantine',self.current())
        self.assertIn('unknown owner retained',self.current()['last_error'])
        self.assertTrue(tx.platform_owns_path(str(self.path)))
        self.assertIsNone(sparse.eligible(dict(sealed=True,kind='native+external',members=[self.member]))[0])
    def test_unknown_transaction_record_kind_is_not_complete_inventory(self):
        bad=Path(tx.tx_path(self.sid,'aaaaaa000002'));bad.write_text('{}')
        with self.assertRaisesRegex(RuntimeError,'kind unknown'):tx.platform_owns_path(str(self.path)+'-other')
    # historical-fixture-partial: cleanup_owner — complete for THIS fixture, for
    # the reason recorded above test_missing_legacy_checkout_keeps_its_registered
    # _index: a member built by _verify_native_member and persisted without a
    # seal carries no cleanup_policy to strip. The assertion below is the proof
    # rather than the claim — terminalize() reaches save_ref+quarantine only for
    # a member that is neither platform-owned nor daily-reclaimed, so `state ==
    # quarantined` fails the moment this fixture stops being historical.
    def test_historical_native_keeps_existing_recovery_route(self):
        self.member.pop('cleanup_owner');self.persist();tx.terminalize(self.sid,self.aid)
        self.assertEqual(self.current()['state'],'quarantined');self.assertTrue(Path(self.current()['quarantine']).is_dir())
    def test_platform_marker_with_historical_quarantine_never_takes_it_over(self):
        self.member['quarantine']=str(self.root/'old');self.persist()
        with self.assertRaisesRegex(RuntimeError,'historical quarantine'):self.observe()
        self.assertTrue(self.path.is_dir())

if __name__=='__main__':unittest.main(verbosity=2)
