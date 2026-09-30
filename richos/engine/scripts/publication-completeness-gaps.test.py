#!/usr/bin/env python3
"""publication-completeness must not call the tree complete over documents it never read.

Hunt P5-08 (part 5): Tree.read returned None for a tracked document that was over
the size bound or unreadable, and the three checks that call it skipped the file
(`if text is None: continue`), so its citations, declarations and onboarding
links vanished from the result. The file's own header says exceeding a bound is
BROKEN, "never 'checked what we could'". Now the read is recorded and main()
refuses with BROKEN once the checks have run (the callers still skip, so one bad
document does not hide what the others say).

  U1  (control) every tracked document is read: nothing is recorded, no refusal
  U2  an oversized tracked document is recorded and refused
  U3  an unreadable tracked document is recorded and refused
  U4  main() returns 2 on it, and 0/1 on the control (the wiring, not only the helper)
"""
import importlib.util
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "publication_completeness", os.path.join(HERE, "publication-completeness.py"))
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)
ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)


class Unread(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="pc-gaps."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        run("git", "init", "-q", "-b", "main", self.tmp, cwd=self.tmp)
        for name, text in (("README.md", "see docs/a.md\n"), ("docs/a.md", "a doc\n")):
            p = os.path.join(self.tmp, name)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as fh:
                fh.write(text)
        run("git", "add", "-A", cwd=self.tmp)

    def tree(self):
        return pc.Tree(self.tmp)

    def test_u1_control_nothing_unread_no_refusal(self):
        t = self.tree()
        self.assertEqual(t.read("README.md"), "see docs/a.md\n")
        self.assertEqual(t.unread, {})
        t.require_all_read()                      # does not raise

    def test_u2_an_oversized_tracked_document_is_recorded_and_refused(self):
        with open(os.path.join(self.tmp, "docs", "a.md"), "w") as fh:
            fh.write("x" * (pc.MAX_FILE_BYTES + 1))
        t = self.tree()
        self.assertIsNone(t.read("docs/a.md"))
        self.assertIn("docs/a.md", t.unread)
        with self.assertRaises(pc.Broken) as cm:
            t.require_all_read()
        self.assertIn("docs/a.md", str(cm.exception))

    @unittest.skipIf(ROOT_USER, "root reads everything")
    def test_u3_an_unreadable_tracked_document_is_recorded_and_refused(self):
        p = os.path.join(self.tmp, "docs", "a.md")
        os.chmod(p, 0)
        self.addCleanup(os.chmod, p, stat.S_IRUSR | stat.S_IWUSR)
        t = self.tree()
        self.assertIsNone(t.read("docs/a.md"))
        with self.assertRaises(pc.Broken):
            t.require_all_read()

    def _main(self, cfg_root):
        """main() with the four checks stubbed to read one document each."""
        real_tree = pc.Tree

        def checks(tree, *a, **k):
            tree.read("docs/a.md")

        stdin = io.StringIO(json.dumps({"root": cfg_root}))
        err = io.StringIO()
        with mock.patch.object(pc, "derive_declarations", lambda tree: {}), \
                mock.patch.object(pc, "check_citations", checks), \
                mock.patch.object(pc, "check_declarations", lambda *a, **k: None), \
                mock.patch.object(pc, "check_workflows", lambda *a, **k: None), \
                mock.patch.object(pc, "check_misplacement", lambda *a, **k: None), \
                mock.patch.object(sys, "stdin", stdin), mock.patch.object(sys, "stderr", err):
            pc.FINDINGS.clear()
            rc = pc.main()
        return rc, err.getvalue()

    def test_u4_main_refuses_with_2_only_when_a_read_failed(self):
        rc, _ = self._main(self.tmp)
        self.assertEqual(rc, 0)
        with open(os.path.join(self.tmp, "docs", "a.md"), "w") as fh:
            fh.write("x" * (pc.MAX_FILE_BYTES + 1))
        rc, err = self._main(self.tmp)
        self.assertEqual(rc, 2)
        self.assertIn("BROKEN", err)
        self.assertIn("docs/a.md", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
