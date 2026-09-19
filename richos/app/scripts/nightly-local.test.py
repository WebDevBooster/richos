#!/usr/bin/env python3
"""Local release entry point: explicit trigger, isolation and private credentials."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
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

    def test_one_declared_host_gap_reaches_the_runner_and_nothing_else(self):
        # The nightly build of candidate .10 failed on front-door.test.sh, a suite that
        # drives the shipped window and has no window on a build host. run-tests.sh
        # tolerates its "this host cannot answer" ONLY under a caller declaration naming
        # it WITH a reason. This asserts the declaration is on the runner's step and on
        # NOTHING else, and that it is ONE well-formed line -- run-tests.sh:117-133
        # refuses a bare name, and a second suite smuggled in here would be tolerated
        # without anyone reading it.
        base = {"PATH": "/usr/bin", "RICHOS_NAMED_PERSONS_FILE": "/fixture/list",
                "RUN_TESTS_DECLARED_GAPS": "smuggled.test.sh: from the operator's shell"}
        r = m.Runner(self.root, self.root / "state", dict(base), io.StringIO(), self.CREDENTIALS)
        seen = []

        def record(args, **kwargs):
            seen.append((args, kwargs["env"]))
            return subprocess.CompletedProcess(args, 0, "", "")

        with patch.object(m.subprocess, "run", side_effect=record), contextlib.redirect_stdout(io.StringIO()):
            r.gates()
        declared = [(args, env["RUN_TESTS_DECLARED_GAPS"]) for args, env in seen
                    if env.get("RUN_TESTS_DECLARED_GAPS") != base["RUN_TESTS_DECLARED_GAPS"]]
        self.assertEqual(len(declared), 1)
        args, value = declared[0]
        self.assertTrue(args[-1].endswith("run-tests.sh"), args)
        lines = [line for line in value.splitlines() if line.strip()]
        self.assertEqual(len(lines), 1, lines)
        suite, _, reason = lines[0].partition(":")
        self.assertEqual(suite, "front-door.test.sh")
        self.assertGreater(len(reason.strip()), 40, reason)
        # Every other gate keeps whatever the environment held: this value is stated about
        # one step, and the pop in local_environment() is what keeps a shell out of it.
        for other_args, env in seen:
            if other_args is not args:
                self.assertEqual(env["RUN_TESTS_DECLARED_GAPS"], base["RUN_TESTS_DECLARED_GAPS"])

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

    def test_preflight_asks_the_publisher_whether_branches_are_still_banned(self):
        """The check that used to REQUIRE a hole in the branch rule now forbids one.

        Until 2026-09-17 this preflight called
        `gh api repos/<repo>/rules/branches/nightly-channel` and refused to run if any
        `creation`/`update` rule applied -- "configure its narrow exception first". A
        publisher that demands an exemption is how `refs/heads/nightly-channel` came to
        be added to the `main-only` ruleset on 2026-09-16 and how the public repository
        page came to read "2 Branches" the next morning. The channel is a release tag
        now, so no exemption is wanted and the absence of one is the precondition.
        """
        r = self.identity_runner()
        r.command = Mock(return_value="true")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.suppress(Exception):
            r.preflight()
        commands = [call.args for call in r.command.call_args_list]
        checks = [c for c in commands if "check-rules" in c]
        self.assertEqual(len(checks), 1, commands)
        self.assertEqual(Path(checks[0][1]).name, "nightly.py")
        # The old shape must not come back under any spelling.
        for command in commands:
            joined = " ".join(str(part) for part in command)
            self.assertNotIn("rules/branches", joined)
            self.assertNotIn("nightly-channel", joined)

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

    CANDIDATE_INFO = {"tag": "v1.2.0-nightly.20260916.1", "version": "1.2.0-nightly.20260916.1",
                      "source_commit": "deadbeefcafe0123456789", "run_id": "fixture-run-id",
                      "run_attempt": "1"}

    def write_candidate(self, out):
        out.mkdir(parents=True, exist_ok=True)
        (out / "candidate.json").write_text(json.dumps({"info": self.CANDIDATE_INFO, "files": {}}))

    def test_build_stops_before_publishing_and_records_the_run(self):
        r = self.runner()
        r.env = {"RICHOS_NIGHTLY_RUN_ID": "fixture-run-id"}
        def fake_command(*args, **kwargs):
            self.assertEqual(args[2], "build")
            self.assertIs(kwargs.get("credentials"), True)
            out = Path(args[args.index("--out") + 1])
            self.write_candidate(out)
        r.command = Mock(side_effect=fake_command)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            r.perform("build")
        r.command.assert_called_once()  # only "build" -- never "run" or "finish"
        pointer = self.root / "state" / "runs" / "fixture-run-id.json"
        self.assertTrue(pointer.exists())
        recorded_out = Path(json.loads(pointer.read_text())["out"])
        self.assertTrue((recorded_out / "candidate.json").exists())
        self.assertIn("publish --run fixture-run-id", buf.getvalue())
        self.assertIn("RICHOS_ACTIVATION=regular", buf.getvalue())
        self.assertIn("the update channel has not moved", buf.getvalue())

    def test_publish_calls_finish_without_signing_credentials(self):
        r = self.runner()
        (self.root / "state" / "source").mkdir(parents=True)
        out = self.root / "state" / "releases" / self.CANDIDATE_INFO["tag"]
        self.write_candidate(out)
        r.record_run(self.CANDIDATE_INFO["run_id"], out)
        r.command = Mock()
        with contextlib.redirect_stdout(io.StringIO()):
            r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"])
        r.checkout.assert_not_called()
        r.plan.assert_not_called()
        args, kwargs = r.command.call_args
        self.assertEqual(args[2], "finish")
        self.assertEqual(Path(args[args.index("--out") + 1]), out)
        self.assertNotIn("credentials", kwargs)

    def test_candidate_prints_without_touching_anything(self):
        r = self.runner()
        out = self.root / "state" / "releases" / self.CANDIDATE_INFO["tag"]
        self.write_candidate(out)
        r.record_run(self.CANDIDATE_INFO["run_id"], out)
        r.command = Mock()
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            r.perform("candidate", run_id=self.CANDIDATE_INFO["run_id"])
        r.command.assert_not_called()
        r.checkout.assert_not_called()
        r.plan.assert_not_called()
        self.assertIn(str(out), buf.getvalue())
        self.assertIn("RICHOS_ACTIVATION=regular", buf.getvalue())
        self.assertIn(f"publish --run {self.CANDIDATE_INFO['run_id']}", buf.getvalue())

    def test_publish_and_candidate_require_a_recorded_run(self):
        r = self.runner()
        for command in ("publish", "candidate"):
            with self.subTest(command=command):
                with self.assertRaisesRegex(ValueError, "no recorded build"):
                    r.perform(command, run_id="never-built")
        r.command.assert_not_called()

    def test_publish_and_candidate_require_a_run_id(self):
        r = self.runner()
        for command in ("publish", "candidate"):
            with self.subTest(command=command):
                with self.assertRaisesRegex(ValueError, "valid --run"):
                    r.perform(command, run_id=None)

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

    # ---- where the time goes, and the one gate a land is allowed to have already run ----

    def gate_commands(self, checks_done_at_land=None):
        """Every gate subprocess a build would launch, as plain argv lists."""
        r = m.Runner(self.root, self.root / "state",
                     {"PATH": "/usr/bin", "RICHOS_NAMED_PERSONS_FILE": "/fixture/list"},
                     io.StringIO())
        seen = []

        def record(args, **kwargs):
            seen.append([str(a) for a in args])
            return subprocess.CompletedProcess(args, 0, "", "")

        with patch.object(m.subprocess, "run", side_effect=record), \
                contextlib.redirect_stdout(io.StringIO()):
            r.gates(checks_done_at_land)
        return r, seen

    def test_default_runs_every_gate_and_names_each_one_in_the_timings(self):
        r, seen = self.gate_commands()
        self.assertEqual(len(seen), 4)
        self.assertEqual(r.skipped, {})
        self.assertEqual([name for name, _, _ in r.timings],
                         ["gates/core-tests", "gates/updater-tests",
                          "gates/script-suites", "gates/privacy-sweep"])

    def test_the_land_proven_gate_is_the_only_one_the_flag_drops(self):
        """`--checks-done-at-land` may drop what a land ran and NOTHING else.

        The land runs `cargo test -p richos-core`, `cargo test --bin richos-tauri` and the
        sharded ui suite on the exact commit that becomes `main`. It does not run the
        updater crate, the fourteen script suites or the privacy sweep, so those stay on
        the candidate path no matter what the flag says. A flag that grew to cover them
        would be trading a gate for time nobody measured.
        """
        r, seen = self.gate_commands("a" * 40)
        self.assertEqual(len(seen), 3)
        joined = [" ".join(argv) for argv in seen]
        self.assertFalse([c for c in joined if "-p richos-core" in c], joined)
        self.assertTrue([c for c in joined if "richos-user-update" in c], joined)
        self.assertTrue([c for c in joined if c.endswith("run-tests.sh")], joined)
        self.assertTrue([c for c in joined if "named-persons.sh" in c], joined)
        self.assertIn(m.LAND_PROVEN_GATE, r.skipped)
        self.assertIn("a" * 40, r.skipped[m.LAND_PROVEN_GATE])

    def test_a_sha_that_is_not_this_runs_source_is_refused(self):
        """The whole safety of the flag is this comparison.

        A flag that took its argument on trust would let yesterday's land wave a different
        tree's tests through today's candidate, which is worse than not having the flag:
        the candidate would carry a provenance record saying a gate was covered when the
        gate covered something else.
        """
        r = m.Runner(self.root, self.root / "state", {}, io.StringIO())
        source = "4f2d57c9f9519409427b86c7502b9a7588216bf1"
        self.assertEqual(r.accept_land_proof(source, source), source)
        self.assertEqual(r.accept_land_proof("4f2d57c", source), source)
        for wrong in ("deadbeefcafe0123456789012345678901234567", "4f2d57d", "4f2d5",
                      "", None, "not-hex", "4F2D57C9"):
            with self.subTest(sha=wrong), self.assertRaises(ValueError):
                r.accept_land_proof(wrong, source)

    def test_a_taken_skip_is_written_into_the_candidates_provenance(self):
        """A skip recorded only in a log lives on this Mac. This one travels.

        nightly.py copies the plan verbatim into `build-info.json` and into the commit it
        builds, so putting the record in the plan is what makes a candidate unable to
        claim a gate it did not run.
        """
        r = self.runner()
        r.env = {"RICHOS_NIGHTLY_RUN_ID": "fixture-run-id"}
        plan_path = self.root / "plan.json"
        r.plan = Mock(return_value=(plan_path, {
            "build": True, "tag": "v1.2.0-nightly.20260916.1",
            "source_commit": "4f2d57c9f9519409427b86c7502b9a7588216bf1"}))
        r.checkout = Mock(return_value="4f2d57c9f9519409427b86c7502b9a7588216bf1")
        r.command = Mock(side_effect=lambda *a, **k: self.write_candidate(
            Path(a[a.index("--out") + 1])))
        with contextlib.redirect_stdout(io.StringIO()):
            r.perform("build", checks_done_at_land="4f2d57c9")
        recorded = json.loads(plan_path.read_text())
        self.assertEqual(recorded["checks_done_at_land"],
                         "4f2d57c9f9519409427b86c7502b9a7588216bf1")
        self.assertEqual(recorded["checks_skipped"], [m.LAND_PROVEN_GATE])
        r.gates.assert_called_once_with("4f2d57c9f9519409427b86c7502b9a7588216bf1")

    def test_a_wrong_sha_refuses_before_any_gate_runs(self):
        r = self.runner()
        r.checkout = Mock(return_value="4f2d57c9f9519409427b86c7502b9a7588216bf1")
        with contextlib.redirect_stdout(io.StringIO()), \
                self.assertRaisesRegex(ValueError, "not the source this run fetched"):
            r.perform("build", checks_done_at_land="deadbeef")
        r.gates.assert_not_called()
        r.preflight.assert_not_called()
        r.command.assert_not_called()

    def test_every_logged_line_carries_the_clock_and_a_child_needs_no_change(self):
        """The log is stamped by handing children a pipe, not by asking them to cooperate.

        nightly.py, make-release.sh and package-app.sh are read from the FETCHED tree, not
        from this checkout, so an instrument that needed their cooperation would not
        measure anything until it had been landed and fetched. This one measures the tree
        as it is.
        """
        path = self.root / "run.log"
        with m.TimestampedLog(path) as log:
            subprocess.run(["/bin/echo", "a child said this"], stdout=log, check=True)
            log.write("and this script said this\n")
        lines = path.read_text().splitlines()
        self.assertEqual(len(lines), 2, lines)
        for line, text in zip(lines, ("a child said this", "and this script said this")):
            self.assertRegex(line, r"^\[\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\] ")
            self.assertTrue(line.endswith(text), line)

    def test_milestones_match_in_order_and_only_while_the_build_step_is_open(self):
        """In order first; armed inside `build` as the second condition.

        Order is what does the work -- the first marker gates every later one. Arming is
        the belt: on the real log of run 20260919T180454Z-ac11d13e not one of the eleven
        patterns matches any of the 2,727 lines before the build step, so today it changes
        nothing. It is kept because `make-engine-asset.test.sh` and `make-release.test.sh`
        drive the very scripts these markers come from, and the day one of them echoes a
        real banner instead of a shim's, an unarmed matcher puts the engine boundary in
        the middle of the suites and reports a compile that took nine minutes.

        This test asserts both: the decoy ahead of the build step is ignored, and a marker
        arriving after the step closes is ignored too.
        """
        path = self.root / "run.log"
        decoy = "https://github.com/WebDevBooster/richos/releases/tag/v-from-a-test-fixture"
        with m.TimestampedLog(path, m.BUILD_MILESTONES) as log:
            log.write(decoy + "\n")
            log.arm(True)
            log.write("building the engine asset for v1.2.0-nightly.20260919.9\n")
            log.write("=== --check: building a second time, in a DIFFERENT environment\n")
            log.arm(False)
            log.write("=== every member accounted for, against git ===\n")
        self.assertEqual([name for name, _ in log.seen],
                         ["build/engine-asset", "build/engine-asset-recheck"])

    def test_an_unseen_milestone_is_reported_rather_than_folded_into_its_neighbor(self):
        """A boundary nobody saw must not silently inflate the segment beside it."""
        r = m.Runner(self.root, self.root / "state",
                     {"RICHOS_NIGHTLY_RUN_ID": "fixture-run-id"}, io.StringIO())
        start = time.time()
        r.timings = [("fetch", start, start + 3), ("build", start + 3, start + 63)]
        r.log.seen = [("build/engine-asset", start + 13)]
        rows = dict(r.segments())
        self.assertEqual(round(rows["fetch"]), 3)
        self.assertEqual(round(rows["build/tag-and-prepare"]), 10)
        self.assertEqual(round(rows["build/engine-asset"]), 50)
        self.assertIsNone(rows["build/app-compile"])
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            r.summary()
        self.assertIn("not observed", buf.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
