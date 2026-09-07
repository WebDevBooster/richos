#!/usr/bin/env python3
"""Real-file refusal and interruption controls for private replay-copy release."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
import uuid
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('mutation',Path(__file__).with_name('legacy-workspace-mutation.py'))
mutation=importlib.util.module_from_spec(spec);spec.loader.exec_module(mutation)
spec=importlib.util.spec_from_file_location('gate',Path(__file__).with_name('legacy-workspace-gate.py'))
gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(gate)

class SnapshotRelease(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='snapshot-release-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve();self.base=self.root/str(uuid.uuid4());self.base.mkdir(mode=0o700)
        self.directory=self.base/'mutation-data';self.directory.mkdir(mode=0o700)
        self.path=self.directory/'original-metadata.jsonl';mutation._atomic(self.path,b'original whole-gate replay preimage\n')
        self.journal=dict(version=1,phase='complete',gate_id=self.base.name,
                          original_metadata_snapshot=mutation._snapshot_digest(self.path))
        self.marker=self.base/'mutation.json';mutation._save(self.marker,self.journal)
        self.authority=SimpleNamespace(uid=os.geteuid(),_no_acl=gate.LegacyGate._no_acl)
        self.bytes=self.path.read_bytes()
    def release(self):
        mutation._release_completed_snapshot(self.authority,self.base,'mutation.json',self.journal)
    def test_incomplete_operation_keeps_its_only_replay_preimage(self):
        self.journal['phase']='applying';mutation._save(self.marker,self.journal)
        with self.assertRaises(mutation.MutationError):self.release()
        self.assertEqual(self.path.read_bytes(),self.bytes)
    def test_historical_operation_is_not_retroactively_authorized(self):
        self.journal.pop('original_metadata_snapshot');mutation._save(self.marker,self.journal)
        self.release();self.assertEqual(self.path.read_bytes(),self.bytes)
    def test_tampered_snapshot_refuses_without_release_intent(self):
        self.path.write_bytes(b'changed bytes')
        with self.assertRaises(mutation.MutationError):self.release()
        self.assertEqual(self.path.read_bytes(),b'changed bytes')
        self.assertNotIn('metadata_snapshot_release',json.loads(self.marker.read_text()))
    def test_external_hardlink_is_never_unlinked(self):
        outside=self.root/'outside';os.link(self.path,outside)
        with self.assertRaises(mutation.MutationError):self.release()
        self.assertEqual(outside.read_bytes(),self.bytes);self.assertTrue(self.path.exists())
    def test_substituted_directory_symlink_cannot_reach_outside_file(self):
        outside=self.root/'outside';self.directory.rename(outside);self.directory.symlink_to(outside,target_is_directory=True)
        with self.assertRaises(mutation.MutationError):self.release()
        self.assertEqual((outside/self.path.name).read_bytes(),self.bytes)
    def test_missing_without_intent_is_not_treated_as_completed_release(self):
        self.path.unlink()
        with self.assertRaises(mutation.MutationError):self.release()
        self.assertNotIn('metadata_snapshot_release',json.loads(self.marker.read_text()))
    def test_release_intent_crash_retries_before_unlink(self):
        real=mutation._save
        def crash(path,value):
            real(path,value)
            if value.get('metadata_snapshot_release',{}).get('state')=='authorized':raise RuntimeError('intent crash')
        with patch.object(mutation,'_save',side_effect=crash),self.assertRaises(RuntimeError):self.release()
        self.assertEqual(self.path.read_bytes(),self.bytes)
        self.journal=json.loads(self.marker.read_text());self.release();self.release()
        self.assertFalse(self.path.exists())
    def test_reappearing_copy_is_retained_as_an_unexpected_new_object(self):
        self.release();mutation._atomic(self.path,self.bytes)
        with self.assertRaises(mutation.MutationError):self.release()
        self.assertEqual(self.path.read_bytes(),self.bytes)
    def test_replay_syncs_an_already_unlinked_copy_before_marking_released(self):
        real_sync=mutation._sync;real_save=mutation._save
        def crash(path):
            if path==self.directory:raise RuntimeError('before directory sync')
            real_sync(path)
        with patch.object(mutation,'_sync',side_effect=crash),self.assertRaises(RuntimeError):self.release()
        self.assertFalse(self.path.exists())
        self.journal=json.loads(self.marker.read_text());self.assertEqual(self.journal['metadata_snapshot_release']['state'],'authorized')
        events=[]
        def sync(path):
            if path==self.directory:events.append('directory synced')
            real_sync(path)
        def save(path,value):
            if value.get('metadata_snapshot_release',{}).get('state')=='released':events.append('released marker')
            real_save(path,value)
        with patch.object(mutation,'_sync',side_effect=sync),patch.object(mutation,'_save',side_effect=save):self.release()
        self.assertEqual(events,['directory synced','released marker'])
    def test_unrelated_recovery_payloads_and_effective_inventory_remain(self):
        other=self.directory/'before';other.mkdir();(other/'ref').write_bytes(b'old ref bytes')
        effective=self.base/'metadata.jsonl';effective.write_bytes(b'current effective gate inventory')
        self.release()
        self.assertEqual((other/'ref').read_bytes(),b'old ref bytes')
        self.assertEqual(effective.read_bytes(),b'current effective gate inventory')
        self.assertEqual(json.loads(self.marker.read_text())['metadata_snapshot_release']['sha256'],self.journal['original_metadata_snapshot']['sha256'])

if __name__=='__main__':unittest.main()
