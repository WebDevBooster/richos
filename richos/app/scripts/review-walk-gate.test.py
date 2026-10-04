#!/usr/bin/env python3
"""review-walk-gate.test.py — no RichConnect build goes to a store review before an automated walk of
exactly what the reviewer does has passed on that exact build (richos/mobile/perf/reviewwalk.py; CEO
2026-10-04, richos-hq/wiki/ceo-decisions.md §107).

A scratch records directory stands for /Volumes/E1TB/state/richos/review-walk. No app, simulator,
phone, store or network.

  W1  no record for the build's commit refuses, and so does an unreadable one (fails closed)
  W2  a failed walk refuses, naming the step it failed at
  W3  a record for different code refuses: only another commit was walked, or the file under this
      commit's name names another commit or the other platform
  W4  the passing case: passed, every step ok, for this platform and this exact commit
  W5  the command line: a refusal exits 1 with one REFUSED line; there is no skip flag; `write`
      refuses a record whose passed disagrees with its steps
"""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "mobile/perf"))
import reviewwalk  # noqa: E402

COMMIT = "0123456789abcdef0123456789abcdef01234567"
OTHER = "fedcba9876543210fedcba9876543210fedcba98"
STEPS = ["sign in", "get a pairing link", "open it in the app", "six words match and They match",
         "send a message and see the Demo reply", "reset the review host"]


def record(commit=COMMIT, platform="ios", failed_at=None):
    steps = [{"name": n, "ok": n != failed_at, "detail": "timed out" if n == failed_at else ""} for n in STEPS]
    return {"platform": platform, "commit": commit, "passed": failed_at is None,
            "at": "2026-10-04T12:00:00Z", "host": "apple-review.richos.dev", "steps": steps}


class Gate(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory(prefix="review-walk-gate-")
        self.root = self.dir.name

    def tearDown(self):
        self.dir.cleanup()

    def refused(self, words, commit=COMMIT, platform="ios"):
        with self.assertRaises(reviewwalk.Refused) as caught:
            reviewwalk.check(platform, commit, root=self.root)
        self.assertIn(commit[:12], str(caught.exception))
        self.assertRegex(str(caught.exception), words)

    def test_w1_no_record_refuses(self):
        self.refused("no review walk has run on this commit")
        path = reviewwalk.path_for("ios", COMMIT, self.root)
        path.parent.mkdir(parents=True)
        path.write_text("{not json")
        self.refused("unreadable")

    def test_w2_failed_walk_refuses_naming_the_step(self):
        reviewwalk.write(record(failed_at="send a message and see the Demo reply"), root=self.root)
        self.refused("FAILED at step 'send a message and see the Demo reply': timed out")
        # A hand-edited passed: true beside a failed step is still a refusal.
        path = reviewwalk.path_for("ios", COMMIT, self.root)
        bad = record(failed_at="reset the review host")
        bad["passed"] = True
        path.write_text(json.dumps(bad))
        self.refused("FAILED at step 'reset the review host'")

    def test_w3_record_for_different_code_refuses(self):
        reviewwalk.write(record(commit=OTHER), root=self.root)
        self.refused("no review walk has run on this commit")
        path = reviewwalk.path_for("ios", COMMIT, self.root)
        path.write_text(json.dumps(record(commit=OTHER)))
        self.refused("not this build")
        path.write_text(json.dumps(record(platform="android")))
        self.refused("not this build")
        reviewwalk.write(record(platform="android"), root=self.root)
        self.refused("no review walk has run", platform="android", commit=OTHER)

    def test_w4_passing_walk_for_this_exact_commit_passes(self):
        written = reviewwalk.write(record(), root=self.root)
        self.assertEqual(written, Path(self.root) / "ios" / f"{COMMIT}.json")
        result = reviewwalk.check("ios", COMMIT, root=self.root)
        self.assertTrue(result["ok"])
        self.assertEqual(result["commit"], COMMIT)
        self.assertIn("review walk PASSED on apple-review.richos.dev", result["line"])
        # The latest walk replaces the earlier one: a later failure withdraws the pass.
        reviewwalk.write(record(failed_at="sign in"), root=self.root)
        self.refused("FAILED at step 'sign in'")

    def test_w5_command_line(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            code = reviewwalk.main(["check", "--platform", "ios", "--commit", "not-a-commit"])
        self.assertEqual(code, 1)
        self.assertTrue(err.getvalue().startswith("REFUSED by the review-walk gate (CEO §107): "))
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            reviewwalk.main(["check", "--platform", "ios", "--commit", COMMIT, "--skip"])
        bad = record()
        bad["passed"] = False
        with self.assertRaises(ValueError):
            reviewwalk.write(bad, root=self.root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
