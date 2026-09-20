#!/usr/bin/env python3
"""Real local Git remotes exercise reservation and compare-and-swap publication.

The publishing tests substitute build/upload commands. No release, signing identity
or installed app is touched by this suite.
"""
import contextlib
from datetime import datetime, timezone
import importlib.util
import hashlib
import inspect
import io
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



class GitFixture(unittest.TestCase):
    """The fixture repository and remote. NO test methods live here.

    Split out from `GitTests` when `StableChannelTests` needed the same fixture:
    subclassing a class that holds test methods re-runs every one of them, which cost
    this suite 28 duplicate cases and ~50 s on a gate that runs in every build.
    """
    FIXTURE_IDENT = "Fixture <fixture@example.invalid>"

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        # A commit identity exported by whatever shell runs this suite overrides every
        # level of git config, so without this the identity assertions below would be
        # about the operator instead of the fixture. patch.dict restores the pops.
        environment = patch.dict(os.environ, {})
        environment.start()
        self.addCleanup(environment.stop)
        for name in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME",
                     "GIT_COMMITTER_EMAIL", "EMAIL"):
            os.environ.pop(name, None)
        root = Path(self.temp.name)
        self.remote = root / "remote.git"
        self.repo = root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "--bare", "-q", str(self.remote)], check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        self.patcher = patch.object(n, "ROOT", self.repo)
        self.patcher.start()
        self.addCleanup(self.patcher.stop)
        # Three things in `promote` now reach GitHub rather than this fixture's local
        # remote: the ruleset read-back, the "does the rolling release exist yet" probe,
        # and the asset upload. Defaulted to no-ops here so every test below still
        # describes Git behavior alone -- a test that wants to inspect them patches
        # again locally, and `patch.object` nests. Before the channel moved to a release
        # tag, `promote` ran no external command at all, which is why these defaults did
        # not exist and why six tests reached for the operator's real `gh` when it did.
        for name, result in (("verify_repository_rules", None), ("succeeds", True),
                             ("execute", None)):
            patcher = patch.object(n, name, return_value=result)
            setattr(self, f"stub_{name}", patcher.start())
            self.addCleanup(patcher.stop)
        n.git("config", "user.name", "Fixture")
        n.git("config", "user.email", "fixture@example.invalid")
        n.git("config", "core.hooksPath", "/dev/null")
        n.git("remote", "add", "origin", str(self.remote))
        for name, text in {
            n.MANIFEST: '[package]\nname = "richos-tauri"\nversion = "5.1.0"\n',
            n.LOCK: 'version = 3\n\n[[package]]\nname = "richos-tauri"\nversion = "5.1.0"\n\n[[package]]\nname = "dependency"\nversion = "1.0.0"\n',
            n.CONFIG: n.json_text({"plugins": {"updater": {"endpoints": ["https://stable.invalid/latest.json"]}}}),
            Path("richos/engine/VERSION"): "1.2.0\n",
            # A stand-in for the commit's own release tooling. `stable_plan` refuses a
            # commit whose `nightly.py` predates the stable channel, because that commit
            # cannot build a stable release of itself -- so the fixture carries the marker
            # that check looks for.
            n.APP / "scripts/nightly.py": "CHANNEL_ENDPOINTS = {}  # fixture tooling\n",
        }.items():
            file = self.repo / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(text)
        n.git("add", ".")
        n.git("commit", "-qm", "source")
        n.git("push", "-q", "origin", "main")
        self.source = n.git("rev-parse", "HEAD")

    def plan(self, **kwargs):
        return n.plan(now=NOW, **kwargs)

    def manifest(self, info):
        return {"version": info["version"], "platforms": {"darwin-aarch64": {
            "url": f"https://github.com/{n.REPO}/releases/download/{info['tag']}/RichOS.app.tar.gz",
            "signature": "fixture"}}}

    def reserve(self):
        return n.prepare(self.plan())

    def author_and_committer(self, commit):
        return n.git("show", "-s", "--format=%an <%ae>|%cn <%ce>", commit)


