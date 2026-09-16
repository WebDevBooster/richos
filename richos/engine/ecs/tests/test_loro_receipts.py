import contextlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

COMPONENT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(COMPONENT/"core"),str(COMPONENT/"adapters")]
from app import execute
from ecs_core import EventStore,ValidationError

class LoroReceipts(unittest.TestCase):
    def setUp(self):
        self.scratch=tempfile.TemporaryDirectory();self.addCleanup(self.scratch.cleanup)
        self.root=Path(self.scratch.name);self.store=self.root/"ecs"
        self.binding=self.bind("depot","thread","turn",None)
        self.path=self.root/"loro-corrections.jsonl"
        self.proposal={"rec":"proposed","id":"prop-1","entity_id":"depot","thread_id":"thread","why":"Fictional correction"}
        self.confirmed={"rec":"confirmed","id":"prop-1","at":1000}
        self.written={"rec":"written","id":"prop-1","at":2000,"outcome":{"dryRun":False,"ref":"rec:ceo/records/fictional","text":"fictional writer result"}}
    def bind(self,entity,thread,turn,revision):
        return execute(self.store,{"protocol":1,"command":"bind","scope":{"entity_id":entity,"thread_id":thread,"session_id":"session","turn_id":turn,"audience":"ceo"},"expected_revision":revision,"source_ref":"ledger:"+turn,"request_id":"bind-"+turn})["binding"]
    def journal(self,*rows):self.path.write_text("".join(json.dumps(row)+"\n" for row in rows))
    def sync(self):return execute(self.store,{"protocol":1,"command":"sync-loro-receipts","binding":self.binding})
    def test_confirmed_writer_receipt_projects_once_and_remains_inspectable_after_new_turn(self):
        self.journal(self.proposal,self.confirmed,self.written)
        first=self.sync();self.assertEqual(first["writes_performed"],0);self.assertEqual(first["receipt_count"],1)
        self.binding=self.bind("depot","thread","next",self.binding["revision"])
        self.assertEqual(self.sync(),first)
        result=execute(self.store,{"protocol":1,"command":"inspect","binding":self.binding,"query":{"section":"actions","include_closed":True}})
        self.assertEqual(len(result["records"]),1);self.assertEqual(result["records"][0]["state"],"effect_verified")
    def test_confirmed_without_outcome_does_not_authorize_retry_or_invent_a_receipt(self):
        self.journal(self.proposal,self.confirmed)
        self.assertEqual(self.sync()["receipt_count"],0)
        self.journal(self.proposal,self.written)
        with self.assertRaises(ValidationError):self.sync()
    def test_private_other_scope_does_not_project_and_unknown_journal_is_not_silently_skipped(self):
        self.journal({**self.proposal,"entity_id":"other"},self.confirmed,self.written)
        self.assertEqual(self.sync()["receipt_count"],0)
        self.path.write_text(self.path.read_text()+'{"rec":"future-answer","id":"prop-1"}\n')
        with self.assertRaises(ValidationError):self.sync()
    def test_interruption_between_receipt_and_verified_transition_recovers_without_rewriting(self):
        self.journal(self.proposal,self.confirmed,self.written)
        original=EventStore.append
        def crash(store,event,**fields):
            result=original(store,event,**fields)
            if event=="action.receipt_recorded":raise RuntimeError("synthetic receipt boundary")
            return result
        with patch.object(EventStore,"append",crash):
            with self.assertRaises(RuntimeError):self.sync()
        self.binding=self.bind("depot","thread","recovery",self.binding["revision"])
        self.assertEqual(self.sync()["receipt_count"],1)
        with contextlib.closing(EventStore(self.store).connect()) as conn:
            self.assertEqual(conn.execute("SELECT COUNT(*) FROM ecs_receipts").fetchone()[0],1)

if __name__=="__main__":unittest.main()
