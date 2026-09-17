# SPDX-License-Identifier: AGPL-3.0-only
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil
import sqlite3
import unittest
from unittest.mock import patch

COMPONENT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(COMPONENT / "core"), str(COMPONENT / "adapters")]
from app import execute
from ecs_core import EventStore, ValidationError
from mcp import call as tool_call


class AppProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ecs app ")
        self.root = Path(self.temp.name)
        self.store = self.root / "state"
        self.binding = self.bind("depot", "thread-a", "session-a", "turn-1", None)

    def tearDown(self):
        self.temp.cleanup()

    def call(self, command, ok=True, **fields):
        request = {"protocol": 1, "command": command, **fields}
        if hasattr(self, "binding"):
            request.setdefault("binding", self.binding)
        result = subprocess.run([sys.executable, str(COMPONENT / "bin/ecs"), "--state-root", str(self.store)],
            input=json.dumps(request), text=True, capture_output=True,
            env={**os.environ, "ECS_HOME": str(self.root / "do-not-adopt")})
        output = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0 if ok else 2, result.stdout + result.stderr)
        self.assertEqual(output["ok"], ok)
        self.assertFalse((self.root / "do-not-adopt").exists())
        return output["result"] if ok else output["error"]

    def bind(self, entity, thread, session, turn, revision):
        return self.call("bind", request_id=f"bind-{session}-{turn}", source_ref=f"ledger:{thread}:{turn}",
            expected_revision=revision, scope={"entity_id": entity, "thread_id": thread,
                "session_id": session, "turn_id": turn, "audience": "ceo"})["binding"]

    def checkpoint(self, statements, request_id="checkpoint-1", ok=True):
        return self.call("checkpoint", request_id=request_id, checkpoint={"statements": statements}, ok=ok)

    def test_process_restart_and_duplicate_checkpoint_preserve_one_obligation(self):
        statement = {"verb": "commitment", "fields": {"id": "ship-manual", "title": "Ship the fictional depot manual"}}
        self.assertTrue(self.checkpoint([statement])["accepted"])
        self.assertTrue(self.checkpoint([statement])["duplicate"])
        inspected = self.call("inspect", query={"section": "commitment"})
        self.assertEqual(len(inspected["records"]), 1)
        self.assertEqual(inspected["records"][0]["item_id"], "ship-manual")
        self.assertIn("depot manual", self.call("brief")["text"])
        changed = {"verb": "commitment", "fields": {"id": "ship-manual", "title": "Changed content"}}
        self.assertIn("different content", self.checkpoint([changed], ok=False)["message"])

    def test_stale_and_cross_entity_bindings_are_rejected(self):
        old = self.binding
        self.binding = self.bind("studio", "thread-b", "session-b", "turn-2", old["revision"])
        self.call("brief", binding=old, ok=False)
        error = self.call("checkpoint", binding=old, request_id="stale",
                          checkpoint={"no_changes": True, "reason": "Nothing changed"}, ok=False)
        self.assertEqual(error["kind"], "ScopeError")
        self.assertEqual(self.call("inspect")["entity"], "studio")

    def test_budget_does_not_make_omitted_obligations_unreachable(self):
        for batch in range(3):
            self.checkpoint([{"verb": "open_loop", "fields": {"id": f"loop-{batch}-{i}",
                "title": f"Fictional depot obligation {batch}-{i} with a distinct delivery check"}}
                for i in range(12)], request_id=f"batch-{batch}")
        brief = self.call("brief", budget_chars=900)
        self.assertLessEqual(len(brief["text"]), 900)
        self.assertEqual(brief["inspection"]["counts"]["open_loop"], 36)
        page = self.call("inspect", query={"section": "open_loop", "limit": 10})
        ids = set()
        while True:
            ids.update(row["item_id"] for row in page["records"])
            if page["next_offset"] is None:
                break
            page = self.call("inspect", query={"section": "open_loop", "limit": 10,
                "sequence": page["sequence"], "offset": page["next_offset"]})
        self.assertEqual(len(ids), 36)

    def test_partial_checkpoint_retries_without_duplicate_open(self):
        request = {"protocol": 1, "command": "checkpoint", "binding": self.binding,
            "request_id": "interrupted", "checkpoint": {"statements": [
                {"verb": "commitment", "fields": {"id": "manual", "title": "Draft the manual"}},
                {"verb": "update", "fields": {"id": "manual", "title": "Draft and review the manual"}},
            ]}}
        append = EventStore.append
        def interrupted(store, event, **args):
            result = append(store, event, **args)
            if event == "continuity.item_opened":
                raise RuntimeError("synthetic crash after commit")
            return result
        with patch.object(EventStore, "append", interrupted), self.assertRaises(RuntimeError):
            execute(self.store, request)
        result = execute(self.store, request)
        self.assertTrue(result["accepted"])
        with EventStore(self.store).connect() as conn:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM ecs_events WHERE event_type='continuity.item_opened'").fetchone()[0], 1)
        self.assertEqual(self.call("inspect", query={"item_id": "manual"})["item"]["title"], "Draft and review the manual")

    def test_checkpoint_cannot_certify_external_completion(self):
        self.checkpoint([{"verb": "commitment", "fields": {"id": "work", "title": "Build the artifact"}}])
        error = self.checkpoint([{"verb": "close", "fields": {"id": "work", "evidence": "I said it is done"}}],
                                request_id="claim", ok=False)
        self.assertIn("verification receipt", error["message"])
        error = self.checkpoint([{"verb": "update", "fields": {"id": "work", "status": "completed"}}],
                                request_id="update-claim", ok=False)
        self.assertIn("verification receipt", error["message"])
        self.assertEqual(self.call("inspect", query={"item_id": "work"})["item"]["status"], "active")

    def test_hello_is_read_only_and_no_implicit_state_root_is_accepted(self):
        absent = self.root / "absent"
        self.assertEqual(execute(absent, {"protocol": 1, "command": "hello"})["protocol"], 1)
        self.assertFalse(absent.exists())
        result = subprocess.run([sys.executable, str(COMPONENT / "bin/ecs")], input="{}", text=True, capture_output=True)
        self.assertEqual(result.returncode, 2)

    def test_upgrade_backs_up_readable_state_and_downgrade_is_refused(self):
        migrations = self.root / "migration-copy"
        shutil.copytree(COMPONENT / "migrations", migrations)
        store = EventStore(self.store)
        store.migrations_dir = migrations
        (migrations / "008_fixture.sql").write_text("CREATE TABLE fixture_upgrade(value TEXT);")
        store.initialize()
        backups = list((self.store / "backups").glob("*.sqlite3"))
        self.assertEqual(len(backups), 1)
        with sqlite3.connect(backups[0]) as previous:
            self.assertEqual(previous.execute("SELECT max(version) FROM schema_migrations").fetchone()[0], 7)
            self.assertGreater(previous.execute("SELECT count(*) FROM ecs_events").fetchone()[0], 0)
        with self.assertRaisesRegex(ValidationError, "downgrade refused"):
            EventStore(self.store).initialize()
        # Restoring the backup in a separate root is compatible with old code.
        restored = self.root / "restored"
        restored.mkdir()
        shutil.copyfile(backups[0], restored / "ecs.sqlite3")
        EventStore(restored).initialize()
        self.assertEqual(EventStore(restored).current_context()["entity_id"], "depot")

    def test_failed_migration_keeps_old_schema_and_backup(self):
        migrations = self.root / "broken-migrations"
        shutil.copytree(COMPONENT / "migrations", migrations)
        (migrations / "008_broken.sql").write_text("CREATE TABLE rolled_back(value TEXT); INVALID SQL;")
        store = EventStore(self.store)
        store.migrations_dir = migrations
        with self.assertRaises(sqlite3.Error):
            store.initialize()
        with store.connect() as conn:
            self.assertIsNone(conn.execute("SELECT name FROM sqlite_master WHERE name='rolled_back'").fetchone())
            self.assertEqual(conn.execute("SELECT max(version) FROM schema_migrations").fetchone()[0], 7)
        self.assertEqual(len(list((self.store / "backups").glob("*.sqlite3"))), 1)
        EventStore(self.store).initialize()

    def test_tools_cannot_override_scope_or_mutate_during_hidden_priming(self):
        path = self.root / "scope.json"
        scope = {"version": 1, "actions_allowed": False, "bridge": {"state_root": str(self.store)}, "binding": self.binding}
        path.write_text(json.dumps(scope))
        args = {"request_id": "hidden", "checkpoint": {"no_changes": True, "reason": "Test"}}
        with self.assertRaisesRegex(ValueError, "outside a visible"):
            tool_call(path, "checkpoint", args)
        scope["actions_allowed"] = True
        path.write_text(json.dumps(scope))
        with self.assertRaises(ValueError):
            tool_call(path, "checkpoint", {**args, "binding": self.binding})
        self.assertTrue(tool_call(path, "checkpoint", args)["accepted"])
        self.bind("studio", "thread-b", "session-b", "turn-b", self.binding["revision"])
        with self.assertRaisesRegex(Exception, "stale app binding"):
            tool_call(path, "inspect", {})


