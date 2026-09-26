#!/usr/bin/env python3
"""Bounded runner fixtures: independent failure, dependencies and quarantine."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import subprocess
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
        return pr.Item(name, str(self.root), [sys.executable, "-c", code], weight=kw.pop("weight", .1), **kw)

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
        self.assertGreater(items[1].admission_wait, 0)

    def test_success_dependency_blocks_but_diagnostic_runs(self):
        items = [self.item("failure", "raise SystemExit(1)"),
                 self.item("dependent", "raise AssertionError('must not execute')", requires=["failure"]),
                 self.item("diagnostic", "pass", after=["failure"])]
        self.run_items(items)
        self.assertEqual([i.state for i in items], ["failed", "blocked", "passed"])
        self.assertIsNone(items[1].started)
        self.assertGreater(items[1].admission_wait, 0)

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

    def test_large_engine_slot_refusal_preserves_independent_check(self):
        self.args.slot_wait = .5
        slot_root = self.root / "engine-slot"
        code = ("import sys; sys.path.insert(0,sys.argv[1]); import engine_pass; "
                "s=engine_pass.acquire(20,'fixture',sys.argv[2],wait=0); "
                "print('ready',flush=True); input()")
        with patch.dict(os.environ, {"RICHOS_ENGINE_PASS_DIR": str(slot_root)}):
            holder = subprocess.Popen([sys.executable, "-c", code,
                                       str(Path(pr.engine_pass.__file__).parent), str(self.root)],
                                      stdout=subprocess.PIPE, stdin=subprocess.PIPE,
                                      stderr=subprocess.DEVNULL, text=True)
            try:
                self.assertEqual(holder.stdout.readline().strip(), "ready")
                items = [pr.Item("engine-%d" % i, str(self.root),
                                 ["bash", "scripts/ci-shard.sh", "--only-units", str(i)])
                         for i in range(20)]
                independent = self.item("independent", "pass")
                items.append(independent)
                self.run_items(items)
                self.assertEqual(independent.state, "passed")
                self.assertTrue(all(i.state == "not-admitted" for i in items[:-1]))
                self.assertTrue(all(i.started is None for i in items[:-1]))
                self.assertTrue(all(i.admission_wait >= .5 for i in items[:-1]))
            finally:
                holder.communicate("\n", timeout=5)

    def test_lane_refill_avoids_global_delay_but_new_lane_still_ramps(self):
        items = [self.item("slow", "import time; time.sleep(4)", lane="a", weight=3),
                 self.item("first", "pass", lane="b", weight=2),
                 self.item("replacement", "pass", lane="b", weight=1)]
        with patch.object(pr, "admitted", return_value=(True, {})), \
                contextlib.redirect_stdout(io.StringIO()):
            pr.run(items, self.args, str(self.root / "run"), sampler=lambda: {
                "cpu_user_percent": 5, "cpu_system_percent": 2, "swapout_mb_per_s": 0,
                "memory_pressure": "normal"})
        self.assertTrue(all(i.state == "passed" for i in items))
        self.assertGreaterEqual(items[1].started - items[0].started, pr.SETTLE_SECONDS)
        self.assertLess(items[2].started - items[1].started, pr.SETTLE_SECONDS)

    def test_shared_host_sample_keeps_pressure_and_never_reuses_stale_or_failed_data(self):
        values = iter([
            {"cpu_user_percent": 5, "cpu_system_percent": 2, "memory_pressure": "critical",
             "swapout_mb_per_s": 0},
            {"cpu_user_percent": 95, "cpu_system_percent": 2, "memory_pressure": "normal",
             "swapout_mb_per_s": 0},
        ])
        calls = []
        def sample():
            calls.append(1)
            return next(values)
        with patch.object(pr.time, "monotonic", return_value=10) as clock:
            shared = pr.HostSamples(sample, 10)
            self.assertFalse(pr.admitted(self.args, shared)[0])
            self.assertFalse(pr.admitted(self.args, shared)[0])
            self.assertEqual(len(calls), 1)
            clock.return_value = 11.1
            self.assertFalse(pr.admitted(self.args, shared)[0])
            self.assertEqual(len(calls), 2)
            clock.return_value = 12.2
            with self.assertRaises(StopIteration):
                shared()
            with self.assertRaises(StopIteration):
                shared()
            self.assertEqual(len(calls), 4)

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
