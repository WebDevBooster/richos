#!/usr/bin/env python3
"""Hunt part 5, v3 (richos-hq docs/audits/2026-09-29-hunt/part-5-codex-v3.md).

Each class is one finding's reproduction from that report, red on main 3171302c2
and green with its fix. Fixtures are data only: no command named in a case is run
unless the case says so, and anything it runs is harmless (print, true, grep).
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="hunt-p5v3-")
        self.addCleanup(shutil.rmtree, self.tmp, True)


class P5_08_UnreadManifestBlob(Scratch):
    """A staged blob the scanner could not read is not CLEAN."""

    def scan(self, rows):
        ids = os.path.join(self.tmp, "ids")
        with open(ids, "w") as fh:
            fh.write("FIXTURE-SERIAL-0001\n")
        manifest = os.path.join(self.tmp, "manifest")
        with open(manifest, "w") as fh:
            fh.write("".join("%s\t%s\n" % r for r in rows))
        env = dict(os.environ, RICHOS_DEVICE_IDENTIFIERS_FILE=ids)
        out = subprocess.run([sys.executable, os.path.join(HERE, "device-identifiers.py"),
                              "--scan-manifest", manifest], capture_output=True, text=True,
                             env=env, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        return out.stdout

    def test_missing_blob_is_not_clean(self):
        out = self.scan([("fixture.txt", os.path.join(self.tmp, "no-such-blob"))])
        self.assertEqual(out.split("\t")[0].strip(), "BROKEN", out)

    def test_readable_match_still_found(self):
        blob = os.path.join(self.tmp, "blob")
        with open(blob, "w") as fh:
            fh.write("serial fixture-serial-0001 here\n")
        self.assertTrue(self.scan([("fixture.txt", blob)]).startswith("FOUND\n"))

    def test_readable_clean_blob_is_clean(self):
        blob = os.path.join(self.tmp, "blob")
        with open(blob, "w") as fh:
            fh.write("nothing here\n")
        self.assertEqual(self.scan([("fixture.txt", blob)]), "CLEAN\n")


if __name__ == "__main__":
    unittest.main()
