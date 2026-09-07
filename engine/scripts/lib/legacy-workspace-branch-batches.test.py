#!/usr/bin/env python3
"""Real bounded branch publications and interrupted batch replay in tiny Git repos."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
import uuid
from unittest.mock import patch


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


fixtures=load('legacy-workspace-gate.test');job=load('legacy-workspace-job')


class Batches(unittest.TestCase):
    setUp=fixtures.GateWorkflow.setUp
    git=fixtures.GateWorkflow.git
    stage=fixtures.GateWorkflow.stage

    def ready(self,count=129):
        self.refs=['refs/heads/batch-%03d'%i for i in range(count)]
        payload=''.join('create %s %s\n'%(ref,self.head) for ref in self.refs)
        subprocess.run(['/usr/bin/git','-C',str(self.repo),'update-ref','--stdin'],input=payload,text=True,check=True,capture_output=True)
        self.report=fixtures.gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx],self.records)
        self.digest=job.shadow.digest(self.report)
        self.ident=self.stage()['id'];self.base=self.vault/self.ident
        self.scratch=self.base/'job-scratch';self.scratch.mkdir(mode=0o700)
        self.selection=dict(version=1,gate_id=self.ident,gate_sha256=self.digest,approval_kind='exact-legacy-job',restore=True,
            candidates=[],branches=[dict(repo_alias='fixture',ref=ref,tip=self.head,integration_ref='refs/heads/main',integration_tip=self.head) for ref in self.refs])
        self.approved=job.shadow.digest(self.selection)
        self.binary=job.shadow.TRUSTED_GIT if sys.platform=='darwin' else '/usr/bin/git'
        job.arm(self.manager,self.selection,approved_selection_sha256=self.approved,scratch_root=self.scratch)

    def advance(self):
        return job.advance(self.manager,self.ident,scratch_root=self.scratch,trusted_git=self.binary)

    def next_boot(self):self.current_boot=str(uuid.uuid4())

    def complete(self):
        for _ in range(8):
            result=self.advance();self.assertNotEqual(result['state'],'failed',result)
            if result['state']=='complete':return
        self.fail('bounded batches did not complete')

    def test_129_real_branches_publish_as_128_and_1_after_cutoff(self):
        self.ready();self.assertEqual(self.advance()['state'],'waiting-for-boot')
        self.assertFalse((self.base/'mutation.json').exists());self.next_boot()
        original=job.mutation.publish;published=[]
        def observe(gate,selection,**kwargs):
            published.append(len(selection['branches']));return original(gate,selection,**kwargs)
        with patch.object(job.mutation,'publish',side_effect=observe):self.complete()
        self.assertEqual(published,[128,1]);self.assertEqual(self.git('branch','--list','batch-*'),'')
        self.assertEqual(self.git('rev-parse','main'),self.head);self.assertTrue(self.work.is_dir())
        self.assertEqual(len(list((self.base/'mutation-history').glob('*/receipt.json'))),1)
        self.assertFalse(self.advance()['progressed'])

    def test_lost_first_batch_response_replays_before_second_batch(self):
        self.ready();self.next_boot();original=job.mutation.publish
        def lose(*args,**kwargs):original(*args,**kwargs);raise RuntimeError('lost first batch response')
        with patch.object(job.mutation,'publish',side_effect=lose):self.assertEqual(self.advance()['state'],'failed')
        self.assertEqual(job._read(self.base)['branch_group_index'],0)
        with patch.object(job.mutation,'publish',side_effect=AssertionError('must replay first batch')), \
             patch.object(job.mutation,'replay',wraps=job.mutation.replay) as replay:
            self.assertEqual(self.advance()['branch_group_index'],1);replay.assert_called_once()
        self.complete();self.assertEqual(self.git('branch','--list','batch-*'),'')

    def test_changed_second_batch_tip_holds_remaining_ref(self):
        self.ready();self.next_boot();self.assertEqual(self.advance()['branch_group_index'],1)
        record=job._read(self.base);record['selection']['branches'][-1]['tip']='f'*40
        # Even a newly computed selection hash cannot replace the approved
        # gate job's original intent through the public re-arm operation.
        with self.assertRaisesRegex(job.JobError,'different immutable'):
            job.arm(self.manager,record['selection'],approved_selection_sha256=job.shadow.digest(record['selection']),scratch_root=self.scratch)
        with self.manager.frozen_view(self.ident,approved_sha256=self.digest) as view:
            common=job.shadow._resolve(view,'fixture');last=common/self.refs[-1]
            self.assertTrue(last.is_file())
            original=last.read_bytes();last.write_bytes(b'f'*40+b'\n')
        result=self.advance();self.assertEqual(result['state'],'failed');self.assertEqual(result['branch_group_index'],1)
        self.assertEqual(last.read_bytes(),b'f'*40+b'\n');last.write_bytes(original)
        self.complete()

    def test_batch_map_cannot_drop_reorder_or_duplicate_approved_refs(self):
        self.ready();original=job._read(self.base)
        for groups in ([],list(reversed(original['branch_groups'])),original['branch_groups']*2):
            changed=copy.deepcopy(original);changed['branch_groups']=groups;job._save(self.base,changed)
            with self.assertRaisesRegex(job.JobError,'branch batches differ'):job._read(self.base)
        job._save(self.base,original)

    def test_historical_small_job_replays_original_alias_groups(self):
        self.ready(1);record=job._read(self.base);record.pop('branch_batch_version');record['branch_groups']=['fixture'];job._save(self.base,record)
        self.next_boot();self.complete();self.assertEqual(self.git('branch','--list','batch-*'),'')

    def test_large_job_cannot_be_reinterpreted_as_historical(self):
        self.ready();record=job._read(self.base);record.pop('branch_batch_version');record['branch_groups']=['fixture'];job._save(self.base,record)
        with self.assertRaisesRegex(job.JobError,'historical branch scope'):job._read(self.base)

    def test_selection_count_and_byte_bounds_remain_enforced(self):
        self.ready(1);scope=copy.deepcopy(self.selection)
        scope['branches']=[dict(scope['branches'][0],ref='refs/heads/b-%d'%i) for i in range(512)]
        job._scope(scope,job.shadow.digest(scope));scope['branches'].append(dict(scope['branches'][0],ref='refs/heads/extra'))
        with self.assertRaisesRegex(job.JobError,'bounded nonempty'):job._scope(scope,job.shadow.digest(scope))
        scope['branches']=scope['branches'][:512]
        for i,row in enumerate(scope['branches']):row['ref']='refs/heads/'+('x'*800)+str(i)
        with self.assertRaisesRegex(job.JobError,'byte limit'):job._scope(scope,job.shadow.digest(scope))


if __name__=='__main__':unittest.main()
