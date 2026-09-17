#!/usr/bin/env python3
"""Local release entry point: explicit trigger, isolation and private credentials."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location("local_nightly", Path(__file__).with_name("nightly-local.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class LocalTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def file(self, value, mode=0o600):
        path = self.root / "notary.env"
        path.write_text(value)
        path.chmod(mode)
        return path

    def test_notary_file_is_parsed_without_shell_execution(self):
        key = self.root / "private key.p8"
        key.write_text("fixture")
        key.chmod(0o600)
        path = self.file(f'export RICHOS_NOTARY_KEY="{key}"\nRICHOS_NOTARY_KEY_ID=id\nRICHOS_NOTARY_ISSUER=issuer\n')
        result = m.notary_environment(path)
        self.assertEqual(result["RICHOS_NOTARY_KEY"], str(key))
        self.assertEqual(result["RICHOS_NOTARY_ISSUER"], "issuer")

    def test_notary_profile_is_supported(self):
        self.assertEqual(m.notary_environment(self.file('RICHOS_NOTARY_PROFILE="nightly profile"\n')),
                         {"RICHOS_NOTARY_PROFILE": "nightly profile"})

    def test_unsafe_credentials_refuse(self):
        cases = ['RICHOS_NOTARY_PROFILE="$(touch /tmp/never-run)"',
                 'RICHOS_NOTARY_PROFILE="`id`"', 'OTHER=value',
                 'RICHOS_NOTARY_KEY_ID=partial', 'RICHOS_NOTARY_PROFILE=value; echo unsafe']
        for value in cases:
            with self.subTest(value=value), self.assertRaises(ValueError):
                m.notary_environment(self.file(value))
        with self.assertRaises(ValueError):
            m.notary_environment(self.file('RICHOS_NOTARY_PROFILE=value', 0o644))

    # The credential set as nightly-local.py would assemble it, with values that are
    # obviously fixtures. Names are what these tests assert on; values never leave here.
    CREDENTIALS = {"RICHOS_NOTARY_KEY": "/fixture/AuthKey_FIXTURE000.p8",
                   "RICHOS_NOTARY_KEY_ID": "FIXTURE000", "RICHOS_NOTARY_ISSUER": "fixture-issuer",
                   "RICHOS_NOTARY_PROFILE": "fixture-profile", "RICHOS_NOTARIZE": "1",
                   "RICHOS_SIGNING_IDENTITY": "Developer ID Application: Fixture (FIXTURE000)",
                   "TAURI_SIGNING_PRIVATE_KEY_PATH": "/fixture/richos-updater.key",
                   "TAURI_SIGNING_PRIVATE_KEY_PASSWORD": "fixture-password",
                   "APPLE_ID": "fixture@example.invalid", "APPLE_PASSWORD": "fixt-fixt-fixt-fixt",
                   "APPLE_TEAM_ID": "FIXTURETM1"}

    def test_exported_signing_variables_leave_the_gate_environment(self):
        # The operator's own shell is a source of these, not only notary.env, and the
        # gates must not inherit them from either.
        env = dict(self.CREDENTIALS, PATH="/usr/bin", RICHOS_NAMED_PERSONS_FILE="/fixture/list",
                   RICHOS_NIGHTLY_RUN_ID="20260917T000000Z-fixture", RICHOS_RUNTIME_DIR="/fixture/runtime")
        credentials = m.split_credentials(env)
        self.assertEqual(credentials, self.CREDENTIALS)
        self.assertEqual(sorted(env), ["PATH", "RICHOS_NAMED_PERSONS_FILE",
                                       "RICHOS_NIGHTLY_RUN_ID", "RICHOS_RUNTIME_DIR"])

    def test_gates_receive_no_signing_credential_and_still_get_the_privacy_list(self):
        # The 2026-09-16 nightly published nothing because package-app.test.sh's
        # "no credentials" cases ran with the operator's complete API key. This asserts
        # the environment of every gate subprocess, not the suite's verdict.
        base = {"PATH": "/usr/bin", "RICHOS_NAMED_PERSONS_FILE": "/fixture/list"}
        r = m.Runner(self.root, self.root / "state", dict(base), io.StringIO(), self.CREDENTIALS)
        seen = []

        def record(args, **kwargs):
            seen.append(kwargs["env"])
            return subprocess.CompletedProcess(args, 0, "", "")

        with patch.object(m.subprocess, "run", side_effect=record), contextlib.redirect_stdout(io.StringIO()):
            r.gates()
        self.assertEqual(len(seen), 4)
        for env in seen:
            self.assertEqual([name for name in env if m.is_credential(name)], [])
            self.assertEqual(env["RICHOS_NAMED_PERSONS_FILE"], "/fixture/list")
        # ...and the same runner still hands the whole set to a step that signs.
        with patch.object(m.subprocess, "run", side_effect=record):
            r.command("codesign", credentials=True)
        self.assertEqual({name: seen[-1][name] for name in self.CREDENTIALS}, self.CREDENTIALS)

    def test_an_exported_commit_identity_leaves_the_release_environment(self):
        # These override every level of git config, so a stray export in the operator's
        # shell would author the release as someone else while `git config user.email`
        # still reported the configured address.
        env = dict.fromkeys(m.IDENTITY_OVERRIDES, "someone-else@example.invalid")
        env.update(PATH="/usr/bin", RICHOS_NAMED_PERSONS_FILE="/fixture/list")
        removed = m.strip_identity_overrides(env)
        self.assertEqual(sorted(removed), sorted(m.IDENTITY_OVERRIDES))
        self.assertEqual(sorted(env), ["PATH", "RICHOS_NAMED_PERSONS_FILE"])
        for name in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
                     "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"):
            self.assertIn(name, m.IDENTITY_OVERRIDES)

    def identity_runner(self, configured=True):
        state = self.root / "state"
        source = state / "source"
        source.mkdir(parents=True)
        env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull,
               "GIT_CONFIG_SYSTEM": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        m.strip_identity_overrides(env)
        subprocess.run(["git", "init", "-q", str(source)], check=True, env=env)
        if configured:
            for name, value in (("user.name", "Fixture Operator"),
                                ("user.email", "fixture@example.invalid")):
                subprocess.run(["git", "config", name, value], cwd=source, check=True, env=env)
        return m.Runner(self.root, state, env, io.StringIO())

    def test_release_is_authored_with_the_checkouts_own_identity(self):
        self.assertEqual(self.identity_runner().identity(),
                         "Fixture Operator <fixture@example.invalid>")

    def test_unset_identity_is_refused_before_any_other_preflight_check(self):
        # The 2026-09-17 attempt found its wrong identity at the tag push, after every
        # gate had passed. This is the same class of defect found in milliseconds.
        r = self.identity_runner(configured=False)
        r.command = Mock()
        with self.assertRaisesRegex(ValueError, "no configured git identity"), \
                contextlib.redirect_stdout(io.StringIO()):
            r.preflight()
        r.command.assert_not_called()

    def test_lock_rejects_concurrent_manual_commands_and_releases_after_failure(self):
        state = self.root / "state"
        with self.assertRaises(RuntimeError):
            with m.exclusive(state):
                with self.assertRaisesRegex(ValueError, "another local"):
                    with m.exclusive(state):
                        self.fail("second publisher acquired lock")
                raise RuntimeError("failed build")
        with m.exclusive(state):
            pass

    def runner(self, build=True):
        r = m.Runner(self.root, self.root / "state", {}, io.StringIO())
        r.checkout = Mock(return_value="source-sha")
        r.plan = Mock(return_value=(self.root / "plan.json", {
            "build": build, "reason": "already published", "tag": "v1.2.0-nightly.20260916.1"}))
        for name in ("preflight", "runtime", "gates", "command"):
            setattr(r, name, Mock())
        return r

    def test_check_never_builds_or_publishes(self):
        r = self.runner()
        r.perform("check")
        r.preflight.assert_called_once()
        r.gates.assert_not_called()
        r.runtime.assert_not_called()
        r.command.assert_not_called()

    def test_command_timeout_does_not_expose_signing_password(self):
        r = m.Runner(self.root, self.root, {}, io.StringIO())
        args = ["cargo", "tauri", "signer", "sign", "-p", "secret-password"]
        with patch.object(m.subprocess, "run", side_effect=subprocess.TimeoutExpired(args, 30)):
            with self.assertRaisesRegex(RuntimeError, "cargo timed out") as raised:
                r.command(*args, timeout=30)
        self.assertNotIn("secret-password", str(raised.exception))

    def test_only_release_reaches_publisher(self):
        r = self.runner()
        r.perform("release")
        r.runtime.assert_called_once()
        r.gates.assert_called_once()
        args = r.command.call_args.args
        self.assertEqual(args[2], "run")
        # The publisher is the step that signs, notarizes and signs the updater manifest.
        self.assertIs(r.command.call_args.kwargs["credentials"], True)
        self.assertEqual(r.plan.call_count, 2)

    def test_unchanged_source_does_not_build(self):
        r = self.runner(False)
        r.perform("release")
        r.gates.assert_not_called()
        r.command.assert_not_called()

    def test_failed_gates_do_not_publish(self):
        for method in ("preflight", "runtime", "gates"):
            with self.subTest(method=method):
                r = self.runner()
                getattr(r, method).side_effect = RuntimeError("failed")
                with self.assertRaises(RuntimeError):
                    r.perform("release")
                r.command.assert_not_called()

    def test_fresh_plan_can_skip_after_checks(self):
        r = self.runner()
        r.plan.side_effect = [r.plan.return_value,
                             (self.root / "plan.json", {"build": False, "reason": "already published"})]
        r.perform("release")
        r.command.assert_not_called()

    def test_checkout_uses_remote_main_without_touching_developer_edits(self):
        repo, remote = self.root / "repo", self.root / "remote.git"
        repo.mkdir()
        def git(*args, cwd=repo):
            return subprocess.check_output(["git", *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL).strip()
        git("init", "--bare", str(remote))
        git("init", "-b", "main")
        git("config", "user.name", "Fixture")
        git("config", "user.email", "fixture@example.invalid")
        git("config", "core.hooksPath", "/dev/null")
        (repo / "source").write_text("committed")
        git("add", ".")
        git("commit", "-m", "source")
        sha = git("rev-parse", "HEAD")
        git("remote", "add", "origin", str(remote))
        git("push", "origin", "main")
        (repo / "source").write_text("uncommitted developer work")
        state = self.root / "state"
        state.mkdir()
        with (self.root / "commands.log").open("w") as log:
            r = m.Runner(repo, state, os.environ.copy(), log)
            self.assertEqual(r.checkout(), sha)
            self.assertEqual((r.source / "source").read_text(), "committed")
            self.assertEqual((repo / "source").read_text(), "uncommitted developer work")
            self.assertEqual(r.checkout(), sha)
            (r.source / "unexpected").write_text("do not delete")
            with self.assertRaisesRegex(ValueError, "has changes"):
                r.checkout()
            self.assertTrue((r.source / "unexpected").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
