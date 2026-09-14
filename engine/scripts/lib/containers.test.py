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

import atexit
import io
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

# THE REGISTRY THIS FILE TALKS TO IS A SANDBOX, SAID HERE, IN THIS FILE.
#
# The D cases were already hermetic -- they inherit workspaces.test.py's Env,
# which redirects HOME and CLAUDE_CONFIG_DIR into a mkdtemp -- and a full local
# run with Docker up left zero fixture rows in the operator's real registry.
# But that sandbox lives in a SIBLING FILE's base class, so nothing in THIS
# file says it, and two things follow from that. land-completeness L21 reads
# source text and cannot see an inherited sandbox, so it read this suite as one
# that writes to the operator's real registry. More importantly, the C cases
# and this module's own import run under the REAL environment with no Env at
# all, so the guarantee today rests on every future case being added to the
# right class. Inherited hermeticity is not a property of a file; this is.
#
# ONLY RICHOS_WORKSPACES_DIR, AND DELIBERATELY NOT HOME. state_dir() reads this
# variable first, so it redirects the whole registry on its own. Redirecting
# HOME here would also move ~/.docker, and docker_usable() runs at import: the
# D cases would stop finding the daemon and SKIP, which is this suite quietly
# losing the only cases that prove a container is really removed. A sandbox
# that disables the tests it protects is worse than no sandbox.
#
# Env pops RICHOS_WORKSPACES_DIR and saves/restores it, so the D cases keep
# their own sandbox and this one is back in place when they close.
_REGISTRY_SANDBOX = tempfile.mkdtemp(prefix="containers-test-registry-")
atexit.register(shutil.rmtree, _REGISTRY_SANDBOX, ignore_errors=True)
os.environ["RICHOS_WORKSPACES_DIR"] = _REGISTRY_SANDBOX

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


# ===========================================================================
# WHO OWNS A CONTAINER THIS SUITE STARTED, AND WHO HAS TO REMOVE IT
# ===========================================================================
# The header above promises the D cases remove their containers "even when the
# assertion fails", and tearDown delivers exactly that much: A FAILED
# ASSERTION. It does not survive the RUN ENDING, and measured on the pristine
# tree on 2026-09-14, on this machine:
#
#   SIGINT to the process group — a plain Ctrl-C     → 1 container left Up
#   SIGKILL of a full run mid mutation pool          → 8 containers left Up
#
# Three different holes, not one. unittest's testPartExecutor RE-RAISES
# KeyboardInterrupt rather than recording it, so a Ctrl-C leaves TestCase.run()
# before _callTearDown ever runs; SIGTERM's default action never reaches Python
# at all; and SIGKILL cannot be handled by anything, ever.
#
# WHY THAT IS WORSE THAN WASTED RESOURCES. containers.py bounds every docker
# call with a timeout (`docker inspect --size` at 30s), because a wedged daemon
# must not hang a land. Residue pushes the machine toward that bound, so
# inventory() starts coming back short or unavailable, the reaper deletes
# nothing, and cases that expect a deletion go red AT CODE THAT IS INNOCENT.
# An engineer lost most of an evening to exactly that on 2026-09-13, attributed
# six consecutive reds to his own edit, and watched a bisect appear to confirm
# it (esc-20260914T003636Z-ea530880). A suite that produces a confident false
# accusation is worse than one that produces no result.
#
# So ownership is DECLARED ON THE CONTAINER — the same move containers.py makes
# for everything else — and the run removes what it owns on every ending it can
# be given:
#
#   sh.richos.test-run          the per-case tag. tearDown's filter, unchanged.
#   sh.richos.test-run-owner    the RUN responsible for removing it. The residue
#                               sweep reads this and asks whether that process
#                               still exists.
#   sh.richos.test-run-sweeper  a SECOND run that may also remove it. This is
#                               the only reason the two keys are not one: the
#                               interrupt probe is a CHILD process that is
#                               deliberately about to be killed, so its owner is
#                               by construction not going to tidy up, and its
#                               sweeper — this process — still will.
RUN_ID = "%d.%s" % (os.getpid(), uuid.uuid4().hex[:8])
OWNER_LABEL = "sh.richos.test-run-owner"
SWEEPER_LABEL = "sh.richos.test-run-sweeper"
# Set by the parent when this process is an interrupt probe; its own RUN_ID
# otherwise, so an ordinary run is its own sweeper and the two keys agree.
SWEEPER_ID = os.environ.get("RICHOS_CONTAINER_TEST_SWEEPER") or RUN_ID


