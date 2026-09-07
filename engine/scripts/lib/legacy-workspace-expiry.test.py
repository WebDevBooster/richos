#!/usr/bin/env python3
"""Actual tiny linked-worktree clean proof, recovery publication and expiry."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import sys
import time
import unittest
import uuid
from unittest.mock import patch


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

fixtures=load('legacy-workspace-gate.test');expiry=load('legacy-workspace-expiry')
retirement=load('legacy-workspace-retirement');shadow=expiry.shadow


class Expiry(unittest.TestCase):
    setUp=fixtures.GateWorkflow.setUp
    git=fixtures.GateWorkflow.git
    stage=fixtures.GateWorkflow.stage

    def prepare(self,change=None):
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        (admin/'custom-state').write_bytes(b'\x00unique admin bytes\xff')
        if change:change(admin)
        self.ident=self.stage()['id'];self.current_boot=str(uuid.uuid4())
        self.scratch=self.vault/self.ident/'scratch';self.scratch.mkdir(mode=0o700)
        self.binary=shadow.TRUSTED_GIT if sys.platform=='darwin' else '/usr/bin/git'
        artifact=expiry.capture.prepare(self.manager,self.ident,approved_gate_sha256=self.digest,repo_alias='fixture',
            candidate_path=str(self.work),scratch_root=self.scratch,trusted_git=self.binary)
        self.directory=Path(artifact['artifact_path'])
        self.receipt=json.loads((self.directory/'receipt.json').read_text());self.receipt_hash=shadow.digest(self.receipt)
        self.args=dict(approved_gate_sha256=self.digest,repo_alias='fixture',capture_path=str(self.directory),
            capture_receipt_sha256=self.receipt_hash,scratch_root=self.scratch,trusted_git=self.binary)
        self.proof=expiry.prepare(self.manager,self.ident,**self.args)
        return self.proof

    def retire_restore(self):
        observed=shadow.observe(self.manager,self.ident,approved_gate_sha256=self.digest,repo_alias='fixture',
            scratch_root=self.scratch,trusted_git=self.binary)
        selected={key:observed[key] for key in ('version','gate_id','gate_sha256','repo_alias','ref_snapshot_sha256','registry_sha256')}
        selected.update(capture_path=str(self.directory),capture_receipt_sha256=self.receipt_hash,approval_kind='exact-captured-recovery')
        retirement.mutation.publish_recovery(self.manager,selected,approved_selection_sha256=shadow.digest(selected),
            scratch_root=self.scratch,trusted_git=self.binary)
        selected={key:selected[key] for key in ('version','gate_id','gate_sha256','repo_alias','capture_path','capture_receipt_sha256')}
        selected['approval_kind']='exact-captured-retirement'
        retirement.retire(self.manager,selected,approved_selection_sha256=shadow.digest(selected),scratch_root=self.scratch,trusted_git=self.binary)
        self.manager.restore(self.ident,approved_sha256=self.digest)

    def expire(self,**kw):
        args={key:value for key,value in self.args.items() if key!='scratch_root'}
        args.update(proof_sha256=self.proof['proof_sha256'],retention_days=1,now=time.time()+86401);args.update(kw)
        return expiry.expire(self.manager,self.ident,**args)

    def test_clean_expiry_preserves_metadata_and_git_admin_bytes(self):
        self.assertEqual(self.prepare()['state'],'clean-prepared',self.proof)
        self.retire_restore();result=self.expire()
        self.assertEqual(result['state'],'expired');self.assertFalse((self.directory/'recovery.tar.gz').exists())
        compact=json.loads((self.directory/'compact-metadata.json').read_text())
        self.assertEqual(base64.b64decode(compact['contents']['git-admin/custom-state']),b'\x00unique admin bytes\xff')
        self.assertIn('worktree/.git',compact['contents']);self.assertIn('worktree/file',compact['manifest'])
        self.assertEqual(self.expire()['state'],'expired')

    def test_extra_working_bytes_retain_archive(self):
        result=self.prepare(lambda _: (self.work/'ignored-but-unique').write_bytes(b'unique'))
        self.assertEqual(result['state'],'retained',result)
        self.assertIn('extra or missing',result['reason']);self.assertFalse((self.directory/'clean-expiry.json').exists())

    def test_working_change_retains_archive(self):
        result=self.prepare(lambda _: (self.work/'file').write_text('unique working bytes'))
        self.assertEqual(result['state'],'retained',result)
        self.assertIn('working changes',result['reason'])

    def test_staged_change_retains_archive(self):
        def staged(_):
            (self.work/'file').write_text('unique staged bytes');self.git('-C',str(self.work),'add','file')
        result=self.prepare(staged)
        self.assertEqual(result['state'],'retained',result);self.assertIn('staged changes',result['reason'])

    def test_hidden_index_flag_retains_archive(self):
        result=self.prepare(lambda _: self.git('-C',str(self.work),'update-index','--assume-unchanged','file'))
        self.assertEqual(result['state'],'retained',result);self.assertIn('hidden index flags',result['reason'])

    def test_prepare_retries_exact_proof(self):
        self.prepare();self.assertEqual(expiry.prepare(self.manager,self.ident,**self.args),self.proof)

    def test_retention_and_restore_boundaries(self):
        self.prepare()
        with self.assertRaisesRegex(expiry.ExpiryError,'restoration'):self.expire()
        self.retire_restore();self.assertEqual(self.expire(now=time.time())['state'],'waiting-retention')
        self.assertTrue((self.directory/'recovery.tar.gz').exists())

    def test_sidecar_tamper_refuses_bulk_unlink(self):
        self.prepare();self.retire_restore()
        (self.directory/'compact-metadata.json').write_text('tampered')
        with self.assertRaisesRegex(expiry.ExpiryError,'metadata changed'):self.expire()
        self.assertTrue((self.directory/'recovery.tar.gz').exists())

    def test_missing_ref_refuses_bulk_unlink(self):
        self.prepare();self.retire_restore()
        oid=self.receipt['dependencies']['required_objects'][0]['oid']
        ref='refs/richos/recovery/'+self.ident+'/'+self.receipt_hash+'/'+oid
        self.git('update-ref','-d',ref)
        with self.assertRaisesRegex(expiry.ExpiryError,'direct ref'):self.expire()
        self.assertTrue((self.directory/'recovery.tar.gz').exists())

    def test_same_tip_symbolic_recovery_ref_refuses_expiry(self):
        self.prepare();self.retire_restore()
        oid=self.head
        ref='refs/richos/recovery/'+self.ident+'/'+self.receipt_hash+'/'+oid
        self.git('update-ref','refs/heads/mutable-target',oid)
        self.git('symbolic-ref',ref,'refs/heads/mutable-target')
        with self.assertRaisesRegex(expiry.ExpiryError,'direct ref'):self.expire()
        self.assertTrue((self.directory/'recovery.tar.gz').exists())

    def test_unlink_lost_response_replays(self):
        self.prepare();self.retire_restore();original=expiry.mutation._sync
        def fail_after_unlink(path):
            if path==self.directory and not (path/'recovery.tar.gz').exists():raise RuntimeError('lost unlink response')
            return original(path)
        with patch.object(expiry.mutation,'_sync',side_effect=fail_after_unlink):
            with self.assertRaisesRegex(RuntimeError,'lost unlink'):self.expire()
        self.assertFalse((self.directory/'recovery.tar.gz').exists())
        self.assertEqual(self.expire()['state'],'expired')

    def test_lost_archive_without_intent_is_refused(self):
        self.prepare();self.retire_restore();(self.directory/'recovery.tar.gz').unlink()
        with self.assertRaisesRegex(expiry.ExpiryError,'without expiry intent'):self.expire()

    def test_metadata_budget_retains_bulk(self):
        with patch.object(expiry.metadata,'MAX_BYTES',16):result=self.prepare()
        self.assertEqual(result['state'],'retained',result);self.assertIn('budget',result['reason'])

if __name__=='__main__':unittest.main()
