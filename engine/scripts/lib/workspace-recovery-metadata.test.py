#!/usr/bin/env python3
import base64
import importlib.util
import os
from pathlib import Path
import tempfile
import sys
import subprocess
import unittest
from unittest.mock import patch
spec=importlib.util.spec_from_file_location('metadata',Path(__file__).with_name('workspace-recovery-metadata.py'))
metadata=importlib.util.module_from_spec(spec);spec.loader.exec_module(metadata)

class Metadata(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);(self.root/'.git/objects/ab').mkdir(parents=True)
        (self.root/'.git/objects/ab'/('c'*38)).write_bytes(b'caller verified object bytes')
        (self.root/'.git/objects/custom-state').write_bytes(b'unique object directory metadata')
        (self.root/'.git/config').write_bytes(b'unique config bytes')
    def test_unknown_object_directory_files_and_all_admin_bytes_are_preserved(self):
        result=metadata.from_managed_tree(self.root,object_storage_verified=True)
        self.assertEqual(base64.b64decode(result['contents']['.git/objects/custom-state']),b'unique object directory metadata')
        self.assertEqual(base64.b64decode(result['contents']['.git/config']),b'unique config bytes')
        self.assertNotIn('.git/objects/ab/'+('c'*38),result['contents'])
    def test_unverified_objects_and_external_admin_symlinks_are_refused(self):
        with self.assertRaises(metadata.MetadataError):metadata.from_managed_tree(self.root)
        (self.root/'.git/external').symlink_to('/etc/passwd')
        with self.assertRaisesRegex(metadata.MetadataError,'symlink'):metadata.from_managed_tree(self.root,object_storage_verified=True)
    def test_actual_hardlink_topology_refuses_compact_proof(self):
        (self.root/'first').write_bytes(b'linked tracked bytes')
        os.link(self.root/'first',self.root/'second')
        self.assertEqual((self.root/'first').stat().st_ino,(self.root/'second').stat().st_ino)
        with self.assertRaisesRegex(metadata.MetadataError,'hardlinked'):
            metadata.from_managed_tree(self.root,object_storage_verified=True)

    @unittest.skipUnless(sys.platform=='darwin','native BSD flags require macOS')
    def test_actual_bsd_flags_refuse_compact_proof(self):
        path=self.root/'flagged';path.write_bytes(b'file with unique flags')
        subprocess.run(['/usr/bin/chflags','hidden',str(path)],check=True)
        self.addCleanup(lambda:subprocess.run(['/usr/bin/chflags','nohidden',str(path)],check=True))
        self.assertNotEqual(path.stat().st_flags,0)
        with self.assertRaisesRegex(metadata.MetadataError,'filesystem flags'):
            metadata.from_managed_tree(self.root,object_storage_verified=True)

    @unittest.skipUnless(sys.platform=='darwin','native ACLs require macOS')
    def test_actual_extended_acl_refuses_compact_proof(self):
        path=self.root/'acl-file';path.write_bytes(b'file with ACL')
        subprocess.run(['/bin/chmod','+a','everyone allow read',str(path)],check=True)
        self.addCleanup(lambda:subprocess.run(['/bin/chmod','-N',str(path)],check=True))
        with self.assertRaisesRegex(metadata.MetadataError,'extended ACL'):
            metadata.from_managed_tree(self.root,object_storage_verified=True)

    @unittest.skipUnless(sys.platform=='darwin','native ACL API requires macOS')
    def test_acl_reader_error_is_not_absence(self):
        class Denied:
            def acl_get_link_np(self,*args):metadata.ctypes.set_errno(metadata.errno.EACCES);return None
        with patch.object(metadata,'_ACL_LIB',Denied()):
            with self.assertRaisesRegex(metadata.MetadataError,'ACL inventory unavailable'):
                metadata.from_managed_tree(self.root,object_storage_verified=True)

    def test_multiply_linked_symlinks_refuse_compact_proof(self):
        source=self.root/'source-link';source.symlink_to('/outside-not-followed')
        second=self.root/'second-link'
        try:os.link(source,second,follow_symlinks=False)
        except OSError:self.skipTest('filesystem does not support symlink hardlinks')
        if source.lstat().st_ino!=second.lstat().st_ino:self.skipTest('link operation followed the symlink')
        with self.assertRaisesRegex(metadata.MetadataError,'hardlinked'):
            metadata.from_managed_tree(self.root,object_storage_verified=True)

    def test_path_and_byte_budget_are_conservative(self):
        for field,budget in [('MAX_PATHS',2),('MAX_BYTES',16)]:
            with patch.object(metadata,field,budget):
                with self.assertRaises(metadata.MetadataError):metadata.from_managed_tree(self.root,object_storage_verified=True)
if __name__=='__main__':unittest.main()
