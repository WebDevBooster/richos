#!/usr/bin/env python3
"""autocheck.test.py — git itself runs the basic checks, at commit and at the land into main.

Every case is a throwaway repository with the real shim, installer and autocheck.py, and
stand-ins for the tools they call: a lint that refuses a file saying LINT-BAD, a selector
that assigns scripts/suite.sh to any change under richos/app, the owning suite (fails when
src/thing.txt says BROKEN) and a runner that runs the selected commands. Escalations go to a
scratch ledger through the real escalate.sh. Nothing touches this repository or its hooks.

  COMMIT   a failing lint refuses the commit; a clean change commits with no record;
           --no-verify is recorded; a linked worktree, `commit -a`, a cherry-pick, a branch
           older than the check and a forged exemption behave; before the check exists the
           hooks do nothing.
  LAND     a merge that breaks its owning suite is refused before main moves; a good one
           lands with a receipt; --no-verify and a fast-forward are recorded and the push
           then runs the checks; an uncovered path, a direct commit and a dirty tree are
           refused; the land that introduces the check is checked by it.
  INSTALL  install, --check and --uninstall, a foreign hook left alone, a chain that
           would never call the hook reported.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
AUTOCHECK = HERE / "autocheck"
ENGINE = HERE.parents[1] / "engine"
HANG_GUARD = 600

LINT = """#!/usr/bin/env bash
# Fixture lint: refuses when a file under richos/app/src says LINT-BAD.
cd "$(dirname "$0")/../../.."
printf 'lint %s\\n' "$*" >> "$AUTOCHECK_FIXTURE_LOG"
if grep -rq LINT-BAD richos/app/src; then
    echo "Lint refused: lint growth: fixture-rule: 1 > 0" >&2
    exit 1
fi
echo "Lint passed"
"""
DRIVER = "# Fixture: this lint knows the commit mode, --changed, and --strict.\n"
PROOF_FOR = """#!/usr/bin/env bash
# Fixture selector: scripts/suite.sh proves every change under richos/app.
cd "$(dirname "$0")/../../.."
shift
if [ "$1" = --paths ]; then
    paths=$(printf '%s\\n' "$2" | tr ',' '\\n')
else
    paths=$(git diff --name-only "$1")
fi
if printf '%s\\n' "$paths" | grep -q uncovered; then
    echo "UNCOVERED: richos/app/src/uncovered.txt" >&2
    exit 1
fi
if printf '%s\\n' "$paths" | grep -q '^richos/app/'; then
    echo "  cd richos/app && bash scripts/suite.sh"
fi
if printf '%s\\n' "$paths" | grep -q 'screen'; then
    echo "  cd richos/app && bash scripts/screen.sh"
fi
if printf '%s\\n' "$paths" | grep -q 'claims'; then
    echo "  cd richos/app/ui/tests && node quick.js"
    echo "  cd richos/app/ui/tests && node heavy.js"
fi
"""
# A document-vs-tree check that measures under a second (weight 0): fails when the claim in
# src/claims.txt says FALSE. And a heavy suite selected beside it, which a commit never runs.
QUICK = """const fs = require("fs");
fs.appendFileSync(process.env.AUTOCHECK_FIXTURE_LOG, "node quick.js\\n");
if (fs.readFileSync("../../src/claims.txt", "utf8").includes("FALSE")) {
  console.error("quick: FAIL the README's count is stale");
  process.exit(1);
}
console.log("quick: PASS");
"""
HEAVY = """require("fs").appendFileSync(process.env.AUTOCHECK_FIXTURE_LOG, "node heavy.js\\n");
"""
WEIGHTS = "# fixture weights\nquick.js\t0\nheavy.js\t40\n"
PROOF_RUN = """import json
import os
import subprocess
import sys

