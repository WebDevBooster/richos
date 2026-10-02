#!/usr/bin/env python3
"""operator-fences-holders.test.py: a declared land-lease holder survives its
app moving it, and nothing else passes as it.

On 2026-09-30 21:58 the ChatGPT app updated itself and moved Codex from
ChatGPT.app/Contents/Resources/codex to
ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex.
LAND_LEASE_HOLDERS still named the old path, no ancestor matched it, and every
Codex land in a fenced checkout was refused until the declaration was edited
and the launchers reinstalled by hand.

The fixture is that shape: an app bundle whose declared executable is MISSING
while a program of the same name runs at another path inside the same bundle.
The processes are real (copies of a small sleeper compiled here, started at the
fixture paths and stopped by the pid captured at spawn), the ancestry chain is
the real (pid, start) the kernel reports, and only the code-signing TEAM is
substituted, because no fixture can carry a Developer ID signature. One case
leaves the kernel query real, to prove that a program with no signing team (the
sleeper is signed ad hoc, as the linker signs everything it builds) never
passes as the holder.

WHY A COMPILED SLEEPER AND NOT A COPY OF /bin/sleep: the system binaries are
arm64e on Apple silicon, and the kernel kills a copy of one run from anywhere
else (measured here: SIGKILL at exec, with copyfile and with cp alike).

NO FIXTURE PROGRAM EVER RUNS FROM A PATH WITH A `.app` COMPONENT. A first
version of this suite ran its copies inside a fixture `Vendor.app`, and macOS
put "Vendor.app is damaged and can't be opened" on the CEO's screen. So the
fixture bundle is a plain directory, `app_bundle` is substituted to name it as
the bundle, and `run_at` refuses any path with a `.app` component before it
starts anything. `app_bundle` itself is a pure function of a path and is
tested on strings alone, with no file and no process behind them.

Each acceptance has refusals beside it: the wrong team, the wrong file name,
the right name outside the bundle. And `holder_problems` names a holder that is
gone before anybody's land meets it.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import operator_fences as F            # noqa: E402
import operator_fences_admin as A      # noqa: E402

TEAM = "FIXTURE123"
SLEEPER_C = "#include <unistd.h>\nint main(void) { sleep(60); return 0; }\n"


def build_sleeper(where):
    """A program that sleeps, which this kernel will run from any path."""
    if sys.platform != "darwin":
        return "/bin/sleep"
    cc = shutil.which("cc")
    if not cc:
        raise RuntimeError("this suite builds its fixture program with cc, and there is no cc on PATH; "
                           "a copy of /bin/sleep is killed at exec on Apple silicon (arm64e)")
    src = os.path.join(where, "sleeper.c")
    out = os.path.join(where, "sleeper")
    with open(src, "w") as fh:
        fh.write(SLEEPER_C)
    subprocess.run([cc, "-o", out, src], check=True, capture_output=True, timeout=120)
    return out


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_dir = tempfile.mkdtemp(prefix="fences-holders-build.")
        cls.sleeper = build_sleeper(cls.build_dir)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.build_dir, True)

    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="fences-holders."))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        # The bundle is a PLAIN directory (see the header: no `.app` is ever
        # executed from), named as the bundle by the substituted app_bundle.
        self.bundle = os.path.join(self.tmp, "VendorBundle")
        # Where LAND_LEASE_HOLDERS says it is: NOT created. The update moved it.
        self.declared = os.path.join(self.bundle, "Contents", "Resources", "codex")
        # Where the update put it.
        self.moved = os.path.join(self.bundle, "Contents", "Resources", "codex-cli", "CodexCLI",
                                  "Contents", "MacOS", "codex")
        self.procs = []
        saved = {n: getattr(F, n, None) for n in ("signing_team", "bundle_team", "file_signing_team",
                                                  "app_bundle")}

        def restore():
            for n, v in saved.items():
                if v is None:
                    if hasattr(F, n):
                        delattr(F, n)
                else:
                    setattr(F, n, v)
        self.addCleanup(restore)
        self.addCleanup(self.stop_all)
        real_app_bundle = saved["app_bundle"]
        bundle = self.bundle
        F.app_bundle = lambda path: bundle if (path or "").startswith(bundle + os.sep) else (
            real_app_bundle(path) if real_app_bundle else "")

    def place(self, path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        shutil.copyfile(self.sleeper, path)
        os.chmod(path, 0o755)
        return path

    def run_at(self, path):
        """Start a real process at `path` and return its (pid, start) link."""
        if any(part.endswith(".app") for part in path.split(os.sep)):
            raise AssertionError("refusing to run %s: a program inside a `.app` directory can make macOS "
                                 "show a dialog on this Mac's screen" % path)
        p = subprocess.Popen([path] + (["60"] if self.sleeper == "/bin/sleep" else []))
        self.procs.append(p)
        for _ in range(100):
            info = F.proc(p.pid)
            if info and F.proc_path(p.pid) == os.path.realpath(path):
                return (p.pid, info["start"])
            time.sleep(0.02)
        self.fail("the fixture process at %s never reported its own path" % path)

    def stop_all(self):
        # Only the processes this case started, by the pid captured at spawn.
        for p in self.procs:
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
                    p.wait(timeout=5)

    def conf(self, exe=None):
        return {"HOLDERS": "codex=%s" % (exe or self.declared)}

    def teams(self, by_pid=None, bundle=TEAM, files=None):
        """Substitute the signing teams: `by_pid` {pid: team} for running
        processes, `bundle` for the bundle, `files` {path: team} on disk."""
        by_pid = by_pid or {}
        files = files or {}
        F.signing_team = lambda pid: by_pid.get(int(pid), "")
        F.bundle_team = lambda b: bundle if b == self.bundle else ""
        F.file_signing_team = lambda path: files.get(os.path.realpath(path), "")


class MovedHolder(Base):
    def test_moved_inside_its_bundle_and_signed_by_its_team_is_the_holder(self):
        # THE 2026-09-30 CASE. Red on the code before this fix: the declared
        # path matched no ancestor and the holder was refused.
        self.assertFalse(os.path.exists(self.declared))
        link = self.run_at(self.place(self.moved))
        self.teams(by_pid={link[0]: TEAM})
        who = F.declared_holder("codex", self.conf(), chain=[link])
        self.assertNotIn("error", who, who)
        self.assertEqual(who["pid"], link[0])
        self.assertEqual(who["start"], link[1])
        self.assertEqual(who["executable"], os.path.realpath(self.moved))
        self.assertEqual(who["declared"], os.path.realpath(self.declared))

    def test_found_among_other_ancestors(self):
        # The holder is an ancestor somewhere up the chain, not the first link:
        # the shell Codex runs a command in sits between it and Git.
        shell = self.run_at(self.place(os.path.join(self.tmp, "bin", "zsh")))
        link = self.run_at(self.place(self.moved))
        self.teams(by_pid={link[0]: TEAM, shell[0]: TEAM})
        who = F.declared_holder("codex", self.conf(), chain=[shell, link])
        self.assertEqual(who.get("pid"), link[0], who)

    def test_the_wrong_signing_team_does_not_pass(self):
        link = self.run_at(self.place(self.moved))
        self.teams(by_pid={link[0]: "SOMEONEELSE"})
        who = F.declared_holder("codex", self.conf(), chain=[link])
        self.assertIn("error", who)
        self.assertIn("no longer exists", who["error"])

    def test_no_signing_team_does_not_pass(self):
        link = self.run_at(self.place(self.moved))
        self.teams(by_pid={})
        self.assertIn("error", F.declared_holder("codex", self.conf(), chain=[link]))

    def test_the_apps_other_programs_do_not_pass(self):
        # The app itself is Codex's parent and is signed by the same team; it
        # must not be taken for Codex.
        main = self.run_at(self.place(os.path.join(self.bundle, "Contents", "MacOS", "Vendor")))
        helper = self.run_at(self.place(os.path.join(self.bundle, "Contents", "Helpers", "codex-helper")))
        self.teams(by_pid={main[0]: TEAM, helper[0]: TEAM})
        self.assertIn("error", F.declared_holder("codex", self.conf(), chain=[main, helper]))

    def test_the_right_name_outside_the_bundle_does_not_pass(self):
        link = self.run_at(self.place(os.path.join(self.tmp, "elsewhere", "codex")))
        self.teams(by_pid={link[0]: TEAM})
        self.assertIn("error", F.declared_holder("codex", self.conf(), chain=[link]))

    def test_a_declared_path_in_no_bundle_has_no_fallback(self):
        link = self.run_at(self.place(os.path.join(self.tmp, "elsewhere", "codex")))
        self.teams(by_pid={link[0]: TEAM})
        exe = os.path.join(self.tmp, "usr-local-bin", "codex")
        self.assertIn("error", F.declared_holder("codex", self.conf(exe), chain=[link]))

    def test_the_real_kernel_gives_a_team_less_program_no_identity(self):
        # No substitution of the process side: the kernel's own answer for an
        # ad hoc signed program is "no team", so it cannot pass even with the
        # right name in the right bundle.
        link = self.run_at(self.place(self.moved))
        F.bundle_team = lambda b: TEAM
        self.assertEqual(F.signing_team(link[0]), "")
        self.assertIn("error", F.declared_holder("codex", self.conf(), chain=[link]))

    def test_the_exact_declared_path_still_wins_without_asking_for_a_signature(self):
        self.place(self.declared)
        link = self.run_at(self.declared)

        def no_signature_needed(_pid):
            raise AssertionError("the exact declared path must not need a signature check")
        F.signing_team = no_signature_needed
        who = F.declared_holder("codex", self.conf(), chain=[link])
        self.assertEqual(who.get("executable"), os.path.realpath(self.declared), who)
        self.assertNotIn("declared", who)


class BundleOfAPath(unittest.TestCase):
    """app_bundle on strings only: no file, no process."""

    def test_the_outermost_app_directory(self):
        self.assertEqual(F.app_bundle("/Applications/ChatGPT.app/Contents/Resources/codex"),
                         "/Applications/ChatGPT.app")
        self.assertEqual(F.app_bundle("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/"
                                      "Contents/MacOS/codex"), "/Applications/ChatGPT.app")

    def test_no_bundle(self):
        self.assertEqual(F.app_bundle("/usr/local/bin/codex"), "")
        self.assertEqual(F.app_bundle("/Applications/ChatGPT.app"), "")
        self.assertEqual(F.app_bundle("/opt/.app/codex"), "")
        self.assertEqual(F.app_bundle(""), "")


class Reported(Base):
    def test_a_moved_holder_is_a_note_naming_where_it_is(self):
        self.place(self.moved)
        self.teams(files={os.path.realpath(self.moved): TEAM})
        problems, notes = A.holder_problems("/repo", self.conf())
        self.assertEqual(problems, [])
        self.assertEqual(len(notes), 1, notes)
        self.assertIn(os.path.realpath(self.moved), notes[0])
        self.assertIn("LAND_LEASE_HOLDERS", notes[0])

    def test_a_holder_gone_with_nothing_to_take_its_place_is_a_problem(self):
        self.place(self.moved)
        self.teams(files={})          # nothing on disk is signed by the bundle's team
        problems, notes = A.holder_problems("/repo", self.conf())
        self.assertEqual(notes, [])
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("is gone", problems[0])

    def test_a_launcher_behind_its_declaration_is_a_problem(self):
        self.place(self.declared)
        self.teams()
        problems, _notes = A.holder_problems("/repo", self.conf(),
                                             {"LAND_LEASE_HOLDERS": "codex=%s" % self.moved})
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("operator-fences.sh install", problems[0])

    def fenced_repo(self, holders, state="on"):
        """A repository whose launcher is `state` and names `holders`."""
        repo = os.path.join(self.tmp, "repo")
        subprocess.run(["git", "init", "-q", repo], check=True, capture_output=True)
        hooks = os.path.join(repo, ".git", "hooks")
        os.makedirs(hooks, exist_ok=True)
        with open(os.path.join(hooks, "reference-transaction"), "w") as fh:
            fh.write("#!/bin/sh\n# %s\nOPERATOR_FENCES_STATE=\"%s\"\nOPERATOR_FENCES_HOLDERS=\"%s\"\n"
                     % (F.MARKER, state, holders))
        return repo

    def notice(self, repo):
        said = []
        saved = A.say
        A.say = said.append
        try:
            self.assertEqual(A.cmd_holders_notice({}, [repo]), 0)
        finally:
            A.say = saved
        return said

    def test_the_session_start_notice_names_a_moved_holder(self):
        self.place(self.moved)
        self.teams(files={os.path.realpath(self.moved): TEAM})
        said = self.notice(self.fenced_repo("codex=%s" % self.declared))
        self.assertEqual(len(said), 1, said)
        self.assertIn(os.path.realpath(self.moved), said[0])

    def test_the_session_start_notice_is_silent_when_every_holder_is_in_place(self):
        self.place(self.declared)
        self.teams()
        self.assertEqual(self.notice(self.fenced_repo("codex=%s" % self.declared)), [])

    def test_the_session_start_notice_says_nothing_for_a_launcher_that_is_off(self):
        self.teams()
        self.assertEqual(self.notice(self.fenced_repo("codex=%s" % self.declared, state="off")), [])

    def test_every_holder_in_place_says_nothing(self):
        self.place(self.declared)
        self.teams()
        self.assertEqual(A.holder_problems("/repo", self.conf(),
                                           {"LAND_LEASE_HOLDERS": "codex=%s" % self.declared}), ([], []))


if __name__ == "__main__":
    unittest.main()
