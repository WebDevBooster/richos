#!/usr/bin/env python3
"""Negative delivery checks use fictional files, never operator state."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("verify_runtime", Path(__file__).with_name("verify-runtime.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RuntimeInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="richos runtime inventory ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "runtime"
        (self.root / "bin").mkdir(parents=True)
        self.sources = Path(self.temp.name) / "sources.json"
        self.sources.write_text('{"synthetic":true}')
        (self.root / "runtime-sources.json").write_bytes(self.sources.read_bytes())
        for name in ("python3", "node", "git", "jq"):
            path = self.root / "bin" / name
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        self.manifest = {"schema": 1, "platform": "aarch64-apple-darwin", "versions": {}, "links": {},
            "files": {str(p.relative_to(self.root)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in self.root.rglob("*") if p.is_file()}}
        self.save()

    def save(self):
        (self.root / "delivery.json").write_text(json.dumps(self.manifest))

    def test_complete_delivery_passes(self):
        module.verify(self.root, self.sources)

    def test_unlisted_private_record_refuses(self):
        (self.root / "fictional-private-record.json").write_text('{"fictional":true}')
        with self.assertRaisesRegex(ValueError, "unexpected"):
            module.verify(self.root, self.sources)

    def test_changed_binary_refuses(self):
        (self.root / "bin/git").write_text("#!/bin/sh\nexit 1\n")
        with self.assertRaisesRegex(ValueError, "changed"):
            module.verify(self.root, self.sources)

    def test_escaping_symlink_refuses_even_if_declared(self):
        (self.root / "escape").symlink_to(self.sources)
        self.manifest["links"]["escape"] = str(self.sources)
        self.save()
        with self.assertRaisesRegex(ValueError, "invalid runtime link"):
            module.verify(self.root, self.sources)

    def test_changed_source_recipe_refuses(self):
        self.sources.write_text('{"synthetic":false}')
        with self.assertRaisesRegex(ValueError, "public recipe"):
            module.verify(self.root, self.sources)

    def test_nonexecutable_runtime_refuses(self):
        (self.root / "bin/node").chmod(0o644)
        with self.assertRaisesRegex(ValueError, "not executable"):
            module.verify(self.root, self.sources)

    def test_invalid_member_name_refuses(self):
        self.manifest["files"]["../outside"] = "0" * 64
        self.save()
        with self.assertRaisesRegex(ValueError, "member name"):
            module.verify(self.root, self.sources)


if __name__ == "__main__":
    unittest.main()
