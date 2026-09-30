#!/usr/bin/env python3
"""A stale session file must not hide the live process that now holds its pid (hunt P5-02).

Session file A names pid 99999 with the start time the old process had. The pid was
reused: a running claude process with that pid started later, and no session file
names it. That process may own scratch, so the reaper must treat it as unattributed
(INDETERMINATE for any scratch written after it started), never as "every process is
attributed, so this session ended". State is a temporary directory; nothing is signaled.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("scratch_reaper", HERE / "scratch-reaper.py")
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)

OLD_START = "Sun Sep 20 08:00:00 2020"
NEW_START = "Sun Sep 20 08:00:00 2026"


class Workspaces(object):
    """Stand-in for the workspace registry: pid 99999 runs, started NEW_START."""

    def process_start(self, pid):
        return ("ok", NEW_START) if int(pid) == 99999 else ("gone", "")

    def session_state(self, session_id):
        return ("unknown", "the registry has no record of it")


class ReusedPid(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="reaper-liveness-test.")
        self.before = os.environ.get("RICHOS_SESSIONS_DIR")
        os.environ["RICHOS_SESSIONS_DIR"] = self.tmp
        Path(self.tmp, "old.json").write_text(json.dumps(
            {"pid": 99999, "sessionId": "dead-session-0000", "procStart": OLD_START}))

    def tearDown(self):
        if self.before is None:
            os.environ.pop("RICHOS_SESSIONS_DIR", None)
        else:
            os.environ["RICHOS_SESSIONS_DIR"] = self.before
        shutil.rmtree(self.tmp, ignore_errors=True)

    def liveness(self):
        with patch.object(reaper, "claude_processes", return_value=[(99999, NEW_START)]):
            return reaper.Liveness(Workspaces())

    def test_the_process_now_holding_a_stale_registrations_pid_is_unattributed(self):
        live = self.liveness()
        self.assertEqual([p for p, _l, _e in live.unattributed], [99999])

    def test_scratch_written_after_that_process_started_is_indeterminate_not_ended(self):
        live = self.liveness()
        newest = reaper.lstart_epoch(NEW_START) + 3600
        verdict, why = live.verdict("some-other-session-1111", newest)
        self.assertEqual(verdict, reaper.INDETERMINATE, why)

    def test_a_live_registration_still_attributes_its_process(self):
        Path(self.tmp, "old.json").write_text(json.dumps(
            {"pid": 99999, "sessionId": "live-session-0000", "procStart": NEW_START}))
        live = self.liveness()
        self.assertEqual(live.unattributed, [])
        self.assertEqual(live.verdict("live-session-0000", 0)[0], reaper.RUNNING)


if __name__ == "__main__":
    unittest.main(verbosity=2)