class GitTests(GitFixture):
    def test_release_commits_carry_the_checkouts_configured_identity(self):
        # The release is the operator's act, from the operator's checkout. A commit
        # saying otherwise is false, and the machine's push guard refuses it.
        both = f"{self.FIXTURE_IDENT}|{self.FIXTURE_IDENT}"
        info = self.reserve()
        self.assertEqual(self.author_and_committer(info["build_commit"]), both)
        self.assertEqual(self.author_and_committer(n.promote(info, self.manifest(info))), both)

    def test_retired_hard_coded_identity_would_fail_that_check(self):
        """Positive control for the test above.

        Until 2026-09-17 `commit_files` set these four variables itself, which is how
        `5df42d006c45` came to be authored `nightly@users.noreply.github.com` and why
        the first nightly never published. Supplying them through the environment is
        exactly what the old code did, so this proves the assertion bites instead of
        passing because both sides happen to read the same config.
        """
        retired = {"GIT_AUTHOR_NAME": "RichOS nightly", "GIT_COMMITTER_NAME": "RichOS nightly",
                   "GIT_AUTHOR_EMAIL": "nightly@users.noreply.github.com",
                   "GIT_COMMITTER_EMAIL": "nightly@users.noreply.github.com"}
        with patch.dict(os.environ, retired):
            info = self.reserve()
        observed = self.author_and_committer(info["build_commit"])
        self.assertNotEqual(observed, f"{self.FIXTURE_IDENT}|{self.FIXTURE_IDENT}")
        self.assertEqual(observed, "RichOS nightly <nightly@users.noreply.github.com>|"
                                   "RichOS nightly <nightly@users.noreply.github.com>")

    def test_unconfigured_identity_refuses_before_a_number_is_reserved(self):
        n.git("config", "--unset", "user.name")
        n.git("config", "--unset", "user.email")
        with patch.dict(os.environ, {"GIT_CONFIG_GLOBAL": os.devnull,
                                     "GIT_CONFIG_SYSTEM": os.devnull,
                                     "GIT_CONFIG_NOSYSTEM": "1"}):
            # git's hostname fallback would otherwise mint `user@host.home` here and
            # `git commit-tree` would accept it; the push guard denies that too.
            with self.assertRaisesRegex(ValueError, "no configured commit identity"):
                self.plan()
        self.assertEqual([tag for tag in n.remote_tags() if "nightly" in tag], [])

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
        later = n.plan(force=True,
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
        # The immutable release gets its manifest last of its own assets, and only then
        # is anything verified. The channel comes after that, and last of everything:
        # `verify-assets` is what earns the right to move it.
        manifest_upload = calls[-3]
        self.assertEqual(manifest_upload[:5], ("gh", "release", "upload", info["tag"], "--repo"))
        self.assertTrue(manifest_upload[-1].endswith("/latest.json"))
        self.assertEqual(calls[-2][2], "verify-assets")
        # Last call of the whole publish: the rolling channel release's asset, replaced.
        self.assertEqual(calls[-1][:6], ("gh", "release", "upload", n.CHANNEL_TAG,
                                         "--repo", n.REPO))
        self.assertIn("--clobber", calls[-1])
        self.assertTrue(calls[-1][-1].endswith("/latest.json"))
        oid, current = n.channel()
        self.assertEqual(current, info)
        self.assertEqual(json.loads(n.git("show", f"{oid}:latest.json")), self.manifest(info))
        # The branch ruleset is read back on the way through, not merely documented.
        self.stub_verify_repository_rules.assert_called_once_with()

    def fake_execute(self, out, calls=None):
        calls = calls if calls is not None else []
        def fake(*args, **kwargs):
            calls.append(args)
            if args[0] == "bash" and args[2] == "app":
                (out / "latest.json").write_text(n.json_text(self.manifest_for(out)))
        return fake, calls

    def manifest_for(self, out):
        # `out` is not part of `info`; the candidate's own recorded info supplies the
        # version. Read it back rather than threading `info` through every caller.
        info = json.loads((out / "build-info.json").read_text())
        return self.manifest(info)

    def test_build_stops_before_any_app_upload_or_channel_move(self):
        info = self.reserve()
        out = Path(self.temp.name) / "build-only"
        fake, calls = self.fake_execute(out)
        with patch.object(n, "execute", side_effect=fake), patch.object(n, "promote") as promote:
            n.build(info, out)
        stages = [c[2] for c in calls if c[0] == "bash"]
        # Not "verify-assets": that is finish()'s, and nothing here reached it.
        self.assertEqual(stages, ["engine", "verify-engine", "app"])
        uploads = [c for c in calls if c[:3] == ("gh", "release", "upload")]
        # Only the engine asset -- never the app archive, the .sig or latest.json.
        self.assertEqual(len(uploads), 1)
        self.assertTrue(uploads[0][-1].endswith(".tar.gz"))
        promote.assert_not_called()
        self.assertEqual(n.channel(), (None, None))
        self.assertTrue((out / n.CANDIDATE_MANIFEST).exists())

    def test_finish_refuses_a_tampered_candidate(self):
        info = self.reserve()
        out = Path(self.temp.name) / "tampered"
        fake, _ = self.fake_execute(out)
        with patch.object(n, "execute", side_effect=fake):
            n.build(info, out)
        # Something touched a staged, already-recorded file after `build` ran --
        # here the manifest `finish` is about to upload as `latest.json`.
        (out / "latest.json").write_text("not what was signed")
        with patch.object(n, "execute", side_effect=fake), patch.object(n, "promote") as promote:
            with self.assertRaisesRegex(ValueError, "changed since it was built"):
                n.finish(info, out)
            promote.assert_not_called()
        self.assertEqual(n.channel(), (None, None))

    def test_finish_publishes_an_untouched_candidate(self):
        """Positive control for the test above: the same candidate, unmodified, publishes."""
        info = self.reserve()
        out = Path(self.temp.name) / "untouched"
        fake, calls = self.fake_execute(out)
        with patch.object(n, "execute", side_effect=fake):
            n.build(info, out)
        with patch.object(n, "execute", side_effect=fake):
            n.finish(info, out)
        stages = [c[2] for c in calls if c[0] == "bash"]
        self.assertEqual(stages, ["engine", "verify-engine", "app", "verify-assets"])
        oid, current = n.channel()
        self.assertEqual(current, info)
        self.assertEqual(json.loads(n.git("show", f"{oid}:latest.json")), self.manifest(info))

    def test_finish_refuses_when_source_is_no_longer_an_ancestor_of_main(self):
        info = self.reserve()
        out = Path(self.temp.name) / "stale-main"
        fake, _ = self.fake_execute(out)
        with patch.object(n, "execute", side_effect=fake):
            n.build(info, out)
        # main gets force-pushed to an unrelated, parentless history -- one that does
        # NOT contain the built source as an ancestor -- exactly what a walker being
        # asked to wait for a QA verdict is exposed to.
        empty_tree = n.git("hash-object", "-t", "tree", "/dev/null")
        orphan = n.git("commit-tree", empty_tree, input="rewritten history\n")
        n.git("push", "-q", "--force", "origin", f"{orphan}:main")
        with patch.object(n, "execute", side_effect=fake), patch.object(n, "promote") as promote:
            with self.assertRaises(subprocess.CalledProcessError):
                n.finish(info, out)
            promote.assert_not_called()
        self.assertEqual(n.channel(), (None, None))

    def test_the_rolling_channel_release_is_created_once_then_only_replaced(self):
        """`--verify-tag` is why the create can only run after the tag has moved."""
        self.stub_succeeds.return_value = False       # no `nightly` release yet
        first = self.reserve()
        calls = []
        with patch.object(n, "execute", side_effect=lambda *a, **k: calls.append(a)):
            n.promote(first, self.manifest(first))
        create = [c for c in calls if c[:3] == ("gh", "release", "create")]
        self.assertEqual(len(create), 1)
        self.assertEqual(create[0][3], n.CHANNEL_TAG)
        for flag in ("--verify-tag", "--prerelease", "--latest=false"):
            self.assertIn(flag, create[0])
        # The tag it verifies must already be on the remote by the time create runs.
        self.assertEqual(n.git("ls-remote", "origin", n.CHANNEL_REF).split()[1], n.CHANNEL_REF)

        self.stub_succeeds.return_value = True        # it exists from here on
        n.git("checkout", "-q", "main")
        # The source has not moved, so plan() reports "already published" for it.
        second = n.prepare(self.plan(force=True))
        calls.clear()
        with patch.object(n, "execute", side_effect=lambda *a, **k: calls.append(a)):
            n.promote(second, self.manifest(second))
        self.assertEqual([c for c in calls if c[:3] == ("gh", "release", "create")], [])
        self.assertIn("--clobber", [c for c in calls if c[:3] == ("gh", "release", "upload")][0])

    def test_finish_repairs_an_asset_the_channel_already_names(self):
        """A crash between the lease and the upload must be re-runnable, not a rollback.

        Moving the channel tag and replacing the release asset are two acts, not one.
        Lease first means a crash in between leaves the tag naming a version whose asset
        was never replaced -- users stay on the older one. Re-running `finish` has to
        repair that, and `promote`'s ordering checks would otherwise call it a move
        backwards and refuse. Without the repair arm this state is unrecoverable by
        re-running the documented command.
        """
        info = self.reserve()
        with patch.object(n, "execute", side_effect=subprocess.CalledProcessError(1, "gh")):
            with self.assertRaises(subprocess.CalledProcessError):
                n.promote(info, self.manifest(info))
        # The lease was taken and the tag DID move; only the asset is missing.
        leased, current = n.channel()
        self.assertEqual(current, info)

        calls = []
        with patch.object(n, "execute", side_effect=lambda *a, **k: calls.append(a)):
            repaired = n.promote(info, self.manifest(info))
        self.assertEqual(repaired, leased, "the repair must not move the channel again")
        self.assertEqual(n.channel()[0], leased)
        uploads = [c for c in calls if c[:3] == ("gh", "release", "upload")]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(uploads[0][3], n.CHANNEL_TAG)
        self.assertIn("--clobber", uploads[0])

    def test_the_repair_arm_does_not_excuse_a_genuine_rollback(self):
        """Positive control for the test above: only the SAME candidate is repairable."""
        old = self.reserve()
        n.git("checkout", "-q", "main")
        new = self.reserve()
        with patch.object(n, "execute"):
            n.promote(new, self.manifest(new))
            with self.assertRaisesRegex(ValueError, "newer"):
                n.promote(old, self.manifest(old))

    def test_release_equals_build_then_finish(self):
        """`release` (== `publish`) and an explicit `build` + `finish` reach the same state."""
        fused_info = self.reserve()
        fused_out = Path(self.temp.name) / "fused"
        fused_fake, fused_calls = self.fake_execute(fused_out)
        with patch.object(n, "execute", side_effect=fused_fake):
            n.publish(fused_info, fused_out)
        fused_stages = [c[2] for c in fused_calls if c[0] == "bash"]
        fused_oid, fused_channel = n.channel()

        n.git("checkout", "-q", "main")
        # The source has not moved, so plan() would otherwise report "already
        # published" for it -- force a second nightly of the same source, same as
        # test_successful_source_skipped_but_manual_force_allocates.
        split_info = n.prepare(self.plan(force=True))
        split_out = Path(self.temp.name) / "split"
        split_fake, split_calls = self.fake_execute(split_out)
        with patch.object(n, "execute", side_effect=split_fake):
            n.build(split_info, split_out)
        with patch.object(n, "execute", side_effect=split_fake):
            n.finish(split_info, split_out)
        split_stages = [c[2] for c in split_calls if c[0] == "bash"]
        split_oid, split_channel = n.channel()

        self.assertEqual(fused_stages, split_stages)
        self.assertEqual(fused_channel["version"], fused_info["version"])
        self.assertEqual(split_channel["version"], split_info["version"])
        self.assertEqual(json.loads(n.git("show", f"{fused_oid}:latest.json")),
                         self.manifest(fused_info))
        self.assertEqual(json.loads(n.git("show", f"{split_oid}:latest.json")),
                         self.manifest(split_info))


class OneCodePathTests(unittest.TestCase):
    """The smoke and the release run the SAME functions, and that is not a convention.

    T3 Code has the same smoke in spirit and it has already drifted from the release it
    claims to exercise -- `release.yml:795` passes two positional arguments in one order,
    `release-smoke.ts:328-331` passes them in the other. Nothing told them. These cases
    are what tells us.
    """

    def smoke(self):
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()) as out:
            n.release_smoke(Path(tmp))
            # The fixtures are gone before the directory that held them is (CEO §54).
            self.assertEqual(list(Path(tmp).iterdir()), [])
        return out.getvalue()

    def test_the_smoke_reaches_every_registered_release_only_step(self):
        self.smoke()
        unreached = sorted(name for name, calls in n.RELEASE_STEP_CALLS.items() if not calls)
        self.assertEqual(unreached, [])
        self.assertTrue(n.RELEASE_STEPS, "no release-only step is registered at all")

    def test_a_registered_step_the_smoke_never_calls_turns_the_gate_red(self):
        """PROVED BY DEFEAT, which is the only way a guarantee like this is worth stating.

        Everything else here asserts the mechanism's answer today. This asserts it would
        NOTICE -- register a release-only step, do not smoke it, and the build fails
        naming the function. Without this case, the completeness check could be deleted
        and every other case in this class would still pass.
        """
        @n.release_step
        def decoy_step_nothing_smokes(value):
            return value

        self.addCleanup(n.RELEASE_STEPS.pop, "decoy_step_nothing_smokes", None)
        self.addCleanup(n.RELEASE_STEP_CALLS.pop, "decoy_step_nothing_smokes", None)
        with self.assertRaises(ValueError) as caught:
            self.smoke()
        self.assertIn("decoy_step_nothing_smokes", str(caught.exception))
        self.assertIn("never reached", str(caught.exception))

    def test_the_real_release_path_calls_the_steps_rather_than_copying_them(self):
        """Every registered step is named in the body of the code a real release runs.

        The failure this prevents is not a rename -- Python catches that with a
        NameError. It is the one T3 has: somebody re-implements a step inline "just for
        this path", the smoke keeps exercising the old function, and both are green.
        A step no real release entry point mentions is a step the smoke is alone with.
        """
        real = "".join(inspect.getsource(f) for f in
                       (n.plan, n.prepare, n.promote, n.build, n.finish, n.stable_plan))
        for name in n.RELEASE_STEPS:
            with self.subTest(step=name):
                self.assertIn(name, real,
                              f"{name} is registered as a release-only step but no real "
                              "release path calls it")

    def test_the_smoke_exercises_refusals_and_not_only_happy_paths(self):
        """A step that only ever sees valid input proves its refusals compile."""
        refused = [line for line in self.smoke().splitlines() if "refused:" in line]
        self.assertGreaterEqual(len(refused), 20, refused)


