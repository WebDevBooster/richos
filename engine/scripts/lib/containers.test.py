#!/usr/bin/env python3
"""containers.test.py — the container reaper, proved in both directions.

TWO KINDS OF CASE, AND THE SPLIT IS DELIBERATE

  C1..C9   need no Docker at all. Ownership precedence, the protect/delete
           asymmetry, and every degradation path are decided on synthetic
           inventories, so they run on any machine and in CI.
  D1..D4   start REAL containers and run the REAL lifecycle. They are the only
           evidence that the thing actually removes a container, and they SKIP
           (never fail) where Docker is missing or its daemon is down, which is
           the same degradation the mechanism itself promises.

The D cases label every container they create with a run-unique tag and remove
it in tearDown even when the assertion fails. A test for a reaper that leaks
containers would be its own best counter-example.
"""

import os
import subprocess
import sys
import time
import unittest
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import containers as ct           # noqa: E402
import workspaces as ws           # noqa: E402

TEST_IMAGE = os.environ.get("RICHOS_CONTAINER_TEST_IMAGE", "alpine:latest")
TAG_LABEL = "sh.richos.test-run"


def docker_usable():
    ok, _why = ct.docker_available()
    if not ok:
        return False
    r = subprocess.run(["docker", "image", "inspect", TEST_IMAGE],
                       capture_output=True, text=True)
    return r.returncode == 0


DOCKER = docker_usable()
SKIP = "docker is unavailable, or %s is not present locally — the reaper's own\n" \
       "  degradation path says this must not be a failure" % TEST_IMAGE


_SPEC_SUITE = []


