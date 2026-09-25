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
import threading
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
             "RICHOS_SPAWN_HOOK_SOURCES":f"app={hook}","GIT_CONFIG_GLOBAL":"/dev/null","GIT_CONFIG_NOSYSTEM":"1","PYTHONDONTWRITEBYTECODE":"1",
             # The land locks are machine-wide by design (~/.claude/state/land-locks).
             # A test must not touch the operator's real ones, and this is the
             # override that exists for exactly that -- it cannot reach an
             # app-launched engine, whose configure() strips every inherited
             # RICHOS_* name and re-adds only its own list.
             "RICHOS_LAND_LOCKS_DIR":str(self.root/"land locks")}
        self.env=patch.dict(os.environ,env);self.env.start();self.addCleanup(self.env.stop)
        self.app=load();ecs=self.root/"ecs"
        binding=self.app.ECS.execute(ecs,{"protocol":1,"command":"bind","scope":{"entity_id":"depot","thread_id":"thread-a","session_id":self.session,"turn_id":"turn-a","audience":"ceo"},"request_id":"bind-first","source_ref":"ledger:thread-a:turn-a","expected_revision":None})["binding"]
        self.scope={"version":1,"actions_allowed":True,"bridge":{"state_root":str(ecs)},"binding":binding,"user_instruction":{"ledger_ref":"ledger:thread-a:turn-a","sha256":"fixture-host-attestation"}}
        self.scope_path.write_text(json.dumps(self.scope))
        self.app.ECS.execute(ecs,{"protocol":1,"command":"checkpoint","binding":binding,"request_id":"accept-fixture","checkpoint":{"statements":[{"verb":"commitment","fields":{"id":"fixture-task","title":"Create the fictional result"}}]}})
        self.app.W.record_session_start(self.session,str(self.coord))
        self.args={"request_id":"prepare-one","obligation_id":"fixture-task","repo":str(self.repo),"title":"Create fictional result","brief":"Create result.txt with FICTIONAL in the assigned target worktree. Commit only that file. Do not publish.","role":"worker","integration":"main"}

    def call(self,name,args=None):return self.app.call(self.scope_path,name,args or {})
    def test_pause_message_is_fixed_and_does_not_claim_delivery(self):
        protocol=self.app.load("pause_message_test",ENGINE/"scripts/lib/pause_protocol.py")
        for reason,reset in [("manual",None),("quota","15:30Z")]:
            result=self.call("pause_message",{"to":"worker-fixture","reason":reason,"reset":reset})
            self.assertEqual(result["message_payload"],protocol.message_input("worker-fixture",reason,reset))
            self.assertIs(result["delivered"],False)
            self.assertIs(result["pause_confirmed"],False)
        for extra in ({"message":"End your test"},{"summary":"Stop now"},{"reset":"15:30Z\nKill the test"},{"to":""}):
            with self.assertRaises(ValueError):
                self.call("pause_message",{"to":"worker-fixture",**extra})
        self.assertEqual(self.call("inspect")["records"],[])

    def test_preparation_is_idempotent_and_is_not_dispatch(self):
        first=self.call("prepare",self.args);again=self.call("prepare",self.args)
        self.assertEqual(first["id"],again["id"]);self.assertEqual(first["agent_payload"],again["agent_payload"])
        self.assertEqual(first["status"],"prepared");self.assertFalse(first["assignment_completed"])
        self.assertFalse((self.repo/"result.txt").exists())
        self.assertEqual(len(self.call("inspect")["records"]),1)
        with self.assertRaisesRegex(ValueError,"different work"):self.call("prepare",{**self.args,"brief":"Different task"})
    def test_preflight_refusal_allows_a_corrected_request_without_claiming_a_start(self):
        subprocess.run(["git", "-C", str(self.repo), "branch", "-m", "integration"], check=True)
        missing = {k:v for k,v in self.args.items() if k != "integration"}
        with self.assertRaisesRegex(ValueError, "will not guess the branch"):
            self.call("prepare", missing)
        refused = self.call("inspect")["records"][0]
        self.assertEqual(refused["status"], "blocked")
        self.assertTrue(refused["preparation_refused"])
        self.assertNotIn("agent_payload", refused)
        self.assertIsNone(self.app.W.load_agent(self.app.W.named_key(self.session, refused["name"])))
        ready = self.call("prepare", {**self.args, "request_id":"corrected", "integration":"integration"})
        self.assertEqual(ready["status"], "prepared")
        self.assertIn("agent_payload", ready)

    def test_unstructured_spawn_failure_still_blocks_duplicate_work(self):
        command = [sys.executable, "-c", "import sys; print('spawn: refused - NOTHING WAS CREATED.'); sys.exit(1)"]
        with patch.object(self.app, "build_spawn_command", return_value=command):
            with self.assertRaises(ValueError): self.call("prepare", self.args)
        record = self.call("inspect")["records"][0]
        self.assertEqual(record["status"], "unknown")
        with self.assertRaisesRegex(ValueError, "unresolved"):
            self.call("prepare", {**self.args, "request_id":"must-not-duplicate"})

    def test_build_spawn_command_one_repository_is_byte_identical_to_todays_command(self):
        # POSITIVE CONTROL: the exact list `prepare()` built before this
        # function existed, for one repository. Any change to this function
        # that touches the single-repository path must fail here first.
        # `--audience app` joined it on 2026-09-18: everything reached from
        # here is the APP's dispatch, so it is judged by the user-work guards
        # and never by the development session's (Rich's ruling, CEO §57).
        name,brief_path,title="worker-sonnet-abc123456789",Path("/x/y.brief"),"Some title"
        got=self.app.build_spawn_command([("/some/repo","/dest/path")],name,"worker",brief_path,title,
            integration="main",base=None)
        want=[sys.executable,str(self.app.ENGINE/"scripts/lib/spawn.py"),name,"--repo","/some/repo",
            "--type","richos-app-engine:worker","--model","sonnet","--brief",str(brief_path),
            "--description",title,"--audience","app","--dir","/dest/path","--json","--integration","main"]
        self.assertEqual(got,want)

    def test_build_spawn_command_two_repositories_emits_two_repo_and_scoped_values(self):
        name,brief_path,title="worker-sonnet-def456789012","/x/y.brief","Some title"
        got=self.app.build_spawn_command(
            [("/repoA","/destA"),("/repoB","/destB")],name,"worker",brief_path,title,
            integration="main",base="deadbeef")
        want=[sys.executable,str(self.app.ENGINE/"scripts/lib/spawn.py"),name,
            "--repo","/repoA","--repo","/repoB",
            "--type","richos-app-engine:worker","--model","sonnet","--brief",str(brief_path),
            "--description",title,"--audience","app","--dir","/repoA=/destA","--dir","/repoB=/destB","--json",
            "--integration","/repoA=main","--base","/repoA=deadbeef"]
        self.assertEqual(got,want)

    def test_prepare_with_repos_creates_a_workspace_in_each_and_scopes_the_form(self):
        second=self.root/"second project";second.mkdir()
        subprocess.run(["git","init","--template=","-q","-b","main",str(second)],check=True)
        subprocess.run(["git","-C",str(second),"-c","core.hooksPath=/dev/null","-c","commit.gpgSign=false","-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","--allow-empty","-qm","Fixture"],check=True)
        self.registry.write_text(json.dumps({"version":2,"entities":[{"id":"depot","roots":[str(self.repo),str(second)],
            "connected_repositories":[str(self.repo),str(second)]}]}))
        ready=self.call("prepare",{**self.args,"request_id":"prepare-multi","repos":[str(second)]})
        self.assertEqual(ready["status"],"prepared")
        lines=[l for l in ready["agent_payload"]["prompt"].splitlines() if l.startswith("cross-repo-worktree:")]
        # Neither self.repo nor second is this session's own repository
        # (RICHOS_ENTITY_ROOT is self.coord), so EACH gets its own registered
        # cc/ workspace and its own line in the one payload (point 10).
        self.assertEqual(len(lines),2)
        # Each cross-repo-worktree line names its own DESTINATION (the
        # workspace path), not the source repository — the destination is
        # namespaced by the repository's own basename, so that is what each
        # repository's line is checked against.
        self.assertTrue(any(self.repo.name in l for l in lines))
        self.assertTrue(any(second.name in l for l in lines))
        self.assertEqual(self.call("inspect")["records"][0]["request"]["repos"],[str(self.repo),str(second)])

    def test_prepare_rejects_a_repeated_or_unconnected_repos_entry(self):
        with self.assertRaisesRegex(ValueError,"distinct"):
            self.call("prepare",{**self.args,"request_id":"prepare-dup","repos":[str(self.repo)]})
        unconnected=self.root/"not connected";unconnected.mkdir()
        with self.assertRaisesRegex(ValueError,"connect this exact repository"):
            self.call("prepare",{**self.args,"request_id":"prepare-unconnected","repos":[str(unconnected)]})

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
        # THE SAME LAND, REPEATED, IS THE SAME ANSWER — except for this call's
        # own observation of the lock, which is not a fact about the work: it is
        # how long THIS call waited for the repository and where it waited. That
        # was compared too until 2026-09-17 and made this assertion flaky within
        # hours of the lock landing (`land_lock.landed.at` is a whole-second ISO
        # stamp, so two calls either side of a second boundary differed; measured
        # red on pristine f5157115). The land itself is now recorded in the
        # append-only history beside the lock, which the repeat does not touch.
        again=self.call("integrate",args)
        self.assertEqual({k:v for k,v in again.items() if k!="land_lock"},
                         {k:v for k,v in result.items() if k!="land_lock"})
        self.assertEqual(again["land_lock"]["repository"],result["land_lock"]["repository"])
        self.assertLess(again["land_lock"]["waited_seconds"],1.0)
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

    def test_a_prepared_worker_is_dispatched_in_the_background_because_nothing_else_works(self):
        """The invariant candidate .10 exposed, and the one this was changed to and back.

        `run_in_background: True` carried no comment and no test of its own, so it read like
        an accident. It is not: `guard-worktree-isolation.sh` clause 7b refuses a file-capable
        spawn with `False`, and `workspaces.py`'s `bind_agent` — the only thing that joins the
        platform's agent id to this receipt — runs at `PostToolUse[Agent]`, which a synchronous
        call does not deliver until the worker has already finished. Measured with `False` on
        a real provider: `SubagentStart` arrived and then every one of the worker's own tool
        calls was refused with *"worker identity has not joined its app receipt"*.

        Waiting for the helper is therefore the host's (`work_host.rs`'s `run_one` step 3b),
        and this assertion exists so the next reader changes the host rather than this line.
        """
        ready=self.call("prepare",self.args)
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
    # ---------------------------------------------------------------- the work seat
    def bind_seat(self,seat,turn,audience="worker",session=None,revision=None):
        return self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":"bind","seat":seat,
            "scope":{"entity_id":"depot","thread_id":"thread-a","session_id":session or ("session-"+turn),
                     "turn_id":turn,"audience":audience},
            "request_id":"bind-"+(seat or "ceo")+"-"+turn,"source_ref":"ledger:thread-a:"+turn,
            "expected_revision":revision})["binding"]

    def three_ceo_turns(self):
        """His next three sentences. Each one rewrites HIS cursor and bumps it."""
        for number in (2,3,4):
            self.scope["binding"]=self.bind_seat(None,"turn-%d"%number,audience="ceo",
                                                 session=self.session,revision=number-1)
            self.scope_path.write_text(json.dumps(self.scope))
        self.assertEqual(self.scope["binding"]["revision"],4)

    def work_lease(self,assignment="fixture-task",seat=None):
        """A background lease's own scope file: its own seat, one per assignment.

        Its turn_id IS the assignment, because a request cannot outlive a turn id
        and a background assignment has to (5.3). Its grant stands while no turn
        is open, which is the whole reason the work tools are reachable at all.
        """
        seat = seat or ("work-seat:"+assignment)
        binding = self.bind_seat(seat,assignment)
        path = self.root/("work-scope-"+assignment+".json")
        path.write_text(json.dumps({**self.scope,"binding":binding,"seat":seat}))
        return path,seat

    def test_reused_work_lease_cannot_inspect_or_land_another_assignment(self):
        ready=self.call("prepare",self.args)
        current,_=self.work_lease()
        self.assertEqual(self.app.call(current,"inspect",{})["records"][0]["id"],ready["id"])
        other,_=self.work_lease("another-assignment")
        self.assertEqual(self.app.call(other,"inspect",{}),{"records":[],"next_offset":None})
        with patch.object(self.app,"land_lock") as lock:
            with self.assertRaisesRegex(ValueError,"another assignment"):
                self.app.call(other,"integrate",{"worker_id":ready["id"],"reviewer_id":"unread"})
            lock.assert_not_called()
        # The conversation still owns the combined history.
        self.assertEqual(len(self.call("inspect")["records"]),1)

    def test_a_background_assignment_still_reports_after_three_ceo_turns(self):
        """Acceptance 7.2, and the half that fails is the REPORT, not the read.

        A running process that can no longer speak looks identical to a healthy one
        from the outside, which is exactly why this gate went unnoticed twice. So
        this walks it with the tool that WRITES.
        """
        ready=self.call("prepare",self.args)
        self.app.dispatch_intent(self.scope,{"session_id":self.session,
            "tool_use_id":"actual-native-id","tool_input":ready["agent_payload"]})
        work,seat = self.work_lease()
        self.three_ceo_turns()
        store=self.store()
        # THE TRAP THIS TEST EXISTS TO AVOID: with the two rows left sitting at the
        # same revision the broken form passes. His row is at 4 and the assignment's
        # is at 1, and only then is the report below a real question.
        self.assertEqual((dict(store.current_context())["revision"],
                          dict(store.current_context(seat))["revision"]),(4,1))
        before=len(self.events(store,"work_unit.upserted"))
        # The assignment speaks. This appends work_unit.upserted, which is fenced
        # against the row belonging to the event's own person.
        self.assertEqual(self.app.call(work,"inspect",{})["records"][0]["status"],"dispatching")
        wrote=self.events(store,"work_unit.upserted")
        self.assertEqual(len(wrote),before+1)
        self.assertEqual(wrote[-1]["person_id"],seat)
        # And his own conversation still sees the background record, because the
        # entity and the thread stay single and shared.
        units=self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":"inspect",
            "binding":self.scope["binding"],"query":{"section":"work"}})["records"]
        self.assertEqual([row["status"] for row in units],["assigned"])

    def store(self):
        sys.path.insert(0,str(ENGINE/"ecs/core"))
        from ecs_core import EventStore
        return EventStore(self.root/"ecs")

    def events(self,store,event_type):
        conn=store.connect()
        try:
            return [dict(row) for row in conn.execute(
                "SELECT person_id FROM ecs_events WHERE event_type=? ORDER BY sequence",
                (event_type,)).fetchall()]
        finally:
            conn.close()

    def test_every_request_from_a_work_lease_carries_its_seat(self):
        self.call("prepare",self.args)
        work,seat = self.work_lease()
        seen=[]
        real=self.app.ECS.execute
        def watch(root,request):
            seen.append(request.get("seat"));return real(root,request)
        with patch.object(self.app.ECS,"execute",watch):
            self.app.call(work,"inspect",{})
            self.assertTrue(seen and all(value==seat for value in seen),seen)
            # The control that makes the assertion mean something: the same tool on
            # the conversation's scope names no seat at all, so a seat can never be
            # something this adapter supplies by default.
            seen.clear();self.call("inspect")
            self.assertTrue(seen and all(value is None for value in seen),seen)

    def test_a_work_lease_prepares_against_the_obligation_its_scope_carries_and_never_one_it_names(self):
        """The fourth way a background job stalled, 2026-09-18.

        The whole flow ran for real for the first time on 2026-09-18 and got as
        far as this call and no further. The work lease's brief names the
        repositories and the title and no identifier at all, deliberately; this
        tool required an ``obligation_id``; so the model supplied the only thing
        it could, a guess. It invented ``obl-add-notes-line`` where the real
        obligation was ``qa-notes-line`` and was refused in 8 ms with "item is
        absent or outside the active scope". Nothing was prepared, no worker ran,
        and the fixture repository never gained its commit.

        Arm B is the one that matters, and it is deliberately not "a wrong id is
        refused": a wrong id must be IGNORED, because the scope already holds the
        right one. It reuses arm A's ``request_id``, so if the invented id had
        reached ``normalized`` at all the call would refuse with "already used
        for different work" instead of returning arm A's own record.

        Arms C and D are the controls. Without C the derivation could have been a
        blanket "obligation_id is optional now"; without D it could have been
        "any work scope prepares anything".
        """
        work, _ = self.work_lease()
        # A. The lease names nothing. The scope's own binding answers.
        first = self.app.call(work, "prepare", {key: value for key, value in self.args.items()
                                                if key != "obligation_id"})
        self.assertEqual(first["status"], "prepared")
        self.assertEqual(self.call("inspect")["records"][0]["request"]["obligation_id"], "fixture-task")

        # B. The lease names the WRONG one, which is exactly what happened. The
        #    scope wins and the invented id is nowhere in the receipt.
        again = self.app.call(work, "prepare", {**self.args, "obligation_id": "obl-add-notes-line"})
        self.assertEqual(again["id"], first["id"])
        self.assertEqual(again["request"]["obligation_id"], "fixture-task")
        self.assertNotIn("obl-add-notes-line", json.dumps(self.call("inspect")["records"]))

        # C. CONTROL -- a conversation scope carries no obligation in its binding
        #    (its turn_id is a TURN), so there the argument is still required and
        #    a wrong one is still refused by the ECS read.
        with self.assertRaisesRegex(ValueError, "obligation_id must be a nonempty bounded string"):
            self.call("prepare", {key: value for key, value in self.args.items()
                                  if key != "obligation_id"})
        with self.assertRaises(Exception):
            self.call("prepare", {**self.args, "request_id": "ceo-wrong",
                                  "obligation_id": "obl-add-notes-line"})

        # D. CONTROL -- deriving is not the same as trusting. A work scope bound
        #    to an obligation that does not exist is refused exactly as before,
        #    and nothing is prepared for it.
        absent, _ = self.work_lease(assignment="no-such-assignment")
        with self.assertRaises(Exception):
            self.app.call(absent, "prepare", {**self.args, "request_id": "absent-one"})
        self.assertEqual(len(self.call("inspect")["records"]), 1)

    def test_a_work_lease_completes_the_obligation_its_scope_carries(self):
        """The same derivation on the call that CLOSES the assignment.

        Fixing only ``prepare`` would have moved the defect one step later and
        made it harder to see: a job that did every piece of its work and then
        named the wrong obligation here leaves the obligation open, and the app's
        settle reading reports a failure over work that actually landed.

        The refusal asserted below is the completion gate doing its own job
        ("unresolved execution"), reached only because the obligation resolved --
        an invented id would have been refused earlier and for a different reason,
        which is what the second arm pins.
        """
        worker = self.call("prepare", self.args)
        work, _ = self.work_lease()
        with self.assertRaisesRegex(ValueError, "unresolved execution"):
            self.app.call(work, "complete", {"worker_ids": [worker["id"]]})
        # The same call naming a guess reaches the same gate: the scope wins and
        # the guess is never read.
        with self.assertRaisesRegex(ValueError, "unresolved execution"):
            self.app.call(work, "complete", {"obligation_id": "obl-add-notes-line",
                                             "worker_ids": [worker["id"]]})
        # CONTROL: on the conversation's scope the argument is still required.
        with self.assertRaisesRegex(ValueError, "obligation_id must be a nonempty bounded string"):
            self.call("complete", {"worker_ids": [worker["id"]]})

    def test_orphan_seats_are_reconciled_and_an_open_assignment_keeps_its_own(self):
        """6.3a. Settled, absent or unknown goes; open stays; his is never touched."""
        self.call("prepare",self.args)
        self.work_lease()                                   # an OPEN assignment
        self.work_lease(assignment="no-such-assignment")    # an ABSENT one
        self.three_ceo_turns()
        report=self.call("inspect")["seats"]
        self.assertEqual([row["assignment"] for row in report["retained"]],["fixture-task"])
        self.assertEqual([(row["assignment"],row["reason"]) for row in report["released"]],
                         [("no-such-assignment","absent")])
        self.assertEqual(report["unreconciled"],[])
        # His own cursor is still there, and it was never a candidate: a work seat is
        # identified by its own audience, never as "everything that is not his".
        seats=self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":"seats",
            "binding":self.scope["binding"]})["seats"]
        self.assertEqual(sorted(row["person_id"] for row in seats),
                         ["ceo-default","work-seat:fixture-task"])
        # Now settle the assignment the way a completion does, and its seat goes too.
        store=self.store()
        item=self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":"inspect",
            "binding":self.scope["binding"],"query":{"item_id":"fixture-task"}})["item"]
        store.append("continuity.item_closed",entity_id="depot",thread_id="thread-a",
            session_id=self.session,active_context_revision=self.scope["binding"]["revision"],
            actor_kind="authority_adapter",actor_id="richos-provider-v1",
            source_ref="app-completion:fixture",idempotency_key="fixture-close",
            expected_revision=int(item["revision"]),
            payload={"item_id":"fixture-task","status":"completed","evidence_ref":"app-completion:fixture"})
        report=self.call("inspect")["seats"]
        self.assertEqual([(row["assignment"],row["reason"]) for row in report["released"]],
                         [("fixture-task","settled")])
        self.assertEqual(report["retained"],[])

    def ceo_thread_seat(self,thread,turn="turn-1",revision=None):
        """His front desk for ANOTHER conversation thread, bound the way that
        thread's own front desk binds it: the derived seat, its own thread, the
        ceo audience."""
        seat="ceo-thread:"+thread
        self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":"bind","seat":seat,
            "scope":{"entity_id":"depot","thread_id":thread,"session_id":"session-"+thread,
                     "turn_id":turn,"audience":"ceo"},
            "request_id":f"bind-{seat}-{turn}","source_ref":f"ledger:{thread}:{turn}",
            "expected_revision":revision})
        return seat

    def ledger(self,*threads):
        """The app's own record of which conversation threads exist, at the path
        the app actually writes it to: `$RICHOS_APP_STATE/conversation-ledger.jsonl`
        (src-tauri/src/main.rs:1461, whose data_dir is the engine's state root)."""
        path=Path(os.environ["RICHOS_APP_STATE"])/"conversation-ledger.jsonl"
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text("".join(json.dumps({"event":"ThreadCreated","thread_id":t,
            "title":"a conversation","at":1}) +"\n" for t in threads)
            # A turn record between them, so the reader is walking a real ledger
            # and not a list of thread rows.
            + json.dumps({"event":"TurnStarted","turn_id":"t-1","thread_id":threads[0] if threads else "",
                          "at":2})+"\n")
        return path

    def test_his_orphan_thread_seat_is_reconciled_and_a_live_threads_never_is(self):
        """HIS SEAT IS ONE PER CONVERSATION THREAD, and until 2026-09-17 nothing
        would ever have reconciled one: `reconcile_seats` enumerated every seat
        and then skipped everything whose audience was not `worker`, so an
        orphan thread seat -- a seat for a thread the app's own record has never
        heard of -- would have lived forever.

        The question asked of one of his is NOT `assignment_state`: it has no
        assignment. It is whether that conversation thread still exists, which
        only the app knows (ecs/CONTRACT.md), so it is read from the app's own
        conversation ledger. Every case below is paired with the one fact
        changed:

          a live thread's seat   -> KEPT, and the ledger is the only difference
          a dead thread's seat   -> RELEASED, with the revision it was
                                    enumerated at, which is the store's own
                                    independent liveness proof
          ceo-default            -> refused by name, and still there afterwards
          the ledger unreadable  -> reported as unreconciled, never released:
                                    absence is not evidence
        """
        mine=self.ceo_thread_seat("thread-a")          # THIS conversation's own seat
        live=self.ceo_thread_seat("thread-live")
        dead=self.ceo_thread_seat("thread-dead")
        def seats():
            return sorted(row["person_id"] for row in self.app.ECS.execute(self.root/"ecs",
                {"protocol":1,"command":"seats","binding":self.scope["binding"]})["seats"])
        self.assertEqual(seats(),sorted(["ceo-default",mine,live,dead]))
        # THE UNDECIDABLE CASE FIRST, and it is the control for every release
        # below: with no ledger to read, NOTHING is released. The seat of the
        # conversation this is running IN is not even a candidate -- it is kept
        # on a fact that needs no file.
        report=self.call("inspect")["seats"]
        self.assertEqual(report["released"],[])
        self.assertEqual(sorted(row["seat"] for row in report["unreconciled"]),sorted([live,dead]))
        self.assertIn("could not be read",report["unreconciled"][0]["reason"])
        self.assertIn((mine,"this conversation"),
                      [(row["seat"],row.get("reason")) for row in report["retained"]])
        self.assertEqual(seats(),sorted(["ceo-default",mine,live,dead]))
        # NOW THE APP'S RECORD EXISTS AND NAMES ONE OF THE TWO. That single fact
        # decides them in opposite directions.
        self.ledger("thread-a","thread-live")
        report=self.call("inspect")["seats"]
        self.assertEqual([(row["seat"],row["reason"]) for row in report["released"]],
                         [(dead,"thread absent")])
        self.assertIn((live,"open"),[(row["seat"],row.get("reason")) for row in report["retained"]])
        self.assertEqual(report["unreconciled"],[])
        # HIS LEGACY CURSOR IS UNTOUCHED, and so are the live thread's seat and
        # this conversation's own.
        self.assertEqual(seats(),sorted(["ceo-default",mine,live]))
        # AND IT IS REFUSED BY NAME, not merely left alone by a filter: asked
        # directly, for his legacy cursor, the store says no.
        with self.assertRaisesRegex(Exception,"never reconciled away"):
            self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":"release-seat",
                "binding":self.scope["binding"],"person_id":"ceo-default","reason":"never",
                "request_id":"refuse-default","source_ref":"app-reconcile:refuse-default"})
        self.assertEqual(seats(),sorted(["ceo-default",mine,live]))

    def test_a_seat_that_cannot_be_released_is_reported_rather_than_ignored(self):
        self.work_lease(assignment="no-such-assignment")
        real=self.app.ecs
        def refuse(scope,request):
            if request["command"]=="release-seat": raise ValueError("the store is locked by another writer")
            return real(scope,request)
        with patch.object(self.app,"ecs",refuse):
            report=self.call("inspect")["seats"]
        self.assertEqual(report["released"],[])
        self.assertEqual([row["seat"] for row in report["unreconciled"]],
                         ["work-seat:no-such-assignment"])
        self.assertIn("locked by another writer",report["unreconciled"][0]["reason"])
        # The positive control: without the refusal the very same seat IS released,
        # so the report above is a real failure and not a permanently broken path.
        self.assertEqual([row["seat"] for row in self.call("inspect")["seats"]["released"]],
                         ["work-seat:no-such-assignment"])

    def test_a_work_lease_cannot_reconcile_seats_or_write_his_continuity(self):
        work,seat = self.work_lease()
        self.three_ceo_turns()
        self.assertNotIn("seats",self.app.call(work,"inspect",{}))
        binding=json.loads(work.read_text())["binding"]
        for command,fields in (("seats",{}),
                               ("release-seat",{"person_id":seat,"request_id":"r1",
                                                "source_ref":"reconcile:1"}),
                               ("brief",{}),
                               ("checkpoint",{"request_id":"c1","checkpoint":{"no_changes":True,
                                                                              "reason":"Test"}})):
            with self.assertRaisesRegex(Exception,"conversation's own seat"):
                self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":command,
                    "seat":seat,"binding":binding,**fields})
        # Control: every one of those four is fine on his own seat.
        for command,fields in (("seats",{}),("brief",{}),
                               ("checkpoint",{"request_id":"c1","checkpoint":{"no_changes":True,
                                                                              "reason":"Test"}})):
            self.app.ECS.execute(self.root/"ecs",{"protocol":1,"command":command,
                "binding":self.scope["binding"],**fields})

    # =======================================================================
    # THE LAND LOCK — ONE PER REPOSITORY, SHARED BY EVERY CONVERSATION
    # =======================================================================
    # BEFORE THIS EXISTED, reproduced by Frank from the engine's own identity
    # hash (docs/plans/two-riches-spec-2026-09-17-frank-check.md, item 3):
    #
    #   $ python3 -c 'import hashlib,json; f=lambda e,t: hashlib.sha256(
    #       json.dumps([e,t],separators=(",",":")).encode()).hexdigest();
    #       print(f("acme","thread-A")); print(f("acme","thread-B"))'
    #   b447822dc584e545fefdaf85c0415fcf229fc64b927a4b3aa2771726a8b5c344
    #   ad0ffd91066fe26a6aba8489bd6ef0ffe6233682f2316a473c9d940c4911924f
    #
    # Two threads, two lock files, both taken happily at the same moment, and
    # the `git merge --ff-only` under neither. These tests are the after-state.

    HOLDER_PROGRAM = (
        "import importlib.util,os,sys\n"
        "spec=importlib.util.spec_from_file_location('held_app',sys.argv[1])\n"
        "module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)\n"
        "scope={'binding':{'entity_id':os.environ.get('RICHOS_APP_ENTITY',''),"
        "'thread_id':sys.argv[3],'session_id':'holder-session'}}\n"
        "with module.land_lock(scope,sys.argv[2]):\n"
        "    sys.stdout.write('HELD\\n');sys.stdout.flush()\n"
        "    sys.stdin.readline()\n"
        "sys.stdout.write('RELEASED\\n');sys.stdout.flush()\n")

    PROBE_PROGRAM = (
        "import fcntl,os,sys\n"
        "fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600)\n"
        "try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)\n"
        "except OSError: sys.exit(3)\n"
        "sys.exit(0)\n")

    def land_lock_free(self,path):
        """Can the lock be taken RIGHT NOW, asked from another process?

        Another process rather than this one on purpose: the whole question is
        whether a second conversation's back end would be held off, and a second
        conversation is a second process."""
        probe=subprocess.run([sys.executable,"-c",self.PROBE_PROGRAM,str(path)])
        self.assertIn(probe.returncode,(0,3),"the lock probe itself failed")
        return probe.returncode==0

    def start_land_lock_holder(self,repo,thread):
        """Hold the repository's land lock from a SECOND conversation — a second
        process, a second thread id, a second workspace partition — through the
        shipped `land_lock`, not a hand-rolled flock."""
        env={**os.environ,"RICHOS_APP_THREAD":thread,
             "RICHOS_WORKSPACES_DIR":str(self.root/"engine-state/workspaces"
                 /hashlib.sha256(json.dumps(["depot",thread],separators=(",",":")).encode()).hexdigest())}
        holder=subprocess.Popen([sys.executable,"-c",self.HOLDER_PROGRAM,str(ENGINE/"mega-lander/app.py"),str(repo),thread],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True,env=env)
        self.addCleanup(self.release_land_lock_holder,holder)
        self.assertEqual(holder.stdout.readline().strip(),"HELD","the second conversation never took the lock")
        return holder

    def release_land_lock_holder(self,holder):
        if holder.poll() is not None: return
        try:
            holder.stdin.write("go\n");holder.stdin.flush()
        except (BrokenPipeError,ValueError):
            holder.kill()
        holder.wait(timeout=30)

    def reviewed_pair(self,tag,repo=None):
        """A worker and a passing reviewer, both run-ended: the exact state
        `integrate` is called from."""
        spec={**self.args,"request_id":"prepare-"+tag}
        if repo: spec["repo"]=str(repo)
        worker=self.call("prepare",spec)
        target=self.start_fixture_worker(worker,tag+"-worker")
        (target/"result.txt").write_text("FICTIONAL "+tag)
        self.app.git(target,"add","result.txt")
        self.app.git(target,"-c","user.name=Fixture","-c","user.email=fixture@example.invalid","commit","-qm","Fictional "+tag)
        commit=self.app.git(target,"rev-parse","HEAD")
        self.finish_fixture_worker(tag+"-worker")
        reviewer=self.call("prepare",{**spec,"request_id":"review-"+tag,"role":"reviewer","review_of":worker["id"],
            "title":"Review "+tag,"brief":"Review the exact result.txt change; do not modify any files."})
        self.start_fixture_worker(reviewer,tag+"-reviewer")
        self.finish_fixture_worker(tag+"-reviewer","RICHOS_REVIEW "+json.dumps(
            {"commit":commit,"verdict":"passed","checks":["synthetic reviewer observation"]}))
        return {"worker_id":worker["id"],"reviewer_id":reviewer["id"]}

    def test_two_conversations_landing_in_one_repository_take_one_lock_and_the_merge_is_under_it(self):
        args=self.reviewed_pair("onelock")
        lock=self.app.land_lock_path(self.repo)
        # ONE LOCK FOR TWO PARTITIONS. Frank's reproduction above is two
        # different paths for two threads; this is the same call from the second
        # thread's partition returning the FIRST one's file, byte for byte.
        other=self.root/"engine-state/workspaces"/hashlib.sha256(b'["depot","thread-b"]').hexdigest()
        with patch.dict(os.environ,{"RICHOS_APP_THREAD":"thread-b","RICHOS_WORKSPACES_DIR":str(other)}):
            self.assertEqual(self.app.land_lock_path(self.repo),lock)
        self.assertNotEqual(str(other),os.environ["RICHOS_WORKSPACES_DIR"])   # the partitions really do differ
        # POSITIVE CONTROL: the probe can say "free", and does, before the land.
        self.assertTrue(self.land_lock_free(lock))
        held=[]
        original=self.app.git
        def watch(repo,*argv):
            if argv[:2]==("merge","--ff-only"): held.append(not self.land_lock_free(lock))
            return original(repo,*argv)
        with patch.object(self.app,"git",side_effect=watch):
            result=self.call("integrate",args)
        self.assertTrue(result["work_integrated"])
        self.assertEqual(held,[True],"the fast-forward ran without this repository's land lock held")
        self.assertTrue(self.land_lock_free(lock),"the land lock outlived the land")
        self.assertLess(result["land_lock"]["waited_seconds"],1.0)
        self.assertNotIn("waited_for",result["land_lock"])

    def test_the_second_lander_waits_for_the_first_and_never_refuses_the_work(self):
        args=self.reviewed_pair("inorder")
        lock=self.app.land_lock_path(self.repo)
        holder=self.start_land_lock_holder(self.repo,"thread-b")
        self.assertFalse(self.land_lock_free(lock))      # POSITIVE CONTROL: it is genuinely held
        # The holder lands while it holds — through the shipped writer, not a
        # hand-made file, so what the waiter reads below is what a real land
        # leaves behind.
        self.app.W.append_land_record(self.repo,{"schema":1,"branch":"main","before":"a"*40,
            "commit":"b"*40,"at":"2026-09-17T19:00:00Z","thread_id":"thread-b","entity_id":"depot",
            "session_id":"holder-session","pid":holder.pid})
        original=self.app.W.git
        release=[]
        def release_once_waiting(repo,*argv,**kw):
            # `land_lock` asks git for the repository's identity immediately
            # before it blocks, so this fires once, at the start of the wait —
            # which is what makes the measured wait below deterministic rather
            # than a race with a timer. That question moved to workspaces.py
            # with the lock's keying rule on 2026-09-17, so this watches W.git.
            result=original(repo,*argv,**kw)
            if argv[:2]==("rev-parse","--path-format=absolute") and not release:
                timer=threading.Timer(0.5,self.release_land_lock_holder,[holder])
                release.append(timer);timer.start()
            return result
        with patch.object(self.app.W,"git",side_effect=release_once_waiting):
            landed=self.call("integrate",args)
        # IT WAITED AND THEN LANDED. It did not refuse, and a refusal here would
        # have sent finished, reviewed work back for a fresh implementation.
        self.assertTrue(landed["work_integrated"])
        self.assertGreater(landed["land_lock"]["waited_seconds"],0.05)
        self.assertIn("thread-b",landed["land_lock"]["waited_for"])
        # AND IT CAN SAY WHAT THE HOLDER DID, read from the append-only history
        # beside the lock rather than from a field on the lock that the next
        # holder rewrites in place.
        self.assertEqual(landed["land_lock"]["waited_for_land"]["thread_id"],"thread-b")
        self.assertEqual(landed["land_lock"]["waited_for_land"]["commit"],"b"*40)
        self.assertEqual(holder.stdout.readline().strip(),"RELEASED")

    def test_a_holder_past_the_bound_is_refused_by_name_with_nothing_merged(self):
        args=self.reviewed_pair("bound")
        before=self.app.git(self.repo,"rev-parse","HEAD")
        holder=self.start_land_lock_holder(self.repo,"thread-stuck")
        with patch.dict(os.environ,{"RICHOS_LAND_LOCK_TIMEOUT":"0.4"}):
            with self.assertRaises(ValueError) as caught: self.call("integrate",args)
        refusal=str(caught.exception)
        self.assertIn("thread-stuck",refusal)            # the holder is NAMED
        self.assertIn("did not finish within 0 seconds",refusal)
        self.assertIn("nothing here was merged",refusal)
        self.assertEqual(self.app.git(self.repo,"rev-parse","HEAD"),before)
        # POSITIVE CONTROL: released, the very same land goes straight through.
        self.release_land_lock_holder(holder)
        self.assertTrue(self.call("integrate",args)["work_integrated"])

    def test_one_repository_reached_two_ways_is_one_lock_and_two_repositories_are_two(self):
        link=self.root/"linked project";link.symlink_to(self.repo,target_is_directory=True)
        self.assertEqual(self.app.land_lock_path(link),self.app.land_lock_path(self.repo))
        # A LINKED WORKTREE SHARES THE REF STORE, so it shares the lock: two
        # paths that can move one branch must never hold two locks.
        checkout=self.root/"linked worktree"
        self.app.git(self.repo,"worktree","add","-q","-b","landlock-probe",str(checkout),"HEAD")
        self.assertEqual(self.app.land_lock_path(checkout),self.app.land_lock_path(self.repo))
        # TWO REPOSITORIES DO NOT WAIT ON EACH OTHER — the case the CEO says he
        # will actually run. A machine-wide lock would make them, for no reason.
        second=self.root/"second project";second.mkdir()
        subprocess.run(["git","init","--template=","-q","-b","main",str(second)],check=True)
        self.assertNotEqual(self.app.land_lock_path(second),self.app.land_lock_path(self.repo))
        self.start_land_lock_holder(self.repo,"thread-b")
        self.assertFalse(self.land_lock_free(self.app.land_lock_path(self.repo)))   # POSITIVE CONTROL
        self.assertTrue(self.land_lock_free(self.app.land_lock_path(second)))
        with self.app.land_lock(self.scope,str(second)) as land:
            self.assertLess(land["waited_seconds"],1.0)
            self.assertNotIn("waited_for",land)

    def test_the_land_lock_refuses_to_live_inside_either_conversation_partition(self):
        for name in ("RICHOS_WORKSPACES_DIR","RICHOS_APP_STATE"):
            with patch.dict(os.environ,{"RICHOS_LAND_LOCKS_DIR":str(Path(os.environ[name])/"land-locks")}):
                with self.assertRaisesRegex(ValueError,"per-conversation partition"):
                    self.app.land_lock_path(self.repo)
        # POSITIVE CONTROL: outside both, the same call answers.
        self.assertTrue(str(self.app.land_lock_path(self.repo)).endswith(".lock"))
        # AND THE DEFAULT IS THE MACHINE-WIDE HOME, which is neither partition:
        # CLAUDE_CONFIG_DIR, the one variable the app neither sets nor strips for
        # the engine it launches (engine_profile.rs:156-210).
        home=self.root/"machine home"
        with patch.dict(os.environ,{"CLAUDE_CONFIG_DIR":str(home)}):
            del os.environ["RICHOS_LAND_LOCKS_DIR"]
            # A string, not a Path: this derivation moved into workspaces.py on
            # 2026-09-17 (one keying rule, in the layer the protected-ref check
            # can reach), and that module is imported by a hook on every tool
            # call of every agent — it uses os.path throughout and imports no
            # pathlib.
            self.assertEqual(self.app.land_locks_dir(),os.path.join(os.path.realpath(home),"state","land-locks"))

    def test_the_land_record_is_appended_beside_the_lock_and_names_the_conversation(self):
        """THE SECOND HALF OF THE LAND LOCK: two threads' lands take turns, and
        the one that WAITED moved the branch under the other's running agents.
        This is the record that lets those agents be told WHICH conversation
        did it (mega-lander/workspaces.py, `land_by_another_conversation`),
        rather than only that the branch moved.

        APPEND-ONLY, AND THAT IS THE PROPERTY UNDER TEST. Until 2026-09-17 the
        land was written as a `landed` field on the lock file — which the next
        lander rewrites in place, so of two lands in a row only the second
        survived, and an agent whose snapshot predated the first saw a move
        nothing could name."""
        record=self.app.W.land_record_path(self.repo)
        self.assertFalse(os.path.exists(record))          # POSITIVE CONTROL: nothing has landed yet
        # BESIDE THE LOCK, AND KEYED THE SAME WAY: one repository, one history.
        self.assertEqual(record,self.app.land_lock_path(self.repo)[:-len(".lock")]+".lands")
        second=self.root/"second project";second.mkdir()
        subprocess.run(["git","init","--template=","-q","-b","main",str(second)],check=True)
        self.assertNotEqual(self.app.W.land_record_path(second),record)
        first_args=self.reviewed_pair("rec1")
        first=self.call("integrate",first_args)
        rows=self.app.W.land_records(self.repo)
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]["thread_id"],"thread-a")            # the conversation that landed
        self.assertEqual(rows[0]["entity_id"],"depot")
        self.assertEqual(rows[0]["branch"],"main")
        self.assertEqual(rows[0]["commit"],first["commit"])
        self.assertEqual(rows[0]["commit"],self.app.git(self.repo,"rev-parse","main"))
        # A REPEATED integrate merges nothing, so it records no land: the record
        # is written where the ref actually moves, not where the call ends.
        self.assertTrue(self.call("integrate",first_args)["work_integrated"])
        self.assertEqual(self.app.W.land_records(self.repo),rows)
        # A SECOND LAND APPENDS. The first row survives it byte for byte, and
        # the two chain: the second's `before` is the first's commit.
        second_result=self.call("integrate",self.reviewed_pair("rec2"))
        after=self.app.W.land_records(self.repo)
        self.assertEqual(len(after),2)
        self.assertEqual(after[0],rows[0])
        self.assertEqual(after[1]["before"],rows[0]["commit"])
        self.assertEqual(after[1]["commit"],second_result["commit"])
        # THE WRITER AND THE READER, END TO END, IN ONE PROCESS. Everything
        # above is the writing half. This is the function the PostToolUse check
        # actually calls (workspaces.py, `land_by_another_conversation`), asked
        # from ANOTHER conversation thread about the land this one just made: it
        # derives the record's path independently, reads the fields by the names
        # the writer wrote, and names the thread. A rename on either side breaks
        # here rather than in silence six weeks from now.
        with patch.dict(os.environ,{"RICHOS_APP_THREAD":"thread-b"}):
            told=self.app.W.land_by_another_conversation(
                str(self.repo),"main",after[1]["before"],after[1]["commit"])
        self.assertIn("thread-a",told)
        self.assertIn(after[1]["at"],told)
        # ... and silent for the conversation that made it.
        with patch.dict(os.environ,{"RICHOS_APP_THREAD":"thread-a"}):
            self.assertIsNone(self.app.W.land_by_another_conversation(
                str(self.repo),"main",after[1]["before"],after[1]["commit"]))
        # AND THE LOCK FILE ITSELF CARRIES NO LAND, which is what made the first
        # of two lands unanswerable.
        self.assertNotIn("landed",self.app._read_land_lock(self.app.land_lock_path(self.repo)) or {})



class _Result(unittest.TextTestResult):
    """Prints `  PASS  <test>` / `  FAIL  <test>` so the mutation harness
    (app.mutation.sh) can tell WHICH property went red, rather than only that
    something did. Same shape as workspaces.test.py's reporter."""

    def addSuccess(self,test):
        super().addSuccess(test);self.stream.write("  PASS  %s\n"%test._testMethodName)

    def addFailure(self,test,err):
        super().addFailure(test,err);self.stream.write("  FAIL  %s\n"%test._testMethodName)

    def addError(self,test,err):
        super().addError(test,err);self.stream.write("  FAIL  %s (error)\n"%test._testMethodName)


if __name__=="__main__":
    runner=unittest.TextTestRunner(stream=sys.stdout,verbosity=0,resultclass=_Result)
    loader=unittest.defaultTestLoader
    names=[a for a in sys.argv[1:] if a]
    suite=(loader.loadTestsFromNames(names,sys.modules[__name__]) if names
           else loader.loadTestsFromModule(sys.modules[__name__]))
    result=runner.run(suite)
    print("=== desktop dispatch tests: %d run, %d failed ==="%(
        result.testsRun,len(result.failures)+len(result.errors)))
    sys.exit(0 if result.wasSuccessful() else 1)
