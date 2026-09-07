#!/usr/bin/env python3
"""Read-only planner acceptance in disposable repositories and history stores."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("planner", HERE / "terminal-branch-cleanup.py")
planner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(planner)


class TerminalBranchPlans(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="terminal-branch-planning-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = mock.patch.dict(os.environ, {"HOME": str(self.root), "GIT_CONFIG_NOSYSTEM": "1"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.repo, self.tip = self.new_repo("seat")
        self.tx = self.transaction(self.repo, self.tip)
        self.record = {"event": "registered", "session_id": "session1", "agent_id": "agent001",
                       "repo": str(self.repo), "worktree": self.tx["members"][0]["path"],
                       "branch": "worker", "ts": "2026-09-01T10:01:00Z"}

    def git(self, repo, *args):
        return subprocess.run(["git", "-C", str(repo), *args], check=True,
                              text=True, capture_output=True).stdout.strip()

    def new_repo(self, name, default="main"):
        repo = self.root / name
        repo.mkdir()
        self.git(repo, "init", "-q", "-b", default)
        self.git(repo, "config", "user.email", "fixture@example.invalid")
        self.git(repo, "config", "user.name", "Fixture")
        (repo / "file").write_text("base\n")
        self.git(repo, "add", "file")
        self.git(repo, "commit", "-qm", "base")
        tip = self.git(repo, "rev-parse", "HEAD")
        self.git(repo, "branch", "worker")
        return repo, tip

    def transaction(self, repo, tip, agent="agent001", session="session1", cls="native"):
        return {"record": "transaction", "sealed": True, "session_id": session, "agent_id": agent,
                "teammate": "worker", "sealed_ts": "2026-09-01T10:00:00Z",
                "terminal": {"ingress": "SubagentStop", "ts": "2026-09-01T11:00:00Z"},
                "state": "removed", "members": [{"repo": str(repo), "path": str(repo / "gone-worker"),
                "class": cls, "branch": "worker", "head": tip, "state": "removed"}]}

    def run_plan(self, txs=None, records=None, policy=None):
        return planner.plan(txs if txs is not None else [self.tx],
                            records if records is not None else [self.record],
                            policy if policy is not None else {str(self.repo): "refs/heads/main"})

    def reason(self, result):
        self.assertEqual(result["eligible"], 0, result)
        return result["members"][0]["reason"]

    @unittest.skipUnless(sys.platform=='darwin','cross-boot UUID contract is macOS only')
    def test_reflog_file_snapshot_survives_kernel_device_renumbering(self):
        spec=importlib.util.spec_from_file_location('renumber_fixture',HERE/'legacy-workspace-gate.test.py')
        fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
        path=self.repo/'.git/logs/HEAD';before=planner._file_snapshot(path)
        with fixture.renumbered_device():after=planner._file_snapshot(path)
        self.assertEqual(after,before)
        self.assertIsInstance(after['device'],str)

    def test_three_repositories_include_native_gone_and_cross_repo_members(self):
        second, tip2 = self.new_repo("engine")
        third, tip3 = self.new_repo("private", "master")
        txs = [self.tx, self.transaction(second, tip2, "agent002", cls="hand-rolled"),
               self.transaction(third, tip3, "agent003", cls="hand-rolled")]
        policy = {str(self.repo): "refs/heads/main", str(second): "refs/heads/main",
                  str(third): "refs/heads/master"}
        before = {str(r): self.git(r, "show-ref") for r in (self.repo, second, third)}
        result = self.run_plan(txs, [], policy)
        self.assertEqual(result["eligible"], 3, result)
        self.assertFalse(result["execution_authorized"])
        for row in result["members"]:
            self.assertEqual(row["reason"], "eligible-plan-only")
            self.assertFalse(row["generation"]["proves_ownership_generation"])
            self.assertEqual(len(row["generation"]["reflog"]["sha256"]), 64)
        self.assertEqual(before, {str(r): self.git(r, "show-ref") for r in (self.repo, second, third)})

    def test_no_terminal_transaction_cannot_authorize_name_shaped_branch(self):
        self.tx["terminal"] = None
        result = self.run_plan()
        self.assertEqual(result["members"], [])
        self.assertEqual(self.git(self.repo, "rev-parse", "worker"), self.tip)

    def test_missing_branch_or_terminal_tip_is_retained_without_guessing(self):
        for missing in ("branch", "head"):
            tx = copy.deepcopy(self.tx)
            del tx["members"][0][missing]
            tx["members"][0]["head_at_seal"] = self.tip
            self.assertEqual(self.reason(self.run_plan([tx])), "terminal-branch-or-tip-missing")

    def test_explicit_integration_required_and_current_feature_is_not_used(self):
        self.git(self.repo, "switch", "-qc", "feature")
        self.assertEqual(self.reason(self.run_plan(policy={})), "integration-policy-missing")
        self.assertEqual(self.run_plan()["members"][0]["integration_ref"], "refs/heads/main")

    def test_current_and_attached_branches_are_retained(self):
        self.git(self.repo, "switch", "-q", "worker")
        self.assertEqual(self.reason(self.run_plan()), "branch-checked-out")
        self.git(self.repo, "switch", "-q", "main")
        work = self.root / "attached"
        self.git(self.repo, "worktree", "add", "-q", str(work), "worker")
        work.rename(self.root / "missing-registered")
        self.assertEqual(self.reason(self.run_plan()), "branch-checked-out")

    def test_unmerged_branch_retained_even_when_current_feature_contains_it(self):
        self.git(self.repo, "switch", "-q", "worker")
        (self.repo / "file").write_text("unmerged\n")
        self.git(self.repo, "commit", "-qam", "worker change")
        self.tx["members"][0]["head"] = self.git(self.repo, "rev-parse", "HEAD")
        self.git(self.repo, "switch", "-qc", "feature")
        self.assertEqual(self.reason(self.run_plan()), "unmerged")

    def test_moved_branch_retained(self):
        (self.repo / "file").write_text("new\n")
        self.git(self.repo, "commit", "-qam", "new")
        self.git(self.repo, "branch", "-f", "worker", "main")
        self.assertEqual(self.reason(self.run_plan()), "branch-moved")

    def test_later_same_tip_branch_owner_vetoes_old_terminal(self):
        newer = dict(self.record, session_id="session2", agent_id="agent002", ts="2026-09-01T12:00:00Z")
        result = self.run_plan(records=[self.record, newer])
        self.assertEqual(self.reason(result), "later-or-undated-ownership")
        self.assertEqual(self.git(self.repo, "rev-parse", "worker"), self.tip)

    def test_live_or_unknown_transaction_vetoes_even_without_ledger_row(self):
        live = copy.deepcopy(self.tx)
        live.update(agent_id="agent002", session_id="session2", terminal=None)
        self.assertEqual(self.reason(self.run_plan([self.tx, live])), "competing-live-or-unknown-transaction")

    def test_undated_unknown_owner_vetoes(self):
        unknown = dict(self.record, agent_id="unknown", ts=None)
        self.assertEqual(self.reason(self.run_plan(records=[unknown])), "later-or-undated-ownership")

    def test_incomplete_same_repository_owner_cannot_be_dismissed(self):
        unknown = {"event": "registered", "repo": str(self.repo)}
        self.assertEqual(self.reason(self.run_plan(records=[unknown])), "later-or-undated-ownership")

    def test_malformed_member_path_is_retained(self):
        self.tx["members"][0]["path"] = 42
        self.assertEqual(self.reason(self.run_plan()), "member-identity-incomplete")

    def test_symbolic_integration_ref_cannot_stand_in_for_integration_branch(self):
        self.git(self.repo, "switch", "-qc", "feature")
        self.git(self.repo, "symbolic-ref", "refs/heads/main", "refs/heads/worker")
        self.assertEqual(self.reason(self.run_plan()), "symbolic-or-unreadable-ref")

    def test_earlier_owner_without_exact_terminal_transaction_vetoes(self):
        unknown = dict(self.record, agent_id="older", session_id="old-session", ts="2026-08-01T10:00:00Z")
        self.assertEqual(self.reason(self.run_plan(records=[unknown])), "competing-live-or-unknown-owner")

    def test_old_terminal_cannot_clear_unrelated_or_post_terminal_registration(self):
        old = self.transaction(self.repo, self.tip, "oldagent", "older")
        old["sealed_ts"] = "2026-09-01T08:00:00Z"
        old["terminal"]["ts"] = "2026-09-01T09:00:00Z"
        registration = dict(self.record, session_id="older", agent_id="oldagent", ts="2026-09-01T08:30:00Z")
        # An exact earlier terminal generation is a valid compatibility control.
        self.assertTrue(self.run_plan([self.tx, old], [registration])["members"][0]["eligible"])
        unrelated = copy.deepcopy(old)
        unrelated["members"][0].update(branch="unrelated", path=str(self.repo / "unrelated"))
        row = self.run_plan([self.tx, unrelated], [registration])["members"][0]
        self.assertFalse(row["eligible"], row)
        self.assertIn("competing-live-or-unknown-owner", row["ownership_vetoes"])
        registration["ts"] = "2026-09-01T09:30:00Z"
        row = self.run_plan([self.tx, old], [registration])["members"][0]
        self.assertFalse(row["eligible"], row)
        self.assertIn("competing-live-or-unknown-owner", row["ownership_vetoes"])

    def test_prepared_then_bound_owner_is_not_mistaken_for_reuse(self):
        prepared = dict(self.record, event="prepared", agent_id=None, teammate="worker", ts="2026-09-01T09:59:00Z")
        self.assertEqual(self.run_plan(records=[prepared, self.record])["eligible"], 1)

    def test_same_branch_name_in_other_repo_does_not_veto(self):
        second, tip = self.new_repo("other")
        row = dict(self.record, repo=str(second), worktree=str(second / "worker"), agent_id="agent002", ts=None)
        self.assertEqual(self.run_plan(records=[self.record, row])["eligible"], 1)

    def test_unreadable_and_malformed_registry_cannot_be_eligible(self):
        original = planner._git
        for response in (None, subprocess.CompletedProcess([], 128, "", "failed"),
                         subprocess.CompletedProcess([], 0, "garbage\0\0", "")):
            def wrapped(repo, *args, **kwargs):
                return response if args[:2] == ("worktree", "list") else original(repo, *args, **kwargs)
            with mock.patch.object(planner, "_git", wrapped):
                self.assertEqual(self.reason(self.run_plan()), "worktree-registry-unreadable")

    def test_missing_reflog_retained_and_branch_absence_reported(self):
        (self.repo / ".git/logs/refs/heads/worker").unlink()
        self.assertEqual(self.reason(self.run_plan()), "branch-generation-unavailable")
        self.git(self.repo, "branch", "-D", "worker")
        self.assertEqual(self.reason(self.run_plan()), "branch-absent")

    def test_malformed_history_vetoes_all_candidates(self):
        result = self.run_plan(records=[{}])
        self.assertEqual(self.reason(result), "input-history-unreadable")
        self.assertTrue(result["errors"])

    def test_refs_changing_during_snapshot_cannot_be_eligible(self):
        original = planner._file_snapshot
        def wrapped(path):
            result = original(path)
            self.git(self.repo, "branch", "-D", "worker")
            return result
        with mock.patch.object(planner, "_file_snapshot", wrapped):
            self.assertEqual(self.reason(self.run_plan()), "refs-changed-during-planning")

    def store_history(self, corrupt=False):
        root = self.root / "transactions"
        session = root / "session1"
        session.mkdir(parents=True)
        (session / "agent001.json").write_text(json.dumps(self.tx))
        ledger = self.root / "ledger.jsonl"
        ledger.write_text(json.dumps(self.record) + "\n" + ("{broken\n" if corrupt else ""))
        return root, ledger

    def test_cli_reads_actual_transaction_store_and_journals_without_git_changes(self):
        root, ledger = self.store_history()
        journal = self.root / "plans.jsonl"
        env = dict(os.environ, RICHOS_WORKTREE_TX_DIR=str(root), RICHOS_WORKTREE_LEDGER=str(ledger))
        before = self.git(self.repo, "show-ref")
        args = ["python3", str(HERE / "terminal-branch-cleanup.py"), "--integration",
                str(self.repo) + "=refs/heads/main", "--journal", str(journal)]
        for _ in range(2):
            result = subprocess.run(args, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["eligible"], 1, report)
        self.assertEqual(len(journal.read_text().splitlines()), 2)
        self.assertEqual(before, self.git(self.repo, "show-ref"))

    def test_actual_loader_rejects_corrupt_ledger_and_skipped_transaction(self):
        root, ledger = self.store_history(corrupt=True)
        with mock.patch.dict(os.environ, RICHOS_WORKTREE_TX_DIR=str(root), RICHOS_WORKTREE_LEDGER=str(ledger)):
            txs, records, errors = planner.load_history()
            self.assertTrue(errors)
            self.assertEqual(self.reason(planner.plan(txs, records, {str(self.repo): "refs/heads/main"}, input_errors=errors)),
                             "input-history-unreadable")
            ledger.write_text(json.dumps(self.record) + "\n")
            (root / "session1/agent002.json").write_text("{broken")
            _, _, errors = planner.load_history()
            self.assertTrue(any("transaction history" in e for e in errors), errors)


if __name__ == "__main__":
    unittest.main(verbosity=2)