def _spec_suite():
    """The workspace spec's own suite (Env, Base and its helpers), loaded from
    `workspaces.test.py` — a filename `import` cannot spell. Reused rather than
    reimplemented so the lifecycle these cases drive is the one the spec suite
    drives, not a second fixture that could drift away from it. Loaded once:
    two copies would be two sandboxes disagreeing about the same state."""
    if not _SPEC_SUITE:
        import importlib.util
        path = os.path.join(HERE, "workspaces.test.py")
        spec = importlib.util.spec_from_file_location("workspaces_spec_suite", path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules["workspaces_spec_suite"] = mod
        spec.loader.exec_module(mod)
        _SPEC_SUITE.append(mod)
    return _SPEC_SUITE[0]


def fake(name, labels=None, binds=None, running=False, size=0, age_days=0):
    """One container as inventory() returns it."""
    return {"id": name[:12], "name": name, "image": "img", "created": "",
            "created_epoch": int(time.time()) - age_days * 86400,
            "running": running, "status": "running" if running else "exited",
            "finished": "", "size_rw": size, "size_root": size,
            "labels": labels or {}, "binds": binds or []}


# ---------------------------------------------------------------------------
# C — ownership and the asymmetry, on any machine
# ---------------------------------------------------------------------------

class Ownership(unittest.TestCase):

    def test_C1_label_is_the_strongest_claim(self):
        """The engine's own label outranks everything else on the container."""
        c = fake("x", labels={ct.WORKSPACE_LABEL: "/w/a",
                              ct.COMPOSE_DIR_LABEL: "/w/b"}, binds=["/w/c"])
        self.assertEqual(ct.declared_owner(c), ("/w/a", "label"))

    def test_C2_compose_working_dir_is_a_declaration(self):
        """The real historical residue is attributable ONLY through this label.
        Measured on the founder's machine: agent-af36c9abcc76937ab-redis-1
        carries working_dir=/Users/alex/ab/deeply/.claude/worktrees/
        agent-af36c9abcc76937ab, six weeks after its agent ended."""
        c = fake("agent-af36c9abcc76937ab-redis-1",
                 labels={ct.COMPOSE_DIR_LABEL: "/ab/deeply/.claude/worktrees/agent-af36"})
        path, kind = ct.declared_owner(c)
        self.assertEqual(kind, "compose")
        self.assertTrue(path.endswith("agent-af36"))

    def test_C3_a_bind_mount_never_authorizes_deletion(self):
        """THE SAFETY ARGUMENT. Mounting a directory is how a person runs a
        container against a checkout by hand, so it is evidence of a
        relationship and never of disposability."""
        c = fake("richos-ci86", binds=["/w/live", "/ab/richos"])
        self.assertEqual(ct.declared_owner(c), (None, None))
        self.assertIn(("/w/live", "mount"), ct.owner_claims(c))

    def test_C4_but_a_bind_mount_does_protect(self):
        """Every kind of evidence is believed when it says 'do not touch'."""
        c = fake("richos-ci86", binds=["/w/live"], running=True)
        st = ct.classify([c], live={"/w/live"})
        self.assertEqual([x["name"] for x in st["protected"]], ["richos-ci86"])
        self.assertEqual(st["orphaned"], [])
        self.assertEqual(st["unowned"], [])

    def test_C5_no_evidence_at_all_is_reported_and_never_touched(self):
        """rl55 and rlx: no labels, no mounts, running three days. A person's."""
        c = fake("rl55", running=True, size=13041664, age_days=3)
        st = ct.classify([c], live={"/w/live"})
        self.assertEqual([x["name"] for x in st["unowned"]], ["rl55"])
        self.assertEqual(st["protected"], [])

    def test_C6_reap_removes_only_what_the_dead_workspace_declared(self):
        """Three containers, one workspace ending: only the declared one is
        even a candidate, and the bind-mounted one is not."""
        inv = [fake("mine", labels={ct.WORKSPACE_LABEL: "/w/dead"}),
               fake("compose-mine", labels={ct.COMPOSE_DIR_LABEL: "/w/dead/sub"}),
               fake("merely-mounted", binds=["/w/dead"]),
               fake("someone-else", labels={ct.WORKSPACE_LABEL: "/w/other"})]
        seen = []
        st = ct.classify(inv, live=set())
        for c in st["orphaned"]:
            owner, _k = ct.declared_owner(c)
            if ct._within(owner, "/w/dead"):
                seen.append(c["name"])
        self.assertEqual(sorted(seen), ["compose-mine", "mine"])

    def test_C7_liveness_unknown_protects_everything(self):
        """An unreadable record is a reason to keep your hands still. With no
        live set known, nothing may be classified as disposable by a sweep."""
        st = ct.classify([fake("x", labels={ct.WORKSPACE_LABEL: "/w/a"})],
                         live=set(), live_ok=False)
        self.assertFalse(st["live_known"])

    def test_C8_docker_absent_is_never_a_failure(self):
        """The promise the workspace deleter depends on: no exception, and a
        result that says plainly that nothing was done."""
        saved = os.environ.get("PATH")
        os.environ["PATH"] = "/nonexistent-for-this-test"
        try:
            res = ct.reap_for_workspaces(["/w/dead"])
            self.assertFalse(res["available"])
            self.assertTrue(res["reason"])
            self.assertEqual(res["removed"], [])
            self.assertEqual(ct.inventory()["containers"], [])
        finally:
            if saved is None:
                os.environ.pop("PATH", None)
            else:
                os.environ["PATH"] = saved

    def test_C10_age_is_read_as_utc_not_local_time(self):
        """Docker stamps UTC. Reading it with time.mktime (which assumes LOCAL)
        and correcting by time.timezone is wrong under daylight saving, because
        time.timezone is the standard-time offset: a container three seconds
        old reported `1h` when this was first measured, in BST.

        An age is half of what the orphan report owes its reader, so this is
        pinned rather than left to whoever next reads the machine's clock."""
        import calendar
        now = time.time()
        stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(now)) + ".123456789Z"
        self.assertLess(abs(ct._epoch(stamp) - now), 5,
                        "a UTC stamp must not be shifted by the local offset")
        self.assertEqual(ct._epoch("2026-09-13T21:08:23Z"),
                         calendar.timegm((2026, 9, 13, 21, 8, 23, 0, 0, 0)))
        self.assertEqual(ct.human_age(ct._epoch(stamp)), "0m")
        self.assertEqual(ct._epoch(""), 0)
        self.assertEqual(ct._epoch("not a date"), 0)

    def test_C9_reap_with_no_paths_does_nothing(self):
        """A caller that passes nothing must never mean 'everything'."""
        res = ct.reap_for_workspaces([])
        self.assertEqual(res["removed"], [])
        self.assertFalse(res["available"])


# ---------------------------------------------------------------------------
# D — real containers, the real lifecycle
# ---------------------------------------------------------------------------

