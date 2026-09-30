#!/usr/bin/env python3
"""dependency-pins.test.py — a branch commit that changes a file the engine's
verification-input selector pins (richos/engine/scripts/lib/verification-dependencies.json)
is refused unless the same change renews that pin.

Every commit case is a throwaway repository with the real shim, installer, autocheck.py and
dependency-pins.py, installed as git hooks, and a small declaration that pins a node source, a
hook-reader source and a repository-rooted external reader. Nothing touches this repository or
its hooks, and no change is under richos/app, so autocheck's lint is never reached.

  REFUSED  a changed node source, hook-reader source or external reader whose pin was not
           renewed; the same through `commit -a`; one committed earlier without the hooks;
           a pin typed wrong by hand
  PASSES   the same change with the pin renewed by the command the refusal names; a change to
           a file nothing pins
  PARITY   the digests the renewal writes are the ones verification_inputs.py accepts, for a
           CRLF node source, a hook-reader source and an external reader
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
AUTOCHECK = Path(os.environ.get("AUTOCHECK_UNDER_TEST", HERE / "autocheck"))
ENGINE_LIB = HERE.parents[1] / "engine" / "scripts" / "lib"
HANG_GUARD = 600

DECLARATION = "richos/engine/scripts/lib/verification-dependencies.json"
NODE = "richos/engine/scripts/reader.sh"
HOOK = "richos/engine/scripts/lib/helper.sh"
EXTERNAL = "richos/tools/external.py"
FREE = "richos/engine/scripts/unpinned.sh"
RENEW = "python3 richos/app/scripts/autocheck/dependency-pins.py --renew"


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dependency-pins-")
        self.base = Path(self.tmp.name)
        (self.base / "gitconfig").write_text("[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n"
                                              "[init]\n\tdefaultBranch = main\n")
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(("GIT_", "RICHOS_AUTOCHECK"))}
        self.env.update(GIT_CONFIG_GLOBAL=str(self.base / "gitconfig"), GIT_CONFIG_NOSYSTEM="1",
                        RICHOS_ESCALATION_LEDGER=str(self.base / "ledger.jsonl"),
                        RICHOS_AUTOCHECK_PROOF_ROOT=str(self.base / "proof-runs"))
        self.repo = self.base / "repo"

    def tearDown(self):
        self.tmp.cleanup()

    def run_(self, argv, env=None):
        return subprocess.run(argv, cwd=self.repo, env=env or self.env, capture_output=True, text=True,
                              timeout=HANG_GUARD)

    def git(self, *args, expect=0):
        result = self.run_(["git", *args])
        if expect is not None:
            self.assertEqual(result.returncode, expect, f"git {' '.join(args)}\n{result.stdout}{result.stderr}")
        return result

    def write(self, rel, text, newline=None):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "w", newline=newline) as handle:
            handle.write(text)

    def head(self):
        return self.git("rev-parse", "HEAD").stdout.strip()

    def renew(self, *paths):
        out = self.run_(["python3", "richos/app/scripts/autocheck/dependency-pins.py", "--renew", *paths])
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        return out

    def make(self, node_newline=None):
        """A repository whose declaration pins NODE, HOOK and EXTERNAL by their current bytes,
        committed on main with the hooks installed, and a branch checked out."""
        self.repo.mkdir()
        self.write(NODE, "echo reader v1\n", newline=node_newline)
        self.write(HOOK, "helper() { :; }\n")
        self.write(EXTERNAL, "print('external v1')\n")
        self.write(FREE, "echo nobody pins me\n")
        self.write(DECLARATION, json.dumps({
            "schema": 1, "status": "fixture", "config_keys": [],
            "nodes": {"scripts/reader.sh": {
                "source": "scripts/reader.sh", "sha256": "0" * 64, "evidence": "fixture reader",
                "keys": [], "edges": [],
                "external": [{"root": "repository", "path": "richos/tools/external.py",
                              "sha256": "0" * 64, "evidence": "fixture external reader"}]}},
            "units": {},
            "hook_readers": {"scripts/hook-reader.test.sh": {
                "commands": [], "evidence": "fixture hook reader",
                "sources": {"scripts/lib/helper.sh": "0" * 64}}},
        }, indent=2) + "\n")
        dest = self.repo / "richos/app/scripts/autocheck"
        dest.mkdir(parents=True)
        for name in ("autocheck.py", "shim.sh", "install.sh", "dependency-pins.py"):
            if (AUTOCHECK / name).is_file():
                shutil.copy(AUTOCHECK / name, dest / name)
        self.git("init", "-q")
        self.renew(NODE, HOOK, EXTERNAL)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")
        out = self.run_(["bash", str(AUTOCHECK / "install.sh"), str(self.repo)])
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.git("checkout", "-q", "-b", "feature")

    def refused(self, out, path):
        text = out.stdout + out.stderr
        self.assertIn("COMMIT REFUSED: a changed file is pinned in verification-dependencies.json", text)
        self.assertIn(path, text)
        self.assertIn(f"{RENEW} {path}", text)
        return text


class Refused(Fixture):
    def test_a_changed_node_source_without_its_pin_renewed_is_refused(self):
        # 2026-09-30: 108 stale pins reached main from ten branches whose every commit passed.
        self.make()
        before = self.head()
        self.write(NODE, "echo reader v2\n")
        self.git("add", "-A")
        text = self.refused(self.git("commit", "-m", "edit a pinned reader", expect=1), NODE)
        self.assertIn('node "scripts/reader.sh"', text)
        self.assertIn("added lines for a new config key", text)
        self.assertEqual(self.head(), before)

    def test_a_changed_hook_reader_source_is_refused(self):
        self.make()
        self.write(HOOK, "helper() { echo changed; }\n")
        self.git("add", "-A")
        text = self.refused(self.git("commit", "-m", "edit a hook reader", expect=1), HOOK)
        self.assertIn('hook reader "scripts/hook-reader.test.sh"', text)

    def test_a_changed_external_reader_is_refused(self):
        self.make()
        self.write(EXTERNAL, "print('external v2')\n")
        self.git("add", "-A")
        text = self.refused(self.git("commit", "-m", "edit an external reader", expect=1), EXTERNAL)
        self.assertIn("external reader", text)

    def test_commit_all_is_checked_on_the_index_it_commits(self):
        self.make()
        before = self.head()
        self.write(NODE, "echo reader via -a\n")
        self.refused(self.git("commit", "-a", "-m", "edit through -a", expect=1), NODE)
        self.assertEqual(self.head(), before)

    def test_a_stale_pin_committed_earlier_without_the_hooks_refuses_the_next_commit(self):
        # The land diffs the whole branch, so the whole branch is asked, not only the staged files.
        self.make()
        self.write(NODE, "echo reader v2\n")
        self.git("add", "-A")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "-q", "-m", "skipped the hooks")
        self.write(FREE, "echo an innocent change\n")
        self.git("add", "-A")
        self.refused(self.git("commit", "-m", "innocent", expect=1), NODE)

    def test_a_pin_typed_wrong_by_hand_is_refused(self):
        self.make()
        path = self.repo / DECLARATION
        path.write_text(path.read_text().replace(
            json.loads(path.read_text())["hook_readers"]["scripts/hook-reader.test.sh"]["sources"]
            ["scripts/lib/helper.sh"], "f" * 64))
        self.git("add", "-A")
        self.refused(self.git("commit", "-m", "retype a pin", expect=1), HOOK)


class Passes(Fixture):
    def test_the_same_change_with_its_pin_renewed_by_the_named_command_passes(self):
        self.make()
        self.write(NODE, "echo reader v2\n")
        self.write(HOOK, "helper() { echo changed; }\n")
        self.write(EXTERNAL, "print('external v2')\n")
        out = self.renew(NODE, HOOK, EXTERNAL)
        self.assertIn("3 pin(s) renewed", out.stdout)
        self.git("add", "-A")
        before = self.head()
        self.git("commit", "-q", "-m", "edit and renew")
        self.assertNotEqual(self.head(), before)

    def test_a_change_nothing_pins_passes(self):
        self.make()
        self.write(FREE, "echo still nobody pins me\n")
        self.git("add", "-A")
        out = self.git("commit", "-m", "unpinned")
        self.assertNotIn("COMMIT REFUSED", out.stdout + out.stderr)


class Parity(Fixture):
    """The digests --renew writes are the ones the selector itself checks."""

    def test_renewed_pins_satisfy_verification_inputs(self):
        self.make(node_newline="\r\n")               # a CRLF source: the selector reads it as text
        sys.path.insert(0, str(ENGINE_LIB))
        try:
            import verification_inputs as vi
        finally:
            sys.path.pop(0)
        engine = self.repo / "richos/engine"
        declaration = json.loads((self.repo / DECLARATION).read_text())
        vi.Dependencies(engine, declaration).node("scripts/reader.sh")   # raises Unsupported on a mismatch
        snapshot = vi.Snapshot(engine, "WORKTREE")
        vi.hook_reader(declaration["hook_readers"]["scripts/hook-reader.test.sh"], snapshot.read)
        self.write(EXTERNAL, "print('changed without renewal')\n")
        with self.assertRaisesRegex(vi.Unsupported, "changed external reader"):
            vi.Dependencies(engine, declaration).node("scripts/reader.sh")


if __name__ == "__main__":
    unittest.main(verbosity=2)
