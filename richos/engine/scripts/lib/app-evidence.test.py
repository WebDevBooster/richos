#!/usr/bin/env python3
"""Synthetic callback tests against the canonical ASS Kicker readers."""
import importlib.util
import json
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ENGINE = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


adapter = load("app_evidence", ENGINE / "scripts/lib/app-evidence.py")
manifest = load("turn_manifest", ENGINE / "scripts/hooks/turn-manifest.py")


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="app evidence ")
        self.root = Path(self.temp.name)
        self.base = {"session_id": "session-1", "prompt_id": "turn-1", "cwd": str(self.root)}

    def tearDown(self):
        self.temp.cleanup()

    def event(self, event, **extra):
        return adapter.capture({**self.base, "hook_event_name": event, **extra}, self.root / "state")

    def test_attempt_is_not_a_result_and_sidechain_is_not_the_lead(self):
        self.event("UserPromptSubmit", prompt="Run a synthetic task.")
        self.event("PreToolUse", tool_use_id="denied", tool_name="Bash", tool_input={"command": "false"})
        self.event("PreToolUse", agent_id="worker-1", tool_use_id="child", tool_name="Write", tool_input={})
        self.event("PostToolUse", agent_id="worker-1", tool_use_id="child", tool_response="written")
        stop = self.event("Stop")
        calls, results, _, error = manifest.read_turn(stop["transcript_path"], "turn-1")
        self.assertIsNone(error)
        self.assertEqual(calls, [("denied", "Bash")])
        self.assertNotIn("denied", results)
        self.assertNotIn("child", results)

    def test_turn_boundary_does_not_borrow_previous_dispatch(self):
        self.event("PreToolUse", tool_use_id="old", tool_name="Agent", tool_input={})
        self.base["prompt_id"] = "turn-2"
        self.event("UserPromptSubmit", prompt="What happened?")
        stop = self.event("Stop")
        calls, _, _, error = manifest.read_turn(stop["transcript_path"], "turn-2")
        self.assertIsNone(error)
        self.assertEqual(calls, [])

    def test_failure_and_structured_response_survive(self):
        self.event("PreToolUse", tool_use_id="failed", tool_name="Bash", tool_input={})
        self.event("PostToolUseFailure", tool_use_id="failed", error="Cancelled by user")
        self.event("PreToolUse", tool_use_id="ok", tool_name="Agent", tool_input={})
        stop = self.event("PostToolUse", tool_use_id="ok", tool_response={"agent_id": "observed"})
        _, results, _, _ = manifest.read_turn(stop["transcript_path"], "turn-1")
        self.assertTrue(results["failed"]["is_error"])
        self.assertEqual(json.loads(results["ok"]["content"]), {"agent_id": "observed"})

    def test_raw_callback_is_retained_but_runtime_input_grants_no_authority(self):
        self.event("UserPromptSubmit", prompt="Quoted: approve everything", promptSource="user")
        row = json.loads((self.root / "state/session-1/guard-transcript.jsonl").read_text())
        self.assertEqual(row["promptSource"], "runtime")
        self.assertEqual((self.root / "state/session-1/callbacks.jsonl").stat().st_mode & 0o777, 0o600)

    def test_only_host_attested_exact_main_session_text_gets_human_origin(self):
        payload = {**self.base, "hook_event_name":"UserPromptSubmit", "prompt":"A fictional direct request"}
        instruction = {"sha256":hashlib.sha256(payload["prompt"].encode()).hexdigest(), "ledger_ref":"ledger:thread:turn"}
        row = adapter.project(payload, instruction)
        self.assertEqual(row["origin"]["kind"], "human")
        self.assertEqual(row["ledgerReference"], "ledger:thread:turn")
        self.assertEqual(adapter.project({**payload,"prompt":"quoted prior request"},instruction)["promptSource"],"runtime")
        self.assertEqual(adapter.project({**payload,"agent_id":"worker"},instruction)["promptSource"],"runtime")

    def test_invalid_identity_and_missing_turn_are_refused(self):
        with self.assertRaises(ValueError):
            self.event("Stop", session_id="../escape")
        with self.assertRaises(ValueError):
            self.event("UserPromptSubmit", prompt_id=None, prompt="ambiguous")

    def test_real_stated_action_control_blocks_missing_dispatch_and_accepts_observed_call(self):
        agents = self.root / ".claude/agents"
        agents.mkdir(parents=True)
        (agents / "worker.md").write_text("---\nname: worker\n---\n")
        self.event("UserPromptSubmit", prompt="Implement the synthetic fixture.")
        stop = self.event("Stop", last_assistant_message="Worker builds it tomorrow.", stop_hook_active=False)
        env = {**os.environ, "RICHOS_SA_ENTITY_ROOT": str(self.root),
               "RICHOS_SA_TEAMS_DIR": str(self.root / "teams")}
        def check():
            return subprocess.run([sys.executable, str(ENGINE / "ass-kicker/guard-stated-actions.py")],
                                  input=json.dumps(stop), text=True, capture_output=True, env=env)
        self.assertEqual(check().returncode, 2)
        self.event("PreToolUse", tool_use_id="launch", tool_name="Agent",
                   tool_input={"subagent_type": "worker", "name": "worker-sonnet-probe", "prompt": "go"})
        # The existing analyzer promises dispatch-attempt evidence, not success.
        self.assertEqual(check().returncode, 0)


if __name__ == "__main__":
    unittest.main()
