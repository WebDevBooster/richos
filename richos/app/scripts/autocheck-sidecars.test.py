#!/usr/bin/env python3
"""autocheck-sidecars.test.py — a merge into main that changes a guard script refreshes the
engine's gitignored .sha256 sidecars by itself, so the integrity probe's BR4 stays green.

The sidecars are gitignored (engine/.gitignore), so a merge brings new script bytes and leaves
the old hashes: BR4 went red on 2026-10-05 after lands that missed the manual install.sh step.
autocheck's post-merge hook now runs the engine's own scripts/hooks/install.sh when
old..new touches richos/engine/scripts/hooks/, and runs nothing otherwise.

Fixture repositories only: a real copy of this engine, committed, with HOME and the Claude config
directory redirected into the fixture so the installer can never touch the operator's pointer,
launchd or settings. The real main checkout is never read or written.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("autocheck_fixture", HERE / "autocheck.test.py")
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

HOOK = "richos/engine/scripts/hooks/scan-secrets.sh"
OTHER = "richos/engine/scripts/hooks/notice-unlanded-branches.sh"


class SidecarRefresh(base.Fixture):
    def setUp(self):
        super().setUp()
        home = self.base / "home"
        (home / ".claude").mkdir(parents=True)
        self.home = home
        self.env.update(HOME=str(home), CLAUDE_CONFIG_DIR=str(home / ".claude"),
                        RICHOS_LAUNCH_AGENTS_DIR=str(home / "LaunchAgents"))
        for name in ("CLAUDE_PROJECT_DIR", "RICHOS_ENTITY_ROOT", "RICHOS_ENGINE_ROOT", "CLAUDE_PLUGIN_ROOT"):
            self.env.pop(name, None)

    def make_with_engine(self):
        self.make(install=False)
        link = self.repo / "richos/engine"
        link.unlink()
        shutil.copytree(base.ENGINE, link, symlinks=True,
                        ignore=shutil.ignore_patterns("*.sha256", ".git", "node_modules", "target"))
        (self.repo / ".git/info/exclude").write_text("")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "engine")
        out = self.run_(["bash", "richos/engine/scripts/hooks/install.sh"])
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.install()

    def probe(self):
        engine = self.repo / "richos/engine"
        env = dict(self.env, RICHOS_ENTITY_ROOT=str(engine))
        return subprocess.run(["bash", str(engine / "scripts/hooks/contract-integrity-probe.sh")], cwd=engine,
                              env=env, capture_output=True, text=True, timeout=base.HANG_GUARD)

    def mismatches(self):
        """The registered scripts whose bytes no longer match their sidecar: BR4's own test."""
        import hashlib
        bad = []
        hooks = self.repo / "richos/engine/scripts/hooks"
        for sidecar in sorted(hooks.glob("*.sh.sha256")):
            script = sidecar.with_suffix("")
            want = sidecar.read_text().split()[0]
            if hashlib.sha256(script.read_bytes()).hexdigest() != want:
                bad.append(script.name)
        return bad

    def test_a_merge_that_changes_a_hook_script_leaves_the_sidecars_matching(self):
        self.make_with_engine()
        self.assertEqual(self.mismatches(), [])
        self.assertTrue((self.repo / (HOOK + ".sha256")).is_file())
        self.branch_with("hook-change", HOOK, (self.repo / HOOK).read_text() + "\n# changed by the branch\n")
        self.git("merge", "--no-ff", "-m", "land hook-change", "hook-change")
        self.assertIn("# changed by the branch", (self.repo / HOOK).read_text())
        self.assertEqual(self.mismatches(), [])
        probe = self.probe()
        self.assertNotIn("MODIFIED since install", probe.stdout + probe.stderr)

    def test_a_fast_forward_that_changes_a_hook_script_refreshes_too(self):
        self.make_with_engine()
        self.branch_with("hook-change", HOOK, (self.repo / HOOK).read_text() + "\n# fast\n")
        self.git("merge", "--ff-only", "hook-change")
        self.assertEqual(self.mismatches(), [])

    def test_a_merge_that_touches_no_hook_script_does_not_run_the_installer(self):
        self.make_with_engine()
        witness = self.repo / "richos/engine/scripts/hooks/install.sh"
        first, rest = witness.read_text().split("\n", 1)
        witness.write_text(first + '\n: > "$HOME/installer-ran"\n' + rest)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "witness the installer", "--no-verify")
        self.branch_with("app-change", "richos/app/src/thing.txt", "fine, better\n")
        self.git("merge", "--no-ff", "-m", "land app-change", "app-change")
        self.assertFalse((self.home / "installer-ran").exists())
        self.branch_with("hook-change", OTHER, (self.repo / OTHER).read_text() + "\n# touched\n")
        self.git("merge", "--no-ff", "-m", "land hook-change", "hook-change")
        self.assertTrue((self.home / "installer-ran").exists())
        self.assertEqual(self.mismatches(), [])

    def test_a_refresh_that_fails_is_recorded_for_the_lead(self):
        self.make_with_engine()
        install = self.repo / "richos/engine/scripts/hooks/install.sh"
        install.write_text("#!/usr/bin/env bash\nexit 7\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "broken installer", "--no-verify")
        self.branch_with("hook-change", HOOK, (self.repo / HOOK).read_text() + "\n# x\n")
        self.git("merge", "--no-ff", "-m", "land hook-change", "hook-change")
        self.assertIn("hook sidecars were not refreshed", self.recorded())


if __name__ == "__main__":
    result = unittest.main(exit=False, verbosity=2).result
    sys.exit(0 if result.wasSuccessful() else 1)
