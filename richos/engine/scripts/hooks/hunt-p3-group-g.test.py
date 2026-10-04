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
