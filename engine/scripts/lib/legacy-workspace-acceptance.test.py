#!/usr/bin/env python3
"""Small fixture routing tests. These do not establish installed root authority."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

HERE=Path(__file__).resolve().parent

def load(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

mod=load('legacy-workspace-acceptance');gate_module=load('legacy-workspace-gate')
identity_fixtures=load('legacy-workspace-gate.test')


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='legacy-acceptance-test-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.root.chmod(0o755)
        self.private=self.root/'private';self.active=self.root/'active'
        self.private.mkdir(mode=0o700);self.active.mkdir(mode=0o755)
        self.account=pwd.getpwuid(os.getuid()) if os.getuid()!=0 else pwd.getpwnam('nobody')
        self.uid=self.account.pw_uid
        self.driver=object.__new__(mod.Acceptance)
        self.driver.release=HERE;self.driver.release_identity={'test':'exact-source'}
        self.driver.policy={'private_root':str(self.private),'active_root':str(self.active),
                            'owners':{str(self.uid):{'gid':self.account.pw_gid}}}
        self.driver.runtime=SimpleNamespace(protected_path=lambda path,**kw:Path(path))
        self.boot=str(uuid.uuid4());fixture=self
        class DisposableGate(gate_module.LegacyGate):
            def __init__(self,vault,**kwargs):super().__init__(vault,require_root=False,**kwargs)
            @staticmethod
            def _boot():return fixture.boot
        self.driver.gate=SimpleNamespace(LegacyGate=DisposableGate,GateError=gate_module.GateError,planner=gate_module.planner,
            owner_report=lambda policy,context:gate_module.owner_report(policy,context,require_root=False))
        self.driver.job=load('legacy-workspace-job');self.driver.ledger=load('worktree-ledger')
        self.processes=[]
        real_popen=subprocess.Popen
        def popen(*args,**kwargs):
            if os.geteuid()!=0:
                for key in ('user','group','extra_groups'):kwargs.pop(key,None)
            process=real_popen(*args,**kwargs);self.processes.append(process);return process
        self.patchers=[patch.object(mod,'PYTHON',sys.executable),patch.object(subprocess,'Popen',side_effect=popen)]
        for item in self.patchers:item.start();self.addCleanup(item.stop)
        self.addCleanup(self.stop_processes)

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill();process.wait(timeout=10)

    def prepare(self):
        self.record=self.driver.prepare(self.uid)
        self.ident=self.record['id'];self.base=self.private/self.ident;self.live=self.active/self.ident
        return self.record

    def update(self,**values):
        record=json.loads((self.base/'receipt.json').read_text());record.update(values)
        mod.save(self.base/'receipt.json',record);return record

    def staged(self):
        self.prepare();vault=self.base/'legacy-gates';vault.mkdir(mode=0o700)
        gate=self.driver.gate.LegacyGate(vault,inspection_context=self.record['inspection_context'])
        result=gate.stage(self.record['report'],approved_sha256=self.record['plan_sha256'])
        ident=result['id'];base=vault/ident;state=gate._load(base)
        held=next(base/row['held'] for row in state['roots'] if row['source']==str(self.live/'sources/worker'))
        (held/'file').write_bytes(b'working-late-before-reboot')
        target=next(row for row in self.record['report']['repositories'][0]['gate_paths'] if row['path']==str(self.live/'sources/worker'))
        selection=dict(version=1,gate_id=ident,gate_sha256=self.record['plan_sha256'],approval_kind='exact-legacy-job',restore=True,
            candidates=[dict(repo_alias='fixture',path=target['path'],identity=target['identity'],git_admin_path=target['git_directory']['path'],head=self.record['expected']['head'])],
            branches=[dict(repo_alias='fixture',ref='refs/heads/worker',tip=self.record['expected']['head'],integration_ref='refs/heads/main',integration_tip=self.record['expected']['head'])])
        scratch=base/'job-scratch';scratch.mkdir(mode=0o700)
        approved=self.driver.job.shadow.digest(selection)
        self.driver.job.arm(gate,selection,approved_selection_sha256=approved,scratch_root=scratch)
        self.update(phase='waiting-for-reboot',gate_id=ident,selection=selection,selection_sha256=approved,staged_boot=self.boot)
        return gate,ident,base

    def test_real_prepare_uses_only_new_paths_and_dead_owner_history(self):
        record=self.prepare()
        self.assertEqual(record['phase'],'prepared');self.assertFalse(record['passed'])
        self.assertFalse((self.base/'legacy-gates').exists())
        self.driver.validate_report(record['report'],self.live/'sources')
        ledger=[json.loads(line) for line in Path(record['inspection_context']['ledger']).read_text().splitlines()]
        self.assertTrue(all(self.driver.ledger.process_status(row['session_pid'],row['pid_start'])in ('gone','reused') for row in ledger))
        self.assertEqual(self.driver.git(record,self.live/'sources/worker','show',':file'),b'staged-only')
        self.assertEqual((self.live/'sources/worker/file').read_bytes(),b'working')
        self.assertFalse(record['cleanup_authorized'])

    def test_arbitrary_id_and_changed_approval_have_no_gate_sideeffects(self):
        for ident in ('../production','legacy-acceptance-../escape','legacy-acceptance-'+'g'*32):
            with self.assertRaisesRegex(ValueError,'minted'):mod.fixed_paths(self.driver.policy,ident)
        self.prepare()
        with self.assertRaisesRegex(ValueError,'matching fixture plan'):
            self.driver.stage(self.ident,'0'*64)
        self.assertFalse((self.base/'legacy-gates').exists())

    def test_replaced_root_and_changed_release_refuse_before_stage(self):
        self.prepare();moved=self.live.with_name(self.live.name+'-original');self.live.rename(moved);self.live.mkdir()
        with self.assertRaisesRegex(ValueError,'root was replaced'):
            self.driver.stage(self.ident,self.record['plan_sha256'])
        self.live.rmdir();moved.rename(self.live)
        self.driver.release_identity={'test':'changed'}
        with self.assertRaisesRegex(ValueError,'exact protected'):
            self.driver.stage(self.ident,self.record['plan_sha256'])
        self.assertFalse((self.base/'legacy-gates').exists())

    def test_old_numeric_and_foreign_volume_fixture_roots_require_new_preparation(self):
        self.prepare();original=json.loads((self.base/'receipt.json').read_text())
        for token in (self.live.lstat().st_dev,'darwin-volume-uuid-v1:'+str(uuid.uuid4())):
            with self.subTest(token=token):
                changed=json.loads(json.dumps(original));changed['active_identity']['device']=token
                mod.save(self.base/'receipt.json',changed)
                with self.assertRaisesRegex(ValueError,'no durable filesystem UUID|root was replaced'):
                    with self.driver.existing(self.ident):self.fail('must not accept replaced volume')
                self.assertEqual((self.live/'sources/worker/file').read_bytes(),b'working')
        mod.save(self.base/'receipt.json',original)

    def test_ambient_installed_owner_change_precedes_creation(self):
        with self.assertRaisesRegex(ValueError,'not approved'):self.driver.prepare(self.uid+12345)
        self.assertEqual(list(self.private.iterdir()),[]);self.assertEqual(list(self.active.iterdir()),[])

    def test_changed_fixture_scope_and_source_inode_refuse_before_gate(self):
        self.prepare();path=self.live/'sources/worker'
        path.rename(path.with_name('preserved'));path.mkdir()
        with self.assertRaises(Exception):self.driver.stage(self.ident,self.record['plan_sha256'])
        self.assertFalse((self.base/'legacy-gates').exists())

    def test_stage_lost_response_records_only_matching_gate_and_cannot_stage_twice(self):
        self.prepare();klass=self.driver.gate.LegacyGate;real=klass.stage
        def lose(instance,*args,**kwargs):real(instance,*args,**kwargs);raise RuntimeError('lost stage response')
        with patch.object(klass,'stage',lose):
            with self.assertRaisesRegex(RuntimeError,'lost stage response'):
                self.driver.stage(self.ident,self.record['plan_sha256'])
        result=json.loads((self.base/'receipt.json').read_text())
        self.assertEqual(result['phase'],'stage-failed');self.assertEqual(result['recovery_gate_ids'],[result['gate_id']])
        self.assertFalse((self.live/'sources/repo').exists())
        with self.assertRaisesRegex(ValueError,'partial gates'):
            self.driver.stage(self.ident,self.record['plan_sha256'])
        self.assertEqual(len(list((self.base/'legacy-gates').iterdir())),1)

    def test_same_boot_resume_never_calls_broker_or_mutates_job(self):
        gate,ident,base=self.staged();before=(base/'job.json').read_bytes()
        with patch.object(self.driver,'run_broker',side_effect=AssertionError('must not run')):
            with self.assertRaisesRegex(ValueError,'different real kernel boot'):
                self.driver.resume(self.ident,self.record['plan_sha256'])
        self.assertEqual((base/'job.json').read_bytes(),before)

    def test_changed_job_scope_after_reboot_refuses_before_broker(self):
        gate,ident,base=self.staged();self.boot=str(uuid.uuid4())
        record=self.driver.job._read(base);record['selection']['branches'][0]['tip']='a'*40
        record['approved_selection_sha256']=self.driver.job.shadow.digest(record['selection'])
        self.driver.job._save(base,record)
        with patch.object(self.driver,'run_broker',side_effect=AssertionError('must not run')):
            with self.assertRaisesRegex(ValueError,'scope changed'):
                self.driver.resume(self.ident,self.record['plan_sha256'])

    @unittest.skipUnless(sys.platform=='darwin','actual macOS xattr expectation')
    def test_real_job_root_pins_and_archive_survive_disposable_boot_and_device_renumber(self):
        gate,ident,base=self.staged();self.boot=str(uuid.uuid4())
        def run(private,active,record):
            for _ in range(20):
                result=self.driver.job.advance(gate,ident,scratch_root=base/'job-scratch')
                self.assertNotEqual(result['state'],'failed',result)
                if result['phase']=='complete':return
            self.fail('job not complete')
        with identity_fixtures.renumbered_device(),patch.object(self.driver,'run_broker',side_effect=run):
            result=self.driver.resume(self.ident,self.record['plan_sha256'])
        self.assertTrue(result['passed']);self.assertFalse(result['activated']);self.assertFalse(result['cleanup_authorized'])
        self.assertTrue((self.base/'legacy-gates').exists())

    def test_restored_pin_refuses_wrong_permissions_and_replaced_inode(self):
        self.prepare();repo=self.live/'sources/repo'
        expected=next(row['identity'] for row in self.record['report']['repositories'][0]['gate_paths'] if row['path']==str(repo))
        mod.restored_pin(repo,expected)
        repo.chmod(0o755)
        with self.assertRaisesRegex(ValueError,'access metadata'):mod.restored_pin(repo,expected)
        repo.chmod(expected['mode']);repo.rename(repo.with_name('saved'));repo.mkdir(mode=expected['mode'])
        with self.assertRaisesRegex(ValueError,'identity'):mod.restored_pin(repo,expected)

    def test_broker_discovery_and_phase_only_failure_surface_immediately(self):
        record={'owner_uid':self.uid,'gate_id':'fixture-gate'}
        base={'server_uid':0,'peer_uid':self.uid,'repositories':['fixture']}
        with self.assertRaisesRegex(ValueError,'policy-revoked'):
            self.driver.broker_progress(dict(base,legacy_maintenance={'inventory_complete':False,'error':'policy-revoked'}),record)
        with self.assertRaisesRegex(ValueError,'lost archive'):
            self.driver.broker_progress(dict(base,legacy_maintenance={'inventory_complete':True,'total':1,
                'records':[{'gate_id':'fixture-gate','phase':'failed','last_error':'lost archive'}]}),record)
        self.assertFalse(self.driver.broker_progress(dict(base,legacy_maintenance={'inventory_complete':False,'error':'not-yet-inspected'}),record))

    def test_child_setup_unblocks_inherited_termination(self):
        self.prepare();source=self.live/'signal-source';source.mkdir();os.chown(source,self.uid,self.account.pw_gid)
        owner=dict(user=self.uid,group=self.account.pw_gid,extra_groups=[]) if os.geteuid()==0 else {}
        prior=signal.pthread_sigmask(signal.SIG_BLOCK,{signal.SIGTERM,signal.SIGINT})
        try:
            process=subprocess.Popen([sys.executable,'-I','-S','-B','-c',mod.SETUP,str(source)],env=mod.ENV,
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**owner)
        finally:signal.pthread_sigmask(signal.SIG_SETMASK,prior)
        self.assertTrue(__import__('select').select([process.stdout],[],[],20)[0]);json.loads(process.stdout.readline())
        process.terminate();process.communicate(timeout=10)
        self.assertEqual(process.returncode,-signal.SIGTERM)


if __name__=='__main__':unittest.main(verbosity=2)
