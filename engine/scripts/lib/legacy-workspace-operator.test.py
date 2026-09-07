#!/usr/bin/env python3
"""Real tiny Git reports exercise plan-bound operator authorization semantics."""
import copy
import importlib.util
import os
from pathlib import Path
import pwd
import unittest
from unittest.mock import patch


def load(name):
    spec=importlib.util.spec_from_file_location(name,Path(__file__).with_name(name+'.py'))
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

operator=load('legacy-workspace-operator');fixtures=load('legacy-workspace-gate.test')


class Operator(unittest.TestCase):
    setUp=fixtures.GateWorkflow.setUp
    git=fixtures.GateWorkflow.git

    def baseline(self,*,terminal=False):
        report=fixtures.gate.planner.plan({'repositories':{'fixture':{'path':str(self.repo)}}},[self.tx] if terminal else [],[])
        report['inspection_context']=dict(version=1,owner_uid=os.getuid(),owner_gid=os.getgid(),
            owner_home=pwd.getpwuid(os.getuid()).pw_dir,transactions=str(self.root/'transactions'),ledger=str(self.root/'ledger.jsonl'))
        return report

    def decisions(self,report,*,action='remove'):
        return [operator.decision_record(row,target,'retain' if target['path']==str(self.repo) else action)
                for row in report['repositories'] for target in row['gate_paths']]

    def attest(self,report,decisions=None):
        return operator.build_attestation(report,self.decisions(report) if decisions is None else decisions,
            'Operator confirms all work has stopped and authorizes the exact listed offline maintenance scope.')

    def test_unknown_owner_authority_preserves_history_and_evidence_without_terminal_fiction(self):
        base=self.baseline();before=copy.deepcopy(base);attestation=self.attest(base)
        result=operator.validate_and_apply(base,attestation)
        self.assertEqual(base,before);self.assertEqual(result['history_sha256'],base['history_sha256'])
        self.assertFalse(result['execution_ready']);self.assertFalse(result['execution_authorized'])
        row=result['repositories'][0];self.assertEqual(row['blockers'],[])
        self.assertEqual(row['operator_waived_blockers'],base['repositories'][0]['blockers'])
        for old,new in zip(base['repositories'][0]['gate_paths'],row['gate_paths']):
            self.assertEqual(old['ownership'],new['ownership'])
        candidate=row['removal_candidates'][0]
        self.assertEqual(candidate['provenance'],'explicit-operator-maintenance')
        self.assertNotIn('session_id',candidate);self.assertNotIn('agent_id',candidate)
        self.assertFalse(candidate['execution_authorized'])
        self.assertEqual(operator.digest(base),fixtures.gate.planner.history._digest(base))

    def test_retain_filters_even_preexisting_terminal_removal_candidates(self):
        base=self.baseline(terminal=True);self.assertEqual(len(base['repositories'][0]['removal_candidates']),1)
        result=operator.validate_and_apply(base,self.attest(base,self.decisions(base,action='retain')))
        self.assertEqual(result['repositories'][0]['removal_candidates'],[])

    def test_every_target_needs_exactly_one_explicit_decision(self):
        base=self.baseline();decisions=self.decisions(base)
        for chosen in (decisions[:-1],decisions+[decisions[0]],decisions[:1]*2):
            with self.subTest(chosen=chosen),self.assertRaises(operator.OperatorError):self.attest(base,chosen)
        changed=copy.deepcopy(decisions);changed[1]['repo_alias']='other'
        with self.assertRaises(operator.OperatorError):self.attest(base,changed)

    def test_exact_complete_report_change_invalidates_authority(self):
        base=self.baseline();attestation=self.attest(base)
        variants=[]
        changed=copy.deepcopy(base);changed['history_sha256']='0'*64;variants.append(changed)
        changed=copy.deepcopy(base);changed['repositories'][0]['temporary_parent_gates'][0]['affected_entries'].append('new-work');variants.append(changed)
        changed=copy.deepcopy(base);changed['repositories'][0]['gate_roots'][0]['identity']['inode']+=1;variants.append(changed)
        changed=copy.deepcopy(base);changed['repositories'][0]['common_git_directory']['inode']+=1;variants.append(changed)
        for changed in variants:
            with self.assertRaises(operator.OperatorError):operator.validate_and_apply(changed,attestation)

    def test_head_admin_and_path_identity_changes_are_not_authorized(self):
        base=self.baseline();attestation=self.attest(base)
        for key,value in (('head','1'*40),('git_admin_path',str(self.root/'other-admin')),('path',str(self.root/'other-work'))):
            changed=copy.deepcopy(attestation);changed['decisions'][1][key]=value
            with self.subTest(key=key),self.assertRaises(operator.OperatorError):operator.validate_and_apply(base,changed)
        changed=copy.deepcopy(attestation);changed['decisions'][1]['identity']['inode']+=1
        with self.assertRaises(operator.OperatorError):operator.validate_and_apply(base,changed)

    def test_live_state_and_alive_witness_cannot_be_waived(self):
        for witness in (False,True):
            base=self.baseline();target=base['repositories'][0]['gate_paths'][1]
            if witness:target['ownership']['evidence'].append({'kind':'process','status':'alive'})
            else:target['ownership']['state']='live'
            with self.assertRaisesRegex(operator.OperatorError,'live'):self.attest(base)

    def test_storage_history_namespace_and_inventory_errors_cannot_be_waived(self):
        for blocker in ('live-owner:'+str(self.work),'inventory-unavailable:unreadable','object-store-external-dependency:/outside',
                        'terminal-member-identity-mismatch:'+str(self.work),'unknown-owner:/unlisted',
                        'overlapping-gate-paths:/a:/b','temporary-parent-inventory-unavailable:/outside'):
            base=self.baseline();base['repositories'][0]['blockers'].append(blocker)
            with self.subTest(blocker=blocker),self.assertRaises(operator.OperatorError):self.attest(base)
        base=self.baseline();base['errors']=['unreadable history']
        with self.assertRaises(operator.OperatorError):self.attest(base)
        base=self.baseline();base['repositories'][0]['inventory_complete']=False
        with self.assertRaises(operator.OperatorError):self.attest(base)

    def test_canonical_and_external_common_stores_cannot_be_removed(self):
        base=self.baseline();decisions=self.decisions(base);decisions[0]['action']='remove'
        with self.assertRaisesRegex(operator.OperatorError,'retained'):self.attest(base,decisions)
        common=copy.deepcopy(base['repositories'][0]['common_git_directory']);common['kind']='external-common-git-directory'
        row=base['repositories'][0]
        decision=operator.decision_record(row,common,'retain');self.assertIsNone(decision['head'])
        self.assertEqual(decision['git_admin_path'],common['path'])
        with self.assertRaisesRegex(operator.OperatorError,'retained'):operator.decision_record(row,common,'remove')

    def test_nested_target_cannot_be_removed_over_retained_descendant(self):
        base=self.baseline();row=base['repositories'][0];child=copy.deepcopy(row['gate_paths'][1])
        child['path']=str(self.work/'child');child['identity']['path']=child['path'];row['gate_paths'].append(child)
        decisions=self.decisions(base);decisions[-1]['action']='retain'
        with self.assertRaisesRegex(operator.OperatorError,'containing'):self.attest(base,decisions)

    def test_changed_owner_extra_fields_and_attestation_chaining_refuse(self):
        base=self.baseline();attestation=self.attest(base)
        for key,value in (('owner_uid',9999),('owner_gid',9999),('extra','unknown'),('authorization','')):
            changed=copy.deepcopy(attestation);changed[key]=value
            with self.subTest(key=key),self.assertRaises(operator.OperatorError):operator.validate_and_apply(base,changed)
        transformed=operator.validate_and_apply(base,attestation)
        with self.assertRaises(operator.OperatorError):operator.validate_and_apply(transformed,attestation)
        extended=copy.deepcopy(base);extended['inspection_context']['operator_attestation']={'path':'/authority','sha256':'0'*64}
        with self.assertRaises(operator.OperatorError):self.attest(extended)

    def test_explicit_orphan_admin_retirement_keeps_separate_kind(self):
        import shutil
        shutil.rmtree(self.work);base=self.baseline()
        attestation=self.attest(base);transformed=operator.validate_and_apply(base,attestation)
        candidate=transformed['repositories'][0]['removal_candidates'][0]
        self.assertEqual(candidate['kind'],'orphan-registration');self.assertEqual(candidate['identity']['state'],'absent')
        self.assertNotIn('session_id',candidate)

    def test_operator_authority_never_bypasses_real_gate_same_boot_barrier(self):
        base=self.baseline();attestation=self.attest(base);transformed=operator.validate_and_apply(base,attestation)
        self.manager.inspection_context=base['inspection_context']
        with patch.object(fixtures.gate,'owner_report',return_value=transformed):
            ident=self.manager.stage(transformed,approved_sha256=operator.digest(transformed))['id']
        self.assertFalse(self.manager.inspect(ident)['boot_cutoff_verified'])
        with self.assertRaisesRegex(fixtures.gate.GateError,'later-boot'):
            with self.manager.frozen_view(ident,approved_sha256=operator.digest(transformed)):pass
        with self.assertRaises(fixtures.gate.GateError):self.manager.restore(ident,approved_sha256=operator.digest(transformed))


if __name__=='__main__':unittest.main()
