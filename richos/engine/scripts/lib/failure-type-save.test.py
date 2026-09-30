#!/usr/bin/env python3
"""failure-type-save.test.py — a failed save of the owed-answer record is never silent (P5-48).

The pending record is the only thing that carries an unpaid failure-type
obligation to the next turn. save_pending used to swallow an OSError, so the next
load returned no debt and the obligation was forgotten without a word.
"""

import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("failure_type", os.path.join(HERE, "failure-type.py"))
FT = importlib.util.module_from_spec(spec)
sys.modules["failure_type"] = FT
spec.loader.exec_module(FT)


class SavePending(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="ft-save.")
        self.addCleanup(lambda: os.system("rm -rf '%s'" % self.root))
        FT.SAVE_FAILURES[:] = []

    ITEMS = [{"source": "t", "hash": "h1", "words": "type failure", "at": 1.0}]

    def test_a_good_save_round_trips_and_reports_nothing(self):
        self.assertTrue(FT.save_pending(self.root, "sess1234", self.ITEMS))
        self.assertEqual(FT.load_pending(self.root, "sess1234"), self.ITEMS)
        self.assertEqual(FT.SAVE_FAILURES, [])

    def test_a_failed_save_is_reported_and_returns_false(self):
        err = io.StringIO()
        with mock.patch.object(FT.os, "replace", side_effect=OSError("disk full")), \
                mock.patch.object(FT.sys, "stderr", err):
            ok = FT.save_pending(self.root, "sess1234", self.ITEMS)
        self.assertFalse(ok)
        self.assertTrue(FT.SAVE_FAILURES and "disk full" in FT.SAVE_FAILURES[0], FT.SAVE_FAILURES)
        self.assertIn("could NOT be saved", err.getvalue())

    def test_the_stop_status_line_says_so_instead_of_none(self):
        out = io.StringIO()
        FT.SAVE_FAILURES.append("the owed failure-type answer could NOT be saved at /x (disk full)")
        with mock.patch.object(FT.sys, "stdout", out):
            FT.stop_status("none", "")
        line = out.getvalue()
        self.assertTrue(line.startswith("FT\tcannot\t"), line)
        self.assertIn("disk full", line)

    def test_blocked_keeps_its_letters(self):
        out = io.StringIO()
        FT.SAVE_FAILURES.append("x")
        with mock.patch.object(FT.sys, "stdout", out):
            FT.stop_status("blocked", "ab")
        self.assertEqual(out.getvalue(), "FT\tblocked\tab\n")


if __name__ == "__main__":
    unittest.main()
