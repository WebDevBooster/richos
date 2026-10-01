#!/usr/bin/env python3
"""escalations-delivery.test.py — an oversized first escalation is never
recorded as delivered while the model could not read all of it (P5-37).

The host caps a Stop hook's additionalContext at 10,000 characters and swaps a
longer value for a 2,000-character preview. render_delivery stays under
DELIVERY_BUDGET for everything but the FIRST entry, which was allowed past it so
delivery always makes progress. That entry's id was then recorded as delivered
although its end never reached the model.
"""

import importlib.util
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("escalations", os.path.join(HERE, "escalations.py"))
E = importlib.util.module_from_spec(spec)
sys.modules["escalations"] = E
spec.loader.exec_module(E)


def entry(n, question):
    return {"id": "esc-20260930T0000%02dZ-0000000%d" % (n, n), "title": "t%d" % n,
            "teammate": "zach", "state": "stopped", "for": "lead", "question": question,
            "age_min": 1}


class OversizedFirstEntry(unittest.TestCase):
    def test_whole_delivery_stays_under_the_host_cap(self):
        text, sent = E.render_delivery([entry(1, "Q" * 12000 + " QUESTION-END")], 0)
        self.assertLess(len(text), E.HOST_CONTEXT_CAP)

    def test_a_cut_question_says_so_and_names_how_to_read_it(self):
        e = entry(1, "Q" * 12000 + " QUESTION-END")
        text, sent = E.render_delivery([e], 0)
        self.assertTrue("QUESTION-END" not in text, "the end of a cut question leaked through")
        self.assertTrue("TRUNCATED" in text, "a cut question does not say it was cut")
        self.assertTrue("escalate.sh show %s" % e["id"] in text, "no pointer to the full text")

    def test_the_visible_preview_is_not_the_only_place_the_pointer_lives(self):
        # The host's preview is the first 2,000 characters when the value is
        # over the cap; staying under the cap means the model gets all of it,
        # pointer included.
        e = entry(1, "Q" * 12000)
        text, _ = E.render_delivery([e], 0)
        self.assertLessEqual(len(text), E.DELIVERY_BUDGET + 1500)

    def test_a_normal_entry_is_untouched(self):
        e = entry(1, "short question")
        text, sent = E.render_delivery([e], 0)
        self.assertIn("short question", text)
        self.assertNotIn("TRUNCATED", text)
        self.assertEqual(sent, [e["id"]])


# ---------------------------------------------------------------------------
# D01-D07: what the stall watcher's wake put in front of the model is not
# delivered again at turn end, and nothing else counts as having done so.
#
# richos-hq docs/operations/2026-10-01-escalation-wakes-the-lead.md (4.3, rule
# 3) and Sage's review of it (richos-hq 8ba32b71, items 1-3 and 10). Every
# transcript row below is a HOST row: the shape (every top-level key, the
# attachment keys, the envelope text) is copied from a real lead transcript,
# with free text and identities replaced:
#   MONITOR_USER   212ab083 line 7893  a monitor event that woke an idle lead
#   MONITOR_QUEUED 212ab083 line 9811  a monitor event delivered mid-turn
#   ENQUEUE        212ab083 line 7891  the host's enqueue of that same event
#   COMPLETION     459554d9 line 610   a teammate's completion notification
# Hand-typed shapes are how a harness-green fix goes app-red.
# ---------------------------------------------------------------------------
import json  # noqa: E402
import shutil  # noqa: E402
import tempfile  # noqa: E402
from datetime import datetime, timezone  # noqa: E402

KEY_A = "esc-20261001T113833Z-c9ac3ed0"
KEY_B = "esc-20261001T130736Z-8a8b192b"
DESC = ("Wakes the lead the moment teammate work stalls or a teammate escalates. "
        "Looks every 60 s, tells each once, and only reports")


def watch_event(*keys):
    """The text the stall watcher prints for these keys, as the host wraps it."""
    lines = ["ESCALATION-WATCH 11:39Z: %d new teammate escalation(s) (in the ledger until "
             "acknowledged; nothing was paused, stopped or killed)" % len(keys)]
    for k in keys:
        lines.append("[%s] fixture title | from fixture-teammate, state=proceeding, for=lead | "
                     "Q: fixture question | full text: escalate.sh show %s" % (k, k.split("@")[0]))
    return ("<task-notification>\n<task-id>bfixture01</task-id>\n<summary>Monitor event: \"%s\"</summary>\n"
            "<event>%s</event>\n</task-notification>" % (DESC, "\n".join(lines)))


def monitor_user_row(text):
    return {"parentUuid": "00000000-0000-4000-8000-000000000001", "isSidechain": False,
            "promptId": "00000000-0000-4000-8000-000000000002", "type": "user",
            "message": {"role": "user", "content": text},
            "uuid": "00000000-0000-4000-8000-000000000003", "timestamp": "2026-10-01T11:39:30.686Z",
            "permissionMode": "bypassPermissions",
            "origin": {"kind": "task-notification", "producer": "session-task"},
            "promptSource": "system", "turnOrigin": "task_notification",
            "turnPosition": {"promptIndex": 11, "turnIndex": 73}, "queueSkipAttachments": True,
            "userType": "external", "entrypoint": "cli", "cwd": "/fixture/lead",
            "sessionId": "fixture-session", "version": "2.1.286", "gitBranch": "main"}