class WorkSeatTests(unittest.TestCase):
    """The tenth turn gate: a background assignment gets its own cursor.

    ``ecs_active_context`` is a CURSOR keyed by ``person_id``, not a store, and the
    conversation rewrites its row at the start of every turn. A background lease
    holding a binding frozen minutes earlier is therefore current until the CEO's
    next sentence and stale from then on -- and the gate is invisible today only
    because every work-tool call happens inside the turn that bound it.

    EVERY TEST HERE RUNS THREE OF HIS TURNS, and that is the whole point: with the
    two rows left sitting at the same revision, the broken form passes. That is
    exactly how the two appends below were shipped as "unaffected".
    """

    SEAT = "work-seat:assign-7"
    OTHER = "work-seat:assign-8"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ecs seat ")
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.ceo = self.bind("depot", "thread-a", "session-conv", "turn-1", None)

    def tearDown(self):
        self.temp.cleanup()

    def call(self, command, ok=True, seat=None, **fields):
        request = {"protocol": 1, "command": command, **fields}
        if seat is not None:
            request["seat"] = seat
        result = subprocess.run(
            [sys.executable, str(COMPONENT / "bin/ecs"), "--state-root", str(self.state)],
            input=json.dumps(request), text=True, capture_output=True,
            env={**os.environ, "ECS_HOME": str(self.root / "do-not-adopt")})
        output = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0 if ok else 2, result.stdout + result.stderr)
        self.assertEqual(output["ok"], ok, result.stdout)
        return output["result"] if ok else output["error"]["message"]

    def bind(self, entity, thread, session, turn, revision, seat=None, audience="ceo"):
        return self.call(
            "bind", seat=seat, request_id=f"bind-{seat or 'ceo'}-{turn}",
            source_ref=f"ledger:{thread}:{turn}", expected_revision=revision,
            scope={"entity_id": entity, "thread_id": thread, "session_id": session,
                   "turn_id": turn, "audience": audience})["binding"]

    def work_seat(self, seat=None, turn="assign-7"):
        """One seat per assignment, named by the assignment and bound as a worker."""
        return self.bind("depot", "thread-a", f"session-{turn}", turn, None,
                         seat=seat or self.SEAT, audience="worker")

    def three_ceo_turns(self):
        """His next three sentences. Each one rewrites HIS row and bumps its revision."""
        for number in (2, 3, 4):
            self.ceo = self.bind("depot", "thread-a", "session-conv", f"turn-{number}",
                                 number - 1)
        self.assertEqual(self.ceo["revision"], 4)
        return self.ceo

    def observe(self, binding, seat, request_id, external, ok=True):
        return self.call("observe", ok=ok, seat=seat, binding=binding,
                         source_ref=f"app-dispatch:{request_id}", request_id=request_id,
                         work={"authority": "richos-provider-v1", "work_unit_id": "wu-" + request_id,
                               "external_id": external, "title": "land three branches",
                               "owner": "work", "status": "started"})

    def rows(self, sql, *args):
        store = EventStore(self.state)
        conn = store.connect()
        try:
            return [dict(row) for row in conn.execute(sql, args).fetchall()]
        finally:
            conn.close()

    def test_a_work_seat_survives_the_conversation_rebinding_its_own_seat(self):
        frozen = self.work_seat()
        self.three_ceo_turns()
        # The claim: three of his turns, his row at revision 4, and the assignment's
        # frozen binding still passes its own fence.
        self.assertEqual(self.call("inspect", seat=self.SEAT, binding=frozen)["turn"], "assign-7")
        # The negative half, and it is the one that matters: a seat that does not
        # exist must RAISE, never fall back to his row. A fallback would pass this
        # test's positive half forever while writing background records onto his
        # cursor.
        self.assertIn("stale app binding",
                      self.call("inspect", ok=False, seat="work-seat:never-bound", binding=frozen))
        # And the same call with no seat at all reads his row, which is not this
        # binding -- so the absence of a seat is a refusal, not a default.
        self.assertIn("stale app binding", self.call("inspect", ok=False, binding=frozen))
        # Positive control on the other side: HIS binding still works on his seat.
        self.assertEqual(self.call("inspect", binding=self.ceo)["turn"], "turn-4")

    def test_a_second_work_seat_does_not_invalidate_the_first_assignments_binding(self):
        first = self.work_seat()
        self.three_ceo_turns()
        second = self.work_seat(seat=self.OTHER, turn="assign-8")
        # Both assignments are live at once, which section 5.5, 5.6 and the worked
        # example all require. Neither one's cursor is the other's.
        self.assertEqual(self.call("inspect", seat=self.SEAT, binding=first)["turn"], "assign-7")
        self.assertEqual(self.call("inspect", seat=self.OTHER, binding=second)["turn"], "assign-8")
        # The negative control is the design this replaced: ONE seat shared by two
        # assignments is gate ten again, with the CEO replaced by the work lease's
        # own next assignment.
        shared = self.bind("depot", "thread-a", "session-assign-9", "assign-9", 1,
                           seat=self.SEAT, audience="worker")
        self.assertEqual(shared["turn_id"], "assign-9")
        self.assertIn("stale app binding",
                      self.call("inspect", ok=False, seat=self.SEAT, binding=first))

    def test_binding_a_work_seat_does_not_re_register_the_entity(self):
        self.work_seat()
        registry = {row["event_type"]: row["person_id"] for row in self.rows(
            "SELECT event_type, person_id FROM ecs_events WHERE idempotency_key LIKE ?",
            f"app-bind:bind-{self.SEAT}-assign-7:%")}
        # The structural half: three of the four events are statements about things
        # that EXIST and are the same facts whoever is looking, so they stay on the
        # registry person. Only thread.activated says who is where right now.
        self.assertEqual(registry["entity.registered"], "ceo-default")
        self.assertEqual(registry["thread.created"], "ceo-default")
        self.assertEqual(registry["session.observed"], "ceo-default")
        self.assertEqual(registry["thread.activated"], self.SEAT)
        # The positive probe for that negative: the guard it would have tripped is
        # live, and it raises when an entity really is registered under another
        # person.
        store = EventStore(self.state)
        with self.assertRaisesRegex(Exception, "already registered differently"):
            store.append("entity.registered", entity_id="depot", thread_id="thread-a",
                         person_id=self.SEAT, source_ref="probe:registry",
                         idempotency_key="probe-registry-1", actor_kind="app",
                         actor_id="richos-app-v1",
                         payload={"display_name": "depot", "canonical_root": "elsewhere",
                                  "git_common_dir": "elsewhere", "status": "active"})

    def test_a_work_seat_can_still_REPORT_after_three_ceo_turns(self):
        """The one the fourth review exists for. A read was never the problem."""
        frozen = self.work_seat()
        self.three_ceo_turns()
        # observe appends work_unit.upserted, which IS a CONVERSATIONAL_EVENT and is
        # fenced against the row belonging to the event's own person. Without the
        # seat this compared the work row's revision (1) against his (4).
        self.assertFalse(self.observe(frozen, self.SEAT, "obs-1", "assign-7")["duplicate"])
        self.assertEqual(
            [row["person_id"] for row in self.rows("SELECT person_id FROM ecs_work_units")],
            [self.SEAT])
        # complete-obligation's append is the other half of how an assignment speaks.
        # Both arms, because the broken form is invisible without his three turns.
        store = EventStore(self.state)
        closed = dict(entity_id="depot", thread_id="thread-a", session_id="session-assign-7",
                      active_context_revision=1, actor_kind="authority_adapter",
                      actor_id="richos-provider-v1", source_ref="app-completion:probe",
                      payload={"item_id": "ship-it", "status": "completed",
                               "evidence_ref": "app-completion:probe"})
        with self.assertRaisesRegex(Exception, "expected 1, actual 4"):
            store.append("continuity.item_closed", idempotency_key="probe-close-no-seat",
                         expected_revision=1, **closed)
        self.call("checkpoint", request_id="open-it", checkpoint={"statements": [
            {"verb": "commitment", "fields": {"id": "ship-it", "title": "Ship it"}}]},
            binding=self.ceo)
        item = self.rows("SELECT revision FROM ecs_continuity_items WHERE item_id='ship-it'")
        store.append("continuity.item_closed", idempotency_key="probe-close-seat",
                     person_id=self.SEAT, expected_revision=int(item[0]["revision"]), **closed)
        self.assertEqual(
            self.rows("SELECT status FROM ecs_continuity_items WHERE item_id='ship-it'"),
            [{"status": "completed"}])

    def test_checkpoint_receipt_and_brief_are_refused_on_a_work_seat(self):
        frozen = self.work_seat()
        self.three_ceo_turns()
        statements = [{"verb": "commitment", "fields": {"id": "his-own", "title": "His own"}}]
        # Positive control first, or the refusals below would pass on a store where
        # these three are simply broken.
        self.assertTrue(self.call("checkpoint", request_id="ceo-1", binding=self.ceo,
                                  checkpoint={"statements": statements})["accepted"])
        self.assertIn("His own", self.call("brief", binding=self.ceo)["text"])
        self.call("receipt", binding=self.ceo, request_id="ceo-1",
                  session_id=self.ceo["session_id"], turn_id=self.ceo["turn_id"])
        for command, fields in (("checkpoint", {"request_id": "work-1",
                                                "checkpoint": {"statements": statements}}),
                                ("brief", {}),
                                ("receipt", {"request_id": "work-1",
                                             "session_id": "session-assign-7",
                                             "turn_id": "assign-7"})):
            self.assertIn("belong to the conversation's own seat",
                          self.call(command, ok=False, seat=self.SEAT, binding=frozen, **fields))


if __name__ == "__main__":
    unittest.main()
