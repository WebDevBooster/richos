#!/usr/bin/env python3
import base64
import importlib.util
import os
from pathlib import Path
import tempfile
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
    def test_path_and_byte_budget_are_conservative(self):
        for field,budget in [('MAX_PATHS',2),('MAX_BYTES',16)]:
            with patch.object(metadata,field,budget):
                with self.assertRaises(metadata.MetadataError):metadata.from_managed_tree(self.root,object_storage_verified=True)
if __name__=='__main__':unittest.main()