class PromotionRecordTests(unittest.TestCase):
    """The COMMITTED record, not a fixture of one.

    Every other case about promotions passes `promotion_decision` text it wrote itself,
    which proves the parser and says nothing about the file the command actually reads.
    A record that has stopped being readable JSON refuses every stable release, and the
    place to find that out is here rather than on the morning he decides to promote one.
    """

    def record(self):
        return json.loads((n.ROOT / n.PROMOTIONS).read_text())

    def test_the_committed_record_is_a_list_this_command_can_read(self):
        self.assertIsInstance(self.record(), list)

    def test_every_recorded_decision_is_one_this_command_accepts(self):
        """Each entry is fed to the real check, so a malformed one cannot sit unnoticed.

        Empty today, and that is the correct state: nothing has been promoted. This case
        is written for the day it is not empty, and it costs nothing until then.
        """
        text = (n.ROOT / n.PROMOTIONS).read_text()
        for entry in self.record():
            with self.subTest(tag=entry.get("tag")):
                accepted = n.promotion_decision(entry["tag"], text)
                self.assertEqual(accepted["tag"], entry["tag"])
                self.assertTrue(accepted["words"].strip())
                # A promotion names a NIGHTLY, never a stable tag or a branch.
                n.nightly_key(entry["tag"].removeprefix("v"))


