#!/usr/bin/env python3
"""Branch retirement safety against real Git repos, with injected read/race failures.

All refs and filesystem changes are confined to disposable fixtures. Injection
wraps the real Git boundary rather than substituting the deletion verdict.
"""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

LIBRARY = Path(os.environ.get("WORKSPACE_RETIRE_TEST_LIBRARY", Path(__file__).with_name("workspace-retire.py")))
spec = importlib.util.spec_from_file_location("branch_retirement_under_test", LIBRARY)
retire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retire)


class BranchRetirementSafety(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="branch-retirement-safety-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.env = mock.patch.dict(os.environ, {"HOME": str(self.root), "GIT_CONFIG_NOSYSTEM": "1",
                                               "GIT_CONFIG_GLOBAL": os.devnull})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        (self.repo / "file").write_text("first\n")
        self.git("add", "file")
        self.git("commit", "-qm", "first")
        self.tip = self.git("rev-parse", "HEAD")
        (self.repo / "file").write_text("second\n")
        self.git("commit", "-qam", "second")
        self.other = self.git("rev-parse", "HEAD")
        self.branch = "worker"
        self.ref = "refs/heads/worker"
        self.backup = "refs/richos/retired/fixture/worker"
        self.git("branch", self.branch, self.tip)
        self.git("update-ref", self.backup, self.tip)

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def call(self):
        return retire._delete_branch_at(str(self.repo), self.branch, self.tip, self.backup)

    def retained(self, result, tip=None):
        self.assertFalse(result["deleted"], result)
        self.assertEqual(self.git("rev-parse", "--verify", self.ref), tip or self.tip)

    def transaction_interleave(self, callback):
        original = retire._git
        fired = []
        def wrapped(repo, *args, **kwargs):
            if args[:2] in (("update-ref", "--stdin"), ("update-ref", "-d")):
                fired.append(True)
                callback()
            return original(repo, *args, **kwargs)
        with mock.patch.object(retire, "_git", wrapped):
            result = self.call()
        self.assertEqual(fired, [True], "the race must actually reach deletion")
        return result

    def registry_response(self, response):
        original = retire._git
        def wrapped(repo, *args, **kwargs):
            if args[:2] == ("worktree", "list"):
                return response
            return original(repo, *args, **kwargs)
        return mock.patch.object(retire, "_git", wrapped)

    def retirement_record(self):
        return {"workspace": {"id": "fixture", "repo": str(self.repo)},
                "branch": {"name": self.branch, "head": self.tip, "backup_ref": self.backup},
                "ts": "2020-01-01T00:00:00Z"}

    def test_real_orphan_deletes_and_backup_retains_tip(self):
        result = self.call()
        self.assertTrue(result["deleted"], result)
        self.assertEqual(self.git("rev-parse", self.backup), self.tip)
        self.assertEqual(subprocess.run(["git", "-C", str(self.repo), "show-ref", "--verify",
                                        "--quiet", self.ref]).returncode, 1)
        self.assertEqual(self.call()["reason_code"], "branch-absent")

    def test_symbolic_branch_cannot_redirect_deletion_to_another_ref(self):
        self.git("branch", "preserved", self.tip)
        self.git("symbolic-ref", self.ref, "refs/heads/preserved")
        result = self.call()
        self.assertEqual(subprocess.run(["git", "-C", str(self.repo), "show-ref", "--verify", "--quiet",
                                        "refs/heads/preserved"]).returncode, 0,
                         "deletion must not follow the symbolic branch and erase its target")
        self.assertEqual(self.git("rev-parse", "refs/heads/preserved"), self.tip)
        self.assertTrue(result["deleted"], result)

    def test_symbolic_backup_is_atomically_pinned_as_direct_ref(self):
        self.git("branch", "backup-target", self.tip)
        self.git("symbolic-ref", self.backup, "refs/heads/backup-target")
        result = self.call()
        self.assertTrue(result["deleted"], result)
        self.git("update-ref", "refs/heads/backup-target", self.other)
        self.assertEqual(self.git("rev-parse", self.backup), self.tip)
        self.assertEqual(subprocess.run(["git", "-C", str(self.repo), "symbolic-ref", "-q",
                                        self.backup], capture_output=True).returncode, 1)

    def test_current_branch_retained(self):
        self.git("switch", "-q", self.branch)
        result = self.call()
        self.retained(result)
        self.assertEqual(result["reason_code"], "branch-checked-out")

    def test_attached_branch_retained_even_when_path_is_missing(self):
        work = self.root / "linked\nworktree"
        self.git("worktree", "add", "-q", str(work), self.branch)
        work.rename(self.root / "retained-worktree")
        result = self.call()
        self.retained(result)
        self.assertEqual(result["reason_code"], "branch-checked-out")

    def test_detached_worktree_does_not_block_unrelated_branch(self):
        self.git("worktree", "add", "-q", "--detach", str(self.root / "detached"), self.tip)
        self.assertTrue(self.call()["deleted"])

    def test_registry_unavailable_retains_branch(self):
        for response in (None, subprocess.CompletedProcess([], 128, "", "reader failed")):
            with self.subTest(response=response), self.registry_response(response):
                result = self.call()
            self.retained(result)
            self.assertEqual(result["reason_code"], "worktree-registry-unreadable")

    def test_registry_malformed_retains_branch(self):
        valid = f"worktree {self.repo}\0HEAD {self.other}\0branch refs/heads/main\0\0"
        malformed = ("", "garbage\0\0", valid[:-1],
                     valid.replace("branch refs/heads/main\0", ""),
                     valid.replace("HEAD ", "HEAD invalid"),
                     valid.replace("branch refs/heads/main", "branch refs/tags/main"),
                     valid.replace("branch refs/heads/main", "branch refs/heads/"),
                     valid.replace("branch refs/heads/main\0", "branch refs/heads/main\0detached\0"),
                     valid + valid, valid.replace("HEAD ", "unknown "))
        for output in malformed:
            with self.subTest(output=output), self.registry_response(subprocess.CompletedProcess([], 0, output, "")):
                result = self.call()
            self.retained(result)
            self.assertEqual(result["reason_code"], "worktree-registry-unreadable")

    def test_dry_run_registry_failure_is_refused(self):
        with mock.patch.object(retire, "last_retirement", return_value=self.retirement_record()), \
                self.registry_response(None):
            result = retire.retire_branch("fixture", retention=0, dry_run=True)
        self.assertEqual(result["reason_code"], "worktree-registry-unreadable", result)
        self.assertEqual(self.git("rev-parse", self.ref), self.tip)

    def test_dry_run_missing_attached_path_is_refused(self):
        work = self.root / "linked"
        self.git("worktree", "add", "-q", str(work), self.branch)
        work.rename(self.root / "retained")
        with mock.patch.object(retire, "last_retirement", return_value=self.retirement_record()):
            result = retire.retire_branch("fixture", retention=0, dry_run=True)
        self.assertEqual(result["reason_code"], "branch-checked-out", result)
        self.assertEqual(self.git("rev-parse", self.ref), self.tip)

    def test_tip_moved_before_read_retained(self):
        self.git("update-ref", self.ref, self.other)
        self.retained(self.call(), self.other)

    def test_backup_missing_before_read_retained(self):
        self.git("update-ref", "-d", self.backup)
        self.retained(self.call())

    def test_backup_moved_between_read_and_delete_aborts_transaction(self):
        result = self.transaction_interleave(lambda: self.git("update-ref", self.backup, self.other))
        self.retained(result)
        self.assertEqual(self.git("rev-parse", self.backup), self.other)

    def test_backup_deleted_between_read_and_delete_aborts_transaction(self):
        result = self.transaction_interleave(lambda: self.git("update-ref", "-d", self.backup))
        self.retained(result)

    def test_tip_moved_between_read_and_delete_aborts_transaction(self):
        result = self.transaction_interleave(lambda: self.git("update-ref", self.ref, self.other))
        self.retained(result, self.other)
        self.assertEqual(self.git("rev-parse", self.backup), self.tip)

    def test_post_delete_reader_failure_cannot_report_success(self):
        original = retire._git
        def wrapped(repo, *args, **kwargs):
            if args[:3] == ("show-ref", "--verify", "--quiet"):
                return None
            return original(repo, *args, **kwargs)
        with mock.patch.object(retire, "_git", wrapped):
            result = self.call()
        self.assertFalse(result["deleted"], result)
        self.assertEqual(result["reason_code"], "delete-unverified")
        self.assertEqual(self.git("rev-parse", self.backup), self.tip)


if __name__ == "__main__":
    unittest.main(verbosity=2)
