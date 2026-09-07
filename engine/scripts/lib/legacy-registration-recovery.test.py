#!/usr/bin/env python3
"""Tiny real Git orphan/locked registration recovery behind a simulated boot gate."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
import uuid
from unittest.mock import patch


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

fixtures=load('legacy-workspace-gate.test');job=load('legacy-workspace-job')
capture=job.capture;retirement=job.retirement


class Registration(unittest.TestCase):
    setUp=fixtures.GateWorkflow.setUp
    git=fixtures.GateWorkflow.git
    stage=fixtures.GateWorkflow.stage

    def ready(self,mode='missing',*,arm=True):
        self.admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        (self.work/'file').write_bytes(b'unique staged index object')
        self.git('-C',str(self.work),'add','file')
        self.index_oid=self.git('-C',str(self.work),'rev-parse',':file')
        (self.admin/'unique-admin').write_bytes(b'\x00unique administrative payload\xff')
        if mode=='locked':self.git('worktree','lock','--reason','explicit terminal lock',str(self.work))
        else:
            shutil.rmtree(self.work)
            if mode=='missing-container':
                # Original worker is outside the canonical checkout. Move its
                # recorded path into a container that no longer exists.
                destination=self.sources/'vanished'/'worker'
                (self.admin/'gitdir').write_text(str(destination/'.git')+'\n')
                self.tx['members'][0]['path']=str(destination);self.work=destination
        self.report=fixtures.gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx],self.records)
        self.digest=job.shadow.digest(self.report)
        row=self.report['repositories'][0];self.assertEqual(row['blockers'],[],row['blockers'])
        self.target=next(target for target in row['gate_paths'] if target['path']==str(self.work))
        if not arm:return
        self.ident=self.stage()['id'];self.base=self.vault/self.ident;self.scratch=self.base/'job-scratch';self.scratch.mkdir(mode=0o700)
        candidate=dict(repo_alias='fixture',path=str(self.work),identity=self.target['identity'],
            git_admin_path=str(self.admin),head=self.head,kind=self.target['kind'])
        self.selection=dict(version=1,gate_id=self.ident,gate_sha256=self.digest,approval_kind='exact-legacy-job',restore=True,
            candidates=[candidate],branches=[dict(repo_alias='fixture',ref='refs/heads/worker',tip=self.head,
                integration_ref='refs/heads/main',integration_tip=self.head)])
        self.binary=job.shadow.TRUSTED_GIT if sys.platform=='darwin' else '/usr/bin/git'
        job.arm(self.manager,self.selection,approved_selection_sha256=job.shadow.digest(self.selection),scratch_root=self.scratch)

    def advance(self):return job.advance(self.manager,self.ident,scratch_root=self.scratch,trusted_git=self.binary)

    def until(self,phase):
        for _ in range(14):
            value=job.status(self.manager,self.ident)
            if value['phase']==phase:return value
            value=self.advance();self.assertNotEqual(value['state'],'failed',value)
        self.fail('job did not reach '+phase)

    def artifact(self):
        item=job._read(self.base)['captures'][0]
        return Path(item['path']),json.loads((Path(item['path'])/'receipt.json').read_text())

    def test_orphan_index_is_preserved_before_registration_and_branch_retirement(self):
        self.ready();self.assertEqual(self.advance()['state'],'waiting-for-boot')
        self.current_boot=str(uuid.uuid4());self.until('complete')
        directory,receipt=self.artifact()
        self.assertEqual(receipt['capture_kind'],'orphan-admin-only');self.assertFalse(receipt['working_tree_bytes_present'])
        manifest=json.loads((directory/'manifest.json').read_text())
        self.assertTrue(all(name=='git-admin' or name.startswith('git-admin/') for name in manifest))
        self.assertIn('git-admin/index',manifest);self.assertIn('git-admin/unique-admin',manifest)
        self.assertFalse(self.admin.exists());self.assertFalse(self.work.exists())
        self.assertEqual(self.git('branch','--list','worker'),'')
        self.git('reflog','expire','--expire=now','--expire-unreachable=now','--all');self.git('gc','--prune=now')
        self.assertEqual(self.git('cat-file','blob',self.index_oid),'unique staged index object')
        state=json.loads((self.base/'retirement.json').read_text())
        self.assertFalse(state['result']['working_directory_reclaimed'])
        self.assertTrue(state['result']['registration_removed'])
        self.assertEqual(job._read(self.base)['captures'][0]['expiry']['state'],'retained')

    def test_locked_exact_terminal_worktree_keeps_lock_in_verified_capture(self):
        self.ready('locked');self.current_boot=str(uuid.uuid4());self.until('complete')
        directory,receipt=self.artifact();manifest=json.loads((directory/'manifest.json').read_text())
        self.assertEqual(receipt['capture_kind'],'full-worktree');self.assertTrue(receipt['working_tree_bytes_present'])
        self.assertIn('git-admin/locked',manifest);self.assertIn('worktree/file',manifest)
        self.assertFalse(self.work.exists());self.assertFalse(self.admin.exists())
        self.assertEqual(self.git('cat-file','blob',self.index_oid),'unique staged index object')

    def test_vanished_parent_container_is_pinned_without_creating_a_worktree(self):
        self.ready('missing-container');self.assertEqual(self.target['identity']['suffix'],'vanished/worker')
        self.current_boot=str(uuid.uuid4());self.until('complete')
        self.assertFalse(self.work.parent.exists());self.assertFalse(self.admin.exists())

    def test_recreated_logical_path_is_never_attributed_to_orphan(self):
        self.ready();self.current_boot=str(uuid.uuid4());self.work.mkdir();(self.work/'new-user-bytes').write_bytes(b'keep')
        value=self.advance();self.assertEqual(value['state'],'failed',value)
        self.assertIn('reappeared',value['last_error']);self.assertEqual((self.work/'new-user-bytes').read_bytes(),b'keep')
        self.assertEqual(job._read(self.base)['captures'],[])

    def test_recreated_path_after_handoff_preserves_new_bytes_admin_and_branch(self):
        self.ready();self.current_boot=str(uuid.uuid4());self.until('retirement')
        self.work.mkdir();(self.work/'new-owner-data').write_bytes(b'new unrelated bytes')
        value=self.advance();self.assertEqual(value['state'],'failed',value)
        self.assertIn('reappeared',value['last_error'])
        self.assertEqual((self.work/'new-owner-data').read_bytes(),b'new unrelated bytes')
        self.assertFalse((self.base/'retirement.json').exists())
        with self.manager.frozen_view(self.ident,approved_sha256=self.digest) as view:
            held_admin,_=capture._map(view,str(self.admin));self.assertTrue((held_admin/'index').is_file())
            self.assertEqual((held_admin/'unique-admin').read_bytes(),b'\x00unique administrative payload\xff')
            common=job.shadow._resolve(view,'fixture')
            self.assertEqual((common/'refs/heads/worker').read_text().strip(),self.head)
        self.assertTrue((self.artifact()[0]/'recovery.tar.gz').is_file())

    def test_recreated_intermediate_namespace_refuses_even_when_leaf_absent(self):
        self.ready('missing-container');self.current_boot=str(uuid.uuid4());self.work.parent.mkdir()
        value=self.advance();self.assertEqual(value['state'],'failed',value);self.assertIn('reappeared',value['last_error'])
        self.assertTrue(self.work.parent.is_dir())

    def test_orphan_requires_explicit_selection_kind(self):
        self.ready(arm=False);self.ident=self.stage()['id'];base=self.vault/self.ident;scratch=base/'job-scratch';scratch.mkdir(mode=0o700)
        selected=dict(repo_alias='fixture',path=str(self.work),identity=self.target['identity'],git_admin_path=str(self.admin),head=self.head)
        scope=dict(version=1,gate_id=self.ident,gate_sha256=self.digest,approval_kind='exact-legacy-job',restore=True,candidates=[selected],branches=[])
        with self.assertRaisesRegex(job.JobError,'candidate identity'):job.arm(self.manager,scope,approved_selection_sha256=job.shadow.digest(scope),scratch_root=scratch)
        self.assertFalse((base/'job.json').exists())

    def test_admin_only_receipt_cannot_masquerade_as_full_worktree(self):
        self.ready();self.current_boot=str(uuid.uuid4());self.until('handoff');directory,receipt=self.artifact()
        receipt.pop('capture_kind');(directory/'receipt.json').write_text(json.dumps(receipt))
        with self.manager.frozen_view(self.ident,approved_sha256=self.digest) as view:
            with self.assertRaisesRegex(capture.CaptureError,'capture kind'):
                capture.validate_capture(view,directory,self.scratch,self.binary)

    def test_orphan_partial_admin_unlink_replays_exact_remaining_registration(self):
        self.ready();self.current_boot=str(uuid.uuid4());self.until('retirement')
        original=Path.unlink;fired=[]
        def interrupt(path,*args,**kwargs):
            result=original(path,*args,**kwargs)
            if path.name=='gitdir' and 'content' in path.parts and not fired:
                fired.append(True);raise RuntimeError('lost orphan admin unlink response')
            return result
        with patch.object(Path,'unlink',interrupt):
            value=self.advance();self.assertEqual(value['state'],'failed',value)
        self.assertTrue(fired);self.until('complete');self.assertFalse(self.admin.exists())
        self.assertEqual(self.git('cat-file','blob',self.index_oid),'unique staged index object')

    def test_orphan_unknown_or_live_ownership_still_vetoes(self):
        self.ready(arm=False)
        for transactions,active in [([],[]),([self.tx],[str(self.work)])]:
            report=fixtures.gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},transactions,self.records,active_paths=active)
            row=report['repositories'][0];self.assertTrue(row['blockers'])
            with self.assertRaises(fixtures.gate.GateError):self.manager.stage(report,approved_sha256=job.shadow.digest(report))
            self.assertTrue(self.admin.exists())

    def test_foreign_or_traversing_admin_pointer_is_a_blocker(self):
        self.ready(arm=False)
        (self.admin/'gitdir').write_text(str(self.sources/'..'/'foreign'/'worker'/'.git')+'\n')
        report=fixtures.gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx],self.records)
        self.assertTrue(report['repositories'][0]['blockers'])
        self.assertFalse(report['repositories'][0]['inventory_complete'])

if __name__=='__main__':unittest.main()
