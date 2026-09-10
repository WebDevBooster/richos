#!/usr/bin/env python3
"""Actual Git and hook controls. All native/task/session records are fixtures."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('completion_proof',HERE/'completion-proof.py')
proof=importlib.util.module_from_spec(spec);spec.loader.exec_module(proof)
HOOK=HERE.parent/'hooks/task-completed-handoff.sh'

class Completion(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='richos-completion-test-')
        self.root=Path(self.temp.name).resolve();self.repo=self.root/'canonical';self.repo.mkdir()
        self.home=self.root/'home';self.home.mkdir();self.profile=self.home/'.claude';self.profile.mkdir()
        env={k:v for k,v in os.environ.items() if not k.startswith(('RICHOS_','CLAUDE_','TASK_COMPLETED_'))}
        env.update(HOME=str(self.home),CLAUDE_CONFIG_DIR=str(self.profile),RICHOS_WORKTREE_LEDGER=str(self.root/'ledger.jsonl'))
        self.environment=patch.dict(os.environ,env,clear=True);self.environment.start()
        self.git(self.repo,'init','-b','main');self.git(self.repo,'config','user.name','Fixture');self.git(self.repo,'config','user.email','fixture@example.invalid')
        (self.repo/'orchestration.config').write_text('# fixture adoption\n');(self.repo/'tracked').write_text('initial\n');(self.repo/'.gitignore').write_text('ignored\n')
        self.git(self.repo,'add','.');self.git(self.repo,'commit','-m','initial')
        self.worker=self.root/'worker';self.git(self.repo,'worktree','add','-b','worker',str(self.worker))
        self.sid='fixture-session-123456';self.aid='fixture-agent-123456';self.owner='worker-fixture';self.tid='7'
        self.member=dict(path=str(self.worker),repo=str(self.repo),branch='worker',**{'class':'hand-rolled'})
        self.tx=dict(record='transaction',session_id=self.sid,agent_id=self.aid,tool_use_id='tool-1',teammate=self.owner,kind='cwd',members=[self.member],sealed=True,start_cwd=str(self.worker),terminal=None)
        self.write(self.profile/'state/worktree-transactions'/self.sid/(self.aid+'.json'),self.tx)
        self.write(self.profile/'state/worktree-transactions'/self.sid/'bound'/(self.aid+'.json'),dict(agent_id=self.aid,session_id=self.sid,teammate=self.owner,tool_use_id='tool-1'))
        self.write(self.profile/'state/worktree-transactions'/self.sid/'starts'/(self.aid+'.json'),dict(agent_id=self.aid,session_id=self.sid,cwd_real=str(self.worker)))
        self.task=dict(id=self.tid,subject='Fixture delivery',description='Work',status='in_progress',owner=self.owner)
        self.task_path=self.profile/'tasks'/self.sid/(self.tid+'.json');self.write(self.task_path,self.task)
        self.payload=dict(hook_event_name='TaskCompleted',session_id=self.sid,task_id=self.tid,task_subject=self.task['subject'],teammate_name=self.owner,cwd=str(self.repo))
    def tearDown(self):self.environment.stop();self.temp.cleanup()
    def write(self,path,data):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(data))
    def git(self,path,*args):
        result=proof.git(path,*args);return result.stdout.decode().strip()
    def commit(self):self.git(self.worker,'add','--all');self.git(self.worker,'commit','-m','delivery')
    def merge(self):self.git(self.repo,'merge','--ff-only','worker')
    def hook(self,payload=None):
        data=json.dumps(self.payload if payload is None else payload)
        return subprocess.run(['/bin/bash',str(HOOK)],input=data,text=True,capture_output=True,env=dict(os.environ))
    def lead(self,cwd=None):
        self.task.pop('owner',None);self.write(self.task_path,self.task);self.payload.pop('teammate_name',None)
        self.payload['cwd']=str(cwd or self.repo)
        start=subprocess.check_output(['/bin/ps','-p',str(os.getpid()),'-o','lstart='],env={'PATH':'/usr/bin:/bin','LC_ALL':'C','TZ':'UTC'},text=True).strip()
        row=dict(pid=os.getpid(),procStart=start,sessionId=self.sid,cwd=self.payload['cwd'],kind='interactive',startedAt=1)
        self.session_path=self.profile/'sessions'/(str(os.getpid())+'.json');self.write(self.session_path,row)
        return row
    def test_clean_integrated_member_and_receipt(self):
        result=proof.prove_member(self.member)
        self.assertEqual(result['head'],self.git(self.repo,'rev-parse','main'))
        receipt=proof.complete(self.payload)
        self.assertEqual(proof.verify_receipt(receipt,self.worker)['head'],result['head'])
        self.assertEqual(len(proof.receipts_for_member(self.sid,self.aid,self.worker)),1)
    def test_dirty_staged_untracked_and_assume_flags_refuse(self):
        for kind in ('dirty','staged','untracked','assume'):
            with self.subTest(kind=kind):
                target=self.worker/('tracked' if kind in ('dirty','staged','assume') else kind)
                target.write_text('unique data')
                if kind=='staged':self.git(self.worker,'add','tracked')
                if kind=='assume':self.git(self.worker,'update-index','--assume-unchanged','tracked')
                with self.assertRaises(proof.CompletionError):proof.prove_member(self.member)
                if kind=='assume':self.git(self.worker,'update-index','--no-assume-unchanged','tracked')
                if target.name=='tracked':self.git(self.worker,'reset','--hard','HEAD')
                else:target.unlink()
    def test_ignored_files_do_not_change_or_refuse_a_linked_worktree_proof(self):
        # Round 10 (2026-09-10): an ignored file is not undelivered work. Before
        # this a linked worktree with one __pycache__ could neither complete its
        # task nor ever be reclaimed. The proof's digest covers tracked entries
        # only, so the ignored file leaves it byte-identical; what becomes of the
        # ignored bytes is the reclaim lane's decision, pinned in
        # daily-workspace-cleanup.test.py.
        clean=proof.prove_member(self.member)
        (self.worker/'ignored').write_text('local build output')
        cache=self.worker/'__pycache__';cache.mkdir();(cache/'x.pyc').write_bytes(b'\x00')
        (self.repo/'.git/info/exclude').write_text('__pycache__/\n')  # ignored, with the tracked .gitignore byte-identical
        with_ignored=proof.prove_member(self.member)
        self.assertEqual(with_ignored['working_tree_sha256'],clean['working_tree_sha256'])
        self.assertTrue((self.worker/'ignored').exists())
        (self.worker/'really-untracked').write_text('not ignored')
        with self.assertRaisesRegex(proof.CompletionError,'intended deliverables'):proof.prove_member(self.member)
    def test_unmerged_commit_completes_and_is_reclaimable_only_after_merge(self):
        # This case used to be test_unmerged_commit_refuses_then_actual_merge_
        # accepts, and it pinned the wrong contract: it required the lead's
        # merge BEFORE the worker could finish, while the lead merges only
        # after the worker reports. The worker's evidence is its own branch;
        # main's ancestry is the RECLAMATION question and is pinned below on
        # the same fixture, so neither half is dropped.
        (self.worker/'tracked').write_text('deliverable\n');self.commit()
        head=self.git(self.worker,'rev-parse','HEAD')
        self.assertNotEqual(head,self.git(self.repo,'rev-parse','main'))
        member=proof.complete(self.payload)['members'][0]
        self.assertEqual(member['head'],head)
        with self.assertRaisesRegex(proof.CompletionError,'no longer contains the delivery'):
            proof.verify_member_proof(member)
        self.merge();proof.verify_member_proof(member)
        self.assertEqual(proof.complete(self.payload)['members'][0]['head'],self.git(self.repo,'rev-parse','main'))
    def test_a_squash_landing_is_held_and_the_reason_SAYS_it_was_a_squash(self):
        # SAGE D6 / FRANK, 2026-09-10. A squash-landed or rebased branch can
        # never become an ancestor of main, so it is held FOREVER with
        # "Current canonical main no longer contains the delivery" — a sentence
        # that reads as "this never landed" and sends the reader to land work
        # that is already on main under a different sha.
        #
        # THE VERDICT IS UNCHANGED AND MUST BE. Only a tip proven an ancestor
        # is ever removed; that is the protection both reviewers confirmed
        # held, and nothing here relaxes it. What changed is that the reason
        # now distinguishes the two ways of arriving, because they need
        # different actions from a person.
        (self.worker/'tracked').write_text('deliverable\n');self.commit()
        member=proof.complete(self.payload)['members'][0]
        # squash-land it: the content is on main under a DIFFERENT commit
        self.git(self.repo,'merge','--squash','worker')
        self.git(self.repo,'commit','-m','squashed the delivery')
        with self.assertRaises(proof.CompletionError) as caught:
            proof.verify_member_proof(member)
        message=str(caught.exception)
        self.assertIn('no longer contains the delivery',message)
        self.assertIn('squash or rebase',message)
        self.assertIn('held forever',message)

    def test_genuinely_unlanded_work_says_UNLANDED_not_squashed(self):
        # The negative control for the case above. Without it, "squash" could
        # be printed on every refusal and the message would carry no
        # information at all.
        (self.worker/'tracked').write_text('deliverable\n');self.commit()
        member=proof.complete(self.payload)['members'][0]
        with self.assertRaises(proof.CompletionError) as caught:
            proof.verify_member_proof(member)
        message=str(caught.exception)
        self.assertIn('no longer contains the delivery',message)
        self.assertIn('unlanded work',message)
        self.assertNotIn('squash or rebase',message)

    def test_a_repository_whose_trunk_is_not_main_is_HELD_and_says_why(self):
        # SAGE D6. prove_member hard-codes integration='refs/heads/main', so on
        # a `master` repository direct() raised 'Git proof could not complete'
        # — fail-closed, which is right, with a reason that sends the reader
        # looking for a broken git. It is not broken: this lane understands
        # `main` and nothing else, and guessing the trunk is how a lane deletes
        # work from a branch nobody integrated into.
        other=self.root/'master-repo';other.mkdir()
        self.git(other,'init','-b','master')
        self.git(other,'config','user.name','Fixture');self.git(other,'config','user.email','f@example.invalid')
        (other/'f').write_text('base\n');self.git(other,'add','.');self.git(other,'commit','-m','base')
        wt=self.root/'master-worker';self.git(other,'worktree','add','-b','topic',str(wt))
        with self.assertRaises(proof.CompletionError) as caught:
            proof.prove_member(dict(path=str(wt),repo=str(other),branch='topic',
                                    **{'class':'hand-rolled'}))
        message=str(caught.exception)
        self.assertIn('has no refs/heads/main',message)
        self.assertIn('`master`',message)
        self.assertIn('nothing to repair',message)

    def test_actual_unfinished_merge_and_operation_markers_refuse(self):
        self.git(self.repo,'branch','side')
        self.git(self.repo,'commit','--allow-empty','-m','main advance')
        self.git(self.worker,'merge','--ff-only','main')
        self.git(self.repo,'worktree','add',str(self.root/'side'),'side')
        self.git(self.root/'side','commit','--allow-empty','-m','side advance')
        self.git(self.worker,'merge','--no-ff','--no-commit','side')
        with self.assertRaisesRegex(proof.CompletionError,'unfinished Git'):proof.prove_member(self.member)
        self.git(self.worker,'merge','--abort')
        admin=Path(self.git(self.worker,'rev-parse','--absolute-git-dir'))
        for name in ('rebase-merge','rebase-apply','CHERRY_PICK_HEAD','REVERT_HEAD','sequencer'):
            marker=admin/name;marker.symlink_to(self.root/'absent')
            with self.subTest(marker=name),self.assertRaisesRegex(proof.CompletionError,'unfinished Git'):proof.prove_member(self.member)
            marker.unlink()
        proof.prove_member(self.member)
    def test_tracked_parent_symlink_substitution_refuses(self):
        nested=self.worker/'nested';nested.mkdir();(nested/'file').write_text('deliverable')
        self.commit();self.merge();outside=self.root/'outside';nested.rename(outside);nested.symlink_to(outside,target_is_directory=True)
        with self.assertRaises(proof.CompletionError):proof.prove_member(self.member)
    def test_wrong_task_session_owner_and_binding_refuse(self):
        for key,value in [('task_id','wrong'),('session_id','wrong-session'),('teammate_name','different')]:
            payload=dict(self.payload,**{key:value})
            with self.subTest(key=key),self.assertRaises((proof.CompletionError,FileNotFoundError)):proof.complete(payload)
        start=self.profile/'state/worktree-transactions'/self.sid/'starts'/(self.aid+'.json')
        self.write(start,dict(agent_id=self.aid,session_id='other',cwd_real=str(self.worker)))
        with self.assertRaisesRegex(proof.CompletionError,'session'):proof.complete(self.payload)
    def test_foreign_canonical_and_changed_canonical_identity_refuse(self):
        other=self.root/'other';other.mkdir();self.git(other,'init','-b','main')
        with self.assertRaises(proof.CompletionError):proof.prove_member(dict(self.member,repo=str(other)))
        value=proof.prove_member(self.member);value['identities']['repo'][1]+=1
        with self.assertRaisesRegex(proof.CompletionError,'identity'):proof.verify_member_proof(value)
    def test_lead_cwd_does_not_replace_delegated_worker_scope(self):
        (self.worker/'tracked').write_text('worker-only dirty')
        self.assertEqual(self.git(self.repo,'status','--porcelain'),'')
        result=self.hook();self.assertEqual(result.returncode,2,result.stderr)
        self.assertFalse((self.root/'ledger.jsonl').exists())
        self.assertEqual((self.worker/'tracked').read_text(),'worker-only dirty')
    def test_ordinary_unassigned_lead_task_uses_native_session_and_checks_canonical(self):
        self.lead();result=self.hook();self.assertEqual(result.returncode,0,result.stderr)
        receipt=proof.read_json(proof.receipt_root()/self.sid/(self.tid+'.json'))
        self.assertEqual(receipt['members'][0]['original_path'],str(self.repo))
        (self.repo/'tracked').write_text('lead pending work')
        result=self.hook();self.assertEqual(result.returncode,2,result.stderr)
        self.assertIn('unstaged',result.stderr)
    def test_lead_ignored_local_secrets_stay_in_place_and_are_non_reclaimable(self):
        self.lead();(self.repo/'ignored').write_text('local secret stays private')
        result=proof.complete(self.payload);member=result['members'][0]
        self.assertFalse(member['reclaimable'])
        self.assertEqual((self.repo/'ignored').read_text(),'local secret stays private')
        with self.assertRaises(proof.CompletionError):proof.verify_member_proof(member,path_present=False)
        (self.repo/'new-deliverable').write_text('not ignored')
        with self.assertRaisesRegex(proof.CompletionError,'intended deliverables'):proof.complete(self.payload)
    def test_native_lead_identity_uses_producer_utc_contract_not_hook_environment(self):
        self.lead()
        with patch.dict(os.environ,{'LC_ALL':'fr_FR.UTF-8','LANG':'de_DE.UTF-8','TZ':'Pacific/Honolulu'}):
            result=self.hook();self.assertEqual(result.returncode,0,result.stderr)
    def test_lead_wrong_process_incarnation_and_cwd_refuse(self):
        row=self.lead();row['procStart']='wrong';self.write(self.session_path,row)
        with self.assertRaisesRegex(proof.CompletionError,'incarnation'):proof.complete(self.payload)
        self.lead();self.payload['cwd']=str(self.worker)
        with self.assertRaisesRegex(proof.CompletionError,'cwd'):proof.complete(self.payload)
    def test_explicit_non_git_native_lead_task_has_no_deletion_proof(self):
        business=self.root/'business';business.mkdir();(business/'report').write_text('meaningful report')
        self.lead(business);receipt=proof.complete(self.payload)
        self.assertEqual(receipt['members'],[]);self.assertEqual(receipt['non_code_evidence'],'lead-non-git')
        self.assertTrue((business/'report').exists())
    def test_named_lead_and_foreign_team_session(self):
        self.lead();self.task['owner']='orchestrator';self.write(self.task_path,self.task)
        self.payload.update(teammate_name='orchestrator',team_name='actual-team')
        config=dict(leadSessionId=self.sid,leadAgentId='lead-agent',members=[dict(agentId='lead-agent',name='orchestrator')])
        team=self.profile/'teams/actual-team/config.json';self.write(team,config)
        self.assertFalse(proof.complete(self.payload)['members'][0]['reclaimable'])
        foreign=self.profile/'tasks/actual-team'/(self.tid+'.json');self.write(foreign,self.task);self.task_path.unlink()
        config['leadSessionId']='other-session';self.write(team,config)
        with self.assertRaisesRegex(proof.CompletionError,'another session'):proof.complete(self.payload)
    def test_multiple_task_receipts_select_current_proof_after_native_removal(self):
        proof.complete(self.payload)
        (self.worker/'tracked').write_text('later deliverable');self.commit();self.merge()
        self.tid='8';self.task['id']=self.tid;self.task_path=self.profile/'tasks'/self.sid/(self.tid+'.json');self.write(self.task_path,self.task);self.payload['task_id']=self.tid
        latest=proof.complete(self.payload)
        self.git(self.repo,'worktree','remove',str(self.worker))
        receipts=proof.receipts_for_member(self.sid,self.aid,self.worker)
        self.assertEqual(receipts,[latest])
        prior=proof.receipt_root()/self.sid/'7.json';row=proof.read_json(prior);row['teammate']='tampered';self.write(prior,row)
        with self.assertRaisesRegex(proof.CompletionError,'digest'):proof.receipts_for_member(self.sid,self.aid,self.worker)
    def test_remote_task_is_explicit_nonlocal_scope(self):
        self.tx.update(kind='remote',members=[]);self.write(self.profile/'state/worktree-transactions'/self.sid/(self.aid+'.json'),self.tx)
        receipt=proof.complete(self.payload);self.assertEqual(receipt['members'],[]);self.assertEqual(receipt['non_code_evidence'],'remote')
    def test_post_removal_replay_allows_exact_branch_absence_not_substitution(self):
        value=proof.prove_member(self.member);self.git(self.repo,'worktree','remove',str(self.worker))
        proof.verify_member_proof(value,path_present=False)
        self.git(self.repo,'branch','-d','worker');proof.verify_member_proof(value,path_present=False)
        self.git(self.repo,'symbolic-ref','refs/heads/worker','refs/heads/main')
        with self.assertRaisesRegex(proof.CompletionError,'direct'):proof.verify_member_proof(value,path_present=False)
    def test_changed_branch_and_recreated_path_refuse_cleanup_replay(self):
        value=proof.prove_member(self.member);self.git(self.repo,'worktree','remove',str(self.worker))
        self.worker.symlink_to(self.root/'nonexistent')
        with self.assertRaisesRegex(proof.CompletionError,'path'):proof.verify_member_proof(value,path_present=False)
        self.worker.unlink();(self.repo/'tracked').write_text('new');self.git(self.repo,'add','.');self.git(self.repo,'commit','-m','new')
        self.git(self.repo,'branch','-f','worker','main')
        with self.assertRaisesRegex(proof.CompletionError,'changed'):proof.verify_member_proof(value,path_present=False)
    def test_global_hook_stands_down_only_for_unadopted_repositories(self):
        for branch in ('main','master'):
            other=self.root/('unadopted-'+branch);other.mkdir();self.git(other,'init','-b',branch)
            (other/'pending').write_text('unrelated work')
            with patch.dict(os.environ,{'CLAUDE_PROJECT_DIR':str(other)}):
                result=self.hook(dict(self.payload,cwd=str(other),session_id='unrelated-session',task_id='1'))
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual((other/'pending').read_text(),'unrelated work')
        with patch.dict(os.environ,{'RICHOS_ENTITY_ROOT':str(self.root/'missing-adopter')}):
            result=self.hook()
        self.assertEqual(result.returncode,2)
        self.assertFalse(proof.receipt_root().exists())
    def test_actual_hook_records_unreadable_events_without_side_effects_or_blocking(self):
        # An unreadable event is not a refusal to complete: it is the hook
        # saying it could not read the message. It must therefore take NO
        # advisory action and must not hold the task open on the strength of
        # evidence it never saw -- but it must stay visible, so the refusal is
        # written to the durable event log.
        unreadable=self.profile/'teammate-task-events.jsonl'
        payloads=({}, {'hook_event_name':None}, {'hook_event_name':42},
                  {'hook_event_name':[]}, {'hook_event_name':''}, {'hook_event_name':'   '})
        for index,payload in enumerate(payloads,start=1):
            with self.subTest(payload=payload):
                result=self.hook(payload)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertFalse(proof.receipt_root().exists())
                self.assertFalse((self.root/'ledger.jsonl').exists())
                rows=[json.loads(x) for x in unreadable.read_text().splitlines()]
                self.assertEqual(len(rows),index)
                self.assertEqual(rows[-1]['decision'],'unreadable')
                self.assertEqual(rows[-1]['session_id'],'')
        result=self.hook({'hook_event_name':'TaskCreated'})
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(len(unreadable.read_text().splitlines()),len(payloads))

    def test_actual_hook_records_only_verified_completions_and_fails_closed(self):
        teams=self.profile/'teams'/('session-'+self.sid[:8]);teams.mkdir(parents=True)
        result=self.hook();self.assertEqual(result.returncode,0,result.stderr)
        events=[json.loads(x) for x in (teams/'task-events.jsonl').read_text().splitlines()]
        self.assertEqual(events[0]['decision'],'verified')
        rows=[json.loads(x) for x in (self.root/'ledger.jsonl').read_text().splitlines()]
        self.assertEqual(rows[0]['signal'],'TaskCompleted')
        before=(teams/'task-events.jsonl').read_bytes();self.task_path.unlink()
        result=self.hook();self.assertEqual(result.returncode,2,result.stderr);self.assertEqual((teams/'task-events.jsonl').read_bytes(),before)
        # Unparseable bytes: no block, no ledger row, and the refusal is on the
        # record beside the completion it is not.
        ledger=(self.root/'ledger.jsonl').read_bytes()
        result=subprocess.run(['/bin/bash',str(HOOK)],input='not-json',capture_output=True,text=True,env=dict(os.environ))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.root/'ledger.jsonl').read_bytes(),ledger)
        events=[json.loads(x) for x in (teams/'task-events.jsonl').read_text().splitlines()]
        self.assertEqual([row['decision'] for row in events],['verified','unreadable'])
        result=self.hook(dict(self.payload,hook_event_name='TaskCreated'));self.assertEqual(result.returncode,0)
        self.assertEqual(len((teams/'task-events.jsonl').read_text().splitlines()),2)

if __name__=='__main__':unittest.main()
