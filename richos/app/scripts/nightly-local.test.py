#!/usr/bin/env python3
"""Local release entry point: explicit trigger, isolation and private credentials."""
import contextlib
import importlib.util
import io
import json
import os
import shlex
import signal
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
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

        with patch.object(m, "owned_run", side_effect=record), contextlib.redirect_stdout(io.StringIO()):
            r.gates()
        self.assertEqual(len(seen), 9)
        for env in seen:
            self.assertEqual([name for name in env if m.is_credential(name)], [])
            self.assertEqual(env["RICHOS_NAMED_PERSONS_FILE"], "/fixture/list")
        # ...and the same runner still hands the whole set to a step that signs.
        with patch.object(m, "owned_run", side_effect=record):
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

        with patch.object(m, "owned_run", side_effect=record), contextlib.redirect_stdout(io.StringIO()):
            r.gates()
        declared = [(args, env["RUN_TESTS_DECLARED_GAPS"]) for args, env in seen
                    if env.get("RUN_TESTS_DECLARED_GAPS") != base["RUN_TESTS_DECLARED_GAPS"]]
        self.assertEqual(len(declared), 1)
        args, value = declared[0]
        # The declaration reaches the SUITE RUNNER and nothing else. Matched anywhere in
        # argv rather than at its end: the runner grew `--results-out` (and may grow
        # `--no-host-screen`), and an assertion about an argument's POSITION would fail on
        # a change that has nothing to do with what this case is about.
        self.assertTrue([a for a in args if str(a).endswith("run-tests.sh")], args)
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

    def test_a_variable_nobody_thought_about_reaches_no_gate(self):
        """The allowlist's whole claim, tested the only way that proves it: by surprise.

        Every other case here names a variable somebody already knew was dangerous, so
        every one of them would still pass against the deny-list this replaced -- which
        is exactly how the deny-list looked right on 2026-09-18 and broke the build on
        2026-09-19. The variable planted below is deliberately one NO list anywhere in
        this repository mentions. A deny-list passes it through; an allowlist cannot,
        and it cannot for a reason that does not depend on anyone having foreseen it.
        """
        stray = "RICHOS_TEST_STRAY_" + uuid.uuid4().hex
        with patch.dict(os.environ, {stray: "from the operator's shell", "HOME": os.environ["HOME"]}):
            env, credentials = m.local_environment()
        self.assertNotIn(stray, env)
        self.assertNotIn(stray, credentials)
        # Not vacuous: the planting worked, and an allowlisted name from the SAME
        # os.environ did come through. Without this the case would pass just as well
        # against a local_environment() that returned an empty dict.
        self.assertIn("HOME", env)
        # And the property in general, not one specimen of it: nothing in the returned
        # environment came from the shell except by being named in the allowlist.
        #
        # BOTH SIDES SUBTRACT GATE_SET_BY_BUILD, and the first version of this case
        # subtracted it from only the left -- which passed in a terminal and failed inside
        # a build, the exact shape of defect this file's allowlist exists to end. The
        # cause is that RICHOS_NAMED_PERSONS_FILE is in BOTH tuples: the operator may set
        # it, and the build sets it regardless. So in a terminal it is absent from
        # os.environ and the asymmetry is invisible; inside a gate it is present and the
        # two sides disagree about a name that never came from a shell at all. A name
        # this script sets is not evidence about what the shell got through, whichever
        # tuple also lists it.
        from_shell = sorted(set(env) - set(m.GATE_SET_BY_BUILD))
        self.assertEqual(from_shell,
                         sorted(n for n in m.GATE_PASSTHROUGH
                                if n in os.environ and n not in m.GATE_SET_BY_BUILD))

    def test_the_allowlist_is_the_only_door_and_e1_derives_its_list_from_it(self):
        """`gate-environment` is what run-tests.test.sh case E1 reads instead of copying.

        E1 re-runs the whole script suite under the environment a build hands it. Its
        list used to be hand-written, so it went stale in silence the next time anyone
        added a variable. This asserts the printed contract is complete and well-formed:
        if a name is added to either tuple and this is the only copy, E1 picks it up for
        free; if the printing ever stops covering a tuple, this fails rather than E1
        quietly testing less than it claims to.
        """
        printed = subprocess.run(
            [sys.executable, str(Path(__file__).with_name("nightly-local.py")), "gate-environment"],
            capture_output=True, text=True, check=True).stdout
        rows = [line.split("\t") for line in printed.splitlines() if line]
        self.assertTrue(all(len(row) == 2 for row in rows), rows)
        by_kind = {}
        for kind, name in rows:
            by_kind.setdefault(kind, []).append(name)
        self.assertEqual(by_kind.get("passthrough"), list(m.GATE_PASSTHROUGH))
        self.assertEqual(by_kind.get("set"), list(m.GATE_SET_BY_BUILD))
        self.assertEqual(by_kind.get("per-step"), list(m.GATE_SET_PER_STEP))
        # No credential name may ever be printed here: E1 exports every name this prints.
        self.assertEqual([name for _, name in rows if m.is_credential(name)], [])

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
        with patch.object(m, "owned_run", side_effect=subprocess.TimeoutExpired(args, 30)):
            with self.assertRaisesRegex(RuntimeError, "cargo timed out") as raised:
                r.command(*args, timeout=30)
        self.assertNotIn("secret-password", str(raised.exception))

    def test_capture_cannot_wait_forever_on_a_descendants_inherited_pipe(self):
        # The leader exits, but its child keeps the stdout pipe open. A timeout
        # must stop that child too, otherwise communicate() cannot finish.
        # Normal-exit cleanup now closes it before a timeout is necessary.
        script = self.root / "pipe.py"
        script.write_text("""import subprocess, sys
from pathlib import Path
p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
Path(sys.argv[1]).write_text(str(p.pid))
""")
        pid_file = self.root / "pipe-child"
        with (self.root / "pipe.log").open("w") as log:
            r = m.Runner(self.root, self.root, dict(os.environ), log)
            start = time.monotonic()
            r.command(sys.executable, script, pid_file, cwd=self.root,
                      capture=True, timeout=5)
            self.assertLess(time.monotonic() - start, 5)
        self.assert_pid_gone(int(pid_file.read_text()))

    def test_every_gate_has_a_named_deadline(self):
        for phase, budget in m.GATE_BUDGETS.items():
            with self.subTest(phase=phase):
                r = m.Runner(self.root, self.root, {}, io.StringIO())
                r.restore_source_tree = Mock()
                def run(args, **kwargs):
                    if r.active_phase == phase:
                        self.assertEqual(kwargs["timeout"], budget)
                        raise subprocess.TimeoutExpired(args, budget)
                    return subprocess.CompletedProcess(args, 0, "", "")
                with patch.object(m, "owned_run", side_effect=run), \
                        contextlib.redirect_stdout(io.StringIO()), \
                        self.assertRaisesRegex(RuntimeError, f"{phase} timed out after {budget}s"):
                    r.gates()

    def assert_executed_gate_deadlines(self, checks_done_at_land=None):
        """Discover phases by executing gates(), independently of the budget table."""
        r = m.Runner(self.root, self.root, {}, io.StringIO())
        r.restore_source_tree = Mock()
        original_phase = r.phase
        phases, commands = set(), set()

        @contextlib.contextmanager
        def registered_phase(name):
            if name.startswith("gates/"):
                self.assertIn(name, m.GATE_BUDGETS, f"{name} has no registered deadline")
                phases.add(name)
            with original_phase(name):
                yield

        def run(args, **kwargs):
            name = r.active_phase
            if name and name.startswith("gates/"):
                self.assertEqual(kwargs.get("timeout"), m.GATE_BUDGETS[name],
                                 f"{name} did not pass its registered deadline")
                commands.add(name)
            return subprocess.CompletedProcess(args, 0, "", "")

        r.phase = registered_phase
        with patch.object(m, "owned_run", side_effect=run), \
                contextlib.redirect_stdout(io.StringIO()):
            r.gates(checks_done_at_land)
        self.assertTrue(phases)
        self.assertEqual(commands, phases)

    def test_executed_gates_have_registered_and_wired_deadlines(self):
        self.assert_executed_gate_deadlines()
        self.assert_executed_gate_deadlines("land-proof-fixture")

    def test_gate_coverage_detects_a_missing_budget_entry(self):
        budgets = dict(m.GATE_BUDGETS)
        del budgets["gates/lint-tauri"]
        with patch.object(m, "GATE_BUDGETS", budgets), \
                self.assertRaisesRegex(AssertionError, "gates/lint-tauri has no registered deadline"):
            self.assert_executed_gate_deadlines()

    def test_gate_coverage_detects_an_unwired_timeout(self):
        command = m.Runner.command

        def without_lint_timeout(runner, *args, **kwargs):
            if runner.active_phase == "gates/lint-tauri":
                kwargs.pop("timeout", None)
            return command(runner, *args, **kwargs)

        with patch.object(m.Runner, "command", without_lint_timeout), \
                self.assertRaisesRegex(AssertionError, "gates/lint-tauri did not pass its registered deadline"):
            self.assert_executed_gate_deadlines()

    def test_cleanup_commands_have_deadlines(self):
        r = m.Runner(self.root, self.root, {}, io.StringIO())
        r.command = Mock(side_effect=[" M fixture", None])
        with contextlib.redirect_stdout(io.StringIO()):
            r.restore_source_tree("fixture")
        self.assertEqual(len(r.command.call_args_list), 2)
        for call in r.command.call_args_list:
            self.assertEqual(call.kwargs["timeout"], m.CLEANUP_TIMEOUT)

    def test_ui_does_not_restore_files_when_group_cleanup_failed(self):
        r = m.Runner(self.root, self.root, {}, io.StringIO())
        r.command = Mock(side_effect=m.CommandCleanupError("owned group still running"))
        r.restore_source_tree = Mock()
        with contextlib.redirect_stdout(io.StringIO()), \
                self.assertRaisesRegex(RuntimeError, "owned group still running"):
            r.ui_suite()
        r.restore_source_tree.assert_not_called()

    def process_fixture(self):
        script = self.root / "tree.py"
        script.write_text("""import os, signal, subprocess, sys, time
from pathlib import Path
root = Path(sys.argv[1])
level = int(sys.argv[2])
signal.signal(signal.SIGTERM, signal.SIG_IGN)
(root / ('pid' + str(level))).write_text(str(os.getpid()))
if level < 2:
    subprocess.Popen([sys.executable, __file__, str(root), str(level + 1)])
while True: time.sleep(.02)
""")
        return [sys.executable, str(script), str(self.root), "0"]

    def assert_pid_gone(self, pid):
        until = time.monotonic() + 3
        while time.monotonic() < until:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(.02)
        self.fail(f"owned process {pid} survived cleanup")

    def test_parent_only_kill_leaves_descendants_but_group_cleanup_does_not(self):
        p = subprocess.Popen(self.process_fixture(), start_new_session=True)
        try:
            until = time.monotonic() + 5
            while not (self.root / "pid2").exists() and time.monotonic() < until:
                time.sleep(.02)
            ids = [int((self.root / f"pid{i}").read_text()) for i in range(3)]
            p.kill()
            p.wait(timeout=3)
            for pid in ids[1:]:
                os.kill(pid, 0)  # Positive evidence: parent-only kill left both alive.
            m.finish_group(p)
            for pid in ids:
                self.assert_pid_gone(pid)
        finally:
            m.finish_group(p)

    def test_real_timeout_escalates_and_preserves_unrelated_process(self):
        sentinel = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                    start_new_session=True)
        try:
            with (self.root / "log").open("w") as log:
                r = m.Runner(self.root, self.root, dict(os.environ), log)
                start = time.monotonic()
                with self.assertRaisesRegex(RuntimeError, "timed out after 1s"):
                    r.command(*self.process_fixture(), cwd=self.root, timeout=1)
                # The supervisor gives EXIT traps eight seconds to clean up.
                # Bound this by the caller's complete cleanup allowance rather
                # than the former, shorter grace period.
                self.assertLess(time.monotonic() - start,
                                1 + m.TERM_GRACE + 2 * m.KILL_GRACE + 2)
            for i in range(3):
                self.assert_pid_gone(int((self.root / f"pid{i}").read_text()))
            self.assertIsNone(sentinel.poll())
        finally:
            sentinel.kill()
            sentinel.wait(timeout=3)

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
                      "candidate_ref": "refs/candidates/1",
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
        self.assertIn("Candidate build 1:", buf.getvalue())
        self.assertIn("no public version tag or release-list entry", buf.getvalue())
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

        with patch.object(m, "owned_run", side_effect=record), \
                contextlib.redirect_stdout(io.StringIO()):
            r.gates(checks_done_at_land)
        return r, seen

    def test_default_runs_every_gate_and_names_each_one_in_the_timings(self):
        r, seen = self.gate_commands()
        self.assertEqual(len(seen), 9)
        self.assertEqual(r.skipped, {})
        # ORDER IS PART OF THE ASSERTION, not incidental. The release smoke is first
        # because it is the cheapest refusal in the build (0.2 s against ~950 s), and the
        # defect class it catches -- a release-only step that rotted since the last
        # release -- is otherwise found by the release that needed it.
        self.assertEqual([name for name, _, _ in r.timings],
                         ["gates/release-smoke", "gates/core-tests", "gates/updater-tests",
                          "gates/script-suites", "gates/lint-tauri", m.WORKSPACE_MUTANTS_GATE,
                          m.UI_SUITE_GATE, "gates/privacy-sweep"])
        # The workspace-spec mutation pass runs HERE, before every nightly, and on no land
        # (CEO, 2026-09-23, "Only before nightlies"): the unit through ci-shard.sh, with the
        # opt-in stated at this call site.
        mut = [argv for argv in seen if "workspace-spec-fourteen.test.sh" in " ".join(argv)]
        self.assertEqual(mut, [["bash", "richos/engine/scripts/ci-shard.sh", "--only-units",
                                "mega-lander/tests/workspace-spec-fourteen.test.sh"]])
        lint = [argv for argv in seen if any(a.endswith('/lint.sh') for a in argv)]
        self.assertEqual(lint, [["bash", str(r.source / m.SCRIPTS / "lint.sh"), "--all",
                                 "--suite-results", str(r.state / m.SUITE_RESULTS)]])
        smoke = [argv for argv in seen if "release-smoke" in " ".join(argv)]
        self.assertEqual(len(smoke), 1, seen)
        self.assertTrue([a for a in smoke[0] if a.endswith("nightly.py")], smoke)
        # THE UI SUITE IS ONE SUBPROCESS, not a fan-out written beside `command()`. If this
        # ever counts more than one `run.js`, the shards have been hoisted back into this
        # file and every assertion in this class about a gate's argv and environment has
        # quietly stopped covering four of the five gates.
        ui = [argv for argv in seen if "run.js" in " ".join(argv)]
        self.assertEqual(len(ui), 1, seen)
        self.assertIn(f"--shards={m.UI_SHARDS}", ui[0])
        # THE SUITE WRITES TO ITS OWN CHECKOUT (lib/harness.js:publishShot rewrites a
        # committed screenshot whose picture changed), and `checkout()` refuses a dirty
        # worktree on the NEXT build. So the gate asks git what moved. Losing this call
        # would not fail anything today; it would refuse to start tomorrow.
        self.assertTrue([argv for argv in seen if argv[:3] == ["git", "status", "--porcelain"]],
                        seen)

    def test_the_flag_drops_only_what_a_land_proved_and_the_ui_suite_needs_a_proof(self):
        """`--checks-done-at-land` may drop what a land ran and NOTHING else.

        The land runs `cargo test -p richos-core`, `cargo test --bin richos-tauri` and the
        sharded ui suite on the exact commit that becomes `main`. It does not run the
        updater crate, the fourteen script suites or the privacy sweep, so those stay on
        the candidate path no matter what the flag says. A flag that grew to cover them
        would be trading a gate for time nobody measured.

        THE TWO SKIPS ARE NOT THE SAME STRENGTH, and that asymmetry is the case below. The
        core tests go on the sha alone, because the land ALWAYS runs them. The UI suite
        additionally needs the coverage proof its own run writes, because "the land ran it"
        is a claim about something that may not have happened -- and the safe direction for
        a missing file to fail in is "run the suite anyway", which is what this asserts.
        """
        r, seen = self.gate_commands("a" * 40)
        joined = [" ".join(argv) for argv in seen]
        self.assertFalse([c for c in joined if "-p richos-core" in c], joined)
        self.assertTrue([c for c in joined if "richos-user-update" in c], joined)
        self.assertTrue([c for c in joined if "run-tests.sh" in c], joined)
        self.assertTrue([c for c in joined if "named-persons.sh" in c], joined)
        self.assertIn(m.LAND_PROVEN_GATE, r.skipped)
        self.assertIn("a" * 40, r.skipped[m.LAND_PROVEN_GATE])
        # The release smoke is NEVER dropped by this flag. A land does not run it, and
        # its input is the release path itself rather than a tree whose sha was proved.
        self.assertTrue([c for c in joined if "release-smoke" in c], joined)
        # NO PROOF ON THIS MACHINE: the UI suite runs, and is NOT recorded as skipped.
        self.assertEqual(len(seen), 8)
        # The workspace-spec mutation pass is never dropped by this flag: a land does not run it
        # (CEO, 2026-09-23, "Only before nightlies"), so there is nothing a land proved.
        self.assertTrue([c for c in joined if "workspace-spec-fourteen" in c], joined)
        self.assertTrue([c for c in joined if "run.js" in c], joined)
        self.assertNotIn(m.UI_SUITE_GATE, r.skipped)

    def test_a_ui_coverage_proof_for_this_sha_drops_the_ui_suite_and_a_wrong_one_refuses(self):
        """The proof is read the way every other proof in this file is: by its commit.

        A file named after the right sha whose CONTENTS name a different tree is the most
        useful lie available here -- it would buy 378 s by certifying a run over something
        else -- so both are checked, and disagreement raises rather than silently running
        the suite.
        """
        sha = "a" * 40
        r = m.Runner(self.root, self.root / "state",
                     {"PATH": "/usr/bin", "RICHOS_NAMED_PERSONS_FILE": "/fixture/list"},
                     io.StringIO())
        proof_path = r.ui_proof_path(sha)
        proof_path.parent.mkdir(parents=True, exist_ok=True)

        # No file at all: nothing is accepted and nothing is raised.
        self.assertIsNone(r.accept_ui_proof(sha))

        proof_path.write_text(json.dumps(
            {"proof": "ui-suite-coverage", "commit": sha, "ran": 55, "checks": 863,
             "at": "2026-09-20T00:00:00Z"}))
        self.assertEqual(r.accept_ui_proof(sha)["ran"], 55)

        seen = []

        def record(args, **kwargs):
            seen.append([str(a) for a in args])
            return subprocess.CompletedProcess(args, 0, "", "")

        with patch.object(m, "owned_run", side_effect=record), \
                contextlib.redirect_stdout(io.StringIO()):
            r.gates(sha)
        self.assertFalse([c for c in seen if "run.js" in " ".join(c)], seen)
        self.assertIn(m.UI_SUITE_GATE, r.skipped)

        # A proof whose contents name a different tree proves nothing about this one.
        proof_path.write_text(json.dumps(
            {"proof": "ui-suite-coverage", "commit": "b" * 40, "ran": 55, "checks": 863}))
        with self.assertRaises(ValueError):
            r.accept_ui_proof(sha)

        # And a file that is not a coverage proof at all is not one.
        proof_path.write_text(json.dumps({"proof": "gui-boot", "commit": sha}))
        self.assertIsNone(r.accept_ui_proof(sha))

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
        # `checks_skipped` is now read off the runner's OWN record of its skips rather than
        # being a literal, so the stand-in for gates() has to record one. That is the point
        # of the change: the plan cannot claim a skip that did not happen, or miss one that
        # did, the next time a gate becomes skippable.
        r.gates.side_effect = lambda *a, **k: r.skip(m.LAND_PROVEN_GATE, "fixture skip")
        with contextlib.redirect_stdout(io.StringIO()):
            r.perform("build", checks_done_at_land="4f2d57c9")
        recorded = json.loads(plan_path.read_text())
        self.assertEqual(recorded["checks_done_at_land"],
                         "4f2d57c9f9519409427b86c7502b9a7588216bf1")
        self.assertEqual(recorded["checks_skipped"], [m.LAND_PROVEN_GATE])
        # The land proof reaches gates() as the FIRST positional, which is what this case
        # is about. The keywords beside it (`--no-host-screen`, skip-when-unchanged) are a
        # different question with its own cases; asserting the exact call signature here
        # would make every future gate option fail a case about the land proof.
        self.assertEqual(r.gates.call_count, 1)
        self.assertEqual(r.gates.call_args.args[0],
                         "4f2d57c9f9519409427b86c7502b9a7588216bf1")

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

    # =====================================================================================
    # `--no-host-screen`, and the evidence `publish` demands in exchange for it
    # =====================================================================================
    #
    # The CEO, 2026-09-19: *"So, every engineer will keep opening the app making me unable
    # to do anything here or WHAT???"*. `gui-boot.test.sh` boots the real app on the real
    # screen for ~162 s of every build, and `--no-host-screen` holds it back.
    #
    # THAT IS A TRADE, NOT A FREE WIN, and every case below is one way the second half of
    # the trade could quietly not happen — which would leave the mode as nothing but a way
    # of skipping a gate on the road to a published release.

    def gui_candidate(self, gui_state=None, no_host_screen=None, build_commit=None):
        """A staged candidate whose build-info records `gui_state` for gui-boot."""
        info = dict(self.CANDIDATE_INFO)
        if build_commit:
            info["build_commit"] = build_commit
        if no_host_screen is not None:
            info["no_host_screen"] = no_host_screen
        if gui_state is not None:
            info["script_suites"] = {"jobs": 3, "suites": [
                {"name": "make-release.test.sh", "state": "passed"},
                {"name": "gui-boot.test.sh", "state": gui_state,
                 "reason": "no screen this run may use"}]}
        r = self.runner()
        (self.root / "state" / "source").mkdir(parents=True, exist_ok=True)
        out = self.root / "state" / "releases" / info["tag"]
        out.mkdir(parents=True, exist_ok=True)
        (out / "candidate.json").write_text(json.dumps({"info": info, "files": {}}))
        r.record_run(info["run_id"], out)
        r.command = Mock()
        return r, info

    def proof(self, name="gui.proof", suite="gui-boot.test.sh", result="pass",
              commit="deadbeefcafe0123456789", where="vm:richos-test-1"):
        path = self.root / name
        path.write_text(f"richos-gui-proof 1\nsuite={suite}\ncommit={commit}\n"
                        f"where={where}\nresult={result}\nat=2026-09-19T20:00:00Z\n"
                        "--- output ---\n  PASS  B1 the app booted\n")
        return path

    def test_a_candidate_whose_gui_boot_did_not_run_is_refused_without_a_proof(self):
        """THE CASE THE WHOLE MODE TURNS ON.

        A screenless build is only honest if the boot it did not watch has to be watched
        before anything becomes installable. Without this refusal, `--no-host-screen` is a
        way to publish an app nobody ever saw start.
        """
        r, _ = self.gui_candidate(gui_state="not-run", no_host_screen=True)
        with self.assertRaises(ValueError) as caught:
            with contextlib.redirect_stdout(io.StringIO()):
                r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"])
        self.assertIn("gui-boot", str(caught.exception))
        self.assertIn("gui-proof-in-vm.sh", str(caught.exception))
        # AND NOTHING WAS PUBLISHED. A refusal that still called `finish` would be a
        # warning wearing an exception's clothes.
        r.command.assert_not_called()

    def test_a_screenless_build_that_lost_its_report_is_refused_too(self):
        """Silence from a build that was TOLD not to use the screen is not a pass.

        The report could go missing for an innocent reason; what cannot happen is that the
        innocent reason and "the suite never ran" become indistinguishable. `no_host_screen`
        is recorded separately from the report for exactly this case.
        """
        r, _ = self.gui_candidate(gui_state=None, no_host_screen=True)
        with self.assertRaises(ValueError):
            with contextlib.redirect_stdout(io.StringIO()):
                r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"])
        r.command.assert_not_called()

    def test_a_candidate_from_before_the_field_still_publishes(self):
        """...and the mirror image, which the first version of this got WRONG.

        "Silence is never read as a pass" sounds right and would have made every candidate
        already staged on this Mac unpublishable, because none of them carries a field that
        did not exist when it was built. Those builds ran gui-boot; it was not skippable
        then. This case is what stops that rule being rediscovered.
        """
        r, _ = self.gui_candidate(gui_state=None, no_host_screen=None)
        with contextlib.redirect_stdout(io.StringIO()):
            r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"])
        self.assertEqual(r.command.call_args.args[2], "finish")

    def test_a_proof_against_this_candidate_lets_it_publish(self):
        r, _ = self.gui_candidate(gui_state="not-run", no_host_screen=True)
        with contextlib.redirect_stdout(io.StringIO()):
            r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"],
                      gui_proof=str(self.proof()))
        self.assertEqual(r.command.call_args.args[2], "finish")

    def test_a_proof_taken_against_another_tree_is_refused(self):
        """The sha is the whole point, exactly as it is for --checks-done-at-land.

        A proof that is not required to name THIS commit is a proof that can be taken once
        and reused forever, which is worse than no proof: it reads as diligence.
        """
        r, _ = self.gui_candidate(gui_state="not-run", no_host_screen=True)
        with self.assertRaises(ValueError) as caught:
            with contextlib.redirect_stdout(io.StringIO()):
                r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"],
                          gui_proof=str(self.proof(commit="0123456789abcdef")))
        self.assertIn("different tree", str(caught.exception))
        r.command.assert_not_called()

    def test_a_proof_naming_the_build_commit_is_accepted(self):
        """The bundle is compiled from `build_commit` -- the version-bump commit whose
        parent is `source_commit`. A proof taken against the thing that was actually built
        must not be refused for naming it."""
        r, _ = self.gui_candidate(gui_state="not-run", no_host_screen=True,
                                  build_commit="abc123def456")
        with contextlib.redirect_stdout(io.StringIO()):
            r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"],
                      gui_proof=str(self.proof(commit="abc123def456")))
        self.assertEqual(r.command.call_args.args[2], "finish")

    def test_a_proof_that_records_a_failure_is_refused(self):
        r, _ = self.gui_candidate(gui_state="not-run", no_host_screen=True)
        with self.assertRaises(ValueError) as caught:
            with contextlib.redirect_stdout(io.StringIO()):
                r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"],
                          gui_proof=str(self.proof(result="fail:1")))
        self.assertIn("not a pass", str(caught.exception))
        r.command.assert_not_called()

    def test_a_proof_for_a_different_suite_is_refused(self):
        r, _ = self.gui_candidate(gui_state="not-run", no_host_screen=True)
        with self.assertRaises(ValueError):
            with contextlib.redirect_stdout(io.StringIO()):
                r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"],
                          gui_proof=str(self.proof(suite="front-door.test.sh")))

    def test_a_shipped_bundle_boot_in_a_guest_is_accepted_evidence(self):
        """`gui-proof-in-vm.sh` boots the SIGNED, NOTARIZED artifact this release will
        publish, on a clean guest with no developer environment -- fewer assertions than
        gui-boot.test.sh, and a truer artifact. It is accepted, under its OWN name: a proof
        that borrowed the suite's name would be the most useful lie in the release chain."""
        r, _ = self.gui_candidate(gui_state="not-run", no_host_screen=True)
        with contextlib.redirect_stdout(io.StringIO()):
            r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"],
                      gui_proof=str(self.proof(suite="shipped-bundle-boot")))
        self.assertEqual(r.command.call_args.args[2], "finish")

    def test_a_file_that_is_not_a_proof_is_refused_by_name(self):
        """A malformed proof is refused loudly rather than read past: this file is the one
        thing standing between an unexercised boot and a published release."""
        path = self.root / "not-a-proof"
        path.write_text("looks official enough\ncommit=deadbeefcafe0123456789\nresult=pass\n")
        r, _ = self.gui_candidate(gui_state="not-run", no_host_screen=True)
        with self.assertRaises(ValueError) as caught:
            with contextlib.redirect_stdout(io.StringIO()):
                r.perform("publish", run_id=self.CANDIDATE_INFO["run_id"], gui_proof=str(path))
        self.assertIn("richos-gui-proof 1", str(caught.exception))

    def test_the_flag_reaches_the_suite_runner_and_the_record_travels(self):
        """`--no-host-screen` has to arrive at `run-tests.sh` AND be written into the plan.

        Either half alone is a defect: a flag that does not reach the runner opens a window
        while claiming not to, and a run that does not record what it held back leaves
        `publish` unable to tell a screenless build from an old one.
        """
        # A real Runner: self.runner() mocks `gates` itself, which is the method under test.
        r = m.Runner(self.root, self.root / "state", {}, io.StringIO())
        r.state.mkdir(parents=True, exist_ok=True)
        (r.state / m.SUITE_RESULTS).write_text(json.dumps(
            {"jobs": 3, "suites": [{"name": "gui-boot.test.sh", "state": "not-run"}]}))
        r.command = Mock(return_value="")
        with contextlib.redirect_stdout(io.StringIO()):
            report = r.gates(no_host_screen=True, skip_unchanged=True)
        argvs = [" ".join(str(a) for a in call.args) for call in r.command.call_args_list]
        runner_calls = [c for c in argvs if "run-tests.sh" in c]
        self.assertEqual(len(runner_calls), 1, argvs)
        self.assertIn("--no-host-screen", runner_calls[0])
        self.assertEqual(report["suites"][0]["state"], "not-run")
        # ...and skip-when-unchanged is stated at the call site, never inherited.
        env = [c.kwargs["env_extra"] for c in r.command.call_args_list
               if "env_extra" in c.kwargs][0]
        self.assertEqual(env["RUN_TESTS_SKIP_UNCHANGED"], "1")
        # The middle iPhone size runs before every nightly (CEO, 2026-09-23, "Only before
        # nightlies"): stated at this call site, where a failure stops the nightly.
        self.assertEqual(env["RICHOS_NATIVE_IOS_APP_A8"], "1")
        # ...and so does the workspace-spec mutation pass, at its own gate.
        mut = [c for c in r.command.call_args_list
               if "workspace-spec-fourteen.test.sh" in " ".join(str(a) for a in c.args)]
        self.assertEqual(len(mut), 1, argvs)
        self.assertEqual(mut[0].kwargs.get("env_extra"), {"RICHOS_FOURTEEN_MUTANTS": "1"})
        self.assertEqual(mut[0].kwargs.get("timeout"), m.GATE_BUDGETS[m.WORKSPACE_MUTANTS_GATE])

    def test_release_never_skips_a_suite_over_unchanged_inputs(self):
        """A proof file on this host may excuse a suite for a CANDIDATE. It may never
        excuse one for the command that makes a build installable in one motion."""
        r = self.runner()
        r.gates = Mock(return_value=None)
        r.plan = Mock(return_value=(self.root / "plan.json",
                                    {"build": True, **self.CANDIDATE_INFO}))
        (self.root / "plan.json").write_text("{}")
        r.checkout = Mock(return_value="deadbeefcafe0123456789")
        r.preflight = Mock()
        r.runtime = Mock()
        r.command = Mock()
        with contextlib.redirect_stdout(io.StringIO()):
            r.perform("release")
        self.assertIs(r.gates.call_args.kwargs["skip_unchanged"], False)


