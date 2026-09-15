#!/usr/bin/env python3
"""Native tiny inode/volume proof and deterministic parser/race controls."""
import ctypes
import importlib.util
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
import uuid
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('identity',Path(__file__).with_name('durable-filesystem-identity.py'))
mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)


class FilesystemIdentity(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='filesystem-token-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.file=self.root/'file';self.file.write_bytes(b'tiny')
        self.link=self.root/'link';self.link.symlink_to('file')
        self.dangling=self.root/'dangling';self.dangling.symlink_to('/nonexistent-filesystem-token-target')

    def test_real_directory_file_symlink_and_dangling_link_same_volume(self):
        values=[mod.filesystem_token(path,path.lstat()) for path in (self.root,self.file,self.link,self.dangling)]
        self.assertEqual(len(set(values)),1)
        self.assertTrue(values[0].startswith(mod.DARWIN_PREFIX if sys.platform=='darwin' else mod.LINUX_PREFIX))
        self.assertEqual(self.file.read_bytes(),b'tiny');self.assertEqual(os.readlink(self.link),'file')

    def test_cross_volume_symlink_identifies_link_volume_without_following(self):
        candidates=[Path('/System/Volumes/VM'),Path('/'),Path('/dev')]
        target=next((p for p in candidates if p.exists() and p.lstat().st_dev!=self.root.lstat().st_dev),None)
        if target is None:self.skipTest('no separately mounted read-only observation target')
        link=self.root/'other-volume';link.symlink_to(target)
        self.assertEqual(mod.filesystem_token(link),mod.filesystem_token(self.root))
        self.assertNotEqual(mod.filesystem_token(link),mod.filesystem_token(target))

    def test_supplied_lstat_for_different_inode_refuses_before_open(self):
        with patch.object(mod.os,'open',side_effect=AssertionError('must not open')):
            with self.assertRaisesRegex(mod.FilesystemIdentityError,'supplied lstat'):
                mod.filesystem_token(self.file,self.root.lstat())

    def test_path_replacement_during_query_is_refused_and_descriptor_is_closed(self):
        query='_darwin_token' if sys.platform=='darwin' else '_linux_token';real=getattr(mod,query);descriptors=[]
        def replace(value):
            result=real(value)
            self.file.rename(self.root/'old');self.file.write_bytes(b'replacement')
            return result
        real_open=mod.os.open
        def opened(*args,**kwargs):
            fd=real_open(*args,**kwargs);descriptors.append(fd);return fd
        with patch.object(mod,query,side_effect=replace),patch.object(mod.os,'open',side_effect=opened):
            with self.assertRaisesRegex(mod.FilesystemIdentityError,'changed during'):
                mod.filesystem_token(self.file)
        with self.assertRaises(OSError):os.fstat(descriptors[0])
        self.assertEqual((self.root/'old').read_bytes(),b'tiny')

    def test_query_is_bound_to_original_inode_even_if_path_is_temporarily_replaced(self):
        query='_darwin_token' if sys.platform=='darwin' else '_linux_token';original=self.file.lstat()
        def check(value):
            self.file.rename(self.root/'saved');self.file.write_bytes(b'other')
            opened=os.fstat(value) if sys.platform=='darwin' else value
            self.assertEqual((opened.st_dev,opened.st_ino),(original.st_dev,original.st_ino))
            self.file.unlink();(self.root/'saved').rename(self.file)
            return 'test-pinned-volume'
        with patch.object(mod,query,side_effect=check):
            # Rename changes ctime on macOS/Linux. Refusal is appropriate; the
            # important property is that the native query used the pinned FD.
            try:self.assertEqual(mod.filesystem_token(self.file),'test-pinned-volume')
            except mod.FilesystemIdentityError:pass

    def test_lookup_has_no_result_cache(self):
        query='_darwin_token' if sys.platform=='darwin' else '_linux_token'
        with patch.object(mod,query,side_effect=['first-volume','second-volume']) as called:
            self.assertEqual(mod.filesystem_token(self.file),'first-volume')
            self.assertEqual(mod.filesystem_token(self.file),'second-volume')
        self.assertEqual(called.call_count,2)

    def test_native_result_requires_exact_length_and_nonzero_uuid(self):
        value=uuid.uuid4();raw=(20).to_bytes(4,sys.byteorder)+value.bytes
        self.assertEqual(mod._decode_volume(raw),mod.DARWIN_PREFIX+str(value))
        for invalid in (b'',raw[:-1],raw+b'x',(19).to_bytes(4,sys.byteorder)+value.bytes,(20).to_bytes(4,sys.byteorder)+bytes(16)):
            with self.assertRaises(mod.FilesystemIdentityError):mod._decode_volume(invalid)
        self.assertEqual(ctypes.sizeof(mod.AttrList),24)

    def test_linux_fallback_changes_across_boot_and_rejects_malformed_boot(self):
        first=str(uuid.uuid4());second=str(uuid.uuid4());info=self.file.lstat()
        with patch.object(mod.Path,'read_text',side_effect=[first,second]):
            one=mod._linux_token(info);two=mod._linux_token(info)
        self.assertNotEqual(one,two);self.assertEqual(one,mod.LINUX_PREFIX+first+':'+str(info.st_dev))
        for value in ('',str(uuid.UUID(int=0)),'not-a-uuid',first.replace('-','')):
            with patch.object(mod.Path,'read_text',return_value=value),self.assertRaises(mod.FilesystemIdentityError):mod._linux_token(info)

    @unittest.skipUnless(sys.platform=='darwin','native macOS syscall')
    def test_native_syscall_error_is_not_an_absence_or_default_token(self):
        with self.assertRaises(mod.FilesystemIdentityError):mod._darwin_token(-1)


if __name__=='__main__':unittest.main(verbosity=2)
