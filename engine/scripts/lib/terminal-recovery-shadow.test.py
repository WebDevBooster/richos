#!/usr/bin/env python3
"""Tiny real Git closure and additive ref preparation under a disposable gate."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import unittest
from unittest.mock import patch


def load(name, filename):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(filename))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


fixtures=load('recovery_fixtures','legacy-workspace-capture.test.py')
recovery=load('recovery','terminal-recovery-shadow.py')


class RecoveryRefs(unittest.TestCase):
    setUp=fixtures.Recovery.setUp
    git=fixtures.Recovery.git
    stage=fixtures.Recovery.stage
    ready=fixtures.Recovery.ready
    staged=fixtures.Recovery.staged

    def captured(self):
        self.ready()
        self.capture=fixtures.capture.prepare(self.manager,self.ident,approved_gate_sha256=self.digest,
            repo_alias='fixture',candidate_path=str(self.work),scratch_root=self.scratch,trusted_git=self.binary)
        self.capture_path=Path(self.capture['artifact_path'])
        observed=recovery.shadow.observe(self.manager,self.ident,approved_gate_sha256=self.digest,
            repo_alias='fixture',scratch_root=self.scratch,trusted_git=self.binary)
        self.selection={key:observed[key] for key in ('version','gate_id','gate_sha256','repo_alias','ref_snapshot_sha256','registry_sha256')}
        receipt=json.loads((self.capture_path/'receipt.json').read_text())
        self.selection.update(capture_path=str(self.capture_path),capture_receipt_sha256=recovery.shadow.digest(receipt),approval_kind='exact-captured-recovery')
        self.approved=recovery.shadow.digest(self.selection)
        with self.manager.frozen_view(self.ident,approved_sha256=self.digest) as view:
            self.common=recovery.shadow._resolve(view,'fixture')
        self.original=recovery.shadow._metadata(self.common)

    def prepare(self):
        return recovery.prepare(self.manager,self.selection,approved_selection_sha256=self.approved,
            scratch_root=self.scratch,trusted_git=self.binary)

    def test_additive_refs_pin_staged_blob_and_commit_without_held_changes(self):
        self.staged();self.captured();result=self.prepare()
        self.assertEqual(recovery.shadow._metadata(self.common),self.original)
        preserved={row['oid']:row for row in result['preserved_objects']}
        self.assertEqual(preserved[self.staged_oid]['type'],'blob')
        self.assertEqual(preserved[self.head]['type'],'commit')
        self.assertTrue(result['transitive_closure_verified'])
        self.assertEqual(result['retired_branches'],[])
        self.assertFalse(result['registration_removal_authorized'])
        self.assertFalse(result['held_storage_modified'])
        for change in result['changes']:
            self.assertIsNone(change['before'])
            self.assertTrue(change['path'].startswith('refs/richos/recovery/'+self.ident+'/'))
            self.assertTrue((Path(result['artifact_path'])/'after'/change['path']).is_file())
        self.assertFalse(any(p.name=='objects' for p in Path(result['artifact_path']).rglob('*')))

    def test_reflog_tree_and_per_worktree_ref_endpoints_are_all_pinned(self):
        self.git('-C',str(self.work),'commit','--allow-empty','-qm','later detached endpoint')
        later=self.git('-C',str(self.work),'rev-parse','HEAD')
        self.git('-C',str(self.work),'reset','--hard',self.head)
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        tree=self.git('rev-parse','HEAD^{tree}')
        (admin/'AUTO_MERGE').write_text(tree+'\n')
        (admin/'refs/worktree').mkdir(parents=True)
        (admin/'refs/worktree/retained').write_text(later+'\n')
        self.captured();result=self.prepare()
        preserved={row['oid']:row for row in result['preserved_objects']}
        self.assertEqual(preserved[tree]['type'],'tree')
        self.assertIn(later,preserved)
        self.assertTrue(any('logs/' in reason for reason in preserved[later]['sources']))

    def test_caller_omitted_dependency_is_refused_after_independent_revalidation(self):
        self.staged();self.captured()
        path=self.capture_path/'receipt.json';receipt=json.loads(path.read_text())
        receipt['dependencies']['required_objects']=[row for row in receipt['dependencies']['required_objects'] if row['oid']!=self.staged_oid]
        path.write_text(json.dumps(receipt))
        self.selection['capture_receipt_sha256']=recovery.shadow.digest(receipt)
        self.approved=recovery.shadow.digest(self.selection)
        with self.assertRaises(Exception):self.prepare()
        self.assertEqual(recovery.shadow._metadata(self.common),self.original)

    def test_missing_transitive_tree_refuses_even_when_endpoint_commit_exists(self):
        tree=self.git('rev-parse','HEAD^{tree}')
        common=Path(self.git('rev-parse','--absolute-git-dir'))
        # Corruption predates the gate, so its inventory is valid. The capture
        # lists the existing HEAD commit but not this tree.
        (common/'objects'/tree[:2]/tree[2:]).unlink()
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        (admin/'index').unlink()  # No direct TREE cache endpoint can mask closure traversal.
        self.captured()
        with self.assertRaisesRegex(recovery.RecoveryError,'incomplete captured object closure'):self.prepare()
        self.assertEqual(recovery.shadow._metadata(self.common),self.original)

    def test_unparsed_state_and_external_gitlinks_refuse(self):
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        (admin/'FETCH_HEAD').write_text(self.head+'\t\tfixture\n')
        self.captured()
        with self.assertRaisesRegex(recovery.RecoveryError,'unresolved or external'):self.prepare()

    def test_gitlink_dependency_is_not_mistaken_for_local_object(self):
        self.git('-C',str(self.work),'update-index','--add','--cacheinfo','160000',self.head,'external')
        self.captured()
        with self.assertRaisesRegex(recovery.RecoveryError,'unresolved or external'):self.prepare()

    def test_source_config_and_hooks_are_never_executed(self):
        common=Path(self.git('rev-parse','--absolute-git-dir'))
        hook=common/'hooks/reference-transaction'
        hook.write_text('#!/bin/sh\nexit 99\n');hook.chmod(0o755)
        self.captured()
        (self.common/'config').write_text('[invalid config\n')
        result=self.prepare()
        self.assertTrue(result['preserved_objects'])

    def test_changed_capture_archive_or_source_is_refused(self):
        self.captured();archive=self.capture_path/'recovery.tar.gz'
        archive.write_bytes(b'corrupted archive')
        with self.assertRaises(Exception):self.prepare()
        self.assertEqual(recovery.shadow._metadata(self.common),self.original)

    def test_wrong_approval_changed_ref_snapshot_and_closed_gate_refuse(self):
        self.captured();approved=self.approved;self.approved='wrong'
        with self.assertRaises(recovery.RecoveryError):self.prepare()
        self.approved=approved
        (self.common/'refs/heads/unrelated').write_text(self.head+'\n')
        with self.assertRaises(Exception):self.prepare()
        (self.common/'refs/heads/unrelated').unlink()
        self.manager.restore(self.ident,approved_sha256=self.digest)
        with self.assertRaises(Exception):self.prepare()

    def test_capture_symlink_and_writable_receipt_refuse(self):
        self.captured();link=self.scratch/'alias';link.symlink_to(self.capture_path,target_is_directory=True)
        self.selection['capture_path']=str(link);self.approved=recovery.shadow.digest(self.selection)
        with self.assertRaisesRegex(recovery.RecoveryError,'canonical'):self.prepare()
        self.selection['capture_path']=str(self.capture_path);self.approved=recovery.shadow.digest(self.selection)
        (self.capture_path/'receipt.json').chmod(0o666)
        with self.assertRaisesRegex(recovery.RecoveryError,'protected'):self.prepare()

    def test_selection_is_bounded_before_hash_or_capture_read(self):
        self.captured();self.selection['capture_path']='x'*4097
        with patch.object(recovery.shadow,'digest',side_effect=AssertionError('hashed before bound')):
            with self.assertRaisesRegex(recovery.RecoveryError,'bounded'):self.prepare()


if __name__=='__main__':unittest.main(verbosity=2)
