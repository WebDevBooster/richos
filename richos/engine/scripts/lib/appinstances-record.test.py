#!/usr/bin/env python3
"""appinstances-record.test.py — P5-48: a failed write of the durable failure
record was swallowed, so a standing "a window refuses to close" alert vanished
with the disk fault. It is now reported (stderr) and carried in the result.
"""

import importlib.util
import io
import os
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("appinstances", os.path.join(HERE, "appinstances.py"))
A = importlib.util.module_from_spec(spec)
sys.modules["appinstances"] = A
spec.loader.exec_module(A)


class FailureRecordWrite(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="appinst-record.")
        self.addCleanup(lambda: os.system("rm -rf '%s'" % self.tmp))
        self.path = os.path.join(self.tmp, "state", "app-instance-failures.json")

    def survivor(self):
        return [{"pid": os.getpid(), "argv": "richos-tauri", "how": "would not quit", "root": "/scratch/x"}]

    def test_a_failed_write_is_reported_not_swallowed(self):
        errors = []
        err = io.StringIO()
        with mock.patch.object(A.os, "replace", side_effect=OSError("disk full")), \
                mock.patch.object(A.sys, "stderr", err):
            rows = A.record_failures(self.survivor(), path=self.path, errors=errors)
        self.assertEqual(len(rows), 1, "the standing row is still returned")
        self.assertTrue(errors and "disk full" in errors[0], errors)
        self.assertIn("could NOT be written", err.getvalue())

    def test_collect_and_record_carries_the_error_in_its_result(self):
        fake = {"collected": [], "survivors": self.survivor(), "left": [], "undecided": [],
                "unreadable": False}
        with mock.patch.object(A, "collect", return_value=fake), \
                mock.patch.object(A, "failures_path", return_value=self.path), \
                mock.patch.object(A.os, "replace", side_effect=OSError("read-only")), \
                mock.patch.object(A.sys, "stderr", io.StringIO()):
            res = A.collect_and_record()
        self.assertTrue(res.get("record_errors"), res)

    def test_a_good_write_reports_nothing(self):
        errors = []
        A.record_failures(self.survivor(), path=self.path, errors=errors)
        self.assertEqual(errors, [])
        self.assertTrue(os.path.exists(self.path))


if __name__ == "__main__":
    unittest.main()
