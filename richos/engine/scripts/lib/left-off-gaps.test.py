#!/usr/bin/env python3
"""left-off must not print "nothing landed" over a repository whose git log failed.

Hunt P5-08 (part 5): repo_state folded `git log` failing (None) into the same
empty string as "no commit in the window", so a repository nobody could read
rendered "WHAT LANDED: nothing on any integration branch". It now reports
`why_not` for that repository (the channel the report already has for a
repository it cannot answer for), and the closing sentence is only as wide as the
repositories that were read.
"""
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("left_off", os.path.join(HERE, "left-off.py"))
lo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lo)


def run(*args, cwd):
    subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)


def base_result(repos):
    return {"gap_human": "9 hours", "anchor_when": "2026-09-30T20:00:00+00:00", "anchor_text": "go",
            "sitting": [], "sitting_truncated": 0, "last_reply": None, "jobs": [],
            "repos": repos, "repo_scope": "test", "escalations": [], "degraded_rows": 0,
            "transcript": "t.jsonl", "now": "2026-10-01T05:00:00+00:00",
            "transcript_is_previous_session": False}


class LeftOffGaps(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="lo-gaps."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = os.path.join(self.tmp, "repo")
        run("git", "init", "-q", "-b", "main", self.repo, cwd=self.tmp)
        for key, fallback in (("user.email", "tester@example.invalid"), ("user.name", "tester")):
            got = subprocess.run(["git", "config", key], capture_output=True, text=True).stdout.strip()
            run("git", "config", key, got or fallback, cwd=self.repo)
        with open(os.path.join(self.repo, "a.txt"), "w") as fh:
            fh.write("x\n")
        run("git", "add", "-A", cwd=self.repo)
        run("git", "commit", "-q", "-m", "landed in the window", cwd=self.repo)
        p = mock.patch.object(lo, "integration_branch", lambda repo: "main")
        p.start()
        self.addCleanup(p.stop)
        self.end = datetime.now(timezone.utc) + timedelta(minutes=5)
        self.start = self.end - timedelta(hours=1)

    def state(self):
        return lo.repo_state([self.repo], self.start, self.end)[self.repo]

    def test_1_control_a_readable_log_lists_the_commit_and_has_no_why_not(self):
        info = self.state()
        self.assertEqual(info["why_not"], "")
        self.assertEqual([c[2] for c in info["commits"]], ["landed in the window"])

    def test_2_an_empty_window_is_still_an_answer_not_a_gap(self):
        self.start = self.end + timedelta(hours=1)
        self.end = self.start + timedelta(hours=1)
        info = self.state()
        self.assertEqual(info["why_not"], "")
        self.assertEqual(info["commits"], [])

    def test_3_a_failed_git_log_is_a_why_not_not_an_empty_list(self):
        real = lo.git

        def fail_log(root, args, timeout=lo.GIT_TIMEOUT):
            if args[:1] == ["log"]:
                return None
            return real(root, args, timeout)

        with mock.patch.object(lo, "git", fail_log):
            info = self.state()
        self.assertIn("failed", info["why_not"])
        self.assertIn("UNKNOWN", info["why_not"])

    def test_4_the_closing_sentence_is_not_nothing_landed_over_an_unread_repository(self):
        read = {"branch": "main", "commits": [], "why_not": ""}
        unread = {"branch": "main", "commits": [], "why_not": "`git log main` failed"}
        text = lo._render(base_result({"/r/read": read, "/r/unread": unread}), 3, 10, 600)
        self.assertNotIn("nothing on any integration branch", text)
        self.assertIn("could NOT be answered for", text)
        only_read = lo._render(base_result({"/r/read": read}), 3, 10, 600)
        self.assertIn("nothing on any integration branch in the window", only_read)


if __name__ == "__main__":
    unittest.main(verbosity=2)
