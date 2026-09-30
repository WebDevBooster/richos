#!/usr/bin/env python3
"""Registered workspace paths stored as objects are protected from cleanup (hunt part 5, P5-04).

The workspace registry stores `workspaces: [{"path": ...}, ...]`. The harvest that
builds the protected set read only string items of that list, so every registered
path in the current object format was missing from it. State is a temporary
directory named by CLAUDE_CONFIG_DIR; nothing outside it is read or written.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("scratch_reaper", HERE / "scratch-reaper.py")
reaper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reaper)


class RegisteredWorkspaces(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="reaper-registered-test.")
        self.before = os.environ.get("CLAUDE_CONFIG_DIR")
        os.environ["CLAUDE_CONFIG_DIR"] = self.tmp
        agents = Path(self.tmp, "state", "workspaces", "agents")
        agents.mkdir(parents=True)
        (agents / "a.json").write_text(json.dumps({
            "name": "worker",
            "workspaces": [{"path": "/scratch/ws-object-one", "repo": "/r"},
                           {"path": "/scratch/ws-object-two", "repo": "/r"},
                           "/scratch/ws-legacy-string"],
            "worktree": "/scratch/ws-single"}))
        (Path(self.tmp, "state", "worktree-ledger.jsonl")).write_text(
            json.dumps({"event": "x", "workspaces": [{"dir": "/scratch/ws-ledger-object"}]}) + "\n")

    def tearDown(self):
        if self.before is None:
            os.environ.pop("CLAUDE_CONFIG_DIR", None)
        else:
            os.environ["CLAUDE_CONFIG_DIR"] = self.before
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_every_registered_shape_is_protected(self):
        got = reaper.registered_workspaces()
        for want in ("/scratch/ws-object-one", "/scratch/ws-object-two", "/scratch/ws-legacy-string",
                     "/scratch/ws-single", "/scratch/ws-ledger-object"):
            self.assertIn(os.path.realpath(want), got, want)


if __name__ == "__main__":
    unittest.main()