@unittest.skipUnless(DOCKER, SKIP)
class RealLifecycle(_spec_suite().Base):
    """The spec suite's own Base, so the lifecycle these cases drive is the one
    that actually runs — a registered workspace, finished, merged, and landed
    by workspaces.land — and not a second fixture that could drift from it."""

    def setUp(self):
        super(RealLifecycle, self).setUp()
        self.tag = "reap-test-" + uuid.uuid4().hex[:8]

    def tearDown(self):
        # Leak nothing, whatever the assertions did. A test for a reaper that
        # leaked containers would be its own best counter-example.
        r = subprocess.run(["docker", "ps", "-aq", "--filter",
                            "label=%s=%s" % (TAG_LABEL, self.tag)],
                           capture_output=True, text=True)
        ids = [i for i in (r.stdout or "").split() if i]
        if ids:
            subprocess.run(["docker", "rm", "-f", "-v"] + ids, capture_output=True)
        super(RealLifecycle, self).tearDown()

    def ended_workspace(self, name):
        """One teammate, start to finished-and-merged: everything `land` needs
        before it will delete anything. Returns its cc workspace path."""
        cc = self.make_cc(name)
        aid, npath = self.spawn(name, cc=cc)
        self.commit(npath, name + ".txt")
        self.commit(cc, name + "-cc.txt")
        self.finish(aid)
        self.merge(self.entity, "worktree-agent-" + aid)
        self.merge(self.other, "cc/" + name)
        return cc

    def live_workspace(self, name):
        """A teammate that is STILL RUNNING: registered, never finished."""
        cc = self.make_cc(name)
        self.spawn(name, cc=cc)
        return cc

    def container(self, cname, owner=None, mount=None):
        args = ["docker", "run", "-d", "--name", cname,
                "--label", "%s=%s" % (TAG_LABEL, self.tag)]
        if owner:
            args += ct.docker_run_args(owner)
        if mount:
            args += ["-v", "%s:/src:ro" % mount]
        args += [TEST_IMAGE, "sleep", "300"]
        r = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, "could not start %s: %s" % (cname, r.stderr))
        return cname

    def exists(self, cname):
        r = subprocess.run(["docker", "ps", "-aq", "--filter", "name=^%s$" % cname],
                           capture_output=True, text=True)
        return bool((r.stdout or "").strip())

    # -- D1 ----------------------------------------------------------------
    def test_D1_a_landed_workspace_takes_its_container_with_it(self):
        """THE CASE THE FOUNDER ASKED FOR. Not a call to the reaper: a real
        `land`, which is the event that removes the worktree."""
        name = "zach-opus-reaped"
        cc = self.ended_workspace(name)
        cname = "reap-owned-" + self.tag
        self.container(cname, owner=cc)
        self.assertTrue(self.exists(cname), "the container must exist before the land")

        ws.land(name, self.sid)

        self.assertFalse(self.exists(cname),
                         "the workspace landed and its container is still on the machine")
        self.assertFalse(os.path.isdir(cc), "the worktree itself should be gone too")

    # -- D2 ----------------------------------------------------------------
    def test_D2_a_live_workspaces_container_survives_the_same_run(self):
        """Four of the six containers on his machine tonight are another
        engineer's running work. The run that reaps one must not touch them."""
        # The live one is started FIRST, deliberately. A spawn auto-lands every
        # finished agent whose work is already in main (point 4), so starting a
        # teammate after the dead one was merged would land it there and not
        # here — which is what D5 is about, and it cost an hour to see.
        live = self.live_workspace("zach-opus-live")
        dead = self.ended_workspace("zach-opus-dead")
        dead_c = self.container("reap-dead-" + self.tag, owner=dead)
        live_c = self.container("reap-live-" + self.tag, owner=live)

        ws.land("zach-opus-dead", self.sid)

        self.assertFalse(self.exists(dead_c), "the landed workspace's container should be gone")
        self.assertTrue(self.exists(live_c),
                        "a LIVE workspace's container was removed — this is the "
                        "failure that costs somebody their running work")

    # -- D3 ----------------------------------------------------------------
    def test_D3_an_unowned_container_is_reported_with_age_and_size_not_deleted(self):
        """The rl55 case: no ownership evidence, so it is a person's until
        proved otherwise, and it only ever gets reported."""
        cname = "reap-unowned-" + self.tag
        self.container(cname)
        dead = self.ended_workspace("zach-opus-sweeper")
        self.container("reap-sweep-" + self.tag, owner=dead)

        ws.land("zach-opus-sweeper", self.sid)
        self.assertTrue(self.exists(cname), "an unowned container was deleted")

        st = ct.classify()
        row = [c for c in st["unowned"] if c["name"] == cname]
        self.assertEqual(len(row), 1, "an unowned container must be REPORTED, not merely spared")
        self.assertTrue(ct.human_age(row[0]["created_epoch"]).endswith(("m", "h", "d")))
        self.assertIsInstance(row[0]["size_rw"], int)

    # -- D4 ----------------------------------------------------------------
    def test_D4_a_mounted_only_container_is_spared_at_its_mounts_land(self):
        """A bind mount is an inference. The workspace it points at can land
        and the container still must not be destroyed."""
        cc = self.ended_workspace("zach-opus-mounted")
        cname = "reap-mounted-" + self.tag
        self.container(cname, mount=cc)

        ws.land("zach-opus-mounted", self.sid)

        self.assertTrue(self.exists(cname),
                        "a container that merely bind-mounted the workspace was "
                        "deleted — only a DECLARATION may authorize that")

    # -- D6 ----------------------------------------------------------------
    def test_D6_a_hand_run_reap_aimed_at_a_live_workspace_removes_nothing(self):
        """The footgun the mutation harness found, closed.

        `containers.sh reap --workspace <path>` typed by hand, or with a path
        mistyped into a workspace somebody is still working in, must remove
        nothing. Only the deleter passes ending=True, and only because it is
        the thing doing the deleting. The D2 guarantee does not cover this:
        there, the live workspace is protected because it was never a target.
        Here it IS the target, and it must still survive."""
        live = self.live_workspace("zach-opus-busy")
        cname = "reap-busy-" + self.tag
        self.container(cname, owner=live)

        res = ct.reap_for_workspaces([live])          # ending defaults to False

        self.assertTrue(self.exists(cname),
                        "a hand-run reap destroyed a LIVE workspace's containers")
        self.assertEqual([k["name"] for k in res["kept"]], [cname])
        self.assertEqual(res["removed"], [])
        self.assertIn("live", res["kept"][0]["why"])

        # ...and the deleter, which knows better, is not blocked by the same check.
        res2 = ct.reap_for_workspaces([live], ending=True, dry_run=True)
        self.assertEqual([r["name"] for r in res2["removed"]], [cname])

    # -- D5 ----------------------------------------------------------------
    def test_D5_the_automatic_land_at_the_next_spawn_reaps_too(self):
        """THE ANSWER TO "how many times will this keep getting repeated".

        Nobody has to remember. A land is not the only way out: starting the
        NEXT teammate auto-lands every finished agent whose work is already in
        main (point 4), and because the reaping hangs off _delete rather than
        off the `land` command, that path reaps as well. This case exists
        because D2 tripped over it — the residue was already gone before the
        assertion ran, and a mechanism that only worked when somebody typed
        `workspaces.sh land` would be the promise this was meant to replace."""
        dead = self.ended_workspace("zach-opus-auto")
        cname = "reap-auto-" + self.tag
        self.container(cname, owner=dead)
        self.assertTrue(self.exists(cname))

        # No land, no cleanup command: just the next piece of work starting.
        self.live_workspace("zach-opus-next")

        self.assertFalse(self.exists(cname),
                         "the automatic land left the container behind, so the "
                         "residue would still depend on somebody remembering")


