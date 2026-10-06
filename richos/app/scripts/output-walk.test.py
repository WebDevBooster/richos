"""Offline output-walk boundaries. No guest, screen or model calls."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True
SCRIPTS = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("output_walk", SCRIPTS / "testvm/output-walk.py")
output = importlib.util.module_from_spec(spec)
spec.loader.exec_module(output)


class OutputWalkTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="output-walk-test-")
        self.addCleanup(tmp.cleanup)
        self.out = Path(tmp.name)
        guard = patch.object(subprocess, "run", side_effect=AssertionError("unexpected guest call"))
        guard.start()
        self.addCleanup(guard.stop)

    def dispatch(self, steps=None, failures=None):
        calls = []
        walk = SimpleNamespace()
        for name in output.STEPS:
            def step(name=name):
                calls.append(name)
                if name in (failures or {}):
                    raise failures[name]
                return {"observed": name}
            setattr(walk, name.replace("-", "_"), step)
        argv = ["output-walk.py", "fixture-vm", "--out", str(self.out), "--expect-sha", "fixture-sha"]
        if steps is not None:
            argv.extend(["--steps", steps])
        with patch.object(sys, "argv", argv), patch.object(output, "OutputWalk", return_value=walk) as owner, \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = output.main()
        return result, calls, json.loads((self.out / "report.json").read_text()), owner

    def test_default_runs_witnesses_without_candidate_steps(self):
        result, calls, report, owner = self.dispatch()
        self.assertEqual(result, 0)
        self.assertEqual(calls, ["identity", "first-run", "connect", "tools", "pdf",
                                 "backend-worker", "front-desk-worker"])
        self.assertEqual([row["step"] for row in report["steps"]], calls)
        self.assertTrue(all(row["outcome"] == "PASS" for row in report["steps"]))
        self.assertEqual((report["vm"], report["expect_sha"]), ("fixture-vm", "fixture-sha"))
        self.assertEqual(owner.call_args.args[0].within, 900)

    def test_explicit_steps_keep_order_and_hyphenated_dispatch(self):
        result, calls, report, _owner = self.dispatch("scroll,job-question,pdf")
        self.assertEqual((result, calls), (0, ["scroll", "job-question", "pdf"]))
        self.assertEqual([row["evidence"] for row in report["steps"]],
                         [{"observed": name} for name in calls])

    def test_unknown_step_refuses_before_constructing_a_walk(self):
        argv = ["output-walk.py", "fixture-vm", "--out", str(self.out), "--expect-sha", "fixture-sha",
                "--steps", "scroll,unknown-step"]
        with patch.object(sys, "argv", argv), patch.object(output, "OutputWalk") as owner, \
                contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as raised:
            output.main()
        self.assertEqual(raised.exception.code, 2)
        owner.assert_not_called()
        self.assertFalse((self.out / "report.json").exists())

    def test_failed_prerequisites_stop_but_independent_witnesses_continue(self):
        for step, error, expected in [
            ("identity", output.StepFailed("wrong source"), ["identity"]),
            ("pdf", RuntimeError("guest refused"), ["identity", "pdf", "backend-worker"]),
            ("pdf", subprocess.TimeoutExpired("fixture", 180), ["identity", "pdf", "backend-worker"]),
        ]:
            with self.subTest(step=step, error=type(error).__name__):
                result, calls, report, _owner = self.dispatch("identity,pdf,backend-worker", {step: error})
                self.assertEqual((result, calls), (1, expected))
                failed = next(row for row in report["steps"] if row["step"] == step)
                self.assertEqual(failed["outcome"], "FAIL")
                self.assertIn(str(error), failed["detail"])

    def walk(self):
        walk = object.__new__(output.OutputWalk)
        walk.vm, walk.out = "fixture-vm", self.out
        walk.a = SimpleNamespace(within=900)
        return walk

    def test_ax_host_wait_outlasts_raised_guest_deadline_and_keeps_larger_caller_budget(self):
        walk = self.walk()
        for guest, caller, expected in [("20", 40, 50), ("150", 40, 180), ("150", 240, 240)]:
            with self.subTest(guest=guest, caller=caller), patch.dict(os.environ, TESTVM_AX_TIMEOUT=guest), \
                    patch.object(output.command_walk.adopt_walk, "command", return_value='{"id":"found"}\n') as run:
                self.assertEqual(walk.ax("find", "--title", "All output", app="fixture-app", timeout=caller),
                                 [{"id": "found"}])
                argv, timeout = run.call_args.args
                self.assertEqual(timeout, expected)
                self.assertEqual(argv, [output.HERE / "ax.sh", "fixture-vm", "find", "--title",
                                        "All output", "--json", "--app", "fixture-app"])

    def test_overlap_refuses_open_panel_pressed_toggle_or_missing_toggle(self):
        for opened, values, fails in [(False, [0, "false"], False), (True, [0, 0], True),
                                       (False, ["1", 0], True), (False, ["true", 0], True),
                                       (False, [0], True)]:
            with self.subTest(opened=opened, values=values), patch.object(output.time, "sleep"):
                walk = self.walk()
                walk.open_panel = walk.to_list = walk.press = Mock()
                walk.present = lambda title: title == "Open the work summary" or opened
                walk.find_all = lambda title, **kw: ([{"title": "Output", "value": v} for v in values]
                                                     if title == "from this thread" else [])
                walk.flip_theme = Mock(return_value=["dark.png", "light.png"])
                if fails:
                    with self.assertRaises(output.StepFailed):
                        walk.overlap()
                else:
                    self.assertFalse(walk.overlap()["output_still_open"])
                evidence = json.loads((self.out / "overlap-observed.json").read_text())
                self.assertEqual(evidence["shots"], ["dark.png", "light.png"])

    def scroll_fixture(self, trace):
        walk = self.walk()
        walk.send = Mock(return_value=("turn-1", 123))
        walk.record = Mock(return_value=[{"path": f"/Acme/scroll-{i:02d}.txt"} for i in range(1, 31)])
        walk.save_record = Mock()
        walk.turn_story = Mock(return_value={})
        walk.close_panel = walk.open_panel = walk.to_list = Mock(
            side_effect=lambda: trace.append(("panel", os.environ["TESTVM_AX_TIMEOUT"])))
        walk.flip_theme = Mock(side_effect=lambda stem: trace.append(("shots", stem)) or ["dark.png", "light.png"])
        walk.app_pid = Mock(return_value=123)
        walk.script = Mock(return_value="0,0,900,100")
        walk.in_panel = lambda nodes: nodes
        walk.divider_x = Mock(return_value=500)
        walk.find_all = lambda title, **kw: trace.append(("read", title)) or [{"title": "row", "y": 120, "h": 20}]
        return walk

    def test_job_question_sets_deadline_before_first_read_and_rejects_false_quit_state(self):
        for quit_card, unavailable, fails in [([], [], False), (["quit card"], [], True),
                                               ([], ["Status unavailable"], True)]:
            with self.subTest(quit_card=quit_card, unavailable=unavailable), patch.dict(os.environ):
                walk = self.walk()
                walk.facts = {"thread": "thread-1"}
                deadlines = []
                walk.close_panel = Mock(side_effect=lambda: deadlines.append(os.environ["TESTVM_AX_TIMEOUT"]))
                walk.present = Mock(return_value=False)
                walk.records = Mock(return_value=[{"thread_id": "thread-1", "obligation_id": "ob-1"}])
                walk.app_pid = Mock(return_value=123)
                walk.conversation_read = Mock(return_value={"question_cards": 1, "quit_card": quit_card,
                                                           "status_unavailable": unavailable})
                walk.flip_theme = Mock(return_value=["dark.png", "light.png"])
                if fails:
                    with self.assertRaisesRegex(output.StepFailed, "cut off by a quit"):
                        walk.job_question()
                else:
                    self.assertEqual(walk.job_question()["question_cards"], 1)
                self.assertEqual(deadlines, ["150"])

    def test_scroll_raises_deadline_and_photographs_before_reading_rows(self):
        trace = []
        with patch.dict(os.environ), patch.object(output.time, "sleep"):
            evidence = self.scroll_fixture(trace).scroll()
        self.assertEqual(trace[:3], [("panel", "150")] * 3)
        self.assertLess(trace.index(("shots", "scroll")), trace.index(("read", "scroll-")))
        self.assertEqual(evidence["recorded"], 30)
        self.assertEqual(evidence["rows_below_window"], 1)

    def test_scroll_without_enough_files_refuses_before_opening_the_panel(self):
        trace = []
        with patch.dict(os.environ), patch.object(output.time, "monotonic", side_effect=[0, 1000]):
            with self.assertRaisesRegex(output.StepFailed, "0 of 30"):
                self.scroll_fixture(trace).scroll()
        self.assertEqual(trace, [])
        self.assertEqual(json.loads((self.out / "scroll-observed.json").read_text())["recorded"], 0)


if __name__ == "__main__":
    unittest.main()
