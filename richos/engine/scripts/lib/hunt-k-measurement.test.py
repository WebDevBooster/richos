#!/usr/bin/env python3
"""Hunt severity-3 group K: measurement tools must not state what they did not measure.

P5-29 qa-throwaways: an unrecognizable transcript is "cannot answer", not a zero.
P5-30 qa-throwaways: same basename with different content is two scripts.
P5-31 handoff-facts: a failed liveness command is UNMEASURED, not ok with alive=0.
P5-46 land-completeness-measure: an echoed or failed `git merge` is not a landing.
P5-58 left-off: f1 does not match a reflog line naming f10.
P5-59 left-off: the token total covers every job, not just the displayed rows.
"""
import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


qt = load("qa_throwaways", os.path.join(HERE, "qa-throwaways.py"))
hf = load("handoff_facts", os.path.join(SCRIPTS, "handoff-facts.py"))
lm = load("land_measure", os.path.join(SCRIPTS, "land-completeness-measure.py"))
lo = load("left_off", os.path.join(HERE, "left-off.py"))


def write_lines(lines):
    fd, path = tempfile.mkstemp(suffix=".jsonl")
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    return path


def write_row(path, content):
    return json.dumps({"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "Write",
         "input": {"file_path": path, "content": content}}]}})


class QaThrowaways(unittest.TestCase):
    def test_p5_29_unrecognized_file_cannot_answer(self):
        path = write_lines(["{}", "not json"])
        self.addCleanup(os.unlink, path)
        with self.assertRaises(qt.CannotAnswer):
            qt.scan(path)

    def test_p5_30_same_name_different_content_is_two_scripts(self):
        path = write_lines([write_row("/one/analyze.py", "print(1)"),
                            write_row("/two/analyze.py", "print(2)")])
        self.addCleanup(os.unlink, path)
        events, _ = qt.scan(path)
        scripts, _ = qt.classify(events)
        self.assertEqual(len(scripts), 2)


class HandoffFacts(unittest.TestCase):
    def test_p5_31_failed_liveness_is_unmeasured(self):
        with mock.patch.object(hf, "run", return_value=(2, "ERROR: cannot resolve the entity")):
            fact = hf.measure_agents()
        self.assertFalse(fact["ok"])


class LandMeasure(unittest.TestCase):
    def test_p5_46_echoed_merge_is_not_a_land(self):
        self.assertIsNone(lm.classify_land("echo git merge cc/example"))
        self.assertEqual(lm.classify_land("cd x && git merge cc/example"), "cc/example")

    def test_p5_46_failed_merge_is_not_a_land(self):
        use = {"type": "assistant", "timestamp": "t1", "message": {"content": [
            {"type": "tool_use", "id": "u1", "name": "Bash",
             "input": {"command": "git merge cc/example"}}]}}
        res = {"type": "user", "timestamp": "t2", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "u1", "is_error": True,
             "content": "refused"}]}}
        path = write_lines([json.dumps(use), json.dumps(res)])
        self.addCleanup(os.unlink, path)
        self.assertEqual([e for e in lm.walk_transcript(path) if e[0] == "land"], [])


class LeftOff(unittest.TestCase):
    def test_p5_58_prefix_name_is_not_a_match(self):
        self.assertFalse(lo.names_ref("cc/mark-opus-f1", "merge cc/mark-opus-f10: ff"))
        self.assertTrue(lo.names_ref("cc/mark-opus-f1", "merge cc/mark-opus-f1: ff"))
        self.assertTrue(lo.names_ref("mark-opus-f1", "merge cc/mark-opus-f1: ff"))

    def test_p5_59_total_counts_hidden_jobs(self):
        n = lo.MAX_JOBS + 1
        jobs = [{"name": "j%d" % i, "title": "t", "tokens": 1, "landed": "LANDED",
                 "no_completion_notice": False} for i in range(n)]
        result = {"gap_human": "9 hours", "anchor_when": "2026-09-30T20:00:00+00:00",
                  "anchor_text": "go", "sitting": [], "sitting_truncated": 0,
                  "last_reply": None, "jobs": jobs, "repos": {}, "repo_scope": "test",
                  "escalations": [], "degraded_rows": 0, "transcript": "t.jsonl",
                  "now": "2026-10-01T05:00:00+00:00",
                  "transcript_is_previous_session": False}
        text = lo._render(result, 3, 10, 600)
        self.assertIn("%d tokens over %d job(s)" % (n, n), text)


if __name__ == "__main__":
    unittest.main()
