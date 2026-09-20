#!/usr/bin/env python3
"""Offline timing proof. No screen, input event or model is used."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
import hashlib

spec = importlib.util.spec_from_file_location("timeline", Path(__file__).with_name("timeline.py"))
timeline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(timeline)


def record(absent=90, present=160, action=(100, 101)):
    return {"clock": "monotonic_ns", "action": {"kind": "native-click",
            "before_ns": action[0]*1000000, "after_ns": action[1]*1000000},
            "frames": [{"number": n, "before_ns": t*1000000, "after_ns": (t+10)*1000000}
                       for n, t in enumerate((absent, present))]}


class Bounds(unittest.TestCase):
    def test_capture_completion_is_the_upper_bound(self):
        result = timeline.visibility_bounds(record(), 0, 1, 100)
        self.assertEqual(result["milliseconds"], [0, 70])
        self.assertEqual(result["acquisition_to_visible"], "PASS")

    def test_straddling_is_unproven(self):
        result = timeline.visibility_bounds(record(present=200), 0, 1, 100)
        self.assertEqual(result["milliseconds"], [0, 110])
        self.assertEqual(result["post_to_visible"], "unproven")

    def test_slow_posting_is_not_a_proven_acquisition_failure(self):
        result = timeline.visibility_bounds(record(absent=220, present=240), 0, 1, 100)
        self.assertEqual(result["post_to_visible"], "over target")
        self.assertEqual(result["acquisition_to_visible"], "unproven")

    def test_wide_action_and_capture_windows_remain_conservative(self):
        result = timeline.visibility_bounds(record(absent=120, present=200, action=(100, 180)), 0, 1, 100)
        self.assertEqual(result["milliseconds"], [0, 110])
        self.assertEqual(result["action_window_ms"], 80)

    def test_invalid_evidence_is_refused(self):
        for value in (float("nan"), float("inf"), 0, -1):
            with self.assertRaises(ValueError):
                timeline.visibility_bounds(record(), 0, 1, value)
        for mutate in (
            lambda r: r.update(clock="wall"),
            lambda r: r["action"].update(kind="none"),
            lambda r: r["action"].update(before_ns=999999999),
            lambda r: r["frames"][1].update(before_ns=1),
            lambda r: r["frames"][1].update(number=2),
        ):
            r = record()
            mutate(r)
            with self.assertRaises(ValueError):
                timeline.visibility_bounds(r, 0, 1, 100)

    def test_cli_checks_frame_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = record()
            for f in r["frames"]:
                data = str(f["number"]).encode()
                (Path(tmp)/("%04d.png" % f["number"])).write_bytes(data)
                f["sha256"] = hashlib.sha256(data).hexdigest()
            (Path(tmp)/"bounds.json").write_text(json.dumps(r))
            self.assertEqual(timeline.cmd_bounds([tmp, "0", "1", "100"]), 0)
            (Path(tmp)/"0001.png").write_bytes(b"changed")
            self.assertEqual(timeline.cmd_bounds([tmp, "0", "1", "100"]), 2)

    def test_native_input_is_behind_host_screen_refusal(self):
        with patch.object(timeline.getpass, "getuser", return_value="operator"), \
             patch.dict(timeline.os.environ, {"RICHOS_QA_CAPTURE": ""}), \
             patch.object(timeline, "native_click") as native:
            with self.assertRaises(SystemExit):
                timeline.cmd_capture(["unused", "1", "--region", "0,0,10,10", "--native-click", "1,1"])
            native.assert_not_called()

    def test_native_click_posts_and_releases_both_events(self):
        cg, cf = Mock(), Mock()
        cg.CGPreflightPostEventAccess.return_value = True
        cg.CGEventCreateMouseEvent.side_effect = [11, 12]
        with patch("ctypes.CDLL", side_effect=[cg, cf]):
            timeline.native_click("5,8")()
        self.assertEqual([c.args for c in cg.CGEventPost.call_args_list], [(0, 11), (0, 12)])
        self.assertEqual([c.args for c in cf.CFRelease.call_args_list], [(11,), (12,)])
        self.assertEqual([c.args for c in cg.CGEventSetIntegerValueField.call_args_list], [(11, 1, 1), (12, 1, 1)])

    def test_native_permission_and_allocation_fail_before_posting(self):
        for allowed in [False, True]:
            cg, cf = Mock(), Mock()
            cg.CGPreflightPostEventAccess.return_value = allowed
            cg.CGEventCreateMouseEvent.side_effect = [11, None]
            with patch("ctypes.CDLL", side_effect=[cg, cf]), self.assertRaises((ValueError, RuntimeError)):
                timeline.native_click("5,8")()
            cg.CGEventPost.assert_not_called()
            if allowed:
                cf.CFRelease.assert_called_once_with(11)

    def test_cli_capture_failure_is_distinct_from_unproven_timing(self):
        with patch.dict(timeline.COMMANDS, {"capture": Mock(side_effect=ValueError("permission unavailable"))}):
            self.assertEqual(timeline.main(["capture"]), 2)

    def test_mock_capture_records_both_regions_and_cleans_up_failure(self):
        def capture(argv, **kwargs):
            Path(argv[-1]).write_bytes(b"fixture")
        with tempfile.TemporaryDirectory() as tmp, \
             patch.dict(timeline.os.environ, {"RICHOS_QA_CAPTURE": "allow"}), \
             patch.object(timeline.subprocess, "run", side_effect=capture), \
             patch.object(timeline, "native_click", return_value=lambda: None) as native:
            timeline.cmd_capture([tmp, ".03", "--region", "0,0,10,10", "--also-region", "10,0,10,10",
                                  "--native-click", "1,1", "--baseline", ".01", "--interval", ".005"])
            a = json.loads((Path(tmp)/"bounds.json").read_text())
            b = json.loads((Path(tmp)/"b/bounds.json").read_text())
            self.assertEqual(a["action"], b["action"])
            self.assertTrue(a["frames"] and b["frames"])
            self.assertTrue(all(f["before_ns"] <= f["after_ns"] for f in a["frames"] + b["frames"]))
            native.assert_called_once_with("1,1")
        with tempfile.TemporaryDirectory() as tmp, \
             patch.dict(timeline.os.environ, {"RICHOS_QA_CAPTURE": "allow"}), \
             patch.object(timeline.subprocess, "run", side_effect=OSError("capture failed")), \
             patch.object(timeline, "native_click", return_value=lambda: self.fail("must not post")):
            with self.assertRaises(RuntimeError):
                timeline.cmd_capture([tmp, ".01", "--region", "0,0,10,10", "--native-click", "1,1", "--baseline", ".02"])
            self.assertFalse((Path(tmp)/"bounds.json").exists())


if __name__ == "__main__":
    unittest.main()
