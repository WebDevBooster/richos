#!/usr/bin/env python3
"""Offline boundary tests. Live GUI behavior is deliberately a separate proof."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
HERE=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(HERE))
import fixture
import rollback
from scenario import Failure


def module(name):
    spec=importlib.util.spec_from_file_location(name,HERE/(name+'.py'))
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value


class WalkTests(unittest.TestCase):
    def test_fixture_keeps_source_and_removes_only_history_in_delta(self):
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'source';data=source/'Library/Application Support/com.richos.app';data.mkdir(parents=True)
            rows=[{'event':'ThreadCreated','thread_id':str(i),'entity_id':'e','person_id':'p','title':'old'} for i in range(2)]
            rows.append({'event':'MessageAdded','text':'old'})
            ledger=data/'conversation-ledger.jsonl';ledger.write_text(''.join(json.dumps(x)+'\n' for x in rows));original=ledger.read_bytes()
            (source/'.claude').symlink_to('/nonexistent/credentials')
            delta=Path(tmp)/'delta';long=Path(tmp)/'long'
            fixture.prepare(source,delta,'delta');fixture.prepare(source,long,'long-history')
            self.assertEqual(ledger.read_bytes(),original)
            self.assertEqual((long/'Library/Application Support/com.richos.app/conversation-ledger.jsonl').read_bytes(),original)
            cooked=[json.loads(x) for x in (delta/'Library/Application Support/com.richos.app/conversation-ledger.jsonl').read_text().splitlines()]
            self.assertEqual([r['title'] for r in cooked],['Scenario A','Scenario B'])
            self.assertFalse((delta/'.claude').exists())
    def test_fixture_refuses_links_before_editing_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            source=Path(tmp)/'source';source.mkdir();outside=Path(tmp)/'original';outside.write_text('untouched')
            (source/'linked').symlink_to(outside)
            with self.assertRaises(ValueError):fixture.prepare(source,Path(tmp)/'copy','delta')
            self.assertEqual(outside.read_text(),'untouched');self.assertFalse((Path(tmp)/'copy').exists())
    def test_rollback_missing_history_never_browses_or_relaunches(self):
        with tempfile.TemporaryDirectory() as tmp,patch.dict(os.environ,TESTVM_ROOT=tmp):
            state=Path(tmp)/'run/demo';state.mkdir(parents=True);(state/'payload').write_text('/Users/admin/testvm/demo')
            with patch.object(rollback,'receipts',side_effect=RuntimeError('missing')),patch.object(rollback,'relaunch') as launch:
                with self.assertRaises(Failure) as raised:rollback.exercise('demo','1.0.1','1.0.2','https://example.invalid/releases/download/v1.0.2/update.json',check_only=True)
                self.assertEqual(raised.exception.outcome,'prerequisite unavailable');launch.assert_not_called()
    def test_rollback_rejects_moving_channel_before_accessing_guest(self):
        with patch.object(rollback,'guest') as guest:
            with self.assertRaises(ValueError):rollback.exercise('demo','1.0.1','1.0.2','https://example.invalid/latest.json')
            guest.assert_not_called()
    def test_manifest_orders_destructive_check_last_and_budget_six(self):
        manifest=json.loads((HERE/'scenarios/delta.json').read_text());steps=manifest['steps'];ids=[x['id'] for x in steps]
        self.assertLess(ids.index('rejected-phone'),ids.index('rollback'))
        self.assertLess(ids.index('phone-to-mac'),ids.index('work-chip-switch'))
        self.assertEqual(manifest['model_turn_limit'],6)
        self.assertEqual(next(x['count'] for x in steps if x['id']=='samples'),5)
    def test_real_key_reads_use_default_search_list_and_never_emit_secrets(self):
        verifier=module('keychain-verify');calls=[]
        def guest(vm,command,timeout):calls.append(command);return json.dumps({a:'fingerprint' for a in verifier.ACCOUNTS})
        with patch.object(verifier,'guest',side_effect=guest):
            result=verifier.keys('demo','/Users/admin/testvm/demo/home')
        self.assertEqual(len(result),3);self.assertIn('find-generic-password',calls[0])
        self.assertNotIn('add-generic-password',calls[0]);self.assertNotIn('login.keychain',calls[0])
        self.assertNotIn(' -A ',calls[0]);self.assertIn('hashlib.sha256',calls[0])
    def test_driver_clock_is_milliseconds_and_negative_latency_is_explicit(self):
        walk=module('delta-walk');w=object.__new__(walk.Walk)
        self.assertEqual(w.bound([-100,500],1000,signed=True)['milliseconds'],[-100,500])
        with self.assertRaises(Failure):w.bound([-100],1000)
        with self.assertRaises(Failure):w.bound([1001],1000)
    def test_deadline_preserves_stdout_stderr_and_status(self):
        r=subprocess.run([sys.executable,str(HERE/'ax-deadline.py'),'3',sys.executable,'-c','import sys;print("partial");print("cause",file=sys.stderr);sys.exit(17)'],input=b'',capture_output=True)
        self.assertEqual(r.returncode,17);self.assertIn(b'partial',r.stdout);self.assertIn(b'cause',r.stderr)


if __name__=='__main__':unittest.main()
