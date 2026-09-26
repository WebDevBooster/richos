#!/usr/bin/env python3
"""Bounded runner fixtures: independent failure, dependencies and quarantine."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("proof_run", HERE / "proof-run.py")
pr = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pr)


class FailurePolicy(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="proof-failure-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = patch.dict(os.environ, {"RICHOS_MACHINE_WORKERS": str(self.root / "machine")})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.args = SimpleNamespace(capacity=2, admission_wait=5, max_cpu=80,
                                    budget=600, deadline=1800, sample_every=.1)

    def item(self, name, code, **kw):
        return pr.Item(name, str(self.root), [sys.executable, "-c", code], weight=.1, **kw)

    def run_items(self, items):
        with patch.object(pr, "SETTLE_SECONDS", 0), patch.object(pr, "admitted", return_value=(True, {})), \
                contextlib.redirect_stdout(io.StringIO()):
            pr.run(items, self.args, str(self.root / "run"), sampler=lambda: {
                "cpu_user_percent": 5, "cpu_system_percent": 2, "swapout_mb_per_s": 0,
                "memory_pressure": "normal"})

    def test_default_preserves_running_and_queued_independent_checks(self):
        items = [self.item("failure", "import time; time.sleep(.4); raise SystemExit(1)"),
                 self.item("sibling", "import time; time.sleep(.8)"),
                 self.item("queued", "pass")]
        self.run_items(items)
        self.assertEqual([i.state for i in items], ["failed", "passed", "passed"])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pr.summarize(items, 1, str(self.root / "run")), 1)

    def test_explicit_fail_fast_cancels_unfinished_checks(self):
        self.args.fail_fast = True
        items = [self.item("failure", "raise SystemExit(1)"), self.item("queued", "pass")]
        self.run_items(items)
        self.assertEqual([i.state for i in items], ["failed", "cancelled"])

    def test_success_dependency_blocks_but_diagnostic_runs(self):
        items = [self.item("failure", "raise SystemExit(1)"),
                 self.item("dependent", "raise AssertionError('must not execute')", requires=["failure"]),
                 self.item("diagnostic", "pass", after=["failure"])]
        self.run_items(items)
        self.assertEqual([i.state for i in items], ["failed", "blocked", "passed"])
        self.assertIsNone(items[1].started)

    def test_contamination_stops_domain_even_if_emitter_exits_zero(self):
        code = ("import os; from pathlib import Path; "
                "p=Path(os.environ['RICHOS_VERIFICATION_CONTAMINATION']); "
                "p.mkdir(); (p/'unit.json').write_text('{}')")
        items = [self.item("unsafe", code), self.item("queued", "pass")]
        self.run_items(items)
        self.assertEqual(items[1].state, "cancelled")
        self.assertEqual(items[-1].label, "execution domain contaminated")
        self.assertEqual(items[-1].state, "failed")

    def test_unknown_or_cyclic_dependencies_refuse_before_launch(self):
        for dependencies in (["missing"], ["self"]):
            item = self.item("self", "pass", requires=dependencies)
            with self.assertRaisesRegex(ValueError, "prerequisites"):
                self.run_items([item])
            self.assertIsNone(item.started)

    def test_cli_defaults_and_compatibility(self):
        for flags, expected in (([], False), (["--keep-going"], False), (["--fail-fast"], True)):
            seen = []
            def selection(args):
                seen.append(args.fail_fast)
                return []
            with patch.object(pr, "selection", side_effect=selection), \
                    patch.object(pr, "default_logdir", return_value=str(self.root)), \
                    contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(pr.main([*flags, "--log-dir", str(self.root / (str(expected) + str(flags)))]), 0)
            self.assertEqual(seen, [expected])


if __name__ == "__main__":
    unittest.main()
