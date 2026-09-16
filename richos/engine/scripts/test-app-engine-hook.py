#!/usr/bin/env python3
"""Synthetic tests of the exact desktop wrapper and canonical Stop analyzer."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ENGINE = Path(__file__).resolve().parents[1]


class DesktopHooks(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="desktop hooks ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.coordination = self.root / "coordination"
        (self.coordination / ".claude/agents").mkdir(parents=True)
        (self.coordination / "orchestration.config").write_text("")
        (self.coordination / ".claude/agents/worker.md").write_text("---\nname: worker\nmodel: sonnet\n---\n")
        self.scope = self.root / "scope.json"
        self.scope.write_text(json.dumps({"version": 1, "actions_allowed": True}))
        self.env = {**os.environ, "RICHOS_APP_STATE": str(self.root / "state"),
            "RICHOS_APP_SCOPE": str(self.scope), "RICHOS_ENTITY_ROOT": str(self.coordination),
            "RICHOS_ENGINE_ROOT": str(ENGINE), "RICHOS_SA_ENTITY_ROOT": str(self.coordination),
            "RICHOS_SA_TEAMS_DIR": str(self.root / "teams"),
            "RICHOS_WORKSPACES_DIR": str(self.root / "workspaces"),
            "CLAUDE_PROJECT_DIR": str(self.coordination), "PYTHONDONTWRITEBYTECODE": "1"}
        subprocess.run(["git", "init", "-q", str(self.coordination)], check=True, capture_output=True)

    def hook(self, event, **fields):
        payload = {"hook_event_name": event, "session_id": "fictional-session", "prompt_id": "fictional-turn",
            "cwd": str(self.coordination), **fields}
        return subprocess.run([sys.executable, str(ENGINE / "scripts/app-engine-hook.py")],
            input=json.dumps(payload), text=True, capture_output=True, env=self.env, timeout=25)

    def test_stop_refuses_a_claim_of_dispatch_without_dispatch(self):
        result = self.hook("Stop", last_assistant_message="I'm dispatching Worker now.", stop_hook_active=False)
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        self.assertIn("dispatch", result.stderr.lower())

    def test_closed_grant_refuses_new_tools_before_recording_an_attempt(self):
        self.scope.write_text('{"version":1,"actions_allowed":false}')
        result = self.hook("PreToolUse", tool_name="Bash", tool_use_id="tool-1", tool_input={"command":"true"})
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / "state/evidence/fictional-session/callbacks.jsonl").exists())
        self.assertEqual(self.hook("Stop", last_assistant_message="I'm dispatching Worker now.").returncode, 0)

    def test_missing_or_corrupt_grant_fails_closed(self):
        for content in ('{', '{"version":99,"actions_allowed":true}'):
            self.scope.write_text(content)
            self.assertEqual(self.hook("PreToolUse", tool_name="Read", tool_use_id="tool-1").returncode, 2)
        self.scope.unlink()
        self.assertEqual(self.hook("PreToolUse", tool_name="Read", tool_use_id="tool-1").returncode, 2)

    def test_provider_callbacks_preserve_identity_and_do_not_attest_user_authority(self):
        self.assertEqual(self.hook("UserPromptSubmit", prompt="Fictional request").returncode, 0)
        self.assertEqual(self.hook("PreToolUse", tool_name="Read", tool_use_id="tool-7", tool_input={"file_path":"fixture"}).returncode, 0)
        path = self.root / "state/evidence/fictional-session/guard-transcript.jsonl"
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        self.assertEqual(rows[0]["promptSource"], "runtime")
        self.assertEqual(rows[1]["message"]["content"][0]["id"], "tool-7")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_malformed_dispatch_is_refused_by_canonical_guard(self):
        result = self.hook("PreToolUse", tool_name="Agent", tool_use_id="tool-8",
            tool_input={"subagent_type":"worker", "prompt":"Edit an arbitrary file"})
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
