#!/usr/bin/env python3
"""A failed-deletion retry needs the open-file table (hunt part 5, P5-05).

The normal cleanup arms refuse to delete when the open-file table cannot be read,
because a tree something is reading must never be deleted from under it. The
standing-failure retry skipped that refusal: with no table it went straight on to
DELETE. State is a temporary directory; nothing is deleted (the reaper only PLANS
here; `add` records the decision).
"""
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("scratch_reaper", HERE / "scratch-reaper.py")
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)


class NoWalls(object):
    def check(self, *_a, **_k):
        return None


class StandingFailure(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="reaper-standing-test."))
        self.before = os.environ.get("TMPDIR")
        os.environ["TMPDIR"] = self.tmp
        self.victim = os.path.join(self.tmp, "failed-earlier")
        os.makedirs(self.victim)

    def tearDown(self):
        if self.before is None:
            os.environ.pop("TMPDIR", None)
        else:
            os.environ["TMPDIR"] = self.before
        shutil.rmtree(self.tmp, ignore_errors=True)

    def plan(self, snapshot):
        r = object.__new__(reaper.Reaper)
        r._standing = set()
        r._unfailable = set()
        r.cfg = {"legacy_git_is_fixture": False}
        r.decisions = []
        r.add = lambda path, klass, size, action, why, **_k: r.decisions.append((path, klass, action, why))
        r.open_under_tmp = lambda: snapshot
        r.held_in_snapshot = lambda path, snap: path in snap
        rows = {self.victim: {"first": "2026-09-30", "error": "EPERM", "attempts": 1}}
        with patch.object(reaper, "read_failures", return_value=rows), \
                patch.object(reaper, "failures_path", return_value="/nonexistent"), \
                patch.object(reaper, "check_deadline", return_value=None), \
                patch.object(reaper, "system_protected", return_value=None), \
                patch.object(reaper, "measure", return_value=(0, 0, False)):
            r.scan_standing_failures(NoWalls())
        return r.decisions

    def test_an_unreadable_open_file_table_is_never_a_delete(self):
        decisions = self.plan(None)
        self.assertEqual(len(decisions), 1)
        self.assertEqual(decisions[0][2], reaper.INDETERMINATE, decisions)

    def test_control_a_readable_empty_table_still_retries_the_deletion(self):
        decisions = self.plan(set())
        self.assertEqual([d[2] for d in decisions], [reaper.DELETE], decisions)

    def test_control_a_held_directory_is_kept(self):
        decisions = self.plan({self.victim})
        self.assertEqual([d[2] for d in decisions], [reaper.KEEP], decisions)


if __name__ == "__main__":
    unittest.main()