class StableChannelTests(GitFixture):
    """Stable is a REBUILD of a published nightly's commit, never its bytes re-tagged.

    T3's sentence, which is the thing being copied (`release.yml:44-47`): *"Manual stable
    releases build the commit of the latest published nightly, so stable only ever ships
    a build that nightly users have already run."*
    """

    def setUp(self):
        super().setUp()
        # The base fixture compiles in a deliberately wrong endpoint so the nightly cases
        # can assert it gets replaced. A STABLE release keeps the checked-in one, so for
        # these cases the fixture carries what the real tree carries.
        (self.repo / n.CONFIG).write_text(n.json_text(
            {"plugins": {"updater": {"endpoints": [n.STABLE_ENDPOINT]}}}))
        n.git("add", ".")
        n.git("commit", "-qm", "stable endpoint")
        n.git("push", "-q", "origin", "main")
        self.source = n.git("rev-parse", "HEAD")

    DECISION = [{"tag": "v5.1.0-nightly.20260911.1", "decided_on": "2026-09-20",
                 "words": "fixture standing in for his sentence"}]

    def publish_a_nightly(self):
        """A published nightly in the fixture remote, with its provenance in its tag."""
        info = n.prepare(self.plan())
        n.git("checkout", "-q", "main")
        return info

    def test_a_stable_release_rebuilds_the_nightlys_commit_with_its_own_version(self):
        info = self.publish_a_nightly()
        plan = n.stable_plan(info["tag"], n.json_text(self.DECISION), now=NOW)
        self.assertEqual(plan["source_commit"], self.source)
        self.assertEqual(plan["channel"], "stable")
        # The tree's own version, NOT the nightly's prerelease version.
        self.assertEqual(plan["version"], "5.1.0")
        self.assertEqual(plan["tag"], "v5.1.0")
        self.assertEqual(plan["endpoint"], n.STABLE_ENDPOINT)
        self.assertEqual(plan["promoted_from"], info["tag"])
        self.assertEqual(plan["promoted_from_version"], info["version"])
        # His decision travels into the release's provenance, so the record of why this
        # shipped is inside the thing that shipped.
        self.assertEqual(plan["promotion_words"], self.DECISION[0]["words"])

    def test_the_stable_build_compiles_in_the_stable_endpoint_and_no_prerelease_version(self):
        """The two facts that make re-tagging a nightly's bytes a broken stable release."""
        info = self.publish_a_nightly()
        plan = n.stable_plan(info["tag"], n.json_text(self.DECISION), now=NOW)
        files = n.release_files(plan, (self.repo / n.MANIFEST).read_text(),
                                (self.repo / n.LOCK).read_text(),
                                (self.repo / n.CONFIG).read_text())
        compiled = json.loads(files[str(n.CONFIG)])["plugins"]["updater"]["endpoints"]
        self.assertEqual(compiled, [n.STABLE_ENDPOINT])
        self.assertNotIn("nightly", compiled[0])
        self.assertIn('version = "5.1.0"\n', files[str(n.MANIFEST)])
        self.assertNotIn("-nightly.", files[str(n.MANIFEST)])
        self.assertNotIn("-nightly.", files[str(n.LOCK)])

    def test_no_decision_of_his_means_no_stable_release(self):
        """CEO §69, and the substitutes it names are each refused here by construction."""
        info = self.publish_a_nightly()
        with self.assertRaisesRegex(ValueError, "no promotion decision"):
            n.stable_plan(info["tag"], "[]", now=NOW)
        # A decision about a DIFFERENT nightly is not a decision about this one.
        other = n.json_text([{**self.DECISION[0], "tag": "v5.1.0-nightly.20260911.9"}])
        with self.assertRaisesRegex(ValueError, "no promotion decision"):
            n.stable_plan(info["tag"], other, now=NOW)

    def test_a_tag_that_is_not_one_of_our_nightlies_is_refused(self):
        self.publish_a_nightly()
        n.git("tag", "v9.9.9-nightly.20260911.1", "main")
        n.git("push", "-q", "origin", "v9.9.9-nightly.20260911.1")
        decision = n.json_text([{**self.DECISION[0], "tag": "v9.9.9-nightly.20260911.1"}])
        with self.assertRaises(ValueError):
            n.stable_plan("v9.9.9-nightly.20260911.1", decision, now=NOW)

    def test_a_version_that_already_shipped_cannot_ship_again(self):
        info = self.publish_a_nightly()
        n.git("tag", "v5.1.0", "main")
        n.git("push", "-q", "origin", "v5.1.0")
        with self.assertRaisesRegex(ValueError, "already exists"):
            n.stable_plan(info["tag"], n.json_text(self.DECISION), now=NOW)

    def test_a_stable_release_never_calls_itself_a_nightly(self):
        """The label was hard-coded "Nightly" and reached two public surfaces.

        The releases page title and notes, and the `--notes` string `make-release.sh`
        puts in the bundle. A stable release announcing itself as "Nightly 1.2.0" is the
        kind of defect nobody finds in a test of the version number, because the version
        number is right.
        """
        info = self.publish_a_nightly()
        self.assertEqual(n.describe_release(info), f"Nightly {info['version']}")
        plan = n.stable_plan(info["tag"], n.json_text(self.DECISION), now=NOW)
        label = n.describe_release(plan)
        self.assertEqual(label, "RichOS 5.1.0")
        self.assertNotIn("Nightly", label)
        self.assertNotIn("nightly", label)

    def test_publishing_stable_flips_the_release_and_leaves_the_nightly_channel_alone(self):
        """The channel move for stable is GitHub's own `latest` pointer, nothing else.

        Assets go up while the release is still a PRERELEASE -- invisible to every
        installed copy however long that takes -- and one `gh release edit` is the flip.
        The nightly channel must not move: promoting a build to stable says nothing about
        what nightly users should receive.
        """
        info = self.publish_a_nightly()
        plan = n.stable_plan(info["tag"], n.json_text(self.DECISION), now=NOW)
        before, _ = n.channel()
        with patch.object(n, "execute") as execute:
            n.promote_stable(plan)
        flips = [call.args for call in execute.call_args_list]
        self.assertEqual(len(flips), 1, flips)
        self.assertEqual(flips[0][:3], ("gh", "release", "edit"))
        self.assertIn("--latest", flips[0])
        self.assertIn("--prerelease=false", flips[0])
        self.assertIn("v5.1.0", flips[0])
        self.assertEqual(n.channel()[0], before, "the nightly channel must not move")
        # And the rule that keeps branches off the public repository is re-read first.
        self.assertTrue(self.stub_verify_repository_rules.called)