class _Result(unittest.TextTestResult):
    """Prints `  PASS  <test>` / `  FAIL  <test>` so containers.mutation.sh can
    tell WHICH property went red, rather than merely that something did.

    A skip prints `  SKIP`, never `PASS`. The D cases skip where Docker is
    absent, and a skip that read as a pass would be this engine reporting a
    reaper it had not run — the exact shape of failure the whole file is about.
    """

    def addSuccess(self, test):
        super().addSuccess(test)
        self.stream.write("  PASS  %s\n" % test._testMethodName)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.stream.write("  FAIL  %s\n" % test._testMethodName)

    def addError(self, test, err):
        super().addError(test, err)
        self.stream.write("  FAIL  %s (error)\n" % test._testMethodName)

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.stream.write("  SKIP  %s — %s\n" % (test._testMethodName, reason.splitlines()[0]))


if __name__ == "__main__":
    runner = unittest.TextTestRunner(stream=sys.stdout, verbosity=0, resultclass=_Result)
    loader = unittest.defaultTestLoader
    names = [a for a in sys.argv[1:] if a]
    suite = (loader.loadTestsFromNames(names, sys.modules[__name__]) if names
             else loader.loadTestsFromModule(sys.modules[__name__]))
    result = runner.run(suite)
    print("=== container reaping: %d run, %d failed, %d skipped ===" % (
        result.testsRun, len(result.failures) + len(result.errors), len(result.skipped)))
    sys.exit(0 if result.wasSuccessful() else 1)
