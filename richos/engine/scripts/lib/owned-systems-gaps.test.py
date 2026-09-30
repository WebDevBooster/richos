#!/usr/bin/env python3
"""owned-systems: a jurisdiction check that did not ANSWER is UNKNOWN, not "not here".

Hunt P5-08 (part 5): run() returns (None, reason) for a timeout and for a command
that could not be started. judge() treated that exactly like a clean nonzero exit
(OUT-OF-JURISDICTION), so a jurisdiction instrument that hung stood its system
down, left it out of every standing obligation, and render() could print "Every
system in jurisdiction is healthy" with exit 0. A clean nonzero exit still means
"this system is not in this repository": that stand-down is what the declaration
asked for and is kept.
"""
import importlib.util
import os
import shutil
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("owned_systems", os.path.join(HERE, "owned-systems.py"))
osy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(osy)


def row():
    return {"id": "zeta", "title": "a system", "why": "fixture", "jurisdiction": "test -f marker",
            "check": "bash -c 'exit 1'", "timeout": 10, "evidence": "defect", "unknown_exit": []}


class JurisdictionAnswer(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="os-gaps."))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def judge(self, jurisdiction_result):
        calls = []

        def fake_run(cmd, timeout, cwd):
            calls.append(cmd)
            if len(calls) == 1:
                return jurisdiction_result
            return 1, "the real defect\n"         # the check itself, if it is ever reached

        with mock.patch.object(osy, "run", fake_run):
            return osy.judge(row(), self.tmp, self.tmp, None), calls

    def test_1_a_clean_nonzero_exit_is_out_of_jurisdiction_and_the_check_is_not_run(self):
        rec, calls = self.judge((1, ""))
        self.assertEqual(rec["status"], "OUT-OF-JURISDICTION")
        self.assertEqual(len(calls), 1)

    def test_2_a_timeout_is_unknown_not_out_of_jurisdiction(self):
        rec, calls = self.judge((None, "the check overran its declared 20s budget"))
        self.assertEqual(rec["status"], osy.UNKNOWN)
        self.assertIn("overran", " ".join(rec["evidence"]))
        self.assertEqual(len(calls), 1)            # the real check still was not run on a guess

    def test_3_a_jurisdiction_that_could_not_start_is_unknown(self):
        rec, _ = self.judge((None, "the check could not be started: boom"))
        self.assertEqual(rec["status"], osy.UNKNOWN)

    def test_4_the_report_does_not_say_everything_is_healthy_over_it(self):
        rec, _ = self.judge((None, "the check overran its declared 20s budget"))
        rec.setdefault("first_seen", None)
        doc = {"entity": self.tmp, "declaration": "d", "generated_at": "t", "systems": [rec]}
        text = osy.render(doc)
        self.assertNotIn("Every system in jurisdiction is healthy", text)
        self.assertIn("1 system(s) standing", text)
        self.assertEqual([r["id"] for r in osy.ordered_standing(doc)], ["zeta"])

    def test_5_control_a_zero_exit_runs_the_check(self):
        rec, calls = self.judge((0, ""))
        self.assertEqual(len(calls), 2)
        self.assertEqual(rec["status"], osy.UNHEALTHY)


if __name__ == "__main__":
    unittest.main(verbosity=2)