class RepositoryRuleTests(unittest.TestCase):
    """The publisher reads the branch ruleset back before it publishes anything.

    On 2026-09-16 at 21:57Z a Codex run authenticated as the repository owner added
    `refs/heads/nightly-channel` to the `main-only` ruleset's exclusion list so this
    publisher could push a channel branch; at 02:53Z the first nightly created it and
    the public repository page read "2 Branches" (CEO 2026-09-13, ceo-decisions 38:
    *"what is anything other than the `main` doing on GitHub?"*). The ruleset refused
    nothing because nothing asked it. These tests are about the asking.
    """
    GOOD = {"id": 23194738, "name": "main-only", "target": "branch",
            "enforcement": "active", "bypass_actors": [],
            "conditions": {"ref_name": {"include": ["~ALL"], "exclude": ["refs/heads/main"]}},
            "rules": [{"type": "creation"}, {"type": "update"}]}

    def check(self, ruleset=None, listing=None):
        """Run the real read-back against a ruleset the fake `gh` serves."""
        ruleset = self.GOOD if ruleset is None else ruleset
        def fake_run(*args, **kwargs):
            self.assertEqual(args[:2], ("gh", "api"))
            if args[2].endswith("/rulesets"):
                return json.dumps(self.GOOD if listing is None else listing)
            self.assertEqual(args[2], f"repos/{n.REPO}/rulesets/{ruleset['id']}")
            return json.dumps(ruleset)
        with patch.object(n, "run", side_effect=fake_run):
            n.verify_repository_rules()

    def test_the_rule_as_the_ceo_set_it_passes(self):
        """Negative control: without this, every assertion below could pass vacuously."""
        self.check(listing=[self.GOOD])

    def test_a_widened_exclusion_list_refuses_the_publish(self):
        """THE positive control, and the exact shape of what happened on 2026-09-16."""
        widened = json.loads(json.dumps(self.GOOD))
        widened["conditions"]["ref_name"]["exclude"].append("refs/heads/nightly-channel")
        with self.assertRaisesRegex(ValueError, "exempt branches"):
            self.check(widened, listing=[widened])

    def test_every_other_way_to_make_the_ban_a_no_op_also_refuses(self):
        """An exclusion list that reads correctly is not on its own the rule."""
        cases = {
            "enforcement": ({"enforcement": "evaluate"}, "not 'active'"),
            "bypass": ({"bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole"}]},
                       "bypass actor"),
            "narrowed": ({"conditions": {"ref_name": {"include": ["refs/heads/release/*"],
                                                      "exclude": ["refs/heads/main"]}}},
                         r"not \['~ALL'\]"),
            "creation": ({"rules": [{"type": "update"}]}, "does not restrict creation"),
            "update": ({"rules": [{"type": "creation"}]}, "does not restrict update"),
        }
        for name, (override, expected) in cases.items():
            with self.subTest(case=name):
                broken = {**json.loads(json.dumps(self.GOOD)), **override}
                with self.assertRaisesRegex(ValueError, expected):
                    self.check(broken, listing=[broken])

    def test_a_missing_or_duplicated_ruleset_refuses(self):
        for listing in ([], [self.GOOD, {**self.GOOD, "id": 99}]):
            with self.subTest(count=len(listing)):
                with self.assertRaisesRegex(ValueError, "exactly one branch ruleset"):
                    self.check(listing=listing)

    def test_a_ruleset_of_another_name_or_target_is_not_this_rule(self):
        for other in ({"name": "something-else"}, {"target": "tag"}):
            with self.subTest(**other):
                with self.assertRaisesRegex(ValueError, "exactly one branch ruleset"):
                    self.check(listing=[{**self.GOOD, **other}])


