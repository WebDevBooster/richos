#!/usr/bin/env python3
"""Synthetic desktop dispatch across real Git workspaces and the actual ECS store."""
import contextlib
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ENGINE=Path(__file__).resolve().parents[2]
def load():
    spec=importlib.util.spec_from_file_location("test_desktop_work",ENGINE/"mega-lander/app.py")
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

class DesktopWork(unittest.TestCase):
    def setUp(self):
        self.scratch=tempfile.TemporaryDirectory(prefix="app work fixture ");self.addCleanup(self.scratch.cleanup)
        self.root=Path(self.scratch.name).resolve();self.coord=self.root/"coordination";self.repo=self.root/"target project"
        self.session="fixture-session"
        for repo in (self.coord,self.repo):
            repo.mkdir();subprocess.run(["git","init","--template=","-q","-b","main",str(repo)],check=True)
            subprocess.run(["git","-C",str(repo),"-c","core.hooksPath=/dev/null","-c","commit.gpgSign=false","-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","--allow-empty","-qm","Fixture"],check=True)
        (self.coord/".claude/agents").mkdir(parents=True)
        for role in ("worker","reviewer"):(self.coord/f".claude/agents/{role}.md").write_text((ENGINE/f"agents/{role}.md").read_text())
        (self.coord/"orchestration.config").write_text('ALLOWED_MODELS="opus sonnet haiku"\nMODEL_TIERS="opus > sonnet > haiku"\n')
        (self.coord/".gitignore").write_text('.claude/\norchestration.config\n')
        hook=self.root/"spawn-hooks.json";hook.write_text(json.dumps({"hooks":{"PreToolUse":[{"matcher":"Agent","hooks":[{"type":"command","command":f"/bin/bash '{ENGINE}/scripts/hooks/guard-worktree-isolation.sh'"}]}]}}))
        self.registry=self.root/"entities.json";self.registry.write_text(json.dumps({"version":2,"entities":[{"id":"depot","roots":[str(self.repo)],"connected_repositories":[str(self.repo)]}]}))
        self.scope_path=self.root/"scope.json"
        env={"RICHOS_APP_STATE":str(self.root/"engine-state"),"RICHOS_APP_REGISTRY":str(self.registry),"RICHOS_APP_SCOPE":str(self.scope_path),
             "RICHOS_ENGINE_ROOT":str(ENGINE),"RICHOS_ENGINE_DIR":str(ENGINE),"RICHOS_ENTITY_ROOT":str(self.coord),"CLAUDE_PROJECT_DIR":str(self.coord),
             "RICHOS_APP_ENTITY":"depot","RICHOS_APP_THREAD":"thread-a",
             "RICHOS_WORKSPACES_DIR":str(self.root/"engine-state/workspaces"/hashlib.sha256(b'["depot","thread-a"]').hexdigest()),"RICHOS_SESSION_ID":self.session,"RICHOS_SESSION_PID":str(os.getpid()),
             "RICHOS_SPAWN_HOOK_SOURCES":f"app={hook}","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_NOSYSTEM":"1","PYTHONDONTWRITEBYTECODE":"1"}
        self.env=patch.dict(os.environ,env);self.env.start();self.addCleanup(self.env.stop)
        self.app=load();ecs=self.root/"ecs"
        binding=self.app.ECS.execute(ecs,{"protocol":1,"command":"bind","scope":{"entity_id":"depot","thread_id":"thread-a","session_id":self.session,"turn_id":"turn-a","audience":"ceo"},"request_id":"bind-first","source_ref":"ledger:thread-a:turn-a","expected_revision":None})["binding"]
        self.scope={"version":1,"actions_allowed":True,"bridge":{"state_root":str(ecs)},"binding":binding,"user_instruction":{"ledger_ref":"ledger:thread-a:turn-a","sha256":"fixture-host-attestation"}}
        self.scope_path.write_text(json.dumps(self.scope))
        self.app.ECS.execute(ecs,{"protocol":1,"command":"checkpoint","binding":binding,"request_id":"accept-fixture","checkpoint":{"statements":[{"verb":"commitment","fields":{"id":"fixture-task","title":"Create the fictional result"}}]}})
        self.app.W.record_session_start(self.session,str(self.coord))
        self.args={"request_id":"prepare-one","obligation_id":"fixture-task","repo":str(self.repo),"title":"Create fictional result","brief":"Create result.txt with FICTIONAL in the assigned target worktree. Commit only that file. Do not publish.","role":"worker","integration":"main"}

    def call(self,name,args=None):return self.app.call(self.scope_path,name,args or {})
    def test_preparation_is_idempotent_and_is_not_dispatch(self):
        first=self.call("prepare",self.args);again=self.call("prepare",self.args)
        self.assertEqual(first["id"],again["id"]);self.assertEqual(first["agent_payload"],again["agent_payload"])
        self.assertEqual(first["status"],"prepared");self.assertFalse(first["assignment_completed"])
        self.assertFalse((self.repo/"result.txt").exists())
        self.assertEqual(len(self.call("inspect")["records"]),1)
        with self.assertRaisesRegex(ValueError,"different work"):self.call("prepare",{**self.args,"brief":"Different task"})
    def test_dispatch_requires_exact_payload_and_blocks_duplicate_attempt(self):
        ready=self.call("prepare",self.args)
        envelope={"session_id":self.session,"tool_use_id":"actual-native-id","tool_input":ready["agent_payload"]}
        with self.assertRaisesRegex(ValueError,"differs"):self.app.dispatch_intent(self.scope,{**envelope,"tool_input":{**ready["agent_payload"],"prompt":"forged"}})
        self.app.dispatch_intent(self.scope,envelope)
        with self.assertRaisesRegex(ValueError,"already attempted"):self.app.dispatch_intent(self.scope,envelope)
        self.assertNotIn("agent_payload",self.call("prepare",self.args))
        with self.assertRaisesRegex(ValueError,"unresolved"):self.call("prepare",{**self.args,"request_id":"duplicate"})
    def test_unregistered_scope_stopped_turn_and_unknown_obligation_refuse_before_workspace_creation(self):
        other=self.root/"unrelated";other.mkdir()
        for change in ({"repo":str(other)},{"obligation_id":"unknown"}):
            with self.assertRaises(Exception):self.call("prepare",{**self.args,**change})
        self.scope["actions_allowed"]=False;self.scope_path.write_text(json.dumps(self.scope))
        with self.assertRaises(ValueError):self.call("prepare",self.args)
        self.assertFalse((self.root/"engine-state/target-worktrees").exists())
    def test_variable_git_targets_get_format_feedback_without_a_permission_grant(self):
        for command in ['git -C "$TARGET" status', 'git -C $TARGET status', 'git -C "${TARGET}" log -1', 'git -C "$(pwd)" status', 'git commit -m "$(cat <<EOF\nFixture\nEOF\n)"', 'git commit -m `echo Fixture`']:
            with self.subTest(command=command), self.assertRaisesRegex(ValueError,"Unsupported Git command form"):
                self.app.validate_shell_target({"tool_name":"Bash","tool_input":{"command":command}})
        for command in ['git -C "/fictional/target with spaces" status', "git -C '/fictional/$literal' status",  'python3 ./tests.py', "git commit -m 'Fix `marker` and $(literal)'"]:
            self.assertIsNone(self.app.validate_shell_target({"tool_name":"Bash","tool_input":{"command":command}}))
        self.assertIsNone(self.app.validate_shell_target({"tool_name":"Read","tool_input":{"command":"git -C $TARGET status"}}))

    def test_worker_file_boundary_uses_provider_identity_and_registered_target(self):
        ready=self.call("prepare",self.args)
        envelope={"session_id":self.session,"tool_use_id":"observed-call","tool_input":ready["agent_payload"]}
        self.app.dispatch_intent(self.scope,envelope)
        self.app.W.register_spawn(envelope,str(self.coord))
        self.app.W.bind_agent(self.session,"observed-call","observed-agent",str(self.coord))
        target=self.root/"engine-state/target-worktrees"/self.app.folder(self.scope).name/ready["name"]
        event={"session_id":self.session,"agent_id":"observed-agent","cwd":str(self.coord),"tool_name":"Write","tool_input":{"file_path":"wrong.txt"}}
        with self.assertRaisesRegex(ValueError,"outside"):self.app.worker_context(self.scope,event)
        event["tool_input"]["file_path"]=str(target/"right.txt")
        self.assertIn(str(target),self.app.worker_context(self.scope,event)["hookSpecificOutput"]["additionalContext"])
        (target/"redirect").symlink_to(self.coord,target_is_directory=True)
        event["tool_input"]["file_path"]=str(target/"redirect/wrong.txt")
        with self.assertRaisesRegex(ValueError,"outside"):self.app.worker_context(self.scope,event)

    def start_fixture_worker(self, ready, aid):
        payload={"session_id":self.session,"tool_use_id":"call-"+aid,"tool_input":ready["agent_payload"]}
        self.app.dispatch_intent(self.scope,payload)
        self.app.W.register_spawn(payload,str(self.coord))
        native=self.coord/".claude/worktrees"/("agent-"+aid)
        self.app.git(self.coord,"worktree","add","-b","worktree-agent-"+aid,str(native),"HEAD")
        self.app.W.record_start(self.session,aid,str(native),"richos-app-engine:"+ready["request"]["role"])
        self.app.W.bind_agent(self.session,payload["tool_use_id"],aid,str(self.coord))
        return self.root/"engine-state/target-worktrees"/self.app.folder(self.scope).name/ready["name"]

    def finish_fixture_worker(self,aid,report=""):
        self.app.W.record_end(self.session,aid,"SubagentStop")
        self.app.observe(self.scope,{"hook_event_name":"SubagentStop","session_id":self.session,"agent_id":aid,"last_assistant_message":report})

    def test_native_handback_requires_success_identity_and_observed_reviewer_end(self):
        worker=self.call("prepare",self.args)
        target=self.start_fixture_worker(worker,"handback-worker")
        (target/"result.txt").write_text("FICTIONAL")
        self.app.git(target,"add","result.txt")
        self.app.git(target,"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","Fictional handback result")
        commit=self.app.git(target,"rev-parse","HEAD")
        self.finish_fixture_worker("handback-worker")
        reviewer=self.call("prepare",{**self.args,"request_id":"handback-review","role":"reviewer","review_of":worker["id"]})
        self.start_fixture_worker(reviewer,"handback-reviewer")
        report="RICHOS_REVIEW "+json.dumps({"commit":commit,"verdict":"passed","checks":["synthetic exact-commit review"]})
        event={"hook_event_name":"PostToolUse","session_id":self.session,"agent_id":"handback-reviewer",
               "tool_name":"SubagentHandback","tool_use_id":"actual-handback-call", "tool_input":{"message":report},"tool_response":{"success":True}}
        def receipt():
            with self.app.locked(self.scope) as root: return self.app.read_record(root,reviewer["id"])
        for change in ({"hook_event_name":"PreToolUse"},{"agent_id":"another-agent"},{"session_id":"another-session"}):
            self.app.observe(self.scope,{**event,**change})
            self.assertNotIn("review_handback",receipt())
        self.app.observe(self.scope,{**event,"tool_response":{"success":False}})
        self.assertFalse(receipt()["review_handback"]["valid"])
        self.app.observe(self.scope,{**event,"tool_input":{"message":report.replace(commit,"0"*40)}})
        self.assertFalse(receipt()["review_handback"]["valid"])
        self.app.observe(self.scope,event)
        self.assertTrue(receipt()["review_handback"]["valid"])
        self.assertNotIn("review_observation",receipt())
        with self.assertRaises(ValueError): self.call("integrate",{"worker_id":worker["id"],"reviewer_id":reviewer["id"]})
        self.finish_fixture_worker("handback-reviewer","Report delivered to caller.")
        observation=receipt()["review_observation"]
        self.assertTrue(observation["valid"])
        self.assertTrue(observation["end_observed"])
        self.assertEqual(observation["tool_use_id"],"actual-handback-call")
        self.assertEqual(observation["report"]["commit"],commit)
        self.assertIn("review:",self.app.verification_evidence(self.scope,reviewer["id"]))
        # Explicit malformed final reports and failed later handbacks cannot reuse an old pass.
        self.finish_fixture_worker("handback-reviewer","RICHOS_REVIEW malformed")
        self.assertFalse(receipt()["review_observation"]["valid"])
        self.app.observe(self.scope,{**event,"hook_event_name":"PostToolUseFailure","error":"delivery failed"})
        self.finish_fixture_worker("handback-reviewer","No delivered report.")
        self.assertFalse(receipt()["review_observation"]["valid"])
        self.app.observe(self.scope,event)
        self.finish_fixture_worker("handback-reviewer","Report delivered to caller.")
        self.assertTrue(self.call("integrate",{"worker_id":worker["id"],"reviewer_id":reviewer["id"]})["work_integrated"])

    def test_interrupted_continuation_preserves_dirty_files_and_uses_original_session_key(self):
        worker=self.call("prepare",self.args)
        target=self.start_fixture_worker(worker,"interrupted-worker")
        (target/"unfinished.txt").write_text("KEEP UNFINISHED BYTES")
        old_session=self.session
        self.app.W.record_session_end(old_session,"synthetic interruption")
        old_revision=self.scope["binding"]["revision"]
        self.session="replacement-session"
        os.environ["RICHOS_SESSION_ID"]=self.session
        self.app.W.record_session_start(self.session,str(self.coord))
        binding=self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":"bind",
            "scope":{"entity_id":"depot","thread_id":"thread-a","session_id":self.session,"turn_id":"resume-turn","audience":"ceo"},
            "request_id":"resume-binding","source_ref":"ledger:thread-a:resume-turn","expected_revision":old_revision})["binding"]
        self.scope["binding"]=binding;self.scope_path.write_text(json.dumps(self.scope))
        follow={**self.args,"request_id":"continue-one","continue_of":worker["id"],"brief":"Continue the fictional assignment from its saved progress. Preserve the existing file."}
        with self.assertRaisesRegex(self.app.W.SpecError,"uncommitted|dirty"):
            self.call("prepare",follow)
        self.assertEqual((target/"unfinished.txt").read_text(),"KEEP UNFINISHED BYTES")
        self.assertEqual(len(self.call("inspect")["records"]),1)
        # Explicit fictional reconciliation before continuation. The adapter never
        # resets, deletes or silently commits the old dirty files itself.
        self.app.git(target,"add","unfinished.txt")
        self.app.git(target,"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","Saved fictional progress")
        continued=self.call("prepare",follow)
        next_target=self.start_fixture_worker(continued,"replacement-worker")
        canonical=self.app.W.load_agent(self.app.W.named_key(self.session,continued["name"]))
        self.assertEqual(canonical["continues"],[self.app.W.named_key(old_session,worker["name"])])
        self.assertEqual((next_target/"unfinished.txt").read_text(),"KEEP UNFINISHED BYTES")
        self.assertFalse(target.exists())
        self.assertFalse((self.repo/"unfinished.txt").exists())

    def test_review_exact_commit_integration_recovery_and_dirty_checkout_preservation(self):
        worker=self.call("prepare",self.args)
        target=self.start_fixture_worker(worker,"fixture-worker")
        (target/"result.txt").write_text("FICTIONAL")
        self.app.git(target,"add","result.txt")
        self.app.git(target,"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","Fictional result")
        commit=self.app.git(target,"rev-parse","HEAD")
        self.finish_fixture_worker("fixture-worker")
        reviewer=self.call("prepare",{**self.args,"request_id":"review-one","role":"reviewer","review_of":worker["id"],"title":"Review fictional result","brief":"Review the exact result.txt change; do not modify any files."})
        review_target=self.start_fixture_worker(reviewer,"fixture-reviewer")
        self.assertEqual(self.app.git(review_target,"rev-parse","HEAD"),commit)
        self.finish_fixture_worker("fixture-reviewer","RICHOS_REVIEW "+json.dumps({"commit":commit,"verdict":"passed","checks":["synthetic reviewer observation"]}))
        args={"worker_id":worker["id"],"reviewer_id":reviewer["id"]}
        (self.repo/"unrelated.txt").write_text("KEEP")
        with self.assertRaisesRegex(ValueError,"dirty"):self.call("integrate",args)
        self.assertEqual((self.repo/"unrelated.txt").read_text(),"KEEP")
        self.assertFalse((self.repo/"result.txt").exists())
        (self.repo/"unrelated.txt").unlink()
        original=self.app.git
        def crash_after_merge(repo,*argv):
            result=original(repo,*argv)
            if argv[:2]==("merge","--ff-only"):raise RuntimeError("synthetic crash after fast-forward")
            return result
        with patch.object(self.app,"git",side_effect=crash_after_merge):
            with self.assertRaisesRegex(RuntimeError,"synthetic crash"):self.call("integrate",args)
        self.assertEqual((self.repo/"result.txt").read_text(),"FICTIONAL")
        with patch.object(self.app.W,"remove_workspace",return_value=(False,"synthetic busy workspace")):
            pending=self.call("integrate",args)
        self.assertTrue(pending["work_integrated"])
        self.assertTrue(pending["cleanup_pending"])
        self.assertTrue(target.exists())
        with self.assertRaisesRegex(ValueError,"cleanup"):
            self.call("complete",{"obligation_id":"fixture-task","worker_ids":[worker["id"]]})
        result=self.call("integrate",args)
        self.assertTrue(result["work_integrated"]);self.assertFalse(result["obligation_closed"])
        self.assertEqual(result["cleanup_pending"],[])
        self.assertFalse(target.exists());self.assertFalse(review_target.exists())
        self.assertEqual(self.call("integrate",args),result)
        records=self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":"inspect","binding":self.scope["binding"],"query":{"section":"work"}})["records"]
        # The persisted authority event is the proof even if brief projection omits terminal work.
        store=self.app.ECS.EventStore(self.root/"ecs")
        with contextlib.closing(store.connect()) as conn:
            row=conn.execute("SELECT status FROM ecs_work_units WHERE external_id=?",(worker["id"],)).fetchone()
            self.assertEqual(row["status"],"completed")
            review_row=conn.execute("SELECT status FROM ecs_work_units WHERE external_id=?",(reviewer["id"],)).fetchone()
            self.assertEqual(review_row["status"],"completed")
        completion={"obligation_id":"fixture-task","worker_ids":[worker["id"]]}
        with self.assertRaisesRegex(ValueError,"every final worker"):
            self.call("complete",{**completion,"worker_ids":[reviewer["id"]]})
        with self.assertRaisesRegex(ValueError,"every final worker"):
            self.call("complete",{**completion,"worker_ids":[worker["id"],reviewer["id"]]})
        original_execute=self.app.ECS.execute
        def crash_after_close(root,request):
            answer=original_execute(root,request)
            if request["command"]=="complete-obligation":
                raise RuntimeError("synthetic crash after completion commit")
            return answer
        with patch.object(self.app.ECS,"execute",side_effect=crash_after_close):
            with self.assertRaisesRegex(RuntimeError,"synthetic crash"):
                self.call("complete",completion)
        # A new visible turn retries the original intent after ECS committed.
        old_binding=self.scope["binding"]
        binding=original_execute(self.root/"ecs",{"protocol":1,"command":"bind",
            "scope":{**{k:v for k,v in old_binding.items() if k!="revision"},"turn_id":"completion-retry"},
            "expected_revision":old_binding["revision"],"source_ref":"ledger:thread-a:completion-retry","request_id":"completion-retry"})["binding"]
        self.scope["binding"]=binding;self.scope_path.write_text(json.dumps(self.scope))
        completed=self.call("complete",completion)
        self.assertTrue(completed["obligation_closed"])
        self.assertFalse(completed["published"])
        self.assertEqual(self.call("complete",completion),completed)
        item=original_execute(self.root/"ecs",{"protocol":1,"command":"inspect","binding":binding,"query":{"item_id":"fixture-task"}})["item"]
        self.assertEqual(item["status"],"completed")
        with contextlib.closing(store.connect()) as conn:
            self.assertEqual(conn.execute("SELECT count(*) FROM ecs_events WHERE event_type='continuity.item_closed'").fetchone()[0],1)
        self.scope["actions_allowed"]=False;self.scope_path.write_text(json.dumps(self.scope))
        with self.assertRaisesRegex(ValueError,"visible app turn"):self.call("complete",completion)

    def test_rejected_review_then_continuation_cleans_the_complete_review_chain(self):
        worker=self.call("prepare",self.args)
        target=self.start_fixture_worker(worker,"wrong-worker")
        (target/"result.txt").write_text("WRONG")
        self.app.git(target,"add","result.txt")
        self.app.git(target,"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","Incorrect fictional result")
        wrong=self.app.git(target,"rev-parse","HEAD");self.finish_fixture_worker("wrong-worker")
        reviewer=self.call("prepare",{**self.args,"request_id":"reject-review","role":"reviewer","review_of":worker["id"],"title":"Review result","brief":"Verify the fictional requirement."})
        rejected_target=self.start_fixture_worker(reviewer,"reject-reviewer")
        self.finish_fixture_worker("reject-reviewer","RICHOS_REVIEW "+json.dumps({"commit":wrong,"verdict":"changes-requested","checks":["result is WRONG, expected FICTIONAL"]}))
        with self.assertRaisesRegex(ValueError,"passing review"):
            self.call("integrate",{"worker_id":worker["id"],"reviewer_id":reviewer["id"]})
        self.assertFalse((self.repo/"result.txt").exists())
        revised=self.call("prepare",{**self.args,"request_id":"revise-result","continue_of":worker["id"]})
        revised_target=self.start_fixture_worker(revised,"correct-worker")
        (revised_target/"result.txt").write_text("FICTIONAL")
        self.app.git(revised_target,"add","result.txt")
        self.app.git(revised_target,"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","Correct fictional result")
        correct=self.app.git(revised_target,"rev-parse","HEAD");self.finish_fixture_worker("correct-worker")
        final_review=self.call("prepare",{**self.args,"request_id":"final-review","role":"reviewer","review_of":revised["id"],"title":"Review corrected result","brief":"Verify the corrected requirement."})
        final_target=self.start_fixture_worker(final_review,"accept-reviewer")
        self.finish_fixture_worker("accept-reviewer","RICHOS_REVIEW "+json.dumps({"commit":correct,"verdict":"passed","checks":["result is FICTIONAL"]}))
        result=self.call("integrate",{"worker_id":revised["id"],"reviewer_id":final_review["id"]})
        self.assertEqual(result["cleanup_pending"],[])
        for path in (target,rejected_target,revised_target,final_target):self.assertFalse(path.exists(),str(path))
        self.assertEqual((self.repo/"result.txt").read_text(),"FICTIONAL")
        self.assertTrue(self.call("complete",{"obligation_id":"fixture-task","worker_ids":[revised["id"]]})["obligation_closed"])

    def test_completion_refuses_prepared_and_unreviewed_work(self):
        worker=self.call("prepare",self.args)
        args={"obligation_id":"fixture-task","worker_ids":[worker["id"]]}
        with self.assertRaisesRegex(ValueError,"unresolved execution"):self.call("complete",args)
        self.start_fixture_worker(worker,"unfinished")
        self.finish_fixture_worker("unfinished")
        with self.assertRaisesRegex(ValueError,"cleanup"):self.call("complete",args)
        item=self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":"inspect","binding":self.scope["binding"],"query":{"item_id":"fixture-task"}})["item"]
        self.assertNotEqual(item["status"],"completed")

    def test_another_thread_cannot_read_or_dispatch_through_this_provider(self):
        ready=self.call("prepare",self.args)
        other={**self.scope,"binding":{**self.scope["binding"],"thread_id":"thread-b"}}
        self.scope_path.write_text(json.dumps(other))
        with self.assertRaisesRegex(ValueError,"partition"):self.call("inspect")
        self.assertEqual(ready["agent_payload"]["run_in_background"],True)

    def test_uncertain_preparation_is_retained_and_not_repeated(self):
        with patch.object(self.app,"run",side_effect=TimeoutError("synthetic uncertain command")):
            with self.assertRaises(TimeoutError):self.call("prepare",self.args)
        result=self.call("prepare",self.args)
        self.assertEqual(result["status"],"unknown");self.assertNotIn("agent_payload",result)
    def test_ecs_outbox_reconciles_after_commit_before_local_receipt_and_new_turn(self):
        original=self.app.ECS.execute
        def interrupted(root,request):
            result=original(root,request)
            if request["command"]=="observe":raise RuntimeError("synthetic crash after ECS commit")
            return result
        with patch.object(self.app.ECS,"execute",side_effect=interrupted):
            with self.assertRaisesRegex(RuntimeError,"synthetic crash"):self.call("prepare",self.args)
        binding=original(self.root/"ecs",{"protocol":1,"command":"bind","scope":{**{k:v for k,v in self.scope["binding"].items() if k!="revision"},"turn_id":"turn-b"},"expected_revision":self.scope["binding"]["revision"],"source_ref":"ledger:thread-a:turn-b","request_id":"bind-second"})["binding"]
        self.scope["binding"]=binding;self.scope_path.write_text(json.dumps(self.scope))
        result=self.call("inspect")["records"][0]
        self.assertEqual(result["status"],"unknown");self.assertNotIn("ecs_pending",result)
        work=original(self.root/"ecs",{"protocol":1,"command":"inspect","binding":binding,"query":{"section":"work"}})
        self.assertEqual(len(work["records"]),1)

if __name__=="__main__":unittest.main()