def _docker_out(args, timeout=None):
    """stdout of a docker command, or "" — never raises, for the same reason
    containers.py never raises: this runs from an exit path and a signal
    handler, where an exception has nowhere to go.

    BOUNDED BY THE SAME CLOCK AS THE THING UNDER TEST, and borrowed from it
    rather than picked: containers.py bounds every call because a wedged daemon
    must not hang a land, and a wedged daemon must not hang a Ctrl-C either. An
    unbounded `docker ps` inside a signal handler is a process that will not
    die, which is a worse bug than the one this file is fixing.
    """
    try:
        r = subprocess.run(["docker"] + list(args), capture_output=True, text=True,
                           timeout=timeout or ct.DOCKER_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if r.returncode != 0:
        return ""
    return r.stdout or ""


def _ids_labeled(key, value):
    return [i for i in _docker_out(
        ["ps", "-aq", "--filter", "label=%s=%s" % (key, value)]).split() if i]


def _rm_ids(ids):
    ids = list(ids)
    if not ids:
        return
    try:
        subprocess.run(["docker", "rm", "-f", "-v"] + ids, capture_output=True,
                       timeout=ct.DOCKER_REMOVE_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        pass


def _rm_by_tag(tag):
    _rm_ids(_ids_labeled(TAG_LABEL, tag))


def _exists(name):
    return bool(_docker_out(["ps", "-aq", "--filter", "name=^%s$" % name]).strip())


def _label_args(tag):
    """Every container this file starts carries all three, always."""
    return ["--label", "%s=%s" % (TAG_LABEL, tag),
            "--label", "%s=%s" % (OWNER_LABEL, RUN_ID),
            "--label", "%s=%s" % (SWEEPER_LABEL, SWEEPER_ID)]


def cleanup_this_run(why=""):
    """Remove every container THIS run is responsible for, and return them.

    Idempotent and re-entrant on purpose: atexit and a signal handler may both
    call it, and under a signal the second call is the one that has nothing left
    to do. It asks docker rather than tracking a list in memory, because a list
    in memory is exactly the thing an interrupt takes with it.
    """
    if not DOCKER:
        return []
    ids = _ids_labeled(OWNER_LABEL, RUN_ID)
    for i in _ids_labeled(SWEEPER_LABEL, RUN_ID):
        if i not in ids:
            ids.append(i)
    if not ids:
        return []
    _rm_ids(ids)
    if why:
        try:
            sys.stdout.write("  cleanup  %d container(s) removed on %s\n" % (len(ids), why))
            sys.stdout.flush()
        except Exception:                                  # noqa: BLE001
            pass                                           # a dying process owes no output
    return ids


def _cleanup_on_signal(signum, _frame):
    """Clean up, then die of the signal we were sent.

    Restoring SIG_DFL and re-raising is not ceremony: a handler that called
    sys.exit(1) would report a KILLED run as an ordinary test failure, and the
    exit status is what the mutation pool tallies.
    """
    try:
        name = signal.Signals(signum).name
    except (ValueError, AttributeError):
        name = "signal %d" % signum
    cleanup_this_run(name)
    try:
        signal.signal(signum, signal.SIG_DFL)
    except (OSError, ValueError, RuntimeError):
        os._exit(128 + signum)
    os.kill(os.getpid(), signum)


def _install_cleanup_signal(name):
    """INSTALLED UNCONDITIONALLY, including over an inherited SIG_IGN.

    bash sets SIGINT and SIGQUIT to SIG_IGN for a background job when job
    control is off, and a child inherits that — which is not a footnote here,
    because the mutation pool runs every mutant as a background job. Left
    inherited, a SIGINT would be a no-op, the run would carry on, and the
    interrupt case below would pass for a reason that has nothing to do with
    cleanup. It cost two runs to see that: the first reproduction of this leak
    sent SIGINT to a background suite and watched it finish green.
    """
    sig = getattr(signal, name, None)
    if sig is None:
        return
    try:
        signal.signal(sig, _cleanup_on_signal)
    except (OSError, ValueError, RuntimeError):
        pass


_CLEANUP_SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"]
for _sig_name in _CLEANUP_SIGNALS:
    _install_cleanup_signal(_sig_name)
# Covers the endings a handler cannot see: a normal finish, sys.exit, and an
# exception that escapes the runner. SIGKILL is covered by nothing in this
# process, by definition — that is what the residue sweep is for.
atexit.register(cleanup_this_run)


# ===========================================================================
# RESIDUE A RUN THAT DIED LEFT BEHIND — NAMED, NEVER SILENT
# ===========================================================================
# SIGKILL, an OOM kill, a laptop lid: no in-process handler covers those, so
# residue is possible however careful the run above is, and the only place left
# to notice it is THE NEXT RUN. Today the next run notices nothing and simply
# goes red somewhere unrelated, which is the false accusation this whole section
# is about.
#
# THE POLICY IS THE ONE THE THING UNDER TEST USES, because the asymmetry
# containers.py argues for is right here too:
#
#   owner declared, and that process is PROVABLY gone  → removed, and NAMED.
#   owner declared, and alive (or liveness unknown)    → left alone, silently.
#                                                        Under the mutation pool
#                                                        that is seven other
#                                                        concurrent runs, and
#                                                        deleting their
#                                                        containers would be the
#                                                        defect with the sign
#                                                        flipped.
#   no owner declared at all                           → REPORTED, never touched,
#                                                        with the command to
#                                                        remove it. No evidence
#                                                        is not authority (C5).
#
# REMOVED, RATHER THAN REFUSING TO RUN. Refusal was the other candidate and it
# loses on one point that decides it: a refusal can FALSE-ACCUSE. A run that
# finishes normally removes its containers and THEN exits, so there is a window
# in which another run has listed those containers and the owner exits before
# the liveness question is asked — benign if the verdict is "remove it anyway"
# (it is already being removed) and a fabricated failure if the verdict is "stop,
# this machine is dirty". Refusing would hand somebody a red run caused by the
# race and not by their code, which is the exact experience that produced this
# work. Removal is also the ACT the evidence supports: the tag is private to
# this file, nothing else on the machine creates it, and the container's own
# label names a process that no longer exists — a declaration by a dead owner,
# which is precisely the one circumstance containers.py deletes in.
#
# Silence is not the alternative to refusing: every removal is printed with the
# container's name, its status and its dead owner, so a leak that comes back
# shows up as a line rather than as a mystery.


def _owner_alive(run_id):
    """Is the run that declared itself the owner still on this machine?

    TRUE UNLESS PROVABLY GONE. The direction of the doubt is the whole design:
    this answer decides whether containers get REMOVED, so "I could not tell"
    has to mean "leave it alone". Only ProcessLookupError — no such process —
    is treated as evidence of death.
    """
    head = run_id.split(".")[0]
    if not head.isdigit():
        return True                       # an identity we cannot read is not ours to judge
    pid = int(head)
    if pid <= 0:
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False                      # the one positive signal
    except PermissionError:
        return True                       # alive, and another user's
    except OSError:
        return True
    # The pid is in use, but pids are REUSED, and a container can easily outlive
    # the number that made it. So ask what that pid is: something that is not
    # this suite cannot be the owner. `ps` failing or saying nothing is unknown,
    # and unknown means alive.
    try:
        r = subprocess.run(["ps", "-p", str(pid), "-o", "command="],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return True
    cmd = (r.stdout or "").strip()
    if r.returncode != 0 or not cmd:
        return True
    return "containers.test" in cmd


def foreign_residue():
    """Containers carrying this suite's tag that this run did not start, split
    by what the machine can actually prove about each one."""
    if not DOCKER:
        return {"dead": [], "unattributable": []}
    fmt = '{{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Label "%s"}}\t{{.Label "%s"}}' % (
        OWNER_LABEL, SWEEPER_LABEL)
    out = _docker_out(["ps", "-a", "--filter", "label=" + TAG_LABEL, "--format", fmt])
    dead, unattributable = [], []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 5:
            continue
        row = {"id": parts[0], "name": parts[1], "status": parts[2],
               "owner": parts[3].strip()}
        sweeper = parts[4].strip()
        if row["owner"] == RUN_ID:
            continue                      # ours; cleanup_this_run has it
        # ANOTHER LIVE RUN HAS ALREADY SAID IT WILL CLEAN THIS UP, so it is not
        # ours to take. Normally the sweeper IS the owner and this decides
        # nothing; it decides everything for a container held by a CHILD process
        # whose parent is still running, which is exactly what an interrupt
        # probe is. Without it, eight concurrent suites all see the same
        # container as residue and race to remove it: one wins, the losers are
        # told the removal is already in progress, and a suite goes red over a
        # container it named as removed and then found still listed. Measured —
        # that was the last red in eight concurrent runs.
        if sweeper and sweeper != RUN_ID and _owner_alive(sweeper):
            continue
        if not row["owner"]:
            unattributable.append(row)
        elif not _owner_alive(row["owner"]):
            dead.append(row)
    return {"dead": dead, "unattributable": unattributable}


def sweep_residue(stream=sys.stdout):
    """Say what was left behind, remove what a dead run owns, and run on."""
    found = foreign_residue()
    dead, unattributable = found["dead"], found["unattributable"]
    if dead:
        stream.write("=== residue: %d container(s) from a run that was killed "
                     "before it could clean up ===\n" % len(dead))
        for c in dead:
            stream.write("    reaped  %-38s %-20s owner %s no longer exists\n"
                         % (c["name"], c["status"], c["owner"]))
        _rm_ids([c["id"] for c in dead])
        stream.write("    They would have shifted this run's results, so they go "
                     "before any case runs.\n")
    if unattributable:
        stream.write("=== residue: %d container(s) carry this suite's tag and "
                     "DECLARE NO OWNER — kept ===\n" % len(unattributable))
        for c in unattributable:
            stream.write("    kept    %-38s %-20s (started by a run from before "
                         "this file declared ownership)\n" % (c["name"], c["status"]))
        stream.write("    No evidence is not authority to delete. If they are "
                     "yours and finished with:\n      docker rm -f -v %s\n"
                     % " ".join(c["name"] for c in unattributable))
    stream.flush()
    return found


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

    # The program the case below runs in a CHILD process. A module-level
    # constant rather than an inline string so the quoting stays readable, and
    # so the mutation harness's `mutate.py` never has to reason about it.
    _UTC_UNDER_DST = r"""
import calendar, sys, time
sys.path.insert(0, sys.argv[1])
import containers as ct

summer = calendar.timegm((2026, 7, 1, 12, 0, 0, 0, 0, 0))

# THE PIN IS A PRECONDITION, so it is checked before anything rests on it.
if time.timezone != 0:
    sys.exit("the pinned zone's STANDARD offset is %r, expected 0" % (time.timezone,))
if time.localtime(summer).tm_isdst != 1:
    sys.exit("the pinned zone is not in daylight saving at the moment under test"
             " -- outside DST, mktime and timegm agree and this proves nothing")

for stamp in ("2026-07-01T12:00:00Z", "2026-07-01T12:00:00.123456789Z",
              "2026-07-01 12:00:00"):
    got = ct._epoch(stamp)
    if got != summer:
        sys.exit("%s read as %d, expected %d (off by %+d) -- a UTC stamp was"
                 " shifted by the local offset" % (stamp, got, summer, got - summer))
"""

    def test_C10_age_is_read_as_utc_not_local_time(self):
        """Docker stamps UTC. Reading it with time.mktime (which assumes LOCAL)
        and correcting by time.timezone is wrong under daylight saving, because
        time.timezone is the standard-time offset: a container three seconds
        old reported `1h` when this was first measured, in BST.

        An age is half of what the orphan report owes its reader, so this is
        pinned rather than left to whoever next reads the machine's clock.

        WITHOUT A PINNED TIMEZONE THIS CASE PROVES NOTHING ON A RUNNER.
        `mktime(t) - time.timezone` and `calendar.timegm(t)` are
        ARITHMETICALLY IDENTICAL wherever daylight saving is not in force at
        the moment being read -- that is the entire content of the bug -- and a
        GitHub runner is UTC. So this case, written about a defect it could not
        observe, passed on the defect and on the fix alike, and the mutation
        harness said so out loud on 2026-09-13:

            FAIL  age-read-as-local-time — the suite still PASSED without
                  this property.

        A suite reporting that its own assertion carries nothing. The defect
        was never on the runner; the BLINDNESS was, and the only machine that
        could see it was the developer's, in BST.

        A CHILD PROCESS, NOT os.environ + time.tzset() IN THIS ONE, for two
        reasons that have nothing to do with taste. time.tzset() mutates the
        timezone of the WHOLE interpreter, and this file is not an ordinary
        suite -- the D cases drive real Docker containers in the same process,
        so a pin that is restored in a `finally` is still a window in which
        anything running here reads a fabricated clock. And time.tzset() does
        not exist off Unix, so the in-process form would have to choose between
        failing and skipping on a platform where the property is perfectly
        true. The child reads TZ from its environment at start-up, needs no
        tzset at all, and dies with the case.

        A POSIX TZ STRING, NOT A ZONE NAME. "Europe/London" needs the tz
        database, and where tzdata is thin or absent the lookup falls back to
        UTC SILENTLY -- restoring the exact hole this closes, with a green tick
        on top. The string carries its own DST rule and reads nothing from
        disk. And the pin is ASSERTED, never assumed, because a pin that
        quietly did not take is the state this case was already in.
        """
        import calendar

        # --- the defect itself, under a zone that is IN daylight saving -----
        env = dict(os.environ)
        env["TZ"] = "TST0TDT,M3.2.0,M11.1.0"   # std +0, dst +1, Mar..Nov
        r = subprocess.run([sys.executable, "-c", self._UTC_UNDER_DST, HERE],
                           capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 0,
                         "reading a Docker stamp under a DST timezone: "
                         + (r.stdout + r.stderr).strip())

        # --- and the parts that hold in any zone, in this process -----------
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
        # leaked containers would be its own best counter-example. This arm
        # covers a FAILED ASSERTION and nothing else — the run ending is covered
        # by cleanup_this_run, registered above, because tearDown is precisely
        # what an interrupt skips.
        _rm_by_tag(self.tag)
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
        args = ["docker", "run", "-d", "--name", cname] + _label_args(self.tag)
        if owner:
            args += ct.docker_run_args(owner)
        if mount:
            args += ["-v", "%s:/src:ro" % mount]
        args += [TEST_IMAGE, "sleep", "300"]
        r = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, "could not start %s: %s" % (cname, r.stderr))
        return cname

    def exists(self, cname):
        return _exists(cname)

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


def _residue_probe():
    """`--residue-probe`: start ONE container, say its name, and wait to be
    interrupted. Called by this file, in a child process, from the case below.

    A DOCUMENTED MODE RATHER THAN A FIXTURE, because the only honest proof that
    THIS FILE cleans up after a signal is THIS FILE being sent one. A fixture
    that started a container and then asserted a hand-rolled handler removed it
    would be testing the fixture. The child is the suite.

    It carries the parent's tag and the parent as its SWEEPER, so the container
    has three independent nets under it: the child's own handler, the parent's
    tearDown (by tag), and the parent's own exit cleanup (by sweeper).
    """
    tag = os.environ.get("RICHOS_CONTAINER_TEST_TAG") or ("probe-" + RUN_ID)
    name = "reap-probe-" + RUN_ID.replace(".", "-")
    try:
        r = subprocess.run(["docker", "run", "-d", "--name", name]
                           + _label_args(tag) + [TEST_IMAGE, "sleep", "300"],
                           capture_output=True, text=True,
                           timeout=ct.DOCKER_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        sys.stdout.write("PROBE-FAILED %s\n" % e)
        sys.stdout.flush()
        return 3
    if r.returncode != 0:
        sys.stdout.write("PROBE-FAILED %s\n" % (r.stderr or "").strip())
        sys.stdout.flush()
        return 3
    sys.stdout.write("PROBE-CONTAINER %s\n" % name)
    sys.stdout.flush()
    while True:
        time.sleep(0.25)


@unittest.skipUnless(DOCKER, SKIP)
class Interrupted(unittest.TestCase):
    """D7, D8 — what the run leaves behind when it does not FINISH.

    Every other case here asks what the reaper does. These ask what the SUITE
    does, because the suite is a program that starts containers, and the spec's
    standard for a piece of work — leave it as you found it — is not suspended
    for the program that checks the spec.
    """

    def setUp(self):
        self.tag = "reap-test-" + uuid.uuid4().hex[:8]
        self.probes = []

    def tearDown(self):
        for p in self.probes:
            if p.poll() is None:
                p.kill()
                p.wait()
            if p.stdout is not None:
                p.stdout.close()
        _rm_by_tag(self.tag)

    def start_probe(self):
        """A child running THIS file, holding one container, waiting."""
        env = dict(os.environ)
        env["RICHOS_CONTAINER_TEST_SWEEPER"] = RUN_ID
        env["RICHOS_CONTAINER_TEST_TAG"] = self.tag
        p = subprocess.Popen([sys.executable, "-B", "-W", "ignore",
                              os.path.abspath(__file__), "--residue-probe"],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, env=env)
        self.probes.append(p)
        line = (p.stdout.readline() or "").strip()
        self.assertTrue(line.startswith("PROBE-CONTAINER "),
                        "the interrupt probe never started a container: %s"
                        % (line or "<the probe produced no output at all>"))
        name = line.split(None, 1)[1]
        self.assertTrue(_exists(name),
                        "the probe named %s but docker does not have it" % name)
        return p, name

    # -- D7 ----------------------------------------------------------------
    def test_D7_an_interrupted_run_takes_its_containers_with_it(self):
        """THE DEFECT ITSELF. A Ctrl-C used to leave the container Up, because
        unittest re-raises KeyboardInterrupt out of TestCase.run() BEFORE
        tearDown; SIGTERM used to leave it Up because the default action never
        reaches Python at all.

        The exit STATUS is asserted alongside, and not as decoration: a handler
        that cleaned up and then exited 1 would report a killed run as an
        ordinary test failure, which is the same class of lie as the leak.
        """
        # SIGTERM FIRST, AND THE ORDER IS LOAD-BEARING FOR THE HARNESS RATHER
        # THAN FOR THIS CASE. Both signals are checked either way. But when the
        # mutation harness removes the signal registration, the probe falls back
        # to the disposition it INHERITED, and a pool worker is a background job
        # whose SIGINT is SIG_IGN — so a SIGINT-first loop spends the full
        # 60-second wait discovering that, while the machine runs seven other
        # mutants. Measured: that one mutant took 1m11s, more than the whole
        # pristine harness took to run, and the contention it added turned
        # unrelated mutants red. SIGTERM is never inherited-ignored, so it fails
        # in about a second and the harness stops competing with itself.
        for sig in (signal.SIGTERM, signal.SIGINT):
            p, name = self.start_probe()
            p.send_signal(sig)
            p.wait(timeout=60)
            self.assertFalse(
                _exists(name),
                "%s left %s behind — an interrupted run still leaks, and the "
                "next run on this machine will classify against it"
                % (signal.Signals(sig).name, name))
            self.assertEqual(p.returncode, -sig,
                             "%s must still end the run AS that signal (got %r)"
                             % (signal.Signals(sig).name, p.returncode))

    # -- D8 ----------------------------------------------------------------
    def test_D8_residue_a_killed_run_left_is_named_and_removed_not_left_to_lie(self):
        """SIGKILL IS THE ENDING NOTHING IN-PROCESS CAN COVER, so the residue is
        real rather than planted: a child run of this file is killed outright
        and its container survives. That container is what the next run on the
        machine would silently classify against.

        Three properties, and the middle one is the dangerous one. The sweep
        must NAME and REMOVE a container whose owner is gone; it must NOT touch
        a container whose owner is alive -- under the mutation pool that is
        seven other concurrent runs, and reaping their work would be this defect
        with the sign flipped; and having removed something once it must be
        quiet about it afterwards, because a warning that repeats on a clean
        machine is a warning nobody reads.
        """
        mine = "reap-mine-" + self.tag
        r = subprocess.run(["docker", "run", "-d", "--name", mine]
                           + _label_args(self.tag) + [TEST_IMAGE, "sleep", "300"],
                           capture_output=True, text=True,
                           timeout=ct.DOCKER_TIMEOUT)
        self.assertEqual(r.returncode, 0, "could not start %s: %s" % (mine, r.stderr))

        # A SECOND run that is STILL GOING, and it is the important one. `mine`
        # is skipped by IDENTITY (its owner is this process), so on its own it
        # can never catch a liveness answer that has gone wrong. This one is a
        # different process with a different owner id, alive, and the only thing
        # standing between it and deletion is _owner_alive.
        alive_p, alive_c = self.start_probe()

        p, leaked = self.start_probe()
        p.kill()
        p.wait(timeout=60)
        self.assertTrue(_exists(leaked),
                        "SIGKILL left nothing behind — then this case is not "
                        "exercising residue at all and proves nothing")

        found = foreign_residue()
        self.assertIn(leaked, [c["name"] for c in found["dead"]],
                      "the residue of a killed run was not recognized as residue")
        self.assertNotIn(mine, [c["name"] for c in found["dead"]],
                         "the sweep claimed a container of the run it is part of")
        self.assertNotIn(alive_c, [c["name"] for c in found["dead"]],
                         "the sweep claimed a container of a run that is STILL "
                         "RUNNING — under the mutation pool that is eight "
                         "concurrent suites deleting each other's work, which is "
                         "this defect with the sign flipped")
        self.assertIsNone(alive_p.poll(), "the second probe was supposed to "
                                          "still be running for that question to mean anything")

        said = io.StringIO()
        sweep_residue(said)
        self.assertIn(leaked, said.getvalue(),
                      "the residue was removed without being named — silent is "
                      "the failure mode this exists to end")
        self.assertFalse(_exists(leaked), "named, but still on the machine")
        self.assertTrue(_exists(mine),
                        "the sweep removed a container belonging to the run it "
                        "is part of")
        self.assertTrue(_exists(alive_c),
                        "the sweep removed a container belonging to a DIFFERENT "
                        "run that is still going — the failure that costs "
                        "somebody their work rather than merely their time")

        again = io.StringIO()
        sweep_residue(again)
        self.assertNotIn(leaked, again.getvalue(),
                         "the sweep is still talking about a container it "
                         "already removed")


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
    if "--residue-probe" in sys.argv[1:]:
        sys.exit(_residue_probe())
    # BEFORE ANY CASE RUNS, and never inside the probe: a run must not be
    # classifying against a dead run's containers, and it must not find out by
    # going red somewhere unrelated.
    sweep_residue()
    runner = unittest.TextTestRunner(stream=sys.stdout, verbosity=0, resultclass=_Result)
    loader = unittest.defaultTestLoader
    names = [a for a in sys.argv[1:] if a]
    suite = (loader.loadTestsFromNames(names, sys.modules[__name__]) if names
             else loader.loadTestsFromModule(sys.modules[__name__]))
    result = runner.run(suite)
    print("=== container reaping: %d run, %d failed, %d skipped ===" % (
        result.testsRun, len(result.failures) + len(result.errors), len(result.skipped)))
    sys.exit(0 if result.wasSuccessful() else 1)
