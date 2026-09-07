#!/usr/bin/env python3
"""Tiny real-Git capture, handoff, removal and interruption fixtures."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest
import uuid
from unittest.mock import patch

def load(file):
    spec=importlib.util.spec_from_file_location(file,Path(__file__).with_name(file+'.py'))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod

fixtures=load('legacy-workspace-gate.test');retirement=load('legacy-workspace-retirement')
capture=retirement.capture;mutation=retirement.mutation;shadow=retirement.shadow

class Retirement(unittest.TestCase):
    setUp=fixtures.GateWorkflow.setUp
    git=fixtures.GateWorkflow.git
    stage=fixtures.GateWorkflow.stage

    def prepare(self, *, handoff=True, resolve_undo=False):
        self.undo_objects={}
        if resolve_undo:
            env={'PATH':'/usr/bin:/bin','HOME':'/var/empty','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'}
            for value in ('unique conflict base','unique conflict ours','unique conflict theirs'):
                oid=subprocess.check_output(['/usr/bin/git','-C',str(self.work),'hash-object','-w','--stdin'],input=value.encode(),env=env).decode().strip()
                self.undo_objects[oid]=value
            lines=['0 '+'0'*40+'\tfile']+['100644 '+oid+' '+str(stage)+'\tfile' for stage,oid in enumerate(self.undo_objects,1)]
            subprocess.run(['/usr/bin/git','-C',str(self.work),'update-index','--index-info'],input=('\n'.join(lines)+'\n').encode(),env=env,check=True)
        (self.work/'file').write_text('staged unique bytes')
        subprocess.run(['/usr/bin/git','-C',str(self.work),'add','file'],check=True)
        self.staged_oid=self.git('-C',str(self.work),'rev-parse',':file')
        (self.work/'file').write_text('working unique bytes')
        (self.work/'untracked').write_text('untracked unique bytes')
        self.ident=self.stage()['id'];self.current_boot=str(uuid.uuid4())
        self.base=self.vault/self.ident;self.scratch=self.base/'recovery';self.scratch.mkdir(mode=0o700)
        self.binary=shadow.TRUSTED_GIT if sys.platform=='darwin' else '/usr/bin/git'
        self.artifact=capture.prepare(self.manager,self.ident,approved_gate_sha256=self.digest,repo_alias='fixture',
            candidate_path=str(self.work),scratch_root=self.scratch,trusted_git=self.binary)
        path=self.artifact['artifact_path'];receipt=json.loads((Path(path)/'receipt.json').read_text());receipt_hash=shadow.digest(receipt)
        self.selection=dict(version=1,gate_id=self.ident,gate_sha256=self.digest,repo_alias='fixture',capture_path=path,
                            capture_receipt_sha256=receipt_hash,approval_kind='exact-captured-retirement')
        self.approved=shadow.digest(self.selection)
        if handoff:
            observed=shadow.observe(self.manager,self.ident,approved_gate_sha256=self.digest,repo_alias='fixture',
                                    scratch_root=self.scratch,trusted_git=self.binary)
            selected={key:observed[key] for key in ('version','gate_id','gate_sha256','repo_alias','ref_snapshot_sha256','registry_sha256')}
            selected.update(capture_path=path,capture_receipt_sha256=receipt_hash,approval_kind='exact-captured-recovery')
            mutation.publish_recovery(self.manager,selected,approved_selection_sha256=shadow.digest(selected),
                                      scratch_root=self.scratch,trusted_git=self.binary)

    def retire(self):
        return retirement.retire(self.manager,self.selection,approved_selection_sha256=self.approved,
                                 scratch_root=self.scratch,trusted_git=self.binary)

    def replay(self):
        return retirement.replay(self.manager,self.ident,approved_selection_sha256=self.approved,
                                 scratch_root=self.scratch,trusted_git=self.binary)

    def test_verified_dirty_capture_reclaims_workspace_and_keeps_recovery(self):
        self.prepare();result=self.retire()
        self.assertTrue(result['working_directory_reclaimed']);self.assertTrue(Path(self.artifact['artifact_path']).is_dir())
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertFalse(self.work.exists());self.assertNotIn(str(self.work),self.git('worktree','list','--porcelain'))
        self.assertEqual(self.git('rev-parse','worker'),self.head)
        receipt=json.loads((Path(self.artifact['artifact_path'])/'receipt.json').read_text())
        for dependency in receipt['dependencies']['required_objects']:
            self.assertTrue(self.git('cat-file','-t',dependency['oid']))

    def test_recovery_refs_preserve_unique_index_and_resolve_undo_bytes_after_gc(self):
        self.prepare(resolve_undo=True);self.retire()
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertFalse(self.work.exists());self.assertNotIn(str(self.work),self.git('worktree','list','--porcelain'))
        receipt=json.loads((Path(self.artifact['artifact_path'])/'receipt.json').read_text())
        dependencies={row['oid']:row['sources'] for row in receipt['dependencies']['required_objects']}
        expected=dict(self.undo_objects);expected[self.staged_oid]='staged unique bytes'
        ordinary_reachable=set(self.git('rev-list','--objects','--no-object-names','refs/heads/main','refs/heads/worker').splitlines())
        for oid in expected:
            self.assertNotIn(oid,ordinary_reachable)
            self.assertIn(oid,dependencies)
            ref='refs/richos/recovery/'+self.ident+'/'+self.selection['capture_receipt_sha256']+'/'+oid
            self.assertEqual(self.git('rev-parse',ref),oid)
        for oid in self.undo_objects:self.assertTrue(any('resolve-undo' in reason for reason in dependencies[oid]))
        # Expire reflogs and prune immediately in this disposable repository.
        # Recovery refs must carry these blobs after both index and registration
        # are gone, rather than depending on age grace or branch reachability.
        unpinned=subprocess.check_output(['/usr/bin/git','-C',str(self.repo),'hash-object','-w','--stdin'],input=b'unpinned control blob',env={'PATH':'/usr/bin:/bin','HOME':'/var/empty','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'}).decode().strip()
        self.git('reflog','expire','--expire=now','--expire-unreachable=now','--all')
        self.git('gc','--prune=now')
        with self.assertRaises(subprocess.CalledProcessError):self.git('cat-file','-e',unpinned)
        for oid,value in expected.items():self.assertEqual(self.git('cat-file','blob',oid),value)
        for row in receipt['dependencies']['required_objects']:self.assertTrue(self.git('cat-file','-t',row['oid']))

    def test_missing_handoff_prevents_any_unlink(self):
        self.prepare(handoff=False)
        with self.assertRaisesRegex(retirement.RetirementError,'recovery ref'):self.retire()
        self.assertFalse((self.base/'retirement.json').exists())
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual((self.work/'file').read_text(),'working unique bytes')

    def test_corrupted_archive_prevents_any_unlink(self):
        self.prepare();(Path(self.artifact['artifact_path'])/'recovery.tar.gz').write_bytes(b'corrupt')
        with self.assertRaises(Exception):self.retire()
        self.assertFalse((self.base/'retirement.json').exists())
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertTrue((self.work/'untracked').exists())

    def test_crash_after_first_unlink_blocks_restore_then_replays(self):
        self.prepare();real=Path.unlink;fired=[]
        def crash(path,*args,**kwargs):
            real(path,*args,**kwargs)
            if self.base in path.parents and 'content' in path.parts and not fired:
                fired.append(True);raise RuntimeError('unlink crash')
        with patch.object(Path,'unlink',crash),self.assertRaisesRegex(RuntimeError,'unlink'):self.retire()
        with self.assertRaises(Exception):self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertTrue(self.replay()['working_directory_reclaimed'])
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertFalse(self.work.exists())

    def test_crash_after_effective_metadata_receipt_replays(self):
        self.prepare();real=mutation._atomic;fired=[]
        def crash(path,data,**kwargs):
            real(path,data,**kwargs)
            if path==self.base/'metadata.jsonl' and not fired:
                fired.append(True);raise RuntimeError('metadata crash')
        with patch.object(mutation,'_atomic',side_effect=crash),self.assertRaisesRegex(RuntimeError,'metadata'):self.retire()
        self.assertEqual(self.replay()['phase'],'complete')
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertFalse(self.work.exists())

    def test_partial_registration_without_gitdir_is_replayable(self):
        self.prepare();real=Path.unlink;fired=[]
        def crash(path,*args,**kwargs):
            real(path,*args,**kwargs)
            if 'content' in path.parts and path.name=='gitdir' and not fired:
                fired.append(True);raise RuntimeError('gitdir unlink crash')
        with patch.object(Path,'unlink',crash),self.assertRaisesRegex(RuntimeError,'gitdir'):self.retire()
        with self.assertRaises(Exception):self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual(self.replay()['phase'],'complete')
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertFalse(self.work.exists())

    def test_retired_source_recreated_by_user_is_preserved_during_restore(self):
        self.prepare();self.retire();self.work.mkdir();(self.work/'new-work').write_text('new owner bytes')
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual((self.work/'new-work').read_text(),'new owner bytes')

if __name__=='__main__':unittest.main()
