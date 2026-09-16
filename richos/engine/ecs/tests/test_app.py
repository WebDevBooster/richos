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


if __name__ == "__main__":
    unittest.main()
