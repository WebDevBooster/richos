#!/usr/bin/env python3
"""Real tiny Git publication and crash replay under disposable gate authority."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import unittest
import uuid
from unittest.mock import patch


def load(name, file):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(file))
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod);return mod


fixtures=load('gate_fixtures','legacy-workspace-gate.test.py')
mutation=load('mutation','legacy-workspace-mutation.py')


class Publication(unittest.TestCase):
    setUp=fixtures.GateWorkflow.setUp
    git=fixtures.GateWorkflow.git
    stage=fixtures.GateWorkflow.stage

    def prepare(self, *, packed=False, collision=False):
        self.git('branch','finished')
        self.git('branch','finished-two')
        fixed_uuid=uuid.uuid4()
        if collision:
            self.collision_ref='refs/richos/retired/'+str(fixed_uuid)+'/refs/heads/finished.next'
            self.git('update-ref',self.collision_ref,self.head)
        if packed:self.git('pack-refs','--all')
        self.report=fixtures.gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx],self.records)
        self.digest=fixtures.gate.planner.history._digest(self.report)
        with patch.object(fixtures.gate.uuid,'uuid4',return_value=fixed_uuid):
            self.ident=self.stage()['id']
        self.current_boot=str(uuid.uuid4())
        self.scratch=self.root/'scratch';self.scratch.mkdir(mode=0o700)
        self.binary=mutation.shadow.TRUSTED_GIT if sys.platform=='darwin' else '/usr/bin/git'
        observed=mutation.shadow.observe(self.manager,self.ident,approved_gate_sha256=self.digest,
                                        repo_alias='fixture',scratch_root=self.scratch,trusted_git=self.binary)
        self.selection={key:observed[key] for key in ('version','gate_id','gate_sha256','repo_alias','ref_snapshot_sha256','registry_sha256')}
        self.selection.update(approval_kind='exact-frozen-selection',branches=[dict(ref='refs/heads/finished',tip=self.head,integration_ref='refs/heads/main',integration_tip=self.head)])
        self.approved=mutation.shadow.digest(self.selection)
        self.base=self.vault/self.ident

    def publish(self):
        return mutation.publish(self.manager,self.selection,approved_selection_sha256=self.approved,
                                scratch_root=self.scratch,trusted_git=self.binary)

    def test_loose_ref_publication_restores_a_valid_repo_and_preserves_worker(self):
        self.prepare();result=self.publish()
        self.assertEqual(result['phase'],'complete')
        self.assertTrue(self.manager.inspect(self.ident)['boot_cutoff_verified'])
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual(self.git('branch','--list','finished'),'')
        self.assertEqual(self.git('rev-parse','refs/richos/retired/'+self.ident+'/refs/heads/finished'),self.head)
        self.assertTrue((self.work/'file').exists())
        self.assertEqual(self.git('rev-parse','worker'),self.head)

    def test_packed_ref_publication_and_replay_are_idempotent(self):
        self.prepare(packed=True);self.publish()
        journal=json.loads((self.base/'mutation.json').read_text())
        self.assertEqual(journal['metadata_snapshot_release']['state'],'released')
        self.assertGreater(journal['metadata_snapshot_release']['size'],0)
        self.assertFalse((self.base/'mutation-data/original-metadata.jsonl').exists())
        self.assertTrue(list((self.base/'mutation-data/before').rglob('*')))
        self.assertEqual(mutation.replay(self.manager,self.ident,approved_selection_sha256=self.approved)['phase'],'complete')
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual(self.git('branch','--list','finished'),'')
        self.assertEqual(self.git('rev-parse','main'),self.head)

    def test_wrong_selection_approval_has_no_mutation(self):
        self.prepare();self.approved='wrong'
        with self.assertRaises(Exception):self.publish()
        self.assertFalse((self.base/'mutation.json').exists())
        self.assertTrue(self.manager.inspect(self.ident)['boot_cutoff_verified'])

    def test_unrelated_next_suffix_ref_is_preserved(self):
        self.prepare(collision=True);self.publish()
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual(self.git('rev-parse',self.collision_ref),self.head)

    def next_selection(self):
        observed=mutation.shadow.observe(self.manager,self.ident,approved_gate_sha256=self.digest,
                                        repo_alias='fixture',scratch_root=self.scratch,trusted_git=self.binary)
        for key in ('ref_snapshot_sha256','registry_sha256'):self.selection[key]=observed[key]
        self.selection['branches'][0]['ref']='refs/heads/finished-two'
        self.approved=mutation.shadow.digest(self.selection)

    def test_multiple_publications_chain_effective_inventory_and_recovery(self):
        self.prepare(packed=True);self.publish();self.next_selection();self.publish()
        receipts=list((self.base/'mutation-history').glob('*/receipt.json'))
        self.assertEqual(len(receipts),1)
        self.assertEqual(json.loads(receipts[0].read_text())['metadata_snapshot_release']['state'],'released')
        self.assertFalse(list((self.base/'mutation-history').rglob('original-metadata.jsonl')))
        self.manager.restore(self.ident,approved_sha256=self.digest)
        for name in ('finished','finished-two'):
            self.assertEqual(self.git('branch','--list',name),'')
            self.assertEqual(self.git('rev-parse','refs/richos/retired/'+self.ident+'/refs/heads/'+name),self.head)

    def test_completed_snapshot_unlink_crash_replays_without_losing_ref_recovery(self):
        self.prepare(packed=True);real=Path.unlink;fired=[]
        def crash(path,*args,**kwargs):
            result=real(path,*args,**kwargs)
            if path==self.base/'mutation-data/original-metadata.jsonl' and not fired:
                fired.append(True);raise RuntimeError('snapshot unlink crash')
            return result
        with patch.object(Path,'unlink',crash),self.assertRaisesRegex(RuntimeError,'snapshot unlink'):
            self.publish()
        journal=json.loads((self.base/'mutation.json').read_text())
        self.assertEqual(journal['phase'],'complete')
        self.assertEqual(journal['metadata_snapshot_release']['state'],'authorized')
        self.assertFalse((self.base/'mutation-data/original-metadata.jsonl').exists())
        self.assertEqual(mutation.replay(self.manager,self.ident,approved_selection_sha256=self.approved)['phase'],'complete')
        self.assertEqual(json.loads((self.base/'mutation.json').read_text())['metadata_snapshot_release']['state'],'released')
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual(self.git('rev-parse','refs/richos/retired/'+self.ident+'/refs/heads/finished'),self.head)

    def test_crash_archiving_previous_complete_operation_can_retry(self):
        self.prepare();self.publish();self.next_selection();real=mutation.os.rename;fired=[]
        def crash(source,destination,*args,**kwargs):
            real(source,destination,*args,**kwargs)
            if Path(source)==self.base/'mutation-data' and not fired:
                fired.append(True);raise RuntimeError('archival rename crash')
        with patch.object(mutation.os,'rename',side_effect=crash),self.assertRaisesRegex(RuntimeError,'archival'):
            self.publish()
        self.assertTrue(self.manager.inspect(self.ident)['boot_cutoff_verified'])
        self.publish()
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual(self.git('branch','--list','finished-two'),'')

    def test_unrelated_inode_change_prevents_any_further_replay_write(self):
        self.prepare(packed=True);real=mutation._save;fired=[]
        def crash(path,data):
            real(path,data)
            if path==self.base/'mutation.json' and not fired:
                fired.append(True);raise RuntimeError('intent crash')
        with patch.object(mutation,'_save',side_effect=crash),self.assertRaisesRegex(RuntimeError,'intent'):
            self.publish()
        record=self.manager._load(self.base);held=self.base/record['roots'][0]['held']
        victim=held/'file';replacement=held/'replacement';replacement.write_bytes(victim.read_bytes());replacement.replace(victim)
        with patch.object(mutation,'_atomic',wraps=mutation._atomic) as write,self.assertRaises(Exception):
            mutation.replay(self.manager,self.ident,approved_selection_sha256=self.approved)
        write.assert_not_called()

    def test_pre_intent_payload_crash_preserves_partial_data_and_retries(self):
        self.prepare();real=mutation._atomic;fired=[]
        def crash(path,data,**kwargs):
            real(path,data,**kwargs)
            if 'mutation-data' in path.parts and not fired:
                fired.append(True);raise RuntimeError('pre-intent crash')
        with patch.object(mutation,'_atomic',side_effect=crash),self.assertRaisesRegex(RuntimeError,'pre-intent'):
            self.publish()
        self.assertFalse((self.base/'mutation.json').exists())
        self.publish()
        self.assertTrue(list((self.base/'preparation-history').iterdir()))
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual(self.git('branch','--list','finished'),'')

    def test_crash_after_ref_replace_blocks_restore_and_replays(self):
        self.prepare(packed=True);real=mutation._atomic;fired=[]
        def crash(path,data,**kwargs):
            real(path,data,**kwargs)
            if 'content' in path.parts and not fired:
                fired.append(True);raise RuntimeError('crash after ref replacement')
        with patch.object(mutation,'_atomic',side_effect=crash),self.assertRaisesRegex(RuntimeError,'crash'):
            self.publish()
        with self.assertRaises(Exception):self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual(mutation.replay(self.manager,self.ident,approved_selection_sha256=self.approved)['phase'],'complete')
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual(self.git('branch','--list','finished'),'')

    def test_crash_after_metadata_receipt_replays(self):
        self.prepare();real=mutation._atomic;fired=[]
        def crash(path,data,**kwargs):
            real(path,data,**kwargs)
            if path==self.base/'metadata.jsonl' and not fired:
                fired.append(True);raise RuntimeError('metadata receipt crash')
        with patch.object(mutation,'_atomic',side_effect=crash),self.assertRaisesRegex(RuntimeError,'receipt'):
            self.publish()
        self.assertEqual(mutation.replay(self.manager,self.ident,approved_selection_sha256=self.approved)['phase'],'complete')
        self.manager.restore(self.ident,approved_sha256=self.digest)
        self.assertEqual(self.git('branch','--list','finished'),'')

    def test_corrupted_payload_holds_gate_closed(self):
        self.prepare();real=mutation._save;fired=[]
        def crash(path,data):
            real(path,data)
            if path==self.base/'mutation.json' and not fired:
                fired.append(True);raise RuntimeError('journal crash')
        with patch.object(mutation,'_save',side_effect=crash),self.assertRaisesRegex(RuntimeError,'journal'):
            self.publish()
        payload=next(p for p in (self.base/'mutation-data/after').rglob('*') if p.is_file())
        payload.write_text('bad')
        with self.assertRaisesRegex(mutation.MutationError,'payload'):
            mutation.replay(self.manager,self.ident,approved_selection_sha256=self.approved)
        with self.assertRaises(Exception):self.manager.restore(self.ident,approved_sha256=self.digest)


if __name__=='__main__':unittest.main()