# Fixture runner, proof-run.py's contract: exit 0 all passed, 1 a check did not pass, 3 nothing
# failed and a check was NOT RUN; --summary-out gets summary.json's rows. A command that prints
# "NOT-RUN <why>" and exits 0 is a suite run-tests.sh did not run, for that reason.
plan = sys.argv[sys.argv.index("--commands") + 1]
rows = []
for line in open(plan):
    line = line.strip()
    if line:
        with open(os.environ["AUTOCHECK_FIXTURE_LOG"], "a") as log:
            log.write("run " + line + "\\n")
        done = subprocess.run(["bash", "-c", line], stdout=subprocess.PIPE, text=True)
        sys.stdout.write(done.stdout)
        said = [l.split()[1] for l in done.stdout.splitlines() if l.startswith("NOT-RUN ")]
        if done.returncode:
            print("FAILED " + line)
            rows.append({"check": line, "result": "failed", "not_run": None})
        elif said:
            print("NOT RUN (%s) " % said[0] + line)
            rows.append({"check": line, "result": "not-run",
                         "not_run": {"why": said[0], "suites": [{"name": line, "state": "notrun", "reason": said[0]}]}})
        else:
            rows.append({"check": line, "result": "passed", "not_run": None})
if "--summary-out" in sys.argv:
    with open(sys.argv[sys.argv.index("--summary-out") + 1], "w") as out:
        json.dump({"checks": rows}, out)
results = {row["result"] for row in rows}
sys.exit(1 if results - {"passed", "not-run"} else 3 if "not-run" in results else 0)
"""
SUITE = """#!/usr/bin/env bash
# Fixture owning suite.
cd "$(dirname "$0")/.."
if grep -q BROKEN src/thing.txt; then
    echo "suite: FAIL src/thing.txt is broken" >&2
    exit 1
fi
echo "suite: PASS"
"""
SCREEN = """#!/usr/bin/env bash
# Fixture screen suite: does not run, for the reason src/screen.txt names.
cd "$(dirname "$0")/.."
echo "NOT-RUN $(cat src/screen.txt)"
"""


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="autocheck-")
        self.base = Path(self.tmp.name)
        self.log = self.base / "tools.log"
        self.ledger = self.base / "ledger.jsonl"
        (self.base / "gitconfig").write_text("[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n"
                                              "[init]\n\tdefaultBranch = main\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "RICHOS_AUTOCHECK"))}
        self.env.update(GIT_CONFIG_GLOBAL=str(self.base / "gitconfig"), GIT_CONFIG_NOSYSTEM="1",
                        AUTOCHECK_FIXTURE_LOG=str(self.log), RICHOS_ESCALATION_LEDGER=str(self.ledger))
        self.repo = self.base / "repo"

    def tearDown(self):
        self.tmp.cleanup()

    # -- building ------------------------------------------------------------------------
    def make(self, with_checker=True, install=True):
        app = self.repo / "richos/app"
        for rel, text, mode in (("scripts/lint.sh", LINT, 0o755), ("scripts/lint/driver.py", DRIVER, 0o644),
                                ("scripts/proof-for.sh", PROOF_FOR, 0o755), ("scripts/proof-run.py", PROOF_RUN, 0o644),
                                ("scripts/suite.sh", SUITE, 0o755), ("scripts/screen.sh", SCREEN, 0o755),
                                ("ui/tests/quick.js", QUICK, 0o644), ("ui/tests/heavy.js", HEAVY, 0o644),
                                ("ui/tests/suite-weights.tsv", WEIGHTS, 0o644),
                                ("src/thing.txt", "fine\n", 0o644), ("src/claims.txt", "true\n", 0o644)):
            path = app / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            path.chmod(mode)
        (self.repo / "richos/engine").symlink_to(ENGINE)
        self.git("init", "-q")
        (self.repo / ".git/info/exclude").write_text("richos/engine\n")
        if with_checker:
            self.add_checker()
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")
        if install:
            self.install()

    def add_checker(self, repo=None):
        dest = (repo or self.repo) / "richos/app/scripts/autocheck"
        dest.mkdir(parents=True, exist_ok=True)
        for name in ("autocheck.py", "shim.sh", "install.sh"):
            shutil.copy(AUTOCHECK / name, dest / name)

    def install(self):
        out = self.run_(["bash", str(AUTOCHECK / "install.sh"), str(self.repo)])
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)

    def run_(self, argv, cwd=None, env=None):
        return subprocess.run(argv, cwd=cwd or self.repo, env=env or self.env, capture_output=True, text=True,
                              timeout=HANG_GUARD)

    def git(self, *args, cwd=None, expect=0, env=None):
        result = self.run_(["git", *args], cwd=cwd, env=env)
        if expect is not None:
            self.assertEqual(result.returncode, expect, f"git {' '.join(args)}\n{result.stdout}{result.stderr}")
        return result

    def write(self, rel, text, cwd=None):
        path = (cwd or self.repo) / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def head(self, ref="HEAD", cwd=None):
        return self.git("rev-parse", ref, cwd=cwd).stdout.strip()

    def tools(self):
        return self.log.read_text() if self.log.exists() else ""

    def recorded(self):
        return self.ledger.read_text() if self.ledger.exists() else ""

    def branch_with(self, name, rel, text, message="change", no_verify=False):
        self.git("checkout", "-q", "-b", name)
        self.write(rel, text)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message, *(["--no-verify"] if no_verify else []))
        self.git("checkout", "-q", "main")
        self.log.unlink(missing_ok=True)

    def land_a_merge_commit_on_main(self):
        """main's tip becomes a land merge (two parents), checked and passed like any land."""
        self.branch_with("other", "richos/app/src/thing.txt", "fine, better\n")
        self.git("merge", "--no-ff", "-m", "land other", "other")
        self.assertEqual(len(self.git("rev-list", "--parents", "-n", "1", "main").stdout.split()), 3)


