#!/usr/bin/env python3
"""Tiny closed-link-set and metadata recovery controls, no live repositories."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tarfile
import unittest
import uuid
from unittest.mock import patch

def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result

fixture=load('legacy-workspace-gate.test');gate=fixture.gate
retirement_fixture=load('legacy-workspace-retirement.test')

class Storage(unittest.TestCase):
    setUp=fixture.GateWorkflow.setUp
    git=fixture.GateWorkflow.git
    stage=fixture.GateWorkflow.stage

    def pair(self):
        first=self.work/'linked-a';second=self.work/'linked-b'
        first.write_bytes(b'exact shared private bytes');os.chmod(first,0o751);os.link(first,second)
        return first,second

    def test_closed_pair_original_metadata_and_topology_survive_restore(self):
        first,second=self.pair();inode=first.stat().st_ino
        ident=self.stage()['id'];base=self.manager._base(ident)
        rows=[r for r in self.manager._entries(base).values() if r['inode']==inode]
        self.assertEqual(len(rows),2);self.assertEqual({r['mode'] for r in rows},{0o751})
        self.assertEqual({r['nlink'] for r in rows},{2})
        self.current_boot=str(uuid.uuid4());self.manager.restore(ident,approved_sha256=self.digest)
        self.assertEqual(first.stat().st_ino,second.stat().st_ino)
        self.assertEqual(stat.S_IMODE(first.stat().st_mode),0o751)
        self.assertEqual(first.read_bytes(),b'exact shared private bytes')

    def test_external_alias_refuses_before_any_mutation(self):
        first,second=self.pair();outside=self.root/'outside';os.link(first,outside)
        with self.assertRaisesRegex(gate.GateError,'not closed'):self.stage()
        self.assertTrue(self.work.exists());self.assertEqual(list(self.vault.iterdir()),[])
        self.assertEqual(stat.S_IMODE(outside.stat().st_mode),0o751)

    def test_cross_root_aliases_refuse_even_when_globally_closed(self):
        first=self.work/'linked';first.write_text('private');os.link(first,self.repo/'linked')
        with self.assertRaisesRegex(gate.GateError,'maintenance target'):self.stage()
        self.assertEqual(list(self.vault.iterdir()),[]);self.assertTrue(first.exists())

    def test_nested_native_and_canonical_aliases_refuse_before_mutation(self):
        native=self.repo/'.claude/worktrees/native';native.parent.mkdir(parents=True)
        self.git('worktree','add','-qb','native',str(native))
        self.tx['members'].append(dict(path=str(native),repo=str(self.repo),branch='native',head=self.head))
        first=native/'linked';first.write_text('private');os.link(first,self.repo/'linked')
        self.report=gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx],self.records)
        self.digest=gate.planner.history._digest(self.report)
        with self.assertRaisesRegex(gate.GateError,'maintenance target'):self.stage()
        self.assertEqual(list(self.vault.iterdir()),[])

    def test_crash_after_first_alias_replays_original_preimage(self):
        first,second=self.pair();original=self.manager._apply;injected=[]
        def crash(path,row,**kwargs):
            original(path,row,**kwargs)
            if path.name=='linked-a' and not kwargs.get('restore') and not injected:
                injected.append(True);raise RuntimeError('after first alias')
        with patch.object(self.manager,'_apply',side_effect=crash),self.assertRaisesRegex(RuntimeError,'first alias'):self.stage()
        ident=next(self.vault.iterdir()).name
        self.assertEqual(self.manager.resume(ident)['phase'],'gated')
        self.current_boot=str(uuid.uuid4());self.manager.restore(ident,approved_sha256=self.digest)
        self.assertEqual(first.stat().st_ino,second.stat().st_ino)
        self.assertEqual(stat.S_IMODE(first.stat().st_mode),0o751)

    def test_changed_metadata_after_snapshot_refuses_and_retains_preimage(self):
        first,second=self.pair();original=self.manager._write_snapshot
        def changed(base,entries):
            original(base,entries);os.chmod(first,0o744)
        with patch.object(self.manager,'_write_snapshot',side_effect=changed),self.assertRaisesRegex(gate.GateError,'preimage'):self.stage()
        base=next(self.vault.iterdir())
        self.assertEqual({r['mode'] for r in self.manager._entries(base).values() if r['inode']==first.stat().st_ino} if first.exists() else
                         {r['mode'] for r in self.manager._entries(base).values() if r['relative'].endswith(('/linked-a','/linked-b'))},{0o751})

    def test_outside_alias_added_after_freeze_vetoes_frozen_view(self):
        self.pair();ident=self.stage()['id'];base=self.manager._base(ident)
        held=next(base.rglob('linked-a'));os.link(held,self.root/'outside')
        self.current_boot=str(uuid.uuid4())
        with self.assertRaisesRegex(gate.GateError,'not closed'):
            with self.manager.frozen_view(ident,approved_sha256=self.digest):pass

    def test_partial_restore_preserves_late_hardlinked_symlink(self):
        link=self.work/'alias-link';link.symlink_to('file');original=self.manager._apply;injected=[]
        def crash(path,row,**kwargs):
            original(path,row,**kwargs)
            if path.name=='alias-link' and not kwargs.get('restore') and not injected:
                injected.append(True);os.link(path,self.root/'outside-link',follow_symlinks=False)
                raise RuntimeError('late symlink alias')
        with patch.object(self.manager,'_apply',side_effect=crash),self.assertRaisesRegex(RuntimeError,'late symlink'):self.stage()
        ident=next(self.vault.iterdir()).name;self.current_boot=str(uuid.uuid4())
        self.manager.restore(ident,approved_sha256=self.digest)
        self.assertEqual(link.lstat().st_ino,(self.root/'outside-link').lstat().st_ino)
        self.assertEqual(os.readlink(link),'file');self.assertEqual((self.work/'file').read_text(),'committed')

    def test_historical_partial_gate_cannot_adopt_unjournaled_link_group(self):
        with patch.object(self.manager,'_protect_tree',side_effect=RuntimeError('after rename')),self.assertRaises(RuntimeError):self.stage()
        base=next(self.vault.iterdir());record=self.manager._load(base)
        record.pop('metadata_snapshot_version');self.manager._save(base,record)
        held=next(base/root['held'] for root in record['roots'] if (base/root['held']).exists())
        first=held/'aaa-link-a';first.write_bytes(b'late preserved bytes');os.link(first,held/'aaa-link-b')
        before=(base/'metadata.jsonl').read_bytes()
        with self.assertRaisesRegex(gate.GateError,'historical partial'):self.manager.resume(base.name)
        self.assertEqual((base/'metadata.jsonl').read_bytes(),before)
        self.assertEqual(first.read_bytes(),b'late preserved bytes')

    @unittest.skipUnless(sys.platform=='darwin','actual BSD flags')
    def test_benign_flags_survive_and_other_flags_refuse(self):
        first,second=self.pair();os.chflags(first,0x8040)
        self.addCleanup(lambda:os.chflags(first,0) if first.exists() else None)
        ident=self.stage()['id'];self.current_boot=str(uuid.uuid4())
        self.manager.restore(ident,approved_sha256=self.digest)
        self.assertEqual(first.stat().st_flags,0x8040);self.assertEqual(second.stat().st_flags,0x8040)
        os.chflags(first,1)
        self.report=gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx],self.records)
        self.digest=gate.planner.history._digest(self.report)
        with self.assertRaisesRegex(gate.GateError,'flags'):self.stage()

    @unittest.skipUnless(sys.platform=='darwin','actual native ACL query')
    def test_acl_probe_does_not_spawn_process_and_refuses_unreadable(self):
        with patch.object(gate.subprocess,'run',side_effect=AssertionError('subprocess forbidden')):
            self.manager._no_acl(self.work/'file')
        with patch.object(gate.acl_metadata,'_no_acl',side_effect=gate.acl_metadata.MetadataError('unreadable')):
            with self.assertRaisesRegex(gate.GateError,'ACL'):self.manager._no_acl(self.work/'file')

class CaptureRetirement(unittest.TestCase):
    setUp=fixture.GateWorkflow.setUp
    git=fixture.GateWorkflow.git
    stage=fixture.GateWorkflow.stage
    prepare=retirement_fixture.Retirement.prepare
    retire=retirement_fixture.Retirement.retire
    replay=retirement_fixture.Retirement.replay

    def test_linked_archive_uses_exact_target_without_backward_gzip_reads(self):
        first=self.work/'linked-a';first.write_bytes(b'unique shared bytes');os.link(first,self.work/'linked-b')
        if sys.platform=='darwin':os.chflags(first,0x8040)
        self.prepare()
        directory=Path(self.artifact['artifact_path']);manifest=json.loads((directory/'manifest.json').read_text())
        a,b=manifest['worktree/linked-a'],manifest['worktree/linked-b']
        self.assertEqual(b['hardlink_to'],'worktree/linked-a');self.assertEqual(a['hardlink_group'],b['hardlink_group'])
        if sys.platform=='darwin':self.assertEqual(a['flags'],0x8040)
        original=tarfile.TarFile.extractfile
        def forward_only(archive,item):
            self.assertFalse(item.islnk(),'hardlinks must not seek backwards through gzip')
            return original(archive,item)
        with patch.object(tarfile.TarFile,'extractfile',forward_only):
            retirement_fixture.capture._verify_archive(directory/'recovery.tar.gz',manifest)
        self.retire();self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertFalse(self.work.exists());self.assertTrue((directory/'recovery.tar.gz').is_file())

    def test_retirement_crash_between_alias_unlinks_replays_remaining_count(self):
        first=self.work/'linked-a';first.write_bytes(b'unique shared bytes');os.link(first,self.work/'linked-b')
        self.prepare();original=Path.unlink;injected=[]
        def crash(path,*args,**kwargs):
            result=original(path,*args,**kwargs)
            if path.name=='linked-b' and self.base in path.parents and not injected:
                injected.append(True);raise RuntimeError('after alias unlink')
            return result
        with patch.object(Path,'unlink',crash),self.assertRaisesRegex(RuntimeError,'alias unlink'):self.retire()
        self.assertEqual(self.replay()['phase'],'complete')
        self.manager.restore(self.ident,approved_sha256=self.digest);self.assertFalse(self.work.exists())

    def test_archive_changed_link_target_refuses(self):
        first=self.work/'linked-a';first.write_text('bytes');os.link(first,self.work/'linked-b')
        self.prepare();directory=Path(self.artifact['artifact_path']);manifest=json.loads((directory/'manifest.json').read_text())
        manifest['worktree/linked-b']['hardlink_to']='worktree/file'
        with self.assertRaisesRegex(retirement_fixture.capture.CaptureError,'target'):
            retirement_fixture.capture._verify_archive(directory/'recovery.tar.gz',manifest)

if __name__=='__main__':unittest.main(verbosity=2)