class WalkRecipeTests(unittest.TestCase):
    """The printed walk recipe starts the candidate on ONE scratch home (2026-09-24).

    Under HOME alone, Foundation's NSHomeDirectory() still named the real home, so a
    walked candidate put WebKit's store and the URL cache in the real ~/Library, where the
    daily driver (same bundle identifier) keeps them. These run the recipe's own lines with
    lib/home-probe.sh standing in for the app: no build, no window."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def test_the_recipe_names_one_canonical_noindex_home_and_a_clean_environment(self):
        # The un-resolved temporary folder is the /var symlink the product refuses as a home.
        scratch, lines = m.walk_recipe(Path("/x/RichOS.zip"), "run1", temp_root=tempfile.gettempdir())
        home = scratch / "home.noindex"
        self.assertEqual(scratch, scratch.resolve())
        self.assertTrue(scratch.name.endswith(".noindex"))
        text = "\n".join(lines)
        self.assertIn(f"HOME={shlex.quote(str(home))} CFFIXED_USER_HOME={shlex.quote(str(home))}", text)
        self.assertIn("/usr/bin/env -i ", text)
        self.assertIn("PATH=/usr/bin:/bin:/usr/sbin:/sbin", text)

    @unittest.skipUnless(sys.platform == "darwin", "Foundation's NSHomeDirectory()")
    def test_the_recipe_as_printed_starts_the_app_on_its_scratch_home(self):
        app = self.root / "src" / "RichOS.app" / "Contents" / "MacOS"
        app.mkdir(parents=True)
        probe = app / "richos-tauri"
        probe.write_bytes((Path(__file__).parent / "lib" / "home-probe.sh").read_bytes())
        probe.chmod(0o755)
        bundle = self.root / "RichOS-probe.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(self.root / "src" / "RichOS.app"), str(bundle)],
                       check=True)
        scratch, lines = m.walk_recipe(bundle, "probe", temp_root=self.root)
        home = scratch / "home.noindex"
        env = {"USER": os.environ.get("USER", "probe"), "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
               "HOME": os.environ.get("HOME", "/"), "WALK_RECIPE_CANARY": "from-the-shell"}
        result = subprocess.run(["bash", "-c", "\n".join(lines)], env=env, capture_output=True, text=True,
                                timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("[richos] boot complete", result.stdout)
        seen = dict(line.split("=", 1) for line in (home / ".home-probe" / "env").read_text().splitlines()
                    if "=" in line)
        for bash_own in ("PWD", "SHLVL", "_"):
            seen.pop(bash_own, None)
        self.assertEqual(sorted(seen), ["CFFIXED_USER_HOME", "HOME", "PATH", "RICHOS_ACTIVATION", "TMPDIR", "USER"])
        self.assertEqual((seen["HOME"], seen["CFFIXED_USER_HOME"]), (str(home), str(home)))
        self.assertEqual(seen["TMPDIR"], str(home / "tmp") + "/")
        nshome = (home / ".home-probe" / "nshome").read_text().strip()
        self.assertEqual(Path(nshome).resolve(), home)


if __name__ == "__main__":
    unittest.main(verbosity=2)