def monitor_queued_row(text):
    return {"parentUuid": "00000000-0000-4000-8000-000000000004", "isSidechain": False,
            "attachment": {"type": "queued_command", "prompt": text,
                           "source_uuid": "00000000-0000-4000-8000-000000000005",
                           "commandMode": "task-notification",
                           "origin": {"kind": "task-notification", "producer": "session-task"},
                           "timestamp": "2026-10-01T11:39:30.262Z"},
            "type": "attachment", "uuid": "00000000-0000-4000-8000-000000000006",
            "timestamp": "2026-10-01T11:39:30.262Z",
            "rendered": [{"content": "<system-reminder>\n[SYSTEM NOTIFICATION - NOT USER INPUT]\n"
                                     "</system-reminder>"}],
            "renderedInHumanTurn": False, "renderedRole": "user", "session_id": "fixture-session",
            "userType": "external", "entrypoint": "cli", "cwd": "/fixture/lead",
            "sessionId": "fixture-session", "version": "2.1.286", "gitBranch": "main",
            "slug": "fixture-slug"}


def enqueue_row(text):
    return {"type": "queue-operation", "operation": "enqueue", "timestamp": "2026-10-01T11:39:30.604Z",
            "sessionId": "fixture-session", "content": text}


def completion_row(quoted):
    text = ("<task-notification>\n<task-id>afixture000000001</task-id>\n<tool-use-id>toolu_fixture</tool-use-id>\n"
            "<output-file>/fixture/tasks/afixture000000001.output</output-file>\n<status>completed</status>\n"
            "<summary>Agent \"Fixture teammate\" finished</summary>\n<result>My handoff. The monitor printed:\n%s\n"
            "</result>\n</task-notification>" % quoted)
    row = monitor_user_row(text)
    row["promptSource"] = "system"
    return row


def ledger_rows(*specs):
    rows = []
    for rid, until in specs:
        rows.append({"event": "Escalation", "id": rid, "raised": "2026-10-01T11:38:33Z",
                     "teammate": "fixture-teammate", "state": "proceeding", "for": "lead",
                     "title": "fixture %s" % rid, "question": "a fixture question long enough"})
        if until:
            rows.append({"event": "EscalationAck", "id": rid, "acked": "2026-10-01T11:40:00Z",
                         "disposition": "put to the CEO; look again at the expiry", "until": until,
                         "until_epoch": E.parse_iso(until).timestamp()})
    return rows


NOW = datetime(2026, 10, 1, 13, 0, tzinfo=timezone.utc)


class MonitorEventCountsAsDelivered(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="esc-delivery-")
        self.transcript = os.path.join(self.dir, "lead.jsonl")
        self.state = os.path.join(self.dir, "state")

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def write(self, *rows):
        with open(self.transcript, "w", encoding="utf-8") as fh:
            for r in rows:
                fh.write(json.dumps(r) + "\n")

    def deliver(self, rows):
        text, _note = E.deliver({"session_id": "fixture-session", "transcript_path": self.transcript},
                                self.state, rows, NOW)
        return text

    def test_D01_an_idle_lead_woken_by_the_monitor_is_not_told_again(self):
        self.write(monitor_user_row(watch_event(KEY_A)))
        text = self.deliver(ledger_rows((KEY_A, None), (KEY_B, None)))
        self.assertNotIn(KEY_A, text, "the monitor's wake reached the model; the turn end repeated it")
        self.assertIn(KEY_B, text, "an escalation no event carried must still be delivered")

    def test_D02_a_monitor_event_delivered_mid_turn_counts_too(self):
        self.write(monitor_queued_row(watch_event(KEY_A)))
        text = self.deliver(ledger_rows((KEY_A, None), (KEY_B, None)))
        self.assertNotIn(KEY_A, text, "a queued_command monitor event reached the model mid-turn")
        self.assertIn(KEY_B, text)

    def test_D03_a_wake_that_never_reached_the_transcript_is_delivered(self):
        self.write()
        text = self.deliver(ledger_rows((KEY_A, None)))
        self.assertIn(KEY_A, text, "the backstop: no event in the transcript, so the turn end tells it")

    def test_D05_a_teammate_report_quoting_a_block_is_not_a_delivery(self):
        # Paired with D01 in the same fixture: only the row's envelope differs.
        self.write(completion_row(watch_event(KEY_A)), monitor_user_row(watch_event(KEY_B)))
        text = self.deliver(ledger_rows((KEY_A, None), (KEY_B, None)))
        self.assertIn(KEY_A, text, "a teammate's completion quoting the block was read as the monitor's")
        self.assertNotIn(KEY_B, text)

    def test_D06_an_enqueue_the_model_has_not_read_is_not_a_delivery(self):
        self.write(enqueue_row(watch_event(KEY_A)), monitor_user_row(watch_event(KEY_B)))
        text = self.deliver(ledger_rows((KEY_A, None), (KEY_B, None)))
        self.assertIn(KEY_A, text, "an enqueue-only event counted as reaching the model")
        self.assertNotIn(KEY_B, text)

    def test_D07_a_reopened_escalation_is_reached_only_under_its_reopened_key(self):
        until = "2026-10-01T12:10:00Z"
        reopened = "%s@reopened:%s" % (KEY_A, until)
        rows = ledger_rows((KEY_A, until))
        self.write(monitor_user_row(watch_event(KEY_A)))
        self.assertIn(reopened, self.deliver(rows),
                      "the wake about the FIRST opening was taken as a wake about the reopening")
        shutil.rmtree(self.state, ignore_errors=True)
        self.write(monitor_user_row(watch_event(reopened)))
        self.assertNotIn(KEY_A, self.deliver(rows), "the reopened key's own wake reached the model")


if __name__ == "__main__":
    unittest.main()
