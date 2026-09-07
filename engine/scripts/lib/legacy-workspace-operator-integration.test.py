#!/usr/bin/env python3
"""Actual owner subprocess and isolated gate tests, never real maintenance."""
import copy
import importlib.util
import json
import os
import sys
from pathlib import Path
import unittest
import uuid
from types import SimpleNamespace
from unittest.mock import patch


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

fixture=load('legacy-workspace-inspection.test');gate=fixture.gate
operator=load('legacy-workspace-operator');job=load('legacy-workspace-job')


class OperatorIntegration(unittest.TestCase):
    setUp=fixture.OwnerInspection.setUp
    git=fixture.OwnerInspection.git

    def prepared(self):
        work=self.sources/'unknown-codex';self.git('worktree','add','-qb','codex-fixture',str(work))
        baseline=gate.owner_report(self.policy,self.context,require_root=False)
        self.assertIn('unknown-owner:'+str(work),baseline['repositories'][0]['blockers'])
        decisions=[operator.decision_record(row,target,'retain' if target['kind']=='canonical-checkout' else 'remove')
                   for row in baseline['repositories'] for target in row['gate_paths']]
        attestation=operator.build_attestation(baseline,decisions,'Explicit fixture operator downtime and exact cleanup authorization')
        private=self.root/'operator-private';private.mkdir(mode=0o700)
        path=private/(str(uuid.uuid4())+'.json');path.write_text(json.dumps(attestation));path.chmod(0o600)
        context=dict(self.context,operator_attestation={'path':str(path),'sha256':gate.planner.history._digest(attestation)})
        return work,baseline,path,context

    def test_actual_owner_child_applies_exact_operator_provenance_without_history_changes(self):
        work,baseline,path,context=self.prepared()
        actual=gate.owner_report(self.policy,context,require_root=False)
        self.assertEqual(actual['repositories'][0]['blockers'],[])
        self.assertEqual([r['path'] for r in actual['repositories'][0]['removal_candidates']],[str(work)])
        candidate=actual['repositories'][0]['removal_candidates'][0]
        self.assertNotIn('agent_id',candidate);self.assertNotIn('session_id',candidate)
        self.assertEqual(actual['history_sha256'],baseline['history_sha256'])
        self.assertEqual(actual['inspection_context'],context)
        self.assertEqual(list(self.transactions.iterdir()),[])

    def test_changed_head_and_parent_scope_refuse_existing_attestation(self):
        work,baseline,path,context=self.prepared()
        (self.sources/'unapproved-sibling').mkdir()
        with self.assertRaises(gate.GateError):gate.owner_report(self.policy,context,require_root=False)
        (self.sources/'unapproved-sibling').rmdir()
        (self.repo/'new-file').write_text('new');self.git('add','new-file');self.git('commit','-qm','new actual head')
        with self.assertRaises(gate.GateError):gate.owner_report(self.policy,context,require_root=False)
        self.assertTrue(work.exists())

    def test_hash_mode_and_symlink_refusal_precede_owner_subprocess(self):
        work,baseline,path,context=self.prepared();original=path.read_bytes()
        path.write_bytes(original+b' ')
        # JSON formatting alone is not an authority change; the canonical hash is pinned.
        gate.owner_report(self.policy,context,require_root=False)
        document=json.loads(original);document['authorization']='tampered';path.write_text(json.dumps(document))
        with patch.object(gate.subprocess,'run') as child:
            with self.assertRaisesRegex(gate.GateError,'hash'):gate.owner_report(self.policy,context,require_root=False)
            child.assert_not_called()
        document=json.loads(original);document['owner_uid']+=1;path.write_text(json.dumps(document))
        wrong_owner=dict(context,operator_attestation=dict(context['operator_attestation'],sha256=gate.planner.history._digest(document)))
        with patch.object(gate.subprocess,'run') as child:
            with self.assertRaisesRegex(gate.GateError,'another owner'):gate.owner_report(self.policy,wrong_owner,require_root=False)
            child.assert_not_called()
        path.write_bytes(original);path.chmod(0o644)
        with self.assertRaisesRegex(gate.GateError,'mode'):gate.owner_report(self.policy,context,require_root=False)
        path.chmod(0o600);other=path.with_name('saved');path.rename(other);path.symlink_to(other)
        with self.assertRaisesRegex(gate.GateError,'mode'):gate.owner_report(self.policy,context,require_root=False)
        self.assertTrue(work.exists())

    def test_admin_persists_only_fresh_exact_attestation_without_staging(self):
        work,baseline,unused,context=self.prepared();admin=fixture.admin
        release=self.root/'releases/test';release.mkdir(parents=True)
        private=self.root/'new-private';private.mkdir(mode=0o700)
        installed={'owners':{str(self.account.pw_uid):{'gid':self.account.pw_gid}},'private_root':str(private),
                   'repositories':{'fixture':{'path':str(self.repo),'owners':[self.account.pw_uid]}}}
        (self.root/'policy.json').write_text(json.dumps(installed))
        report_file=self.root/'baseline.json';report_file.write_text(json.dumps(baseline))
        decisions=json.loads(unused.read_text())['decisions'];decision_file=self.root/'decisions.json';decision_file.write_text(json.dumps(decisions))
        runtime=SimpleNamespace(validate_runtime=lambda:release,protected_path=lambda path,**kw:Path(path),validate_policy=lambda value:value)
        args=SimpleNamespace(operation='attest-maintenance',owner_uid=self.account.pw_uid,transactions=str(self.transactions),ledger=str(self.ledger),
             report=str(report_file),approved_sha256=gate.planner.history._digest(baseline),repository=[],decisions=str(decision_file),
             authorization='Explicit fixture maintenance authorization')
        original_owner_report=gate.owner_report;actual_python=sys.executable
        def report_as_owner(policy,ctx):
            with patch.object(gate.sys,'executable',actual_python):return original_owner_report(policy,ctx,require_root=False)
        def modules(name,filename):return runtime if filename=='managed-workspace-broker.py' else operator if filename=='legacy-workspace-operator.py' else gate
        with patch.object(admin,'load',side_effect=modules),patch.object(admin.sys,'executable',gate.INTERPRETER), \
             patch.object(gate,'owner_report',side_effect=report_as_owner):
            result=admin.run(args)
        path=Path(result['operator_attestation']['path'])
        self.assertEqual(path.parent,private/'legacy-authorizations');self.assertEqual(path.stat().st_mode&0o777,0o600)
        self.assertFalse(result['staged']);self.assertFalse((private/'legacy-gates').exists())
        self.assertEqual(result['report']['repositories'][0]['blockers'],[]);self.assertTrue(work.exists())
        # Reusing the approval after a changed parent namespace must refuse
        # before reserving another authorization, even when the JSON parses.
        (self.sources/'changed').mkdir();before=set(path.parent.iterdir())
        with patch.object(admin,'load',side_effect=modules),patch.object(admin.sys,'executable',gate.INTERPRETER), \
             patch.object(gate,'owner_report',side_effect=report_as_owner), \
             patch.object(admin,'persist_attestation') as save:
            with self.assertRaisesRegex(ValueError,'differs'):admin.run(args)
            save.assert_not_called()
        self.assertEqual(set(path.parent.iterdir()),before)

    def test_operator_candidate_still_requires_actual_later_boot_gate_contract(self):
        work,baseline,path,context=self.prepared()
        report=gate.owner_report(self.policy,context,require_root=False)
        vault=self.root/'gate-vault';vault.mkdir(mode=0o700)
        store=gate.LegacyGate(vault,require_root=False,inspection_context=context)
        with patch.object(store,'_boot',return_value='11111111-1111-4111-8111-111111111111'):
            ident=store.stage(report,approved_sha256=gate.planner.history._digest(report))['id']
            with self.assertRaisesRegex(gate.GateError,'boot'):
                with store.frozen_view(ident,approved_sha256=gate.planner.history._digest(report)):pass
            target=next(t for t in report['repositories'][0]['gate_paths'] if t['path']==str(work))
            selection=dict(version=1,gate_id=ident,gate_sha256=gate.planner.history._digest(report),approval_kind='exact-legacy-job',restore=True,
                candidates=[dict(repo_alias='fixture',path=str(work),identity=target['identity'],git_admin_path=target['git_directory']['path'],head=target['head'])],branches=[])
            scratch=store._base(ident)/'job-scratch';scratch.mkdir(mode=0o700)
            job.arm(store,selection,approved_selection_sha256=job.shadow.digest(selection),scratch_root=scratch)
            self.assertEqual(job.advance(store,ident,scratch_root=scratch,trusted_git=('/Library/Developer/CommandLineTools/usr/bin/git' if sys.platform=='darwin' else '/usr/bin/git'))['state'],'waiting-for-boot')
            self.assertEqual(list(scratch.iterdir()),[])
        with patch.object(store,'_boot',return_value='22222222-2222-4222-8222-222222222222'):
            store.restore(ident,approved_sha256=gate.planner.history._digest(report))
        self.assertTrue((work/'file').exists())


if __name__=='__main__':unittest.main(verbosity=2)
