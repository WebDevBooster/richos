#!/usr/bin/env python3
"""Tiny real-Git recovery archives. No image, live gate or extraction into repos."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import subprocess
import tarfile
import unittest
import uuid
from unittest.mock import patch


def load(name,file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file))
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result


fixtures=load('capture_fixtures','legacy-workspace-gate.test.py')
capture=load('capture','legacy-workspace-capture.py')


class Recovery(unittest.TestCase):
    setUp=fixtures.GateWorkflow.setUp
    git=fixtures.GateWorkflow.git
    stage=fixtures.GateWorkflow.stage

    def ready(self):
        self.report=fixtures.gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx],self.records)
        self.digest=fixtures.gate.planner.history._digest(self.report)
        self.ident=self.stage()['id'];self.current_boot=str(uuid.uuid4())
        self.scratch=self.root/'scratch';self.scratch.mkdir(mode=0o700)
        self.binary=capture.shadow.TRUSTED_GIT if sys.platform=='darwin' else '/usr/bin/git'

    def prepare(self,**kwargs):
        args=dict(approved_gate_sha256=self.digest,repo_alias='fixture',candidate_path=str(self.work),
                  scratch_root=self.scratch,trusted_git=self.binary);args.update(kwargs)
        return capture.prepare(self.manager,self.ident,**args)

    def staged(self):
        (self.work/'file').write_bytes(b'unique staged data')
        self.git('-C',str(self.work),'add','file')
        self.staged_oid=self.git('-C',str(self.work),'rev-parse',':file')
        (self.work/'file').write_bytes(b'different working bytes\0')

    def test_all_working_index_metadata_and_cache_bytes_are_preserved(self):
        self.staged();(self.work/'untracked').write_bytes(b'private untracked')
        (self.work/'link').symlink_to('../outside')
        (self.work/'cache').mkdir();(self.work/'cache/CACHEDIR.TAG').write_bytes(capture.CACHE_SIGNATURE+b'\n')
        (self.work/'cache/unique').write_bytes(b'unique data must not be omitted')
        os.chmod(self.work/'file',0o751)
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        index_bytes=(admin/'index').read_bytes()
        self.ready();result=self.prepare();directory=Path(result['artifact_path'])
        manifest=json.loads((directory/'manifest.json').read_text())
        with tarfile.open(directory/'recovery.tar.gz','r:gz') as archive:
            self.assertEqual(archive.extractfile('worktree/file').read(),b'different working bytes\0')
            self.assertEqual(archive.extractfile('git-admin/index').read(),index_bytes)
            self.assertEqual(archive.extractfile('worktree/cache/unique').read(),b'unique data must not be omitted')
            self.assertEqual(archive.getmember('worktree/link').linkname,'../outside')
            self.assertEqual(archive.getmember('worktree/file').mode,0o751)
        self.assertEqual(manifest['worktree/file']['uid'],os.getuid())
        self.assertIn(self.staged_oid,[row['oid'] for row in result['dependencies']['required_objects']])
        self.assertEqual(result['cache_tag_hints'],['worktree/cache/CACHEDIR.TAG'])
        self.assertFalse(result['shared_objects_included']);self.assertFalse(result['standalone_repository'])
        self.assertFalse(result['automatic_expiry_authorized']);self.assertFalse(result['registration_removal_authorized'])
        self.assertEqual(result['omitted_cache_bytes'],0)
        self.assertFalse(any(name.startswith('git-admin/objects/') for name in manifest))
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual((self.work/'file').read_bytes(),b'different working bytes\0')
        self.assertEqual(self.git('-C',str(self.work),'rev-parse',':file'),self.staged_oid)

    @unittest.skipUnless(sys.platform=='darwin','cross-boot UUID contract is macOS only')
    def test_capture_and_validation_survive_kernel_device_renumbering(self):
        self.staged();self.ready()
        with fixtures.renumbered_device():
            result=self.prepare();directory=Path(result['artifact_path'])
            with self.manager.frozen_view(self.ident,approved_sha256=self.digest) as view:
                checked=capture.validate_capture(view,directory,self.scratch,self.binary)
            self.assertEqual(checked['manifest_sha256'],result['manifest_sha256'])
            with tarfile.open(directory/'recovery.tar.gz','r:gz') as archive:
                self.assertEqual(archive.extractfile('worktree/file').read(),b'different working bytes\0')

    def test_xattrs_are_preserved_in_manifest_and_pax(self):
        name='com.richos.capture-test' if sys.platform=='darwin' else 'user.richos.capture-test'
        if sys.platform=='darwin':subprocess.run(['/usr/bin/xattr','-wx',name,'007072697661746520617474726962757465',str(self.work/'file')],check=True)
        else:os.setxattr(self.work/'file',name,b'\0private attribute')
        self.ready();result=self.prepare();directory=Path(result['artifact_path'])
        manifest=json.loads((directory/'manifest.json').read_text())
        with tarfile.open(directory/'recovery.tar.gz') as archive:
            self.assertEqual(json.loads(archive.getmember('worktree/file').pax_headers['RICHOS.xattrs']),manifest['worktree/file']['xattrs'])
        self.assertIn(name,manifest['worktree/file']['xattrs'])

    def test_split_index_staged_objects_are_read_through_controlled_shadow(self):
        self.staged();self.git('-C',str(self.work),'update-index','--split-index')
        self.ready();result=self.prepare()
        self.assertIn(self.staged_oid,[row['oid'] for row in result['dependencies']['required_objects']])
        manifest=json.loads((Path(result['artifact_path'])/'manifest.json').read_text())
        self.assertTrue(any(name.startswith('git-admin/sharedindex.') for name in manifest))

    def test_git_admin_symlink_cannot_redirect_privileged_index_reads(self):
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        external=self.root/'external-index';external.write_bytes((admin/'index').read_bytes())
        (admin/'index').unlink();(admin/'index').symlink_to(external)
        self.ready()
        with patch.object(capture.shadow,'_shadow',side_effect=AssertionError('must refuse before Git')), \
                self.assertRaisesRegex(capture.CaptureError,'Git admin dependency'):
            self.prepare()
        self.assertEqual(list(self.scratch.iterdir()),[])

    def test_resolve_undo_unique_conflict_objects_are_handoff_dependencies(self):
        oids=[]
        env={'PATH':'/usr/bin:/bin','HOME':'/var/empty','GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'}
        for value in (b'conflict base unique',b'conflict ours unique',b'conflict theirs unique'):
            oids.append(subprocess.check_output(['/usr/bin/git','-C',str(self.work),'hash-object','-w','--stdin'],input=value,env=env).decode().strip())
        lines=['0 '+'0'*40+'\tfile']+['100644 '+oid+' '+str(stage)+'\tfile' for stage,oid in enumerate(oids,1)]
        subprocess.run(['/usr/bin/git','-C',str(self.work),'update-index','--index-info'],input=('\n'.join(lines)+'\n').encode(),check=True,env=env)
        (self.work/'file').write_bytes(b'resolved fourth content');self.git('-C',str(self.work),'add','file')
        self.assertTrue(self.git('-C',str(self.work),'ls-files','--resolve-undo'))
        self.ready();result=self.prepare();endpoints={row['oid']:row['sources'] for row in result['dependencies']['required_objects']}
        for oid in oids:
            self.assertIn(oid,endpoints);self.assertTrue(any('resolve-undo' in reason for reason in endpoints[oid]))

    def test_admin_symbolic_ref_traversal_refuses_before_outside_read(self):
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        external=self.root/'outside-ref';external.write_text(self.head+'\n')
        refs=admin/'refs/worktree';refs.mkdir(parents=True)
        target='refs/'+os.path.relpath(external,admin/'refs')
        (refs/'bad').write_text('ref: '+target+'\n')
        self.ready();real=capture.shadow._bytes
        def guarded(path,budget):
            if Path(path).resolve()==external:raise AssertionError('privileged outside ref read')
            return real(path,budget)
        with patch.object(capture.shadow,'_bytes',side_effect=guarded), \
                self.assertRaises(capture.shadow.ShadowError):self.prepare()
        self.assertEqual(list(self.scratch.iterdir()),[])

    def test_unique_cached_tree_and_v4_index_objects_are_preserved(self):
        self.staged();tree=self.git('-C',str(self.work),'write-tree')
        self.git('-C',str(self.work),'update-index','--index-version','4')
        self.ready();result=self.prepare()
        endpoints={row['oid']:row['sources'] for row in result['dependencies']['required_objects']}
        self.assertIn(tree,endpoints)
        self.assertTrue(any('tree-cache' in reason for reason in endpoints[tree]))

    def test_archived_unused_split_index_keeps_its_old_blob_dependency(self):
        self.staged();old=self.staged_oid;self.git('-C',str(self.work),'update-index','--split-index')
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        old_indexes={path.name:path.read_bytes() for path in admin.glob('sharedindex.*')}
        (self.work/'file').write_bytes(b'newest staged data');self.git('-C',str(self.work),'add','file')
        self.git('-C',str(self.work),'update-index','--split-index')
        for name,data in old_indexes.items():(admin/name).write_bytes(data)
        self.ready();result=self.prepare()
        self.assertIn(old,[row['oid'] for row in result['dependencies']['required_objects']])

    def test_unknown_optional_index_extension_is_an_explicit_handoff_veto(self):
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        raw=(admin/'index').read_bytes()[:-20]+b'ZZZZ'+(3).to_bytes(4,'big')+b'new'
        (admin/'index').write_bytes(raw+hashlib.sha1(raw).digest())
        self.ready();result=self.prepare()
        self.assertIn('git-admin/index:extension-5a5a5a5a',result['dependencies']['unparsed_git_state'])

    def test_shared_index_without_primary_index_keeps_its_unique_blobs(self):
        self.staged();old=self.staged_oid;self.git('-C',str(self.work),'update-index','--split-index')
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        (admin/'index').unlink()
        self.ready();result=self.prepare()
        self.assertIn(old,[row['oid'] for row in result['dependencies']['required_objects']])

    def test_unparsed_git_state_is_retained_and_reported(self):
        admin=Path(self.git('-C',str(self.work),'rev-parse','--absolute-git-dir'))
        (admin/'index.lock').write_bytes(b'unfinished index bytes');(admin/'FETCH_HEAD').write_bytes(b'unparsed fetch receipt')
        self.ready();result=self.prepare()
        self.assertEqual(result['dependencies']['unparsed_git_state'],['git-admin/FETCH_HEAD','git-admin/index.lock'])
        self.assertFalse(result['dependencies']['durable_handoff_verified'])
        with tarfile.open(Path(result['artifact_path'])/'recovery.tar.gz') as archive:
            self.assertEqual(archive.extractfile('git-admin/index.lock').read(),b'unfinished index bytes')

    def test_wrong_approval_unknown_candidate_and_same_boot_have_no_artifacts(self):
        self.ready()
        for args in ({'approved_gate_sha256':'wrong'},{'candidate_path':str(self.repo)}):
            with self.assertRaises(Exception):self.prepare(**args)
            self.assertEqual(list(self.scratch.iterdir()),[])
        self.current_boot=self.boot
        with self.assertRaises(Exception):self.prepare()
        self.assertEqual(list(self.scratch.iterdir()),[])

    def test_nested_registered_checkout_is_not_implicitly_selected(self):
        child=self.work/'nested'
        self.git('worktree','add','-qb','nested',str(child))
        self.tx['members'].append(dict(path=str(child),repo=str(self.repo),branch='nested',head=self.head))
        self.ready()
        with self.assertRaisesRegex(capture.CaptureError,'another registered'):self.prepare()
        self.assertEqual(list(self.scratch.iterdir()),[])

    def test_corrupt_archive_is_refused_and_partial_artifact_removed(self):
        self.ready();real=capture._write_archive
        def corrupt(path,manifest,sources):
            real(path,manifest,sources)
            path.write_bytes(b'invalid gzip archive')
        with patch.object(capture,'_write_archive',side_effect=corrupt),self.assertRaises(Exception):self.prepare()
        self.assertEqual(list(self.scratch.iterdir()),[])
        self.assertTrue(self.manager.inspect(self.ident)['boot_cutoff_verified'])

    def test_source_byte_change_after_archive_is_refused(self):
        self.ready();real=capture._verify_archive
        with self.manager.frozen_view(self.ident,approved_sha256=self.digest) as view:held,_=capture._map(view,self.work/'file')
        def change(path,manifest):
            real(path,manifest);held.write_bytes(b'changed by fixture after archive verification')
        with patch.object(capture,'_verify_archive',side_effect=change),self.assertRaisesRegex(capture.CaptureError,'source changed'):
            self.prepare()
        self.assertEqual(list(self.scratch.iterdir()),[])

    def test_validate_capture_recomputes_dependencies_and_rejects_omission(self):
        self.staged();self.ready();result=self.prepare();directory=Path(result['artifact_path'])
        with self.manager.frozen_view(self.ident,approved_sha256=self.digest) as view:
            receipt=capture.validate_capture(view,directory,self.scratch,self.binary)
            self.assertEqual(receipt['archive_sha256'],result['archive_sha256'])
            receipt['dependencies']['required_objects']=[]
            (directory/'receipt.json').write_text(json.dumps(receipt))
            with self.assertRaisesRegex(capture.CaptureError,'dependency set'):
                capture.validate_capture(view,directory,self.scratch,self.binary)

    def test_low_disk_refuses_before_creating_archive(self):
        self.ready();usage=shutil._ntuple_diskusage(100,99,1)
        with patch.object(capture.shutil,'disk_usage',return_value=usage),self.assertRaisesRegex(capture.CaptureError,'free space'):self.prepare()
        self.assertEqual(list(self.scratch.iterdir()),[])


if __name__=='__main__':unittest.main(verbosity=2)
