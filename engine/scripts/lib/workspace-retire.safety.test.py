#!/usr/bin/env python3
"""Recovery and non-erasure regressions; every repository is disposable."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("retire_safety", HERE / "workspace-retire.py")
retire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retire)


class RecoverySafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="workspace-recovery-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo, self.work = self.root / "repo", self.root / "work"
        self.env = patch.dict(os.environ, {
            "RICHOS_WORKTREE_LEDGER": str(self.root / "ledger.jsonl"),
            "RICHOS_WORKSPACE_RETIRE_DIR": str(self.root / "state"),
            "RICHOS_WORKTREE_TX_DIR": str(self.root / "transactions"),
            "RICHOS_WORKTREE_CAPTURE_DIR": str(self.root / "captures"),
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull,
        })
        self.env.start()
        self.addCleanup(self.env.stop)
        self.repo.mkdir()
        self.git(self.repo, "init", "-q", "-b", "main")
        self.git(self.repo, "config", "user.name", "Disposable Test")
        self.git(self.repo, "config", "user.email", "test@example.invalid")
        self.git(self.repo, "config", "core.hooksPath", os.devnull)
        (self.repo / "seed").write_text("committed head\n")
        self.git(self.repo, "add", "seed")
        self.git(self.repo, "commit", "-qm", "seed")
        self.git(self.repo, "worktree", "add", "-qb", "work", self.work)
        self.owner = "abcdef1234567890"
        self.ledger("registered", repo=str(self.repo), worktree=str(self.work),
                    agent_id=self.owner, teammate="audit", session_id="fixture", branch="work",
                    **{"class": "hand-rolled"})
        self.ledger("terminated", agent_id=self.owner, worktree=str(self.work),
                    reason="witnessed termination", witness="test")
        self.wsid = retire.workspace_id(str(self.repo), str(self.work))

    def git(self, repo, *args, **kwargs):
        return subprocess.run(["git", "-C", str(repo)] + list(map(str, args)),
                              check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs).stdout

    def ledger(self, event, **fields):
        record = {"event": event, "ts": retire.now_iso(), **fields}
        with open(os.environ["RICHOS_WORKTREE_LEDGER"], "a") as f:
            f.write(json.dumps(record) + "\n")

    def retire(self):
        result = retire.retire(self.wsid, entity=str(self.repo), retention=0)
        self.assertEqual("quarantined", result["outcome"], result)
        return result

    def recovery_read(self, result, revision):
        return subprocess.run(["git", "--git-dir=" + result["recovery_git_dir"],
                               "show", revision], check=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE).stdout

    def test_missing_post_rename_identity_restores_workspace_without_pruning(self):
        (self.work / "unique").write_text("preserve this write\n")
        real_identity = retire._durable_fsid
        failures = []

        def identity(path, info):
            if ".richos-retired" in Path(path).parts:
                failures.append(str(path))
                raise OSError("native UUID query failed")
            return real_identity(path, info)

        with patch.object(retire, "_durable_fsid", identity):
            result = retire.retire(self.wsid, entity=str(self.repo), retention=0)
        self.assertTrue(failures, "must exercise identity failure after rename")
        self.assertEqual("refused", result["outcome"], result)
        self.assertEqual("identity-unavailable-after-quarantine", result["reason_code"])
        self.assertIsNone(result["quarantine"])
        self.assertEqual("preserve this write\n", (self.work / "unique").read_text())
        self.assertIn(str(self.work).encode(), self.git(self.repo, "worktree", "list", "--porcelain"))
        records = [json.loads(line) for line in Path(retire.records_path()).read_text().splitlines()]
        self.assertFalse(any(row.get("outcome") == "quarantined" for row in records))

    def test_distinct_staged_version_survives_original_object_cleanup(self):
        (self.work / "draft").write_text("staged version A\n")
        self.git(self.work, "add", "draft")
        blob = self.git(self.work, "rev-parse", ":draft").decode().strip()
        (self.work / "draft").write_text("working version B\n")
        self.git(self.work, "update-index", "--split-index")
        self.retire()
        self.git(self.repo, "prune", "--expire=now")
        missing = subprocess.run(["git", "-C", str(self.repo), "cat-file", "-e", blob],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertNotEqual(0, missing.returncode, "fixture must lose the unprotected original blob")
        # A recovery must also work with the original repository unavailable.
        self.repo.rename(self.root / "unavailable-original")
        result = retire.restore(self.wsid, str(self.root / "restored"))
        self.assertEqual("ok", result["outcome"], result)
        self.assertEqual(b"staged version A\n", self.recovery_read(result, ":draft"))
        self.assertEqual(b"committed head\n", self.recovery_read(result, "HEAD:seed"))
        self.assertEqual("working version B\n",
                         (Path(result["recovery_work_tree"]) / "draft").read_text())
        status = subprocess.run(["git", "--git-dir=" + result["recovery_git_dir"],
                                 "--work-tree=" + result["recovery_work_tree"],
                                 "status", "--porcelain"], check=True, capture_output=True).stdout
        self.assertIn(b"AM draft\n", status)

    def test_all_unmerged_index_stages_are_recoverable(self):
        entries = []
        for stage in (1, 2, 3):
            oid = self.git(self.repo, "hash-object", "-w", "--stdin",
                           input=("conflict stage %d\n" % stage).encode()).decode().strip()
            entries.append("100644 %s %d\tconflicted\n" % (oid, stage))
        self.git(self.work, "update-index", "--index-info", input="".join(entries).encode())
        (self.work / "conflicted").write_text("working conflict resolution\n")
        self.retire()
        self.git(self.repo, "prune", "--expire=now")
        result = retire.restore(self.wsid, str(self.root / "restored"))
        self.assertEqual("ok", result["outcome"], result)
        for stage in (1, 2, 3):
            self.assertEqual(("conflict stage %d\n" % stage).encode(),
                             self.recovery_read(result, ":%d:conflicted" % stage))

    def test_unreadable_index_object_refuses_before_quarantine(self):
        missing = "1" * 40
        self.git(self.work, "update-index", "--add", "--cacheinfo", "100644," + missing + ",missing")
        result = retire.retire(self.wsid, entity=str(self.repo))
        self.assertEqual("failed", result["outcome"], result)
        self.assertEqual("preservation-failed", result["reason_code"])
        self.assertTrue(self.work.is_dir())
        self.assertFalse((self.work.parent / ".richos-retired").exists())

    def test_sweep_cannot_erase_a_write_after_coverage(self):
        result = self.retire()
        qpath = Path(result["quarantine"]["path"])
        real_check = retire.quarantine_covered
        observed = []

        def write_after_check(path, manifest):
            verdict = real_check(path, manifest)
            self.assertTrue(verdict[0], verdict)
            (qpath / "late").write_text("unique late write\n")
            self.assertFalse(real_check(path, manifest)[0])
            observed.append(True)
            return verdict

        with patch.object(retire, "quarantine_covered", write_after_check):
            result = retire.sweep(retention=0, execute=True)
        self.assertEqual([True], observed, "the probe must reach the coverage check")
        self.assertEqual("refused", result["outcome"])
        self.assertEqual("retain", result["items"][0]["action"])
        self.assertEqual("unique late write\n", (qpath / "late").read_text())

    def test_legacy_archive_never_claims_complete_staged_recovery(self):
        result = self.retire()
        manifest_path = Path(result["preservation"]["manifest"])
        manifest = json.loads(manifest_path.read_text())
        del manifest["recovery"]
        manifest_path.write_text(json.dumps(manifest))
        restored = retire.restore(self.wsid, str(self.root / "restored"))
        self.assertEqual("failed", restored["outcome"])
        self.assertEqual("legacy-object-pack-missing", restored["reason_code"])
        self.assertEqual("committed head\n", (self.root / "restored/workspace/seed").read_text())

    def test_sweep_cli_reports_refusal_exit(self):
        result = subprocess.run(["python3", str(HERE / "workspace-retire.py"),
                                 "sweep", "--execute"], capture_output=True, text=True)
        self.assertEqual(3, result.returncode)
        self.assertEqual("automatic-erasure-disabled", json.loads(result.stdout)["reason_code"])

    def test_submodule_index_refuses_without_moving_workspace(self):
        head = self.git(self.work, "rev-parse", "HEAD").decode().strip()
        self.git(self.work, "update-index", "--add", "--cacheinfo", "160000," + head + ",submodule")
        result = retire.retire(self.wsid, entity=str(self.repo))
        self.assertEqual("preservation-failed", result["reason_code"], result)
        self.assertTrue(self.work.is_dir())

    def terminal_module(self):
        spec = importlib.util.spec_from_file_location("terminal_safety", HERE.parent / "reconcile-terminal-worktrees.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_terminal_verified_member_refuses_erasure(self):
        module = self.terminal_module()
        (self.work / "late").write_text("after verification\n")
        record = {"members": [{"state": "verified", "quarantine": str(self.work)}]}
        with self.assertRaisesRegex(module.BlockedFailure, "exclusive-access-unavailable"):
            module.unregister_member(record, 0)
        self.assertEqual("after verification\n", (self.work / "late").read_text())
        self.assertIn(str(self.work).encode(), self.git(self.repo, "worktree", "list", "--porcelain"))

    def test_terminal_unregistered_member_refuses_erasure(self):
        module = self.terminal_module()
        (self.work / "late").write_text("after unregister\n")
        record = {"members": [{"state": "unregistered", "quarantine": str(self.work)}]}
        with self.assertRaisesRegex(module.BlockedFailure, "exclusive-access-unavailable"):
            module.remove_member(record, 0)
        self.assertEqual("after unregister\n", (self.work / "late").read_text())

    def test_terminal_retention_keeps_only_recovery_copy(self):
        module = self.terminal_module()
        cap = self.root / "captures" / "old"
        cap.mkdir(parents=True)
        (cap / "only-copy").write_text("irreplaceable\n")
        record = {"state": "removed", "removed_ts": "2000-01-01T00:00:00+00:00",
                  "session_id": "old", "agent_id": "old",
                  "members": [{"capture_dir": str(cap)}]}
        with patch.object(module.tx, "iter_transactions", return_value=iter([record])):
            result = module.retention_pass()
        self.assertEqual("automatic-erasure-disabled", result["reason_code"])
        self.assertEqual("irreplaceable\n", (cap / "only-copy").read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
