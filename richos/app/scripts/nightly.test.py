#!/usr/bin/env python3
"""Real local Git remotes exercise reservation and compare-and-swap publication.

The publishing tests substitute build/upload commands. No release, signing identity
or installed app is touched by this suite.
"""
from datetime import datetime, timezone
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("nightly", Path(__file__).with_name("nightly.py"))
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)
NOW = datetime(2026, 9, 11, 23, 59, tzinfo=timezone.utc)


class VersionTests(unittest.TestCase):
    def test_numeric_suffix_and_day_reset(self):
        tags = [f"v5.1.0-nightly.20260911.{i}" for i in range(1, 12)]
        tags += ["v5.2.0-nightly.20260911.999", "v5.1.0-nightly.20260910.999"]
        self.assertEqual(n.next_version("5.1.0", "20260911", tags), "5.1.0-nightly.20260911.12")
        self.assertEqual(n.next_version("5.1.0", "20260912", tags), "5.1.0-nightly.20260912.1")
        self.assertGreater(n.nightly_key("5.1.0-nightly.20260911.10"), n.nightly_key("5.1.0-nightly.20260911.9"))

    def test_invalid_versions_and_dates(self):
        for version in ("5.1.0-nightly.20260911.01", "5.1.0-nightly.20260911.0",
                        "05.1.0-nightly.20260911.1", "5.1.0-nightly.20260230.1", "5.1.0"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                n.nightly_key(version)

    def test_cadence_and_expiry(self):
        self.assertTrue(n.due("schedule", n.DAILY_SCHEDULE, "", NOW))
        self.assertTrue(n.due("workflow_dispatch", "", "", NOW))
        self.assertFalse(n.due("schedule", n.BURST_SCHEDULE, "", NOW))
        self.assertTrue(n.due("schedule", n.BURST_SCHEDULE, "2026-09-12T00:00:00Z", NOW))
        self.assertFalse(n.due("schedule", n.BURST_SCHEDULE, NOW.isoformat(), NOW))
        with self.assertRaises(ValueError):
            n.due("schedule", n.BURST_SCHEDULE, "2026-09-12", NOW)
        with self.assertRaises(ValueError):
            n.due("schedule", "bogus", "", NOW)


class GitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.remote = root / "remote.git"
        self.repo = root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "--bare", "-q", str(self.remote)], check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        self.patcher = patch.object(n, "ROOT", self.repo)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        n.git("config", "user.name", "Fixture")
        n.git("config", "user.email", "fixture@example.invalid")
        n.git("config", "core.hooksPath", "/dev/null")
        n.git("remote", "add", "origin", str(self.remote))
        for name, text in {
            n.MANIFEST: '[package]\nname = "richos-tauri"\nversion = "5.1.0"\n',
            n.LOCK: 'version = 3\n\n[[package]]\nname = "richos-tauri"\nversion = "5.1.0"\n\n[[package]]\nname = "dependency"\nversion = "1.0.0"\n',
            n.CONFIG: n.json_text({"plugins": {"updater": {"endpoints": ["https://stable.invalid/latest.json"]}}}),
            Path("richos/engine/VERSION"): "1.2.0\n",
        }.items():
            file = self.repo / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(text)
        n.git("add", ".")
        n.git("commit", "-qm", "source")
        n.git("push", "-q", "origin", "main")
        self.source = n.git("rev-parse", "HEAD")

    def plan(self, **kwargs):
        return n.plan("workflow_dispatch", "", "", now=NOW, **kwargs)

    def manifest(self, info):
        return {"version": info["version"], "platforms": {"darwin-aarch64": {
            "url": f"https://github.com/{n.REPO}/releases/download/{info['tag']}/RichOS.app.tar.gz",
            "signature": "fixture"}}}

    def reserve(self):
        return n.prepare(self.plan())

    def test_source_commit_is_complete_and_main_unchanged(self):
        info = self.reserve()
        self.assertEqual(n.git("rev-parse", "main"), self.source)
        self.assertEqual(n.git("rev-parse", "HEAD^"), self.source)
        self.assertEqual(n.git("status", "--porcelain"), "")
        self.assertEqual(n.tomllib.loads((self.repo / n.MANIFEST).read_text())["package"]["version"], info["version"])
        lock = n.tomllib.loads((self.repo / n.LOCK).read_text())["package"]
        self.assertEqual(lock[0]["version"], info["version"])
        self.assertEqual(lock[1]["version"], "1.0.0")
        conf = json.loads((self.repo / n.CONFIG).read_text())
        self.assertEqual(conf["plugins"]["updater"]["endpoints"], [n.ENDPOINT])
        self.assertEqual(json.loads((self.repo / n.PROVENANCE).read_text())["source_commit"], self.source)
        self.assertIn(info["tag"], n.remote_tags())
        n.git("checkout", "-q", "main")
        self.assertEqual(self.plan()["version"], "5.1.0-nightly.20260911.2")

    def test_two_plans_cannot_reuse_a_number(self):
        first, second = self.plan(), self.plan()
        n.prepare(first)
        n.git("checkout", "-q", "main")
        with self.assertRaisesRegex(ValueError, "reserved"):
            n.prepare(second)
        self.assertEqual(n.git("rev-parse", "HEAD"), self.source)

    def test_tag_created_during_allocation_cannot_be_overwritten(self):
        info = self.plan()
        original = n.commit_files

        def competing_tag(*args):
            commit = original(*args)
            n.git("push", "origin", f"{self.source}:refs/tags/{info['tag']}")
            return commit

        with patch.object(n, "commit_files", side_effect=competing_tag):
            with self.assertRaises(subprocess.CalledProcessError):
                n.prepare(info)
        self.assertEqual(n.git("rev-parse", "HEAD"), self.source)
        self.assertEqual(n.git("ls-remote", "origin", f"refs/tags/{info['tag']}").split()[0], self.source)

    def test_dirty_and_released_sources_are_refused(self):
        (self.repo / "untracked").write_text("dirty")
        with self.assertRaisesRegex(ValueError, "clean"):
            self.plan()
        (self.repo / "untracked").unlink()
        n.git("push", "origin", "HEAD:refs/tags/v5.1.0")
        with self.assertRaisesRegex(ValueError, "bump"):
            self.plan()

    def test_plan_is_invalid_if_source_changes(self):
        info = self.plan()
        n.git("commit", "--allow-empty", "-qm", "next source")
        with self.assertRaisesRegex(ValueError, "source changed"):
            n.prepare(info)

    def test_successful_source_skipped_but_manual_force_allocates(self):
        info = self.reserve()
        n.promote(info, self.manifest(info))
        n.git("checkout", "-q", "main")
        self.assertFalse(self.plan()["build"])
        self.assertEqual(self.plan(force=True)["version"], "5.1.0-nightly.20260911.2")
        later = n.plan("workflow_dispatch", "", "", force=True,
                       now=datetime(2026, 9, 12, tzinfo=timezone.utc))
        self.assertEqual(later["version"], "5.1.0-nightly.20260912.1")

    def test_promotion_never_rolls_back(self):
        old = self.reserve()
        n.git("checkout", "-q", "main")
        new = self.reserve()
        n.promote(new, self.manifest(new))
        with self.assertRaisesRegex(ValueError, "newer"):
            n.promote(old, self.manifest(old))
        _, current = n.channel()
        self.assertEqual(current["version"], new["version"])

    def test_promotion_rejects_wrong_manifest(self):
        info = self.reserve()
        bad = self.manifest(info)
        bad["version"] = "5.1.0"
        with self.assertRaisesRegex(ValueError, "version"):
            n.promote(info, bad)
        bad = self.manifest(info)
        bad["platforms"]["darwin-aarch64"]["url"] = "https://elsewhere.invalid/archive"
        with self.assertRaisesRegex(ValueError, "immutable"):
            n.promote(info, bad)
        self.assertEqual(n.channel(), (None, None))

    def test_promotion_compare_and_swap_rejects_race(self):
        info = self.reserve()
        original_commit = n.commit_files
        def competing_writer(files, parent, message):
            planned = original_commit(files, parent, message)
            concurrent = original_commit({"race.txt": "another publisher"}, parent, "competing write")
            n.git("push", "origin", f"{concurrent}:{n.CHANNEL_REF}")
            return planned
        with patch.object(n, "commit_files", side_effect=competing_writer):
            with self.assertRaises(subprocess.CalledProcessError):
                n.promote(info, self.manifest(info))
        ref = n.git("ls-remote", "origin", n.CHANNEL_REF).split()[0]
        self.assertEqual(n.git("show", f"{ref}:race.txt"), "another publisher")

    def test_plan_rejects_divergent_source(self):
        n.git("commit", "--allow-empty", "-qm", "new main")
        advanced_source = n.git("rev-parse", "HEAD")
        info = self.reserve()
        self.assertEqual(info["source_commit"], advanced_source)
        n.promote(info, self.manifest(info))
        n.git("checkout", "--detach", self.source)
        with self.assertRaises(subprocess.CalledProcessError):
            self.plan(force=True)

    def test_failed_build_or_verification_never_moves_channel(self):
        info = self.reserve()
        for failure in ("engine", "verify-engine", "app", "verify-assets"):
            with self.subTest(failure=failure):
                out = Path(self.temp.name) / failure
                def fake(*args, **kwargs):
                    if args[0] == "bash" and args[2] == failure:
                        raise subprocess.CalledProcessError(1, args)
                with patch.object(n, "execute", side_effect=fake), patch.object(n, "promote") as promote:
                    with self.assertRaises(subprocess.CalledProcessError):
                        n.publish(info, out)
                    promote.assert_not_called()
                self.assertEqual(n.channel(), (None, None))

    def test_upload_failure_does_not_move_channel(self):
        info = self.reserve()
        def fake(*args, **kwargs):
            if args[:3] == ("gh", "release", "upload"):
                raise subprocess.CalledProcessError(1, args)
        with patch.object(n, "execute", side_effect=fake), patch.object(n, "promote") as promote:
            with self.assertRaises(subprocess.CalledProcessError):
                n.publish(info, Path(self.temp.name) / "upload-failure")
            promote.assert_not_called()

    def test_publish_order_and_channel_manifest(self):
        info = self.reserve()
        out = Path(self.temp.name) / "publish"
        calls = []
        def fake(*args, **kwargs):
            calls.append(args)
            if args[0] == "bash" and args[2] == "app":
                (out / "latest.json").write_text(n.json_text(self.manifest(info)))
        with patch.object(n, "execute", side_effect=fake):
            n.publish(info, out)
        stages = [c[2] for c in calls if c[0] == "bash"]
        self.assertEqual(stages, ["engine", "verify-engine", "app", "verify-assets"])
        self.assertIn("--prerelease", calls[1])
        self.assertIn("--latest=false", calls[1])
        self.assertTrue(calls[-2][-1].endswith("/latest.json"))
        self.assertEqual(calls[-1][2], "verify-assets")
        oid, current = n.channel()
        self.assertEqual(current, info)
        self.assertEqual(json.loads(n.git("show", f"{oid}:latest.json")), self.manifest(info))


class ReleaseScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.scripts = root / 'richos/app/scripts'
        self.scripts.mkdir(parents=True)
        for name in ('make-release.sh', 'nightly.py'):
            shutil.copy(Path(__file__).with_name(name), self.scripts / name)
        self.config = root / n.CONFIG
        self.config.parent.mkdir(parents=True)
        (root / 'richos/engine').mkdir()
        (root / 'richos/engine/VERSION').write_text('1.2.0\n')
        self.version = '5.1.0-nightly.20260911.10'
        (root / n.MANIFEST).write_text(f'[package]\nversion = "{self.version}"\n')
        self.config.write_text(n.json_text({'plugins': {'updater': {'endpoints': [n.ENDPOINT]}}}))
        self.out = root / 'out'
        self.out.mkdir()
        self.remote = root / 'remote'
        self.remote.mkdir()
        self.bin = root / 'bin'
        self.bin.mkdir()
        curl = self.bin / 'curl'
        curl.write_text('''#!/usr/bin/env python3
import os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
dest = Path(args[args.index('-o') + 1])
url = args[-1]
# verify-assets must not fetch or require the live channel yet.
if '/releases/download/' not in url:
    raise SystemExit('unexpected channel fetch before promotion')
source = Path(os.environ['FAKE_REMOTE']) / url.rsplit('/', 1)[-1]
if source.exists():
    shutil.copy(source, dest)
    print('200', end='')
else:
    print('404', end='')
''')
        curl.chmod(0o755)
        cargo = self.bin / 'cargo'
        cargo.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$FAKE_CARGO_ARGS"\nexit "${FAKE_CARGO_EXIT:-0}"\n')
        cargo.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
                    'FAKE_REMOTE': str(self.remote), 'FAKE_CARGO_ARGS': str(root / 'cargo-args')}
        self.assets()

    def assets(self, manifest_version=None):
        values = {'latest.json': n.json_text({'version': manifest_version or self.version}),
                  'RichOS.app.tar.gz': 'fixture artifact', 'RichOS.app.tar.gz.sig': 'fixture signature'}
        sums = ''
        for name, body in values.items():
            (self.remote / name).write_text(body)
            sums += f'{hashlib.sha256(body.encode()).hexdigest()}  {name}\n'
        (self.out / 'SHA256SUMS').write_text(sums)

    def call(self, command, **env):
        return subprocess.run(['bash', str(self.scripts / 'make-release.sh'), command,
                               '--out', str(self.out)], env={**self.env, **env},
                              capture_output=True, text=True)

    def test_nightly_plan_requires_nightly_endpoint(self):
        result = self.call('plan')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(n.ENDPOINT, result.stdout)
        self.config.write_text(n.json_text({'plugins': {'updater': {'endpoints': ['https://stable.invalid']}}}))
        result = self.call('plan')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('updater endpoint', result.stderr)

    def test_assets_verified_before_channel_exists(self):
        result = self.call('verify-assets')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = Path(self.env['FAKE_CARGO_ARGS']).read_text()
        self.assertIn('verify_update_manifest', args)
        self.assertIn('--locked', args)
        self.assertIn('published bytes, version and updater signature verified', result.stdout)

    def test_changed_bytes_and_missing_assets_refuse(self):
        (self.remote / 'RichOS.app.tar.gz').write_text('corrupt')
        self.assertNotEqual(self.call('verify-assets').returncode, 0)
        self.assets()
        (self.remote / 'latest.json').unlink()
        self.assertNotEqual(self.call('verify-assets').returncode, 0)

    def test_wrong_version_and_signature_refuse(self):
        self.assets('5.1.0-nightly.20260911.9')
        self.assertNotEqual(self.call('verify-assets').returncode, 0)
        self.assets()
        self.assertNotEqual(self.call('verify-assets', FAKE_CARGO_EXIT='1').returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
