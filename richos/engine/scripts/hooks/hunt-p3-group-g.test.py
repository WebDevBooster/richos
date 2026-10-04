"""Hunt part 3 severity-3 findings 19, 20, 21, 26, 28, 35: one test each.

Run: python3 hooks/hunt-p3-group-g.test.py   (synthetic inputs only)
"""
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
HOOKS = SCRIPTS / "hooks"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def write_rows(path, rows):
    with open(path, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")


class GroupG(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="hunt-p3-g.")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    # --- P3-19 -----------------------------------------------------------
    def test_p3_19_refused_agent_call_is_not_started_work(self):
        idle = load("idle_land", HOOKS / "guard-idle-land.py")
        t = os.path.join(self.tmp, "t.jsonl")
        write_rows(t, [
            {"type": "user", "promptId": "p1", "message": {"content": "go"}},
            {"type": "assistant", "promptId": "p1", "message": {"content": [
                {"type": "tool_use", "id": "a1", "name": "Agent", "input": {}}]}},
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "a1", "is_error": True,
                 "content": "refused by a guard"}]}},
        ])
        turn = idle.read_turn(t, "p1")
        self.assertEqual(idle.started_work(turn), "")

    # --- P3-20 and P3-21 -------------------------------------------------
    def test_p3_20_blob_sha_is_not_a_commit(self):
        claims = load("claims", HOOKS / "guard-unresolved-claims.py")
        repo = os.path.join(self.tmp, "repo")
        os.makedirs(repo)
        git = lambda *a: subprocess.run(["git", "-C", repo, *a], check=True,
                                        capture_output=True, text=True).stdout.strip()
        git("init", "-q")
        Path(repo, "f.txt").write_text("hello\n")
        git("add", "f.txt")
        git("-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
            "-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "c")
        commit = git("rev-parse", "HEAD")
        blob = git("rev-parse", "HEAD:f.txt")
        found = claims.resolve_shas([commit, blob], [repo])
        self.assertEqual(found, {commit})
        # v3 re-check: an annotated tag wrapping that blob is not a commit
        # either; an annotated tag of the commit still is.
        git("-c", "user.name=t", "-c", "user.email=t@t", "tag", "-a", "blob-tag",
            "-m", "a tag pointing to a blob", blob)
        git("-c", "user.name=t", "-c", "user.email=t@t", "tag", "-a", "commit-tag",
            "-m", "a tag pointing to the commit", commit)
        blob_tag = git("rev-parse", "blob-tag")
        commit_tag = git("rev-parse", "commit-tag")
        found = claims.resolve_shas([blob_tag, commit_tag], [repo])
        self.assertEqual(found, {commit_tag})

    def test_p3_21_other_sessions_roles_do_not_count_here(self):
        claims = load("claims2", HOOKS / "guard-unresolved-claims.py")
        teams = os.path.join(self.tmp, "teams")
        for sess, name in (("aaaaaaaa", "zach-x"), ("bbbbbbbb", "mark-y")):
            os.makedirs(os.path.join(teams, "session-" + sess))
            Path(teams, "session-" + sess, "spawned-names.log").write_text(name + "\n")
        self.assertEqual(claims.name_history(teams, "aaaaaaaa-1111"), {"zach-x"})
        self.assertEqual(claims.name_history(teams), {"zach-x", "mark-y"})

    # --- P3-26 -----------------------------------------------------------
    def test_p3_26_absent_prompt_is_an_error_not_an_empty_turn(self):
        manifest = load("manifest", HOOKS / "turn-manifest.py")
        t = os.path.join(self.tmp, "t.jsonl")
        write_rows(t, [{"type": "user", "promptId": "other",
                        "message": {"content": "hi"}}])
        calls, results, examined, err = manifest.read_turn(t, "wanted")
        self.assertTrue(err)

    # --- P3-28 -----------------------------------------------------------
    def test_p3_28_crashed_interactive_analyzer_is_not_clean(self):
        copy = os.path.join(self.tmp, "engine")
        os.makedirs(os.path.join(copy, "scripts", "hooks"))
        os.makedirs(os.path.join(copy, "scripts", "lib"))
        shutil.copy(HOOKS / "guard-interactive-prompt.sh",
                    os.path.join(copy, "scripts", "hooks"))
        for f in ("resolve-roots.sh", "resolve-main-checkout.sh",
                  "unevaluated-notice.sh"):
            if (SCRIPTS / "lib" / f).exists():
                shutil.copy(SCRIPTS / "lib" / f, os.path.join(copy, "scripts", "lib"))
        cfg = SCRIPTS.parent / "orchestration.config"
        if cfg.exists():
            shutil.copy(cfg, copy)
        Path(copy, "scripts", "lib", "interactive-prompt.py").write_text(
            "import sys\nsys.exit(1)\n")
        payload = json.dumps({"tool_name": "Bash", "cwd": copy,
                              "tool_input": {"command": "ls"}})
        env = dict(os.environ, RICHOS_ENTITY_ROOT=copy)
        env.pop("CLAUDE_PROJECT_DIR", None)
        p = subprocess.run(
            ["bash", os.path.join(copy, "scripts", "hooks", "guard-interactive-prompt.sh")],
            input=payload, capture_output=True, text=True, env=env)
        self.assertEqual(p.returncode, 2, p.stderr[-300:])
        self.assertIn("no verdict", p.stderr)

    def test_p3_28_v3_crashed_checkers_say_they_did_not_run(self):
        # v3 re-check: five more checkers whose crash passed for a clean check.
        # Each runs as its complete wrapper in a disposable engine copy, with
        # only the named checker made to fail; each must say it did not run.
        copy = os.path.join(self.tmp, "engine")
        shutil.copytree(SCRIPTS / "lib", os.path.join(copy, "scripts", "lib"))
        os.makedirs(os.path.join(copy, "scripts", "hooks"))
        for f in ("guard-unresolved-claims.sh", "notice-inflight-acks.sh",
                  "notice-unanswered-question.sh", "notice-ceo-inputs-unheld.sh",
                  "commit-ceo-inputs.py", "guard-ceo-ruled-ask.sh"):
            shutil.copy(HOOKS / f, os.path.join(copy, "scripts", "hooks", f))
        cfg = SCRIPTS.parent / "orchestration.config"
        if cfg.exists():
            shutil.copy(cfg, copy)
        repo = os.path.join(self.tmp, "repo")
        os.makedirs(os.path.join(repo, ".claude", "state"))
        subprocess.run(["git", "init", "-q", repo], check=True)
        Path(repo, "orchestration.config").write_text('PROTECTED_PATHS="src"\n')
        hooks = os.path.join(copy, "scripts", "hooks")
        lib = os.path.join(copy, "scripts", "lib")
        env = dict(os.environ, RICHOS_ENTITY_ROOT=repo,
                   STOP_NOTICE_STATE_DIR=os.path.join(self.tmp, "notices"))
        env.pop("CLAUDE_PROJECT_DIR", None)
        stop = json.dumps({"session_id": "crash-fixture", "cwd": repo, "hook_event_name": "Stop",
                           "prompt_id": "p", "last_assistant_message": "Inspection complete.",
                           "transcript_path": os.path.join(self.tmp, "unused.jsonl")})

        def run(hook, payload):
            return subprocess.run(["bash", os.path.join(hooks, hook)], input=payload,
                                  capture_output=True, text=True, env=env, timeout=120)

        crash = "import sys\nsys.exit(1)\n"
        Path(hooks, "guard-unresolved-claims.py").write_text(crash)
        out = run("guard-unresolved-claims.sh", stop)
        with self.subTest('claims'):
            self.assertEqual(out.returncode, 0, out.stderr[-300:])
            self.assertIn("DID NOT RUN", out.stdout, "claims")

        Path(lib, "inflight.py").write_text(
            "def assess(*a, **k):\n    raise RuntimeError('fixture assess crash')\n")
        Path(lib, "inflight.sh").write_text(
            'inflight_require(){ return 0; }; '
            'inflight_resolve_teams_dir(){ INFLIGHT_TEAMS_DIR_RESOLVED=""; }; '
            'inflight_timeout_min(){ echo 30; }\n')
        out = run("notice-inflight-acks.sh", stop)
        with self.subTest('inflight'):
            self.assertEqual(out.returncode, 0, out.stderr[-300:])
            self.assertIn("NOT CHECKED", out.stdout, "inflight")

        # A ledger row that is not an object makes the real reader raise.
        Path(repo, ".claude", "state", "ceo-inputs.jsonl").write_text("[]\n")
        out = run("notice-ceo-inputs-unheld.sh", stop)
        with self.subTest('unheld inputs'):
            self.assertEqual(out.returncode, 0, out.stderr[-300:])
            self.assertIn("DID NOT RUN", out.stdout, "unheld inputs")

        Path(lib, "blocking_ask.py").write_text(crash)
        out = run("notice-unanswered-question.sh", stop)
        with self.subTest('unanswered question'):
            self.assertEqual(out.returncode, 0, out.stderr[-300:])
            self.assertIn("DID NOT RUN", out.stdout, "unanswered question")

        ask = json.dumps({"session_id": "crash-fixture", "cwd": repo, "tool_name": "AskUserQuestion",
                          "hook_event_name": "PreToolUse",
                          "tool_input": {"questions": [{"question": "Which fixture first?"}]}})
        out = run("guard-ceo-ruled-ask.sh", ask)
        with self.subTest('deaf lead'):
            self.assertIn("DEAF-LEAD CHECK DID NOT RUN", out.stdout + out.stderr, "deaf lead")

    # --- P3-35 -----------------------------------------------------------
    def test_p3_35_quoted_example_is_not_an_unanswered_question(self):
        ask = load("blocking_ask", SCRIPTS / "lib" / "blocking_ask.py")

        def run(text):
            t = os.path.join(self.tmp, "q.jsonl")
            write_rows(t, [
                {"type": "user", "turnOrigin": "human"},
                {"type": "assistant", "message": {"content": [
                    {"type": "text", "text": text}]}},
                {"type": "user", "turnOrigin": "task_notification"},
            ])
            return ask.unanswered_question(t)

        self.assertIsNotNone(run("Done.\n\nQUESTION FOR YOU:\nWhich first?"))
        fenced = "Example only, no answer needed:\n```\nQUESTION FOR YOU:\nWhich first?\n```\n"
        self.assertIsNone(run(fenced))
        self.assertIsNone(run("> QUESTION FOR YOU:\n> Which first?"))

    def test_p3_40_longer_closing_fence_keeps_the_real_question(self):
        # A fence opened with ``` and closed with ```` is valid Markdown; the
        # real question AFTER it is still a question (v3 re-check, finding 40).
        ask = load("blocking_ask40", SCRIPTS / "lib" / "blocking_ask.py")
        for closer in ("```", "````"):
            t = os.path.join(self.tmp, "f.jsonl")
            write_rows(t, [
                {"type": "user", "turnOrigin": "human"},
                {"type": "assistant", "message": {"content": [{"type": "text", "text":
                    "Example:\n```text\nUnrelated example.\n" + closer +
                    "\n\nQUESTION FOR YOU:\nWhich fixture should run next?\n"}]}},
                {"type": "user", "turnOrigin": "task_notification"},
            ])
            self.assertIsNotNone(ask.unanswered_question(t), closer)
        # A SHORTER closer does not close it: the fenced text stays an example.
        t = os.path.join(self.tmp, "g.jsonl")
        write_rows(t, [
            {"type": "user", "turnOrigin": "human"},
            {"type": "assistant", "message": {"content": [{"type": "text", "text":
                "Example:\n````text\n```\nQUESTION FOR YOU:\nWhich first?\n"}]}},
            {"type": "user", "turnOrigin": "task_notification"},
        ])
        self.assertIsNone(ask.unanswered_question(t))


if __name__ == "__main__":
    unittest.main()
