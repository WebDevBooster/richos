#!/usr/bin/env python3
"""Tiny unprivileged checks for the external harness, not installed acceptance."""
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).parent
spec = importlib.util.spec_from_file_location('acceptance', HERE / 'managed-workspace-interrupted-creation.acceptance.py')
a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='richos-interruption-test-')
        self.root = Path(self.temp.name)
    def tearDown(self):
        self.temp.cleanup()
    def archive(self, name='image.sparsebundle/Info.plist', kind=None):
        result = self.root / 'raw.tar.gz'
        with tarfile.open(result, 'w:gz') as archive:
            root = tarfile.TarInfo('image.sparsebundle'); root.type = tarfile.DIRTYPE; archive.addfile(root)
            member = tarfile.TarInfo(name)
            if kind is not None:
                member.type = kind; member.linkname = '/tmp/outside'; archive.addfile(member)
            else:
                data = b'unique raw bytes\x00\xff'; member.size = len(data); archive.addfile(member, io.BytesIO(data))
        return result
    def test_exact_fixture_namespace(self):
        policy = dict(private_root='/private/a', active_root='/private/b')
        ident = a.PREFIX + 'a' * 32
        self.assertEqual(a.roots(policy, ident), (Path('/private/a') / ident, Path('/private/b') / ident))
        for value in ('../other', ident + '/child', 'acceptance-' + 'a'*32, ident + '\n'):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                a.roots(policy, value)
    def test_extract_complete_binary_file(self):
        image = a.extract_raw(self.archive(), self.root / 'copy')
        self.assertEqual((image / 'Info.plist').read_bytes(), b'unique raw bytes\x00\xff')
        self.assertEqual((image / 'Info.plist').stat().st_mode & 0o777, 0o600)
    def test_extract_cannot_escape_root(self):
        for name in ('../outside', '/tmp/outside', 'image.sparsebundle/../../outside', 'different/file'):
            with self.subTest(name=name), tempfile.TemporaryDirectory(dir=self.root) as directory:
                with self.assertRaises(RuntimeError):
                    a.extract_raw(self.archive(name), Path(directory) / 'copy')
        self.assertFalse((self.root / 'outside').exists())
    def test_extract_never_follows_archive_links(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.FIFOTYPE):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory(dir=self.root) as directory:
                with self.assertRaises(RuntimeError):
                    a.extract_raw(self.archive(kind=kind), Path(directory) / 'copy')
    def test_durable_receipt_updates_without_literal_temporary_collision(self):
        path = self.root / 'receipt.json'
        unrelated = self.root / 'receipt.json.next'; unrelated.write_bytes(b'keep')
        a.save(path, {'phase': 'prepared'}); a.save(path, {'phase': 'completed'})
        self.assertEqual(json.loads(path.read_text()), {'phase':'completed'})
        self.assertEqual(unrelated.read_bytes(), b'keep')
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
    def test_unprivileged_runtime_refuses_before_loading_installed_code(self):
        with mock.patch.object(a.os, 'geteuid', return_value=501), mock.patch.object(a, 'load') as loader:
            with self.assertRaises(RuntimeError):
                a.runtime(object())
            loader.assert_not_called()
    def test_creation_replay_has_identical_owner_scope(self):
        receipt = dict(active_root='/private/test', commit='a'*40, owner_uid=501, owner_gid=20,
                       acceptance_id=a.PREFIX + 'f'*32)
        first = a.creation(receipt, 'crashed-attached')
        self.assertEqual(first, a.creation(dict(receipt), 'crashed-attached'))
        self.assertEqual(first['source_repo'], Path('/private/test/source'))
        self.assertEqual(first['owner_uid'], 501)
        self.assertEqual(first['session_id'], receipt['acceptance_id'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
