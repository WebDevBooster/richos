#!/usr/bin/env python3
"""Tiny real job flow and fault injection, without live gates or actual reboot."""
import importlib.util
import json
from pathlib import Path
import sys
import unittest
import uuid
from unittest.mock import patch


def load(file):
    spec=importlib.util.spec_from_file_location(file,Path(__file__).with_name(file+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

fixtures=load('legacy-workspace-gate.test');job=load('legacy-workspace-job')


class Jobs(unittest.TestCase):
    setUp=fixtures.GateWorkflow.setUp
    git=fixtures.GateWorkflow.git
    stage=fixtures.GateWorkflow.stage

    def ready(self):
        (self.work/'untracked').write_text('unique recovery bytes')
        self.ident=self.stage()['id'];self.base=self.vault/self.ident
        self.scratch=self.base/'job-scratch';self.scratch.mkdir(mode=0o700)
        target=next(row for row in self.report['repositories'][0]['gate_paths'] if row['path']==str(self.work))
        self.selection=dict(version=1,gate_id=self.ident,gate_sha256=self.digest,approval_kind='exact-legacy-job',restore=True,
            candidates=[dict(repo_alias='fixture',path=str(self.work),identity=target['identity'],git_admin_path=target['git_directory']['path'],head=self.head)],
            branches=[dict(repo_alias='fixture',ref='refs/heads/worker',tip=self.head,integration_ref='refs/heads/main',integration_tip=self.head)])
        self.approved=job.shadow.digest(self.selection)
        self.binary=job.shadow.TRUSTED_GIT if sys.platform=='darwin' else '/usr/bin/git'
        job.arm(self.manager,self.selection,approved_selection_sha256=self.approved,scratch_root=self.scratch)

    def advance(self):
        return job.advance(self.manager,self.ident,scratch_root=self.scratch,trusted_git=self.binary)

    def next_boot(self):self.current_boot=str(uuid.uuid4())

    def until(self,phase):
        for _ in range(12):
            result=job.status(self.manager,self.ident)
            if result['phase']==phase:return result
            result=self.advance()
            self.assertNotEqual(result['state'],'failed',result)
        self.fail('job did not reach '+phase)

    def test_real_capture_pin_retire_branch_restore_roundtrip_after_boot(self):
        self.ready();self.assertEqual(self.advance()['state'],'waiting-for-boot')
        self.assertEqual(list(self.scratch.iterdir()),[])
        self.next_boot();result=self.until('complete')
        self.assertEqual(result['state'],'complete')
        self.assertFalse(self.work.exists())
        self.assertEqual(self.git('branch','--list','worker'),'')
        self.assertEqual(self.git('rev-parse','main'),self.head)
        record=json.loads((self.base/'job.json').read_text())
        self.assertTrue((Path(record['captures'][0]['path'])/'recovery.tar.gz').is_file())
        self.assertFalse(self.advance()['progressed'])

    def test_rearming_cannot_broaden_scope_or_use_staging_gate(self):
        self.ready();changed=dict(self.selection,candidates=[])
        with self.assertRaisesRegex(job.JobError,'different immutable'):job.arm(self.manager,changed,approved_selection_sha256=job.shadow.digest(changed),scratch_root=self.scratch)
        (self.base/'job.json').unlink();gated=self.manager._load(self.base);gated['phase']='staging';self.manager._save(self.base,gated)
        with self.assertRaisesRegex(job.JobError,'fully gated'):job.arm(self.manager,self.selection,approved_selection_sha256=self.approved,scratch_root=self.scratch)

    def test_capture_lost_response_adopts_complete_archive_without_recapture(self):
        self.ready();self.next_boot();real=job._save;fired=[]
        def lose(base,record):
            if record['phase']=='handoff' and not fired:fired.append(True);raise RuntimeError('lost capture response')
            return real(base,record)
        with patch.object(job,'_save',side_effect=lose):self.assertEqual(self.advance()['state'],'failed')
        with patch.object(job.capture,'prepare',side_effect=AssertionError('must adopt complete capture')):
            self.assertEqual(self.advance()['phase'],'handoff')

    def lost_operation(self,phase,module,name,replay_name):
        self.ready();self.next_boot();self.until(phase);real=getattr(module,name)
        def lose(*args,**kwargs):real(*args,**kwargs);raise RuntimeError('lost completed primitive response')
        with patch.object(module,name,side_effect=lose):self.assertEqual(self.advance()['state'],'failed')
        with patch.object(module,name,side_effect=AssertionError('must replay persisted operation')),patch.object(module,replay_name,wraps=getattr(module,replay_name)) as replay:
            self.assertNotEqual(self.advance()['state'],'failed');replay.assert_called_once()

    def test_handoff_lost_response_replays_exact_publication(self):
        self.lost_operation('handoff',job.mutation,'publish_recovery','replay')

    def test_retirement_lost_response_replays_after_sources_are_gone(self):
        self.lost_operation('retirement',job.retirement,'retire','replay')

    def test_branch_lost_response_replays_after_ref_is_gone(self):
        self.lost_operation('branches',job.mutation,'publish','replay')

    def test_restore_lost_response_finishes_existing_restored_gate(self):
        self.ready();self.next_boot();self.until('restore');real=self.manager.restore
        def lose(*args,**kwargs):real(*args,**kwargs);raise RuntimeError('lost restore response')
        with patch.object(self.manager,'restore',side_effect=lose):self.assertEqual(self.advance()['state'],'failed')
        self.assertEqual(self.advance()['state'],'complete')

    def interrupted_capture(self,foreign=False):
        def stop(*args,**kwargs):
            scratch=Path(kwargs['scratch_root']);self.partial=scratch/'legacy-capture-123456ab';self.partial.mkdir(mode=0o700)
            (self.partial/('foreign' if foreign else 'recovery.tar.gz')).write_bytes(b'partial duplicate bytes')
            raise RuntimeError('interrupted capture')
        with patch.object(job.capture,'prepare',side_effect=stop):self.assertEqual(self.advance()['state'],'failed')

    def test_known_partial_copy_is_reclaimed_before_recapture(self):
        self.ready();self.next_boot();self.interrupted_capture()
        self.assertEqual(self.advance()['phase'],'handoff')
        self.assertFalse(self.partial.exists())

    def test_matching_receipt_with_incomplete_archive_is_recaptured(self):
        self.ready();self.next_boot();real=job.capture.prepare
        def corrupt(*args,**kwargs):
            result=real(*args,**kwargs);self.partial=Path(result['artifact_path'])
            (self.partial/'recovery.tar.gz').write_bytes(b'truncated completed archive')
            raise RuntimeError('lost final capture response')
        with patch.object(job.capture,'prepare',side_effect=corrupt):self.assertEqual(self.advance()['state'],'failed')
        self.assertEqual(self.advance()['phase'],'handoff');self.assertFalse(self.partial.exists())

    def test_foreign_partial_content_and_changed_original_are_retained(self):
        self.ready();self.next_boot();self.interrupted_capture(foreign=True)
        self.assertEqual(self.advance()['state'],'failed');self.assertTrue((self.partial/'foreign').exists())
        (self.partial/'foreign').rename(self.partial/'recovery.tar.gz')
        with self.manager.frozen_view(self.ident,approved_sha256=self.digest) as view:held,_=job.capture._map(view,self.work/'file')
        held.write_text('different frozen source')
        self.assertEqual(self.advance()['state'],'failed');self.assertTrue(self.partial.exists())

    def test_replaced_scratch_inode_refuses_cleanup(self):
        self.ready();self.next_boot();self.interrupted_capture()
        original=self.partial.parent;original.rename(original.with_name(original.name+'-saved'));original.mkdir(mode=0o700)
        (original/'foreign').write_text('new owner bytes')
        self.assertEqual(self.advance()['state'],'failed');self.assertEqual((original/'foreign').read_text(),'new owner bytes')

    def test_status_never_waits_for_gate_or_job_lock(self):
        self.ready()
        with patch.object(job,'_lock',side_effect=AssertionError('job lock')),patch.object(self.manager,'_lock',side_effect=AssertionError('gate lock')):
            self.assertEqual(job.status(self.manager,self.ident)['state'],'waiting-for-boot')

    def test_actual_two_repo_branch_job_replays_first_and_preserves_distinct_tips(self):
        second=self.sources/'second';second_work=self.sources/'second-worker'
        self.git('init','-q','-b','main',str(second))
        self.git('-C',str(second),'config','user.name','fixture')
        self.git('-C',str(second),'config','user.email','fixture@example.invalid')
        (second/'file').write_text('independent second history')
        self.git('-C',str(second),'add','file');self.git('-C',str(second),'commit','-qm','second root')
        second_head=self.git('-C',str(second),'rev-parse','HEAD')
        self.assertNotEqual(second_head,self.head)
        self.git('-C',str(second),'worktree','add','-qb','worker',str(second_work))
        for repo in (self.repo,second):self.git('-C',str(repo),'branch','finished')
        self.tx['members'].append(dict(path=str(second_work),repo=str(second),branch='worker',head=second_head))
        self.records.append(dict(event='registered',worktree=str(second),repo=str(second),session_id='gone',session_pid=999999999))
        self.report=fixtures.gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)},'second':{'path':str(second)}}},[self.tx],self.records)
        self.digest=job.shadow.digest(self.report)
        self.ident=self.stage()['id'];self.base=self.vault/self.ident
        self.scratch=self.base/'job-scratch';self.scratch.mkdir(mode=0o700)
        self.binary=job.shadow.TRUSTED_GIT if sys.platform=='darwin' else '/usr/bin/git'
        self.selection=dict(version=1,gate_id=self.ident,gate_sha256=self.digest,approval_kind='exact-legacy-job',restore=True,candidates=[],
            branches=[dict(repo_alias=alias,ref='refs/heads/finished',tip=tip,integration_ref='refs/heads/main',integration_tip=tip)
                      for alias,tip in (('second',second_head),('fixture',self.head))])
        self.approved=job.shadow.digest(self.selection)
        job.arm(self.manager,self.selection,approved_selection_sha256=self.approved,scratch_root=self.scratch)
        self.next_boot();real=job.mutation.publish
        def lose(*args,**kwargs):real(*args,**kwargs);raise RuntimeError('lost first repository response')
        with patch.object(job.mutation,'publish',side_effect=lose):self.assertEqual(self.advance()['state'],'failed')
        with patch.object(job.mutation,'publish',side_effect=AssertionError('first repo must replay')):
            self.assertEqual(self.advance()['branch_group_index'],1)
        self.until('complete')
        for repo,tip in ((self.repo,self.head),(second,second_head)):
            self.assertEqual(self.git('-C',str(repo),'branch','--list','finished'),'')
            self.assertEqual(self.git('-C',str(repo),'rev-parse','refs/richos/retired/'+self.ident+'/refs/heads/finished'),tip)
            self.assertEqual(self.git('-C',str(repo),'rev-parse','main'),tip)
            self.assertEqual(self.git('-C',str(repo),'rev-parse','worker'),tip)

    def test_cross_repo_branch_groups_keep_original_tips_despite_new_snapshots(self):
        self.ready();record=job._read(self.base)
        record['phase']='branches';record['branch_groups']=['alpha','beta'];record['branch_group_index']=0
        record['selection']['branches']=[dict(repo_alias=alias,ref='refs/heads/chosen',tip=self.head,integration_ref='refs/heads/main',integration_tip=self.head) for alias in ('beta','alpha')]
        publications=[]
        def observe(*args,**kwargs):
            return dict(version=1,gate_id=self.ident,gate_sha256=self.digest,repo_alias=kwargs['repo_alias'],ref_snapshot_sha256='new',registry_sha256='new',refs={'unapproved-tip':'b'*40})
        def publish(gate,selection,**kwargs):publications.append(selection)
        with patch.object(job.shadow,'observe',side_effect=observe),patch.object(job.mutation,'publish',side_effect=publish):
            job._step(self.manager,self.base,record,self.scratch,self.binary)
            job._step(self.manager,self.base,record,self.scratch,self.binary)
        self.assertEqual([row['repo_alias'] for row in publications],['alpha','beta'])
        self.assertTrue(all(row['branches'][0]['tip']==self.head for row in publications))
        self.assertTrue(all(len(row['branches'])==1 for row in publications))


if __name__=='__main__':unittest.main(verbosity=2)