class Commit(Fixture):
    def test_a_commit_whose_lint_fails_is_refused_with_the_reason(self):
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        before = self.head()
        self.write("richos/app/src/bad.txt", "LINT-BAD\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "bad", expect=1)
        text = out.stdout + out.stderr
        self.assertIn("COMMIT REFUSED", text)
        self.assertIn("Lint refused: lint growth: fixture-rule: 1 > 0", text)
        self.assertEqual(self.head(), before)
        self.assertIn("lint --changed --strict", self.tools())

    def test_a_clean_commit_passes_and_leaves_no_record(self):
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        self.write("richos/app/src/thing.txt", "fine, again\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "good")
        self.assertIn("autocheck: commit: passed", out.stderr)
        self.assertEqual(self.recorded(), "")

    def test_a_change_outside_the_app_runs_no_lint(self):
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        self.write("README.md", "docs\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "docs")
        self.assertIn("no lint applies", out.stderr)
        self.assertEqual(self.tools(), "")

    def test_no_verify_commits_and_is_recorded_for_the_lead(self):
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        self.write("richos/app/src/bad.txt", "LINT-BAD\n")
        self.git("add", "-A")
        out = self.git("commit", "-q", "-m", "bad", "--no-verify")
        self.assertIn("AUTOCHECK SKIPPED, RECORDED", out.stderr)
        rows = [json.loads(line) for line in self.recorded().splitlines() if line.strip()]
        self.assertTrue(any("skipped the automatic checks (--no-verify)" in json.dumps(r) for r in rows), rows)
        self.assertIn("--no-verify", (self.repo / ".git/richos-autocheck/bypass.log").read_text())

    def test_commit_all_and_a_cherry_pick_leave_no_false_record(self):
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        self.write("richos/app/src/thing.txt", "fine, via -a\n")
        self.git("commit", "-q", "-a", "-m", "all")
        self.git("checkout", "-q", "-b", "other", "main")
        self.git("cherry-pick", "feature")
        self.assertEqual(self.recorded(), "")

    def test_a_linked_worktree_is_checked_by_the_same_hooks(self):
        self.make()
        wt = self.base / "wt"
        self.git("worktree", "add", "-q", "-b", "wtbranch", str(wt))
        self.write("richos/app/src/bad.txt", "LINT-BAD\n", cwd=wt)
        self.git("add", "-A", cwd=wt)
        out = self.git("commit", "-m", "bad", cwd=wt, expect=1)
        self.assertIn("COMMIT REFUSED", out.stderr)

    def test_a_copied_exemption_exempts_nothing(self):
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        self.write("richos/app/src/bad.txt", "LINT-BAD\n")
        self.git("add", "-A")
        forged = dict(self.env, RICHOS_AUTOCHECK_ACTIVE=f"{(self.repo / '.git').resolve()}:1")
        out = self.git("commit", "-m", "bad", env=forged, expect=1)
        self.assertIn("COMMIT REFUSED", out.stderr)

    def test_a_branch_older_than_the_check_is_checked_by_mains_copy(self):
        self.make(with_checker=False)
        self.git("checkout", "-q", "-b", "old")
        self.git("checkout", "-q", "main")
        self.add_checker()
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "introduce the check")
        self.git("checkout", "-q", "old")
        self.write("richos/app/src/bad.txt", "LINT-BAD\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "bad", expect=1)
        self.assertIn("COMMIT REFUSED", out.stderr)

    def test_a_commit_the_land_would_refuse_as_uncovered_is_refused_at_the_commit(self):
        # 2026-09-29: isaac-opus-speckle1 and andy-opus-speckle1 each had four UNCOVERED paths
        # that nobody could see until Rich's merge; their commits had passed this hook.
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        before = self.head()
        self.write("richos/app/src/uncovered.txt", "new code\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "uncovered", expect=1)
        self.assertIn("COMMIT REFUSED: a changed code path is covered by no suite", out.stderr)
        self.assertIn("UNCOVERED: richos/app/src/uncovered.txt", out.stderr)
        self.assertEqual(self.head(), before)

    def test_the_whole_branch_is_asked_not_only_the_staged_files(self):
        # An uncovered path committed earlier with --no-verify is still in what the land will
        # diff, so the next ordinary commit on the branch refuses it too.
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        self.write("richos/app/src/uncovered.txt", "new code\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "uncovered", "--no-verify")
        self.write("richos/app/src/thing.txt", "fine, again\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "an innocent change", expect=1)
        self.assertIn("UNCOVERED: richos/app/src/uncovered.txt", out.stderr)

    def test_a_quick_document_check_the_change_falsifies_refuses_the_commit(self):
        # 2026-09-29: a Rust test file made app/README.md's counts false; docs-claims.js (under
        # a second) ran nowhere before the nightly. The commit runs the quick suites selected.
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        self.write("richos/app/src/claims.txt", "FALSE\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "stale claim", expect=1)
        self.assertIn("COMMIT REFUSED: quick.js failed for this branch", out.stderr)
        self.assertIn("quick: FAIL the README's count is stale", out.stderr)
        self.assertNotIn("node heavy.js", self.tools())

    def test_a_true_claim_commits_and_heavy_suites_wait_for_the_land(self):
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        self.write("richos/app/src/claims.txt", "still true\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "claim kept true")
        self.assertIn("ran quick.js", out.stderr)
        self.assertIn("node quick.js", self.tools())
        self.assertNotIn("node heavy.js", self.tools())
        self.assertEqual(self.recorded(), "")

    def test_fast_forwarding_a_branch_onto_a_land_merge_records_no_skip(self):
        # 2026-09-29: echo-opus-speckle1 fast-forwarded its branch onto main's 5ddcce1c, a
        # land merge, and the ledger said "skipped the automatic checks (--no-verify)". No
        # --no-verify was passed; a fast-forward writes no commit and has nothing to skip.
        self.make()
        self.git("branch", "feature")
        self.land_a_merge_commit_on_main()
        self.git("checkout", "-q", "feature")
        out = self.git("merge", "--ff-only", "main")
        self.assertNotIn("AUTOCHECK SKIPPED", out.stderr)
        self.assertEqual(self.recorded(), "")

    def test_a_real_merge_into_a_branch_with_no_verify_is_still_recorded(self):
        self.make()
        self.git("checkout", "-q", "-b", "feature")
        self.write("richos/app/src/feature.txt", "feature work\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "feature work")
        self.git("checkout", "-q", "main")
        self.land_a_merge_commit_on_main()
        self.git("checkout", "-q", "feature")
        self.git("merge", "--no-ff", "--no-verify", "-m", "bring main in", "main")
        self.assertIn("skipped the automatic checks (--no-verify)", self.recorded())

    def test_before_the_check_exists_the_hooks_do_nothing(self):
        self.make(with_checker=False)
        self.git("checkout", "-q", "-b", "feature")
        self.write("richos/app/src/bad.txt", "LINT-BAD\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "bad")
        self.assertEqual(out.stderr, "")
        self.assertEqual(self.tools(), "")


class Land(Fixture):
    def test_a_merge_that_breaks_its_owning_suite_is_refused_before_main_moves(self):
        self.make()
        self.branch_with("feature", "richos/app/src/thing.txt", "BROKEN\n")
        before = self.head("main")
        out = self.git("merge", "--no-ff", "-m", "land feature", "feature", expect=1)
        text = out.stdout + out.stderr
        self.assertIn("MERGE INTO MAIN REFUSED", text)
        self.assertIn("suite: FAIL src/thing.txt is broken", text)
        self.assertEqual(self.head("main"), before)
        self.assertIn("run cd richos/app && bash scripts/suite.sh", self.tools())
        self.assertIn("lint --all", self.tools())
        self.git("merge", "--abort")

    def test_a_good_merge_lands_with_a_receipt_and_no_record(self):
        self.make()
        self.branch_with("feature", "richos/app/src/thing.txt", "fine, better\n")
        out = self.git("merge", "--no-ff", "-m", "land feature", "feature")
        self.assertIn("every selected check passed", out.stderr)
        tree = self.head("HEAD^{tree}")
        self.assertTrue((self.repo / ".git/richos-autocheck/land" / tree).exists())
        self.assertEqual(self.recorded(), "")

    def test_a_land_whose_screen_suites_did_not_run_lands_and_says_not_run(self):
        # 2026-09-29: front-door and gui-boot were NOT RUN (no screen) in the refused land of
        # 6ef73abf and recorded as passed. NOT RUN is not a pass; the one a land accepts is a
        # suite that needs the screen a land may never use, and it says so where it lands.
        self.make()
        self.branch_with("feature", "richos/app/src/screen.txt", "no-screen\n")
        out = self.git("merge", "--no-ff", "-m", "land feature", "feature")
        self.assertIn("MERGE INTO MAIN ALLOWED WITH 1 CHECK(S) NOT RUN, WHICH IS NOT A PASS", out.stderr)
        self.assertIn("NOT RUN: cd richos/app && bash scripts/screen.sh (no-screen)", out.stderr)
        self.assertNotIn("every selected check passed", out.stderr)
        receipt = json.loads((self.repo / ".git/richos-autocheck/land" / self.head("HEAD^{tree}")).read_text())
        self.assertEqual([row["check"] for row in receipt["not_run"]], ["cd richos/app && bash scripts/screen.sh"])
        self.assertEqual(self.recorded(), "")

    def test_a_land_with_any_other_check_not_run_is_refused(self):
        self.make()
        self.branch_with("feature", "richos/app/src/screen.txt", "host-gap\n")
        before = self.head("main")
        out = self.git("merge", "--no-ff", "-m", "land feature", "feature", expect=1)
        self.assertIn("MERGE INTO MAIN REFUSED: a check it owns did not pass", out.stderr)
        self.assertIn("NOT RUN is not a pass", out.stderr)
        self.assertEqual(self.head("main"), before)
        self.git("merge", "--abort")

    def test_no_verify_merge_is_recorded(self):
        self.make()
        self.branch_with("feature", "richos/app/src/thing.txt", "BROKEN\n")
        self.git("merge", "--no-ff", "--no-verify", "-m", "land feature", "feature")
        self.assertIn("without the land checks (git merge --no-verify)", self.recorded())

    def test_a_fast_forward_is_recorded_and_the_push_runs_the_checks(self):
        self.make()
        remote = self.base / "remote.git"
        self.git("init", "-q", "--bare", str(remote))
        self.git("remote", "add", "origin", str(remote))
        self.git("push", "-q", "origin", "main")  # the base: checked here, and it passes
        self.branch_with("feature", "richos/app/src/thing.txt", "BROKEN\n")
        self.git("merge", "--ff-only", "feature")
        self.assertIn("without the land checks (a fast-forward)", self.recorded())
        out = self.git("push", "origin", "main", expect=1)
        self.assertIn("PUSH REFUSED: a check it owns did not pass", out.stderr)
        self.assertNotEqual(self.git("rev-parse", "main", cwd=remote).stdout.strip(), self.head("main"))

    def test_main_fast_forwarded_onto_a_merge_commit_is_named_a_fast_forward(self):
        self.make()
        self.git("checkout", "-q", "-b", "side")
        self.write("richos/app/src/side.txt", "side work\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "side work")
        self.git("checkout", "-q", "main")
        self.land_a_merge_commit_on_main()
        self.git("checkout", "-q", "side")
        self.git("merge", "--no-ff", "--no-verify", "-m", "a merge made off main", "main")
        self.git("checkout", "-q", "main")
        self.ledger.unlink(missing_ok=True)
        self.git("merge", "--ff-only", "side")
        self.assertIn("without the land checks (a fast-forward)", self.recorded())
        self.assertNotIn("--no-verify", self.recorded())

    def test_an_uncovered_path_refuses_the_merge(self):
        # Its own commit refuses it now (Commit, below); a branch that got past that with
        # --no-verify is still refused at the land.
        self.make()
        self.branch_with("feature", "richos/app/src/uncovered.txt", "new code\n", no_verify=True)
        out = self.git("merge", "--no-ff", "-m", "land feature", "feature", expect=1)
        self.assertIn("covered by no suite", out.stderr)

    def test_a_direct_commit_on_main_runs_the_land_checks(self):
        self.make()
        self.write("richos/app/src/thing.txt", "BROKEN\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "straight onto main", expect=1)
        self.assertIn("COMMIT TO MAIN REFUSED", out.stderr)

    def test_a_working_tree_that_differs_from_the_merge_is_refused(self):
        self.make()
        self.branch_with("feature", "richos/app/src/thing.txt", "fine, better\n")
        self.git("merge", "--no-ff", "--no-commit", "feature", expect=None)
        self.write("richos/app/scripts/suite.sh", SUITE + "# edited during the merge\n")
        out = self.git("commit", "-m", "land feature", expect=1)
        self.assertIn("working tree differs", out.stderr)

    def test_the_land_that_introduces_the_check_is_checked_by_it(self):
        self.make(with_checker=False)
        self.git("checkout", "-q", "-b", "intro")
        self.add_checker()
        self.write("richos/app/src/thing.txt", "BROKEN\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "introduce the check")
        self.git("checkout", "-q", "main")
        out = self.git("merge", "--no-ff", "-m", "land intro", "intro", expect=1)
        self.assertIn("MERGE INTO MAIN REFUSED", out.stderr)


class Install(Fixture):
    def test_install_check_and_uninstall_touch_only_their_own_hooks(self):
        self.make(install=False)
        foreign = self.repo / ".git/hooks/pre-push"
        foreign.write_text("#!/bin/sh\nexit 0\n")
        out = self.run_(["bash", str(AUTOCHECK / "install.sh"), str(self.repo)])
        self.assertEqual(out.returncode, 1)
        self.assertIn("REFUSED", out.stdout)
        self.assertEqual(foreign.read_text(), "#!/bin/sh\nexit 0\n")
        foreign.unlink()
        self.install()
        self.assertEqual(self.run_(["bash", str(AUTOCHECK / "install.sh"), "--check", str(self.repo)]).returncode, 0)
        out = self.run_(["bash", str(AUTOCHECK / "install.sh"), "--uninstall", str(self.repo)])
        self.assertEqual(out.stdout.count("REMOVED"), 5)
        self.assertEqual(self.run_(["bash", str(AUTOCHECK / "install.sh"), "--check", str(self.repo)]).returncode, 1)

    def test_a_hooks_path_that_never_calls_the_hook_is_reported(self):
        self.make()
        empty = self.base / "empty-hooks"
        empty.mkdir()
        self.git("config", "core.hooksPath", str(empty))
        out = self.run_(["bash", str(AUTOCHECK / "install.sh"), "--check", str(self.repo)])
        self.assertEqual(out.returncode, 1)
        self.assertIn("UNREACHABLE", out.stdout)


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=2).result
    sys.exit(0 if result.wasSuccessful() else 1)
