#!/usr/bin/env python3
"""External controller bootstrap tests; no installed/root execution."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('controller',Path(__file__).with_name('legacy-workspace-storage.acceptance.py'))
controller=importlib.util.module_from_spec(spec);spec.loader.exec_module(controller)

class Controller(unittest.TestCase):
    def test_unprivileged_run_cannot_create_fixture(self):
        with patch.object(controller.os,'geteuid',return_value=501),patch.object(controller,'load') as load:
            with self.assertRaisesRegex(RuntimeError,'root macOS'):controller.run(SimpleNamespace())
            load.assert_not_called()

    def test_manifest_mismatch_refuses_before_importing_runtime(self):
        with tempfile.TemporaryDirectory(prefix='storage-controller-bootstrap-') as temporary:
            root=Path(temporary);release=root/'releases'/('a'*64);release.mkdir(parents=True)
            (release/'manifest.json').write_text('{}')
            args=SimpleNamespace(release=str(release),manifest_sha256='b'*64,owner_uid=501)
            with patch.object(controller,'INSTALL',root),patch.object(controller,'PYTHON',sys.executable),\
                 patch.object(controller.os,'geteuid',return_value=0),patch.object(controller.sys,'platform','darwin'),\
                 patch.object(controller,'protected',side_effect=lambda path,*args:Path(path)),\
                 patch.object(controller,'load') as load:
                with self.assertRaisesRegex(RuntimeError,'manifest pin'):controller.runtime(args)
                load.assert_not_called()

    @unittest.skipUnless(sys.platform=='darwin','actual ordinary-owner Darwin file flags')
    def test_fixed_owner_setup_makes_only_exact_link_pair(self):
        with tempfile.TemporaryDirectory(prefix='storage-controller-owner-') as temporary:
            root=Path(temporary)
            subprocess.run([sys.executable,'-I','-S','-B','-c',controller.SETUP_LINKS,str(root)],check=True)
            self.assertEqual({path.name for path in root.iterdir()},{'linked-a','linked-b'})
            first,second=root/'linked-a',root/'linked-b'
            self.assertEqual(first.stat().st_ino,second.stat().st_ino)
            self.assertEqual(first.stat().st_uid,os.getuid());self.assertEqual(first.stat().st_nlink,2)
            self.assertEqual(first.stat().st_flags,0x8040);self.assertEqual(first.read_bytes(),b'linked private bytes')

    def test_upgrade_controller_contract_is_explicit(self):
        self.assertEqual(len(controller.CHECKS),12);self.assertEqual(len(set(controller.CHECKS)),12)
        for name in ('actual-owner-metadata-and-links-restored','external-alias-refused-before-mutation',
                     'actual-same-boot-frozen-view-refused','partial-protection-crash-is-recoverable'):
            self.assertIn(name,controller.CHECKS)

if __name__=='__main__':unittest.main(verbosity=2)
