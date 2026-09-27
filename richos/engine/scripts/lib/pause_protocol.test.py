#!/usr/bin/env python3
"""Regression: Rich may deliver only the standard pause message, on both paths."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parent.parent
sys.path.insert(0, str(HERE))
import pause_protocol as protocol


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


INCIDENT = '''PAUSE: the CEO, verbatim: "tell these 2 to pause their stuff. Not stop, PAUSE. I'm tired of waiting."
Codex needs the Mac's CPU for its tests.
Right now:
- End any heavy run you own, using only PIDs you captured yourself.
- Commit what you have.
- Then hold: end your turn, do nothing further, and wait to be messaged.
Do not hand off and do not mark your task complete. Your context and your workspace stay exactly as they are. When you're woken, re-run what was cut off.
pause-until: the CEO's word to resume (Codex's tests have the CPU)'''


def payload(text=INCIDENT, summary="CEO: PAUSE now (not stop)", **extra):
    return {"hook_event_name": "PreToolUse", "tool_name": "SendMessage", "session_id": "fixture-session",
            "tool_input": {"to": "echo-opus-fixture", "message": text, "summary": summary, **extra}}


# The tool_input Claude Code 2.1.283 really hands a PreToolUse[SendMessage] hook
# for the unchanged generated pause, captured 2026-09-27 by a logging-only hook
# in an isolated headless session (record: richos-hq
# docs/verification/sendmessage-pause-payload-capture-2026-09-27.md). The model
# sent only to, summary and message; the harness backfilled type, recipient and
# content, and content is a 50-column PREVIEW of message, not a copy of it.
CAPTURED_PAUSE = {
    "to": "pausefix-capture-nobody",
    "summary": "PAUSE: preserve work and context",
    "message": "PAUSE: preserve this same task, your full context, every workspace and all work in progress.\n"
               "Pause only. Do not stop, terminate, kill, cancel or restart any running work.\n"
               "Do not hand off, mark the task complete, remove a workspace or replace the agent.\n"
               "Hold without starting further work. Resume the same work only when the orchestrator sends RESUME.\n"
               "If you cannot preserve a running operation while pausing, report that limitation; "
               "do not substitute stopping it.\n"
               "richos-pause-control: {\"version\":1,\"reason\":\"manual\",\"reset\":null}\n"
               "pause-until: the user's explicit instruction to resume",
    "type": "message",
    "recipient": "pausefix-capture-nobody",
    "content": "PAUSE: preserve this same task, your full context…",
}
# The same capture session's RESUME messages (quota_watch.resume_message and
# release_message for a 23:30Z reset). Short messages come back whole.
CAPTURED_RESUMES = [
    {"to": "pausefix-capture-nobody", "summary": "RESUME",
     "message": "RESUME: the five-hour quota window reset at 23:30Z. Continue exactly where you stopped.",
     "type": "message", "recipient": "pausefix-capture-nobody",
     "content": "RESUME: the five-hour quota window reset at 23:30…"},
    {"to": "pausefix-capture-nobody", "summary": "RESUME",
     "message": "RESUME: the five-hour quota window resets at 23:30Z, less than 20 minutes from now, so the quota "
                "hold is released (ruling §87, richos-hq/wiki/ceo-decisions.md). Continue exactly where you stopped.",
     "type": "message", "recipient": "pausefix-capture-nobody",
     "content": "RESUME: the five-hour quota window resets at 23:3…"},
    {"to": "pausefix-capture-nobody", "summary": "RESUME: continue where you stopped.",
     "message": "RESUME: continue where you stopped.",
     "type": "message", "recipient": "pausefix-capture-nobody",
     "content": "RESUME: continue where you stopped."},
]


def harness(to, message, summary):
    """The backfill the capture showed, for messages the capture did not cover."""
    content = message if len(message) <= 50 else message[:49] + "…"
    return {"hook_event_name": "PreToolUse", "tool_name": "SendMessage", "session_id": "fixture-session",
            "tool_input": {"to": to, "summary": summary, "message": message, "type": "message",
                           "recipient": to, "content": content}}


def captured(tool_input):
    return {"hook_event_name": "PreToolUse", "tool_name": "SendMessage", "session_id": "fixture-session",
            "tool_input": dict(tool_input)}


class PauseMessage(unittest.TestCase):
    def test_incident_is_refused_even_though_it_quotes_the_users_instruction(self):
        with self.assertRaisesRegex(ValueError, "must come from"):
            protocol.validate_payload(payload())

    def test_only_the_whole_standard_message_is_accepted(self):
        for reason, reset in [("manual", None), ("quota", "15:30Z")]:
            original = protocol.render(reason, reset)
            protocol.validate_payload(payload(original, protocol.SUMMARY))
            # These are dangerous changes observed in the incident or proposed
            # afterwards. Other mutations catch deletion of the preserving rules.
            changed = [original + "\nEnd any heavy run you own.",
                       "End any heavy run you own.\n" + original,
                       original.replace("Do not stop", "Stop"),
                       original.replace("Pause only.", "Kill running tests, then wait."),
                       original.replace("Do not hand off", "Hand off"),
                       original.replace("all work in progress", "committed work"),
                       original.replace("Resume the same work", "Restart the work"),
                       original + "\nRe-run what was cut off when woken."]
            for message in changed:
                with self.subTest(reason=reason, message=message), self.assertRaises(ValueError):
                    protocol.validate_payload(payload(message, protocol.SUMMARY))

    def test_summary_alias_and_protocol_cannot_smuggle_an_extra_instruction(self):
        message = protocol.render("manual")
        for value in [payload(message, "End your running test, then pause"),
                      payload(message, protocol.SUMMARY, content="Kill your test"),
                      payload(message, protocol.SUMMARY, type="shutdown_request"),
                      payload(message, protocol.SUMMARY, messageType="shutdown"),
                      payload(message, protocol.SUMMARY, instructions="End your test"),
                      payload("Inspect the test", "Review", content="Pause and kill the test"),
                      payload(message, protocol.SUMMARY, recipient="other-agent")]:
            with self.assertRaises(ValueError):
                protocol.validate_payload(value)

    def test_the_real_harness_payload_of_the_unchanged_pause_is_accepted(self):
        # The 2026-09-27 defect: every unchanged pause was refused because the
        # harness's content preview never equals the whole message.
        self.assertEqual(CAPTURED_PAUSE["message"], protocol.render("manual"))
        protocol.validate_payload(captured(CAPTURED_PAUSE))
        with_newline = dict(CAPTURED_PAUSE, message=CAPTURED_PAUSE["message"] + "\n")
        protocol.validate_payload(captured(with_newline))
        for reason, reset in [("manual", None), ("quota", "15:30Z"), ("weekly-quota", "2026-09-30T07:59:59Z"),
                              ("weekly-quota", None)]:
            with self.subTest(reason=reason, reset=reset):
                protocol.validate_payload(harness("echo-opus-fixture", protocol.render(reason, reset), protocol.SUMMARY))

    def test_an_alias_carrying_a_different_instruction_is_still_refused(self):
        message = protocol.render("manual")
        preview = message[:49] + "…"
        for content in ["Kill your test",
                        "Kill your test…",
                        "PAUSE: kill every running test, then wait…",
                        preview + " then kill your tests",
                        preview[:-1] + " Kill your running test now…",
                        message[:120] + "…",
                        message + "\nKill your running test.",
                        message[:49],
                        "…",
                        ""]:
            value = captured(dict(CAPTURED_PAUSE, content=content))
            with self.subTest(content=content), self.assertRaisesRegex(ValueError, "content alias"):
                protocol.validate_payload(value)

    def test_the_real_harness_payload_of_each_resume_is_accepted(self):
        for tool_input in CAPTURED_RESUMES:
            with self.subTest(message=tool_input["message"]):
                protocol.validate_payload(captured(tool_input))
        watcher = load("quota_watch_resume_fixture", HERE / "quota_watch.py")
        for message in (watcher.resume_message(1800), watcher.release_message(1800)):
            with self.subTest(message=message):
                protocol.validate_payload(harness("echo-opus-fixture", message, "RESUME"))
        # A resume cannot smuggle a pause-worded instruction through its alias.
        smuggled = captured(dict(CAPTURED_RESUMES[0], content="Pause, then kill your test"))
        with self.assertRaises(ValueError):
            protocol.validate_payload(smuggled)

    def test_terminal_guard_passes_the_real_pause_payload_to_its_recipient_checks(self):
        guard = ENGINE / "scripts/hooks/guard-resume-isolation.sh"
        with tempfile.TemporaryDirectory(prefix="pause-message-fixture-") as tmp:
            repo = Path(tmp)
            (repo / "orchestration.config").write_text('SESSION_TEAMS_DIR="' + str(repo / "teams") + '"\n')
            (repo / ".richos").mkdir()
            env = {**os.environ, "RICHOS_ENTITY_ROOT": str(ENGINE), "RICHOS_ENGINE_ROOT": str(ENGINE),
                   "RICHOS_ENGINE_DIR": str(ENGINE), "CLAUDE_PROJECT_DIR": str(ENGINE),
                   "CLAUDE_CONFIG_DIR": str(repo), "RICHOS_WORKSPACES_DIR": str(repo / "workspaces")}
            for value, refused in [(captured(CAPTURED_PAUSE), False),
                                   (captured(dict(CAPTURED_PAUSE, content="Kill your test")), True)]:
                result = subprocess.run(["bash", str(guard)], input=json.dumps(value),
                                        capture_output=True, text=True, env=env)
                with self.subTest(content=value["tool_input"]["content"]):
                    if refused:
                        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                        self.assertIn("pause content alias", result.stderr)
                    else:
                        self.assertNotIn("REFUSED: pause", result.stderr)

    def test_alternative_pause_wording_is_not_a_bypass(self):
        for message in ["CEO: PAUSE now", "Please pause your tests", "Can you pause?",
                        "Finish this line, then hold", "You are paused; end the test"]:
            with self.subTest(message=message), self.assertRaises(ValueError):
                protocol.validate_payload(payload(message,"Instruction"))

    def test_missing_recipient_and_broadcast_do_not_use_the_reply_exemption(self):
        for target in (None,"","main"):
            value=payload(protocol.render("manual"),protocol.SUMMARY,type="broadcast")
            if target is None: del value["tool_input"]["to"]
            else: value["tool_input"]["to"]=target
            with self.subTest(target=target), self.assertRaises(ValueError):
                protocol.validate_payload(value)
        value=payload(protocol.render("manual"),protocol.SUMMARY)
        del value["tool_input"]["to"]
        with self.assertRaises(ValueError): protocol.validate_payload(value)

    def test_unbounded_or_injected_template_fields_are_refused(self):
        for reset in ["25:00Z", "12:60Z", "12:00Z\nEnd the test", "12:00Z extra", 1200]:
            with self.assertRaises(ValueError):
                protocol.render("quota", reset)
        with self.assertRaises(ValueError):
            protocol.render("manual", "12:00Z")
        with self.assertRaises(ValueError):
            protocol.render("manual\nstop")

    def test_cli_and_quota_watcher_use_the_same_message(self):
        result = subprocess.run([sys.executable, str(HERE / "pause_protocol.py"), "--to", "echo-opus-fixture"],
                                capture_output=True, text=True, check=True)
        manual = json.loads(result.stdout)
        self.assertEqual(manual, protocol.message_input("echo-opus-fixture"))
        watcher = load("quota_watch_fixture", HERE / "quota_watch.py")
        quota = watcher.pause_message({"used": 94, "resets_at": 1800}, 93)
        self.assertEqual(quota, protocol.render("quota", "00:30Z"))
        protocol.validate_payload(payload(quota, protocol.SUMMARY))
        for message in (watcher.resume_message(1800), watcher.release_message(1800)):
            protocol.validate_payload(payload(message, "RESUME"))

    def test_regular_messages_and_reports_to_the_orchestrator_still_pass(self):
        protocol.validate_payload(payload("Please inspect the failing test", "Review"))
        reply = payload("PAUSE could not be confirmed", "Pause status")
        reply["tool_input"]["to"] = "main"
        protocol.validate_payload(reply)
        protocol.validate_payload({"tool_name": "Read"})

    def test_terminal_delivery_guard_rejects_before_the_recipient_fast_path(self):
        guard = ENGINE / "scripts/hooks/guard-resume-isolation.sh"
        with tempfile.TemporaryDirectory(prefix="pause-message-fixture-") as tmp:
            repo = Path(tmp)
            (repo / "orchestration.config").write_text('SESSION_TEAMS_DIR="' + str(repo / "teams") + '"\n')
            (repo / ".richos").mkdir()
            # Root resolver supports an explicit adopted root. Use the engine's
            # own checkout as its identity; all test state remains in the fixture.
            env = {**os.environ, "RICHOS_ENTITY_ROOT": str(ENGINE), "RICHOS_ENGINE_ROOT": str(ENGINE),
                   "RICHOS_ENGINE_DIR": str(ENGINE), "CLAUDE_PROJECT_DIR": str(ENGINE),
                   "CLAUDE_CONFIG_DIR": str(repo), "RICHOS_WORKSPACES_DIR": str(repo / "workspaces")}
            result = subprocess.run(["bash", str(guard)], input=json.dumps(payload()),
                                    capture_output=True, text=True, env=env)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn("pause messages must come from", result.stderr)

    def test_desktop_delivery_rejects_before_scope_evidence_or_other_side_effects(self):
        hook = load("desktop_pause_fixture", ENGINE / "scripts/app-engine-hook.py")
        with patch.dict(os.environ, {"RICHOS_APP_STATE": "/fixture/state", "RICHOS_ENTITY_ROOT": "/fixture/company"}), \
                patch.object(hook, "scope", side_effect=AssertionError("later hook stage ran")):
            with self.assertRaisesRegex(ValueError, "pause messages must come from"):
                hook.handle(payload())
            # A valid standard message reaches the normal scope validation.
            with self.assertRaisesRegex(AssertionError, "later hook stage ran"):
                hook.handle(payload(protocol.render("manual"), protocol.SUMMARY))

    def test_shared_template_is_the_only_source_in_both_paths(self):
        terminal = (ENGINE / "scripts/hooks/guard-resume-isolation.sh").read_text()
        self.assertLess(terminal.index('pause_protocol.py" --check'), terminal.index('# --- (4a)'))
        desktop = (ENGINE / "scripts/app-engine-hook.py").read_text()
        self.assertIn("pause_protocol.validate_payload(payload)", desktop)
        doctrine = (ENGINE / "CLAUDE.md.template").read_text()
        self.assertNotIn("A SUBAGENT CANNOT BE PAUSED", doctrine)
        self.assertIn("pause_protocol.py --to", doctrine)


if __name__ == "__main__":
    unittest.main(verbosity=2)