class ChannelShapeTests(unittest.TestCase):
    def test_the_channel_is_a_release_tag_and_its_endpoint_is_a_release_asset(self):
        """The CEO's rule, asserted rather than left to a comment.

        `main` and release tags, nothing else. A regression here does not break a test
        somewhere downstream -- it silently puts a branch back on the public repository,
        which is the thing that has now happened once.
        """
        self.assertTrue(n.CHANNEL_REF.startswith("refs/tags/"), n.CHANNEL_REF)
        self.assertNotIn("refs/heads/", n.CHANNEL_REF)
        self.assertEqual(n.CHANNEL_REF, f"refs/tags/{n.CHANNEL_TAG}")
        self.assertEqual(
            n.ENDPOINT,
            f"https://github.com/{n.REPO}/releases/download/{n.CHANNEL_TAG}/latest.json")
        self.assertNotIn("raw.githubusercontent.com", n.ENDPOINT)


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
# verify-assets must not fetch or require the live channel yet. Since 2026-09-17 the
# channel endpoint is ITSELF a `/releases/download/` URL ending in `latest.json`, so
# the old substring test would have passed it and then served the immutable release's
# manifest in its place. The channel is named exactly and refused by name.
if url == os.environ['FAKE_CHANNEL_ENDPOINT'] or '/releases/download/' not in url:
    # make-release.sh discards curl's stderr, so a refusal is recorded where a test
    # can see it rather than only inferred from the command failing.
    # No backslash escape here: this script is written from a triple-quoted literal,
    # so an escape would be expanded by the test rather than by this file.
    with open(os.environ['FAKE_REFUSALS'], 'a') as log:
        print(url, file=log)
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
                    'FAKE_REMOTE': str(self.remote), 'FAKE_CARGO_ARGS': str(root / 'cargo-args'),
                    'FAKE_CHANNEL_ENDPOINT': n.ENDPOINT,
                    'FAKE_REFUSALS': str(root / 'refused-urls')}
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

    def test_the_channel_endpoint_is_a_different_url_from_the_releases_own_manifest(self):
        """Positive control for the test above, and it stopped being free on 2026-09-17.

        Both URLs are now `https://github.com/<repo>/releases/download/<tag>/latest.json`
        and differ only in the tag, where before one was a `raw.githubusercontent.com`
        branch URL. `verify-assets` passing above therefore no longer proves on its own
        that it left the channel alone -- so this proves the fixture still tells them
        apart, by running the one command that DOES fetch the channel and watching it
        be refused by name.
        """
        refusals = Path(self.env['FAKE_REFUSALS'])
        self.assertEqual(self.call('verify-assets').returncode, 0)
        self.assertFalse(refusals.exists(), 'verify-assets must not fetch the channel')
        result = self.call('verify-release')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(refusals.read_text().split(), [n.ENDPOINT],
                         'the channel endpoint, and only it, must be refused by name')

    def test_the_compiled_endpoint_is_read_from_the_publisher_not_respelled(self):
        """make-release.sh compiles the endpoint in; nightly.py publishes to it.

        Two spellings of one URL is a silent mismatch waiting to happen, and the
        endpoint check inside make-release.sh would then be comparing the script
        against itself. `plan` printing exactly `nightly.ENDPOINT` is the evidence
        that the script asks the publisher.
        """
        result = self.call('plan')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f'releases/download/{n.CHANNEL_TAG}/latest.json', result.stdout)
        self.assertNotIn('raw.githubusercontent.com', result.stdout)

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
