#!/usr/bin/env python3
"""Tiny real-Git shadow transactions. No copied objects or live gate mutation."""
import contextlib
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

spec=importlib.util.spec_from_file_location('shadow',Path(__file__).with_name('terminal-branch-shadow.py'))
shadow=importlib.util.module_from_spec(spec);spec.loader.exec_module(shadow)
BINARY=shadow.TRUSTED_GIT if sys.platform=='darwin' else shutil.which('git')


class FakeGate:
    require_root=False
    def __init__(self,view):
        self.view=view;self.entered=0;self.closed=False
    @contextlib.contextmanager
    def frozen_view(self,ident,*,approved_sha256):
        if self.closed or ident!=self.view['id'] or approved_sha256!=self.view['approved_sha256']:
            raise RuntimeError('gate is not a verified frozen context')
        self.entered+=1
        try:yield self.view
        finally:self.entered-=1


class BranchShadow(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='terminal-branch-shadow-');self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve();self.repo=self.root/'held';self.scratch=self.root/'scratch';self.scratch.mkdir(mode=0o700)
        self.git('init','-q','-b','main',self.repo)
        self.git('-C',self.repo,'config','user.name','fixture');self.git('-C',self.repo,'config','user.email','fixture@example.invalid')
        (self.repo/'file').write_text('base');self.git('-C',self.repo,'add','.');self.git('-C',self.repo,'commit','-qm','base')
        self.tip=self.git('-C',self.repo,'rev-parse','HEAD').strip()
        for name in ('completed','unrelated','another'):
            self.git('-C',self.repo,'branch',name)
        self.git('-C',self.repo,'pack-refs','--all','--prune')
        self.common=self.repo/'.git';self.ident=str(uuid.uuid4());self.approval='a'*64
        self.view={'id':self.ident,'approved_sha256':self.approval,'plan':{'repositories':[
            {'alias':'repo','common_git_directory':{'path':'/approved/repo/.git'}}]},
            'roots':[{'source':'/approved/repo','held_path':str(self.repo)}]}
        self.gate=FakeGate(self.view)

    def git(self,*args):
        return subprocess.run([BINARY,*map(str,args)],cwd=self.root,
            env={'PATH':'/usr/bin:/bin','HOME':'/var/empty','LC_ALL':'C','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'},
            check=True,capture_output=True).stdout.decode()

    def observation(self):
        return shadow.observe(self.gate,self.ident,approved_gate_sha256=self.approval,repo_alias='repo',
                              scratch_root=self.scratch,trusted_git=BINARY)

    def selection(self,branches=('completed',)):
        seen=self.observation()
        return {key:seen[key] for key in ('version','gate_id','gate_sha256','repo_alias','ref_snapshot_sha256','registry_sha256')} | {
            'approval_kind':'exact-frozen-selection',
            'branches':[{'ref':'refs/heads/'+name,'tip':seen['refs']['refs/heads/'+name]['oid'],
                         'integration_ref':'refs/heads/main','integration_tip':seen['refs']['refs/heads/main']['oid']} for name in branches]}

    def prepare(self,selection):
        return shadow.prepare(self.gate,selection,approved_selection_sha256=shadow.digest(selection),
                              scratch_root=self.scratch,trusted_git=BINARY)

    def source_files(self):
        return {p.relative_to(self.common).as_posix():p.read_bytes() for p in self.common.rglob('*') if p.is_file()}

    def test_exact_retiring_admin_exclusion_preserves_other_registry_checks(self):
        for name in ('retiring','remaining'):
            self.git('-C',self.repo,'worktree','add','-qb',name,self.root/name)
        admin=self.common/'worktrees/retiring'
        (admin/'gitdir').unlink()
        with self.assertRaises(Exception):self.observation()
        with tempfile.TemporaryDirectory(dir=self.scratch) as temp:
            _,_,registry,_=shadow._shadow(self.common,Path(temp)/'view.git',BINARY,
                                          excluded_admin_names=('retiring',))
        self.assertEqual({row['path'] for row in registry},{'HEAD','worktrees/remaining/HEAD'})
        (self.common/'worktrees/remaining/HEAD').unlink()
        with self.assertRaises(Exception):shadow._registry(self.common,excluded_admin_names=('retiring',))

    def test_admin_exclusion_refuses_traversal_multiple_names_and_symlink_entry(self):
        for names in ('worker',('../worker',),('.',),('a','b'),('a/b',),('a\0b',)):
            with self.subTest(names=names),self.assertRaises(shadow.ShadowError):
                shadow._registry(self.common,excluded_admin_names=names)
        (self.common/'worktrees').mkdir()
        (self.common/'worktrees/retiring').symlink_to(self.root,target_is_directory=True)
        with self.assertRaisesRegex(shadow.ShadowError,'malformed worktree registry'):
            shadow._registry(self.common,excluded_admin_names=('retiring',))

    def test_packed_branch_transaction_preserves_unrelated_refs_and_held_bytes(self):
        selection=self.selection();before=self.source_files()
        result=self.prepare(selection)
        self.assertFalse(result['held_storage_modified']);self.assertFalse(result['publication_implemented'])
        self.assertFalse(result['execution_authorized']);self.assertEqual(self.source_files(),before)
        paths={change['path'] for change in result['changes']}
        self.assertEqual(paths,{'packed-refs','logs/refs/heads/completed','refs/richos/retired/'+self.ident+'/refs/heads/completed'})
        self.assertIn(b'refs/heads/unrelated',(Path(result['artifact_path'])/'after/packed-refs').read_bytes())
        self.assertFalse((Path(result['artifact_path'])/'view.git').exists())
        self.assertFalse(any(p.name=='objects' for p in self.scratch.rglob('*')))
        self.assertEqual(self.gate.entered,0)

    def test_shared_integration_verified_once_for_multiple_branches(self):
        result=self.prepare(self.selection(('completed','another')))
        self.assertEqual(len(result['retired_branches']),2)
        self.assertIn(b'refs/heads/unrelated',(Path(result['artifact_path'])/'after/packed-refs').read_bytes())

    def test_original_config_and_hooks_are_never_loaded(self):
        (self.common/'config').write_text('this is not valid Git configuration')
        marker=self.root/'executed'
        hook=self.common/'hooks/reference-transaction';hook.write_text('#!/bin/sh\ntouch '+str(marker)+'\n');hook.chmod(0o755)
        self.assertEqual(len(self.prepare(self.selection())['retired_branches']),1)
        self.assertFalse(marker.exists())

    def test_wrong_approval_or_restored_gate_cannot_prepare(self):
        selection=self.selection()
        with self.assertRaises(shadow.ShadowError):
            shadow.prepare(self.gate,selection,approved_selection_sha256='bad',scratch_root=self.scratch,trusted_git=BINARY)
        self.gate.closed=True
        with self.assertRaises(RuntimeError):self.prepare(selection)
        self.assertEqual(list(self.scratch.iterdir()),[])

    def test_legacy_plan_eligibility_is_not_generation_authorization(self):
        selection=self.selection();selection['approval_kind']='eligible-plan-only'
        with self.assertRaises(shadow.ShadowError):self.prepare(selection)

    def test_branch_tip_change_since_snapshot_refuses(self):
        selection=self.selection()
        self.git('-C',self.repo,'update-ref','refs/heads/new-ref',self.tip)
        with self.assertRaisesRegex(shadow.ShadowError,'changed since approval'):self.prepare(selection)

    def test_new_attachment_after_snapshot_and_existing_attachment_both_refuse(self):
        selection=self.selection();work=self.root/'attached'
        self.git('-C',self.repo,'worktree','add','-q',work,'completed')
        with self.assertRaisesRegex(shadow.ShadowError,'changed since approval'):self.prepare(selection)
        with self.assertRaisesRegex(shadow.ShadowError,'checked out'):self.prepare(self.selection())

    def test_indirect_symbolic_head_still_attaches_target_branch(self):
        self.git('-C',self.repo,'symbolic-ref','refs/heads/indirect','refs/heads/completed')
        (self.common/'HEAD').write_text('ref: refs/heads/indirect\n')
        with self.assertRaisesRegex(shadow.ShadowError,'checked out'):
            self.prepare(self.selection())

    def test_malformed_registered_head_name_is_not_ignored(self):
        (self.common/'HEAD').write_text('ref: refs/heads/not a valid ref\n')
        with self.assertRaises(shadow.ShadowError):self.selection()

    def test_missing_registry_head_is_not_detached(self):
        work=self.root/'attached';self.git('-C',self.repo,'worktree','add','-q',work,'unrelated')
        head=next((self.common/'worktrees').iterdir())/'HEAD';head.unlink()
        with self.assertRaises(FileNotFoundError):self.selection()

    def test_unmerged_tip_and_integration_branch_are_retained(self):
        self.git('-C',self.repo,'checkout','-q','completed');(self.repo/'file').write_text('unique')
        self.git('-C',self.repo,'commit','-qam','unique');self.git('-C',self.repo,'checkout','-q','main')
        with self.assertRaises(shadow.ShadowError):self.prepare(self.selection())
        with self.assertRaises(shadow.ShadowError):self.prepare(self.selection(('main',)))

    def test_symbolic_branch_or_existing_backup_are_retained(self):
        self.git('-C',self.repo,'symbolic-ref','refs/heads/completed','refs/heads/another')
        with self.assertRaisesRegex(shadow.ShadowError,'direct ref'):self.prepare(self.selection())
        self.git('-C',self.repo,'symbolic-ref','--delete','refs/heads/completed')
        self.git('-C',self.repo,'branch','completed')
        self.git('-C',self.repo,'update-ref','refs/richos/retired/'+self.ident+'/refs/heads/completed',self.tip)
        with self.assertRaisesRegex(shadow.ShadowError,'backup already'):self.prepare(self.selection())

    def test_external_objects_and_ref_symlinks_are_refused(self):
        external=self.root/'external';external.mkdir()
        (self.common/'objects/info/alternates').write_text(str(external)+'\n')
        with self.assertRaisesRegex(shadow.ShadowError,'dependency'):self.selection()
        (self.common/'objects/info/alternates').unlink()
        (self.common/'refs/heads/escape').symlink_to(self.common/'HEAD')
        with self.assertRaisesRegex(shadow.ShadowError,'regular file'):self.selection()

    def test_malformed_loose_ref_ignored_by_git_is_explicitly_refused(self):
        (self.common/'refs/heads/broken').write_text('not an object identity\n')
        with self.assertRaises(shadow.ShadowError):self.selection()

    def test_dangling_symbolic_ref_is_not_silently_omitted(self):
        (self.common/'refs/heads/dangling').write_text('ref: refs/heads/missing\n')
        with self.assertRaises(shadow.ShadowError):self.selection()

    def test_declared_ref_with_missing_object_and_duplicate_packed_ref_are_refused(self):
        loose=self.common/'refs/heads/missing-object';loose.write_text('b'*40+'\n')
        with self.assertRaisesRegex(shadow.ShadowError,'missing or unreadable'):self.selection()
        loose.unlink()
        packed=self.common/'packed-refs'
        with packed.open('a') as stream:stream.write(self.tip+' refs/heads/main\n')
        with self.assertRaisesRegex(shadow.ShadowError,'duplicate packed'):self.selection()

    def test_selection_bounds_apply_before_hashing_or_git(self):
        original=self.selection()
        excessive_count=copy.deepcopy(original);excessive_count['branches']*=129
        excessive_field=copy.deepcopy(original);excessive_field['branches'][0]['ref']='r'*1025
        excessive_bytes=copy.deepcopy(original)
        excessive_bytes['branches']=[{'ref':'r'*1024,'tip':'a'*64,'integration_ref':'i'*1024,'integration_tip':'a'*64}]*128
        for selection in (excessive_count,excessive_field,excessive_bytes):
            with self.subTest(selection_size=len(selection['branches'])), patch.object(shadow,'digest',side_effect=AssertionError('hash must not run first')):
                with self.assertRaises(shadow.ShadowError):
                    shadow.prepare(self.gate,selection,approved_selection_sha256='unused',scratch_root=self.scratch,trusted_git=BINARY)

    def test_ref_shadow_size_cap_refuses_without_copying_objects(self):
        with patch.object(shadow,'MAX_METADATA_BYTES',1):
            with self.assertRaisesRegex(shadow.ShadowError,'budget'):self.selection()
        self.assertEqual(list(self.scratch.iterdir()),[])

    def test_metadata_changed_during_shadow_transaction_refuses_artifact(self):
        selection=self.selection();original=shadow._git
        def git(*args,**kwargs):
            result=original(*args,**kwargs)
            if 'update-ref' in args:
                (self.common/'refs/heads/late').write_text(self.tip+'\n')
            return result
        with patch.object(shadow,'_git',side_effect=git):
            with self.assertRaisesRegex(shadow.ShadowError,'changed during'):self.prepare(selection)
        self.assertEqual(list(self.scratch.iterdir()),[])


if __name__=='__main__':unittest.main(verbosity=2)
