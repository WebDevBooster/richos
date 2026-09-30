#!/usr/bin/env python3
"""operator-fences-preserve.test.py — nothing destructive follows a failed
preservation (hunt 2026-09-29 part 5, finding 60).

abort-orphan preserves the repository's state and then runs `git merge
--abort`, which discards the merge's resolutions. preserve() used to ignore
each Git view's exit status and write stderr as the view, so a failed
`git diff --binary HEAD` left "fatal: ..." as the patch and the abort went
ahead anyway. takeover announced the same preservation without checking it.

Git is replaced by a recorder, so the cases see every command the lease
would have run, and a wrong abort is caught as the command it would have been
rather than as lost work. Each refusal has a control beside it: with every
view captured, the abort and the takeover still go ahead, because the reason
for preserving first (recover the operation afterwards) is the reason to act.
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import operator_fences as F   # noqa: E402

PATCH = "diff --git a/f.txt b/f.txt\n+resolved line\n"


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="fences-preserve.")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.conf = {"HOME": os.path.join(self.tmp, "home"), "KEY": "k"}
        self.files = F.Files(self.conf)
        main = os.path.join(self.tmp, "repo")
        gitdir = os.path.join(main, ".git")
        os.makedirs(gitdir)
        with open(os.path.join(gitdir, "MERGE_HEAD"), "w") as fh:
            fh.write("0123456789abcdef0123456789abcdef01234567\n")
        self.paths = {"main": main, "gitdir": gitdir}
        self.calls = []
        self.diff_fails = False
        saved = {n: getattr(F, n) for n in ("git", "_lease_context", "authorized", "merge_owner",
                                             "_identify", "read_lease", "lease_state", "_report_state", "_say")}
        self.addCleanup(lambda: [setattr(F, n, v) for n, v in saved.items()])
        self.said = []
        F.git = self.git
        F._say = self.said.append
        F._lease_context = lambda opts: (self.conf, self.files, main, self.paths)
        F.authorized = lambda files, chain=None: (True, {})
        F.merge_owner = lambda conf, paths, chain=None, consider_lease=True: {
            "verdict": "owner-ended", "kind": "MERGE_HEAD", "head": "0123456", "label": "an ended session"}
        F._identify = lambda opts, conf, taking=False: {"kind": "claude", "pid": os.getpid(), "start": 1}
        F.read_lease = lambda files: {"holder": {"kind": "claude", "pid": 999999, "start": 1}}
        F.lease_state = lambda lease: "dead"
        F._report_state = lambda conf, files, paths: None

    def git(self, cwd, *args, **kw):
        self.calls.append(list(args))
        if args[:1] == ("diff",) and self.diff_fails:
            return 128, "", "fatal: fixture diff failed\n"
        if args[:1] == ("diff",):
            return 0, PATCH, ""
        return 0, "", ""

    def ran(self, *args):
        return list(args) in self.calls

    def only_preserved(self):
        root = self.files.preserved
        names = os.listdir(root) if os.path.isdir(root) else []
        self.assertEqual(len(names), 1, "expected one preservation directory, found %r" % names)
        return os.path.join(root, names[0])


class AbortOrphan(Base):
    def test_a_failed_diff_aborts_nothing(self):
        self.diff_fails = True
        rc = F.cmd_abort_orphan({"--repo": self.paths["main"]})
        self.assertFalse(self.ran("merge", "--abort"),
                         "the merge was aborted after its patch failed to preserve; said: %r" % self.said)
        self.assertNotEqual(rc, 0)
        kept = self.only_preserved()
        patch = os.path.join(kept, "diff-binary-HEAD.patch")
        self.assertFalse(os.path.exists(patch) and "fixture diff failed" in read(patch),
                         "a Git error message was stored as the preserved patch")
        self.assertTrue(F.preservation_problems(kept), "an incomplete preservation was called complete")
        text = "\n".join(self.said)
        self.assertIn("REFUSED", text)
        self.assertIn(kept, text, "the refusal must name what WAS kept")

    def test_a_complete_preservation_still_aborts(self):
        rc = F.cmd_abort_orphan({"--repo": self.paths["main"]})
        self.assertEqual(rc, 0, "said: %r" % self.said)
        self.assertTrue(self.ran("merge", "--abort"))
        kept = self.only_preserved()
        self.assertEqual(read(os.path.join(kept, "diff-binary-HEAD.patch")), PATCH)
        self.assertTrue(os.path.isfile(os.path.join(kept, "MERGE_HEAD")))


class Takeover(Base):
    def lease_written(self):
        return F.read_json(self.files.lease)

    def test_a_failed_diff_keeps_the_lease_where_it_is(self):
        self.diff_fails = True
        rc = F.cmd_takeover({"--repo": self.paths["main"]})
        self.assertNotEqual(rc, 0, "the lease changed hands after its preservation failed; said: %r" % self.said)
        self.assertIsNone(self.lease_written(), "a new lease was written")
        self.assertNotIn("TOOK OVER", "\n".join(self.said))

    def test_a_complete_preservation_still_takes_over(self):
        rc = F.cmd_takeover({"--repo": self.paths["main"]})
        self.assertEqual(rc, 0, "said: %r" % self.said)
        lease = self.lease_written()
        self.assertTrue(lease and lease.get("preserved"), "the takeover did not record where it preserved")
        self.assertEqual(read(os.path.join(lease["preserved"], "diff-binary-HEAD.patch")), PATCH)


if __name__ == "__main__":
    unittest.main(verbosity=2)
