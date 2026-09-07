#!/usr/bin/env python3
"""Unprivileged controller transport tests, not installed/root acceptance."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('operator_acceptance',Path(__file__).with_name('legacy-workspace-operator.acceptance.py'))
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)


class Controller(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='operator-controller-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.source=self.root/'source';self.source.mkdir()
        raw=b'fixture runtime bytes\n';(self.source/'fixture.py').write_bytes(raw)
        (self.source/'manifest.json').write_text(json.dumps({'fixture.py':hashlib.sha256(raw).hexdigest()}))
        self.destination=self.root/('operator-runtime-'+'a'*32)
        self.policy={'fixture-only':'exact policy bytes'}
    def mirrored(self):
        target=self.destination/'releases'/self.source.name
        with patch.object(a,'INSTALL',self.root),patch.object(a,'protected',side_effect=lambda path,*args:Path(path)), \
             patch.object(a,'load',return_value=SimpleNamespace(validate_runtime=lambda:target)):
            return a.mirror_runtime(self.source,self.destination,self.policy)
    def test_exact_runtime_bytes_survive_restrictive_administrator_umask(self):
        previous=os.umask(0o077)
        try:target=self.mirrored()
        finally:os.umask(previous)
        for name in ('fixture.py','manifest.json'):
            self.assertEqual((target/name).read_bytes(),(self.source/name).read_bytes())
            self.assertEqual((target/name).stat().st_mode&0o777,0o644)
        for directory in (self.destination,self.destination/'releases',target):self.assertEqual(directory.stat().st_mode&0o777,0o755)
        self.assertEqual(json.loads((self.destination/'policy.json').read_text()),self.policy)
        self.assertEqual((self.destination/'policy.json').stat().st_mode&0o777,0o600)
    def test_preexisting_namespace_is_never_replaced(self):
        self.destination.mkdir();sentinel=self.destination/'preserve';sentinel.write_bytes(b'preserve')
        with self.assertRaises(FileExistsError):self.mirrored()
        self.assertEqual(sentinel.read_bytes(),b'preserve')
    def test_wrong_namespace_refuses_before_copy(self):
        self.destination=self.root/'unrelated'
        with self.assertRaisesRegex(RuntimeError,'namespace'):self.mirrored()
        self.assertFalse(self.destination.exists())
    def test_source_hash_change_is_never_blessed_by_a_new_manifest(self):
        (self.source/'fixture.py').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError,'changed'):self.mirrored()
        self.assertFalse((self.destination/'releases'/self.source.name/'fixture.py').exists())
    def test_unprivileged_runtime_stops_before_protected_reads(self):
        with patch.object(a.os,'geteuid',return_value=501),patch.object(a,'protected') as read:
            with self.assertRaisesRegex(RuntimeError,'root macOS'):a.runtime(SimpleNamespace())
            read.assert_not_called()


if __name__=='__main__':unittest.main(verbosity=2)
