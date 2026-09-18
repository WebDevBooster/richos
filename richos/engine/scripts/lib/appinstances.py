#!/usr/bin/env python3
"""appinstances.py — a test instance of the app is garbage, and it is collected.

CEO, ceo-decisions §54 addendum 4, verbatim: "Ray had left the test app window
open. Test app windows must always close/quit when testing is finished. Same
hygiene as with any other garbage." Said after the candidate-.7 walk ended with
the QA instance still on his screen. §54 itself is the rule this is an instance
of: garbage is ALWAYS cleaned up, or Rich gets a MASSIVE ALERT and deletes it by
hand.

This module is the ONE definition of what a test instance is, so that the land
step (mega-lander/workspaces.py) and the scratch reaper
(scripts/lib/scratch-reaper.py) cannot disagree about it. Two definitions of
garbage is how the 105 GB escaped: an allowlist can only ever contain the names
somebody thought of.

WHAT THIS MODULE DOES NOT DO, AND WHY IT IS BUILT THE WAY IT IS
---------------------------------------------------------------
The brief that ordered this work prescribed reading the launch environment from
the process -- `ps eww` -- and testing whether `HOME` lies under a scratch root.
**That has no implementation on this machine at any privilege available.**
Measured on macOS 15.6 (Darwin 24.6.0), for a `sleep` child of the invoking
shell, same uid, no sandbox:

    $ ps eww -o command= -p <pid>        ->  "sleep 300"
    $ ps -E  -o command= -p <pid>        ->  "sleep 300"

argv, and no environment at all. Not truncated and not permission-denied: macOS
stopped exposing another process's environment through `ps` entirely. So `HOME`
is NOT a readable property of a running process here, and any design resting on
it would have been a design that silently collected nothing.

What IS readable without root, measured the same way:

    $ lsof -a -p <pid> -d cwd,txt -Fn
    p<pid>
    fcwd
    n/Users/alex/ab/femcboost/.claude/worktrees/agent-a94952b3135184f96
    ftxt
    n/bin/sleep

-- the absolute working directory and the absolute executable, regardless of
what argv says. That is the substrate this module is built on, plus the
process's open files, which is where a scratch `HOME` actually becomes visible:
an app told `HOME=<scratch>` opens its state under `<scratch>`, and those open
paths are absolute in `lsof` whether or not anything can read `HOME`.

WHY THE PROCESS NAME AND THE BUNDLE ID ARE BOTH USELESS AS DISCRIMINATORS
------------------------------------------------------------------------
The shipped app's executable is ALSO named `richos-tauri`
(`RichOS.app/Contents/MacOS/richos-tauri`; `tauri.conf.json` declares
`productName: RichOS`, `identifier: com.richos.app`), and the candidate-.7 walk
recorded its instance's argv as **relative**:

    $ pgrep -fl richos-tauri
    98757 ./RichOS.app/Contents/MacOS/richos-tauri

So the process name, the bundle identifier and argv are all shared between a
test instance and the CEO's own installed app, and none of the three locates the
binary. This is why the graceful quit here is **pid-targeted** (System Events,
`whose unix id is <pid>`) and never `tell application id "com.richos.app" to
quit` or a quit by application name: those address whichever instance the window
server thinks owns the name, which on a machine with his app open is his app.
A cleanup mechanism that can quit the CEO's app is worse than no cleanup
mechanism.

DENY BY DEFAULT, AND WHY THAT IS THE SAFETY MECHANISM
-----------------------------------------------------
Nothing is quit because it failed to appear on a protect-list. A process is
collected only when it is POSITIVELY shown to be rooted under a declared
scratch root. Anything this module cannot place -- an unknown binary, a process
whose open files could not be read, the installed app, an instance running on
the operator's real home -- is left alone by construction, and the protect-list
below is an assertion that the construction holds, not the thing holding it.

That asymmetry is deliberate and it is load-bearing, because the brief's own
protect-list turned out not to exist on this machine:

    $ ls -d /Applications/RichOS.app        -> no such directory
    $ ls -d ~/myrichos-nightly-*            -> no such directory
    $ ls -d ~/Applications/RichOS.app       -> /Users/alex/Applications/RichOS.app
    $ ls -d ~/.richos-nightly               -> /Users/alex/.richos-nightly

Both paths the brief named as "never touch" were absent, and the app that IS
installed sat at a path the brief did not name. Had the protect-list been the
safety mechanism, the only app on this machine worth protecting would have had
no protection at all. Under deny-by-default its absence from the list costs
nothing: it is not under a scratch root, so it is never a candidate.

THREE STATES, NEVER TWO
-----------------------
`classify` returns COLLECT, LEAVE or INDETERMINATE. A process carrying BOTH
scratch evidence and real-home evidence is INDETERMINATE and is never quit --
it is reported instead. Collapsing that into a guess is how a cleanup mechanism
ends up quitting the wrong window once and being switched off forever.
"""

import fnmatch
import json
import os
import re
import signal
import subprocess
import time

# Paths that can never be a scratch root and can never be the operator's app
# state, so they are rejected before anything stats them. These are OS-owned
# trees; $HOME is deliberately NOT here, because both a test instance's
# executable and the operator's app state live under it.
_NEVER_RELEVANT = ("/usr/", "/System/", "/dev/", "/bin/", "/sbin/",
                   "/Library/Frameworks/", "/Library/Apple/")

COLLECT = "COLLECT"
LEAVE = "LEAVE"
INDETERMINATE = "INDETERMINATE"

# Read once per process: the whole-machine process table and the per-candidate
# lsof are snapshots, and two readings inside one pass could disagree with each
# other. Same reasoning as Liveness.oldest_start in scratch-reaper.py.
_CACHE = {}


def _env():
    return dict(os.environ, LC_ALL="C", LANG="C", TZ="UTC0")


# ---------------------------------------------------------------------------
# the declarations — read from the env the reaper exports, else from the
# engine's own orchestration.config
# ---------------------------------------------------------------------------
# WHY BOTH. scripts/scratch-reaper.sh sources orchestration.config and exports
# every SCRATCH_* key before invoking python, so inside the reaper the
# environment IS the declaration. mega-lander/workspaces.py has no such
# wrapper and never sourced the config at all. Reading the file as a fallback
# is what keeps this ONE definition instead of two: the alternative was to
# hard-code the root set here for the land path, which is precisely the second
# definition this module exists to prevent.

_KEY_RE = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)\s*=\s*"?([^"#\n]*)"?\s*(?:#.*)?$')


def engine_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))))


def _config_file():
    p = (os.environ.get("SCRATCH_REAPER_CONFIG") or "").strip()
    if p:
        return p
    return os.path.join(engine_root(), "orchestration.config")


def _from_file():
    if "cfgfile" in _CACHE:
        return _CACHE["cfgfile"]
    out = {}
    try:
        with open(_config_file(), encoding="utf-8") as fh:
            for line in fh:
                m = _KEY_RE.match(line)
                if m:
                    out[m.group(1)] = m.group(2).strip()
    except OSError:
        pass
    _CACHE["cfgfile"] = out
    return out


def declared(name, default=""):
    """The env first (the reaper exports it), then orchestration.config.

    A COVERAGE key, never a threshold, so the fallback is a value and not a
    refusal to run -- the asymmetry scratch-reaper.py's config_from_env spells
    out: a missing threshold risks deleting to the wrong number, a missing
    coverage key risks collecting less than it could, and a collector that
    exits non-zero because a key is absent collects nothing at all.
    """
    v = (os.environ.get(name) or "").strip()
    if v:
        return v
    v = (_from_file().get(name) or "").strip()
    return v if v else default


def _expand(p):
    return os.path.realpath(os.path.expanduser(
        p.replace("%u", str(os.getuid()))))


class RootSet(object):
    """Everything under which a path is machine-made scratch, as a MATCHER.

    DERIVED FROM THE REAPER'S OWN KEYS, not restated. The four arms of
    scratch-reaper.py's scan() are:

      SCRATCH_CLAUDE_ROOTS        the session scratchpads
      $TMPDIR/SCRATCH_ROOT_NAME   the allocator's root, deny-by-default
      SCRATCH_TMP_PATTERNS        the declared workspace families under $TMPDIR
      SCRATCH_LEGACY_TMP_PATTERNS the pre-existing families under $TMPDIR

    and this is their union, so a name family added to the reaper's coverage is
    covered for processes the same day, with no second edit.

    WHY THE $TMPDIR FAMILIES ARE KEPT AS PATTERNS AND NEVER GLOBBED. The first
    version of this file expanded them with glob() into a flat prefix list. It
    worked and it was correct, and it was also too slow to keep: MEASURED on
    this machine, deriving the list cost 1.11 s and matching 3 processes'
    open-file lists against the resulting 1,586 prefixes cost a further 1.07 s.

    That is the exact defect the scratch reaper already recorded once: widening
    its coverage made it do an lsof per candidate, its first dry run produced no
    output at all before being killed at 120 s, and its own note says "a reaper
    too slow to finish is a reaper that gets removed from the session-start
    path, and then nothing sweeps anything."

    So the same reduction it settled on is used here. Every $TMPDIR family
    matches DIRECT CHILDREN of $TMPDIR, so a path under $TMPDIR is decided by
    fnmatching its FIRST COMPONENT against the patterns — no filesystem walk at
    all, and a fixed handful of comparisons per path however many thousand
    directories happen to exist. 2.18 s becomes 0.01 s and stops growing with
    the size of $TMPDIR.

    NOTE ON `richos-qa-*`, which the brief that ordered this work named as a
    root family: it is in no engine allowlist, and it does not need to be. The
    candidate-.7 instance lived in
    `/private/tmp/claude-501/<slug>/<uuid>/scratchpad/richos-qa-cand7`, i.e. a
    subdirectory of a SESSION SCRATCHPAD, already covered by
    SCRATCH_CLAUDE_ROOTS as a prefix. Adding it as a $TMPDIR glob would have
    been a second definition of a path the first one already held.
    """

    def __init__(self, extra=()):
        self.dirs = []
        seen = set()

        def push(p):
            if p and p not in seen and p not in (
                    "/", "/tmp", "/private/tmp", "/var", "/private/var",
                    os.path.realpath(os.path.expanduser("~"))):
                seen.add(p)
                self.dirs.append(p)

        for r in declared("SCRATCH_CLAUDE_ROOTS",
                          "/private/tmp/claude-%u /tmp/claude-%u").split():
            push(_expand(r))
        self.tmp = os.path.realpath(os.environ.get("TMPDIR") or "/tmp")
        push(os.path.join(self.tmp,
                          declared("SCRATCH_ROOT_NAME", "richos-scratch")))
        self.tmp_patterns = (declared("SCRATCH_TMP_PATTERNS", "").split()
                             + declared("SCRATCH_LEGACY_TMP_PATTERNS",
                                        "").split())
        for p in extra or ():
            if p:
                push(os.path.realpath(os.path.expanduser(p)))
        self._tmp_prefix = self.tmp.rstrip("/") + "/"

    def match(self, path):
        """The root `path` lies under, or None. Never touches the filesystem."""
        for d in self.dirs:
            if inside(path, d):
                return d
        if path.startswith(self._tmp_prefix):
            rest = path[len(self._tmp_prefix):]
            if rest:
                first = rest.split("/", 1)[0]
                for pat in self.tmp_patterns:
                    if fnmatch.fnmatch(first, pat):
                        return self._tmp_prefix + first
        return None

    def describe(self):
        return "%d directory prefix(es) + %d $TMPDIR name family(ies)" % (
            len(self.dirs), len(self.tmp_patterns))


def scratch_roots(extra=()):
    """The RootSet for this machine. Kept as a function for the callers and the
    tests; the matcher, not a list, because a list is what was slow."""
    return RootSet(extra=extra)


def app_process_names():
    """The executables that ARE the app.

    Declared rather than guessed, and the reason it is a LIST is that the dev
    build and the bundled build share the Cargo package name `richos-tauri`
    (richos/app/src-tauri/Cargo.toml) while the bundle is called RichOS.
    """
    v = declared("APP_TEST_INSTANCE_PROCESS_NAMES", "richos-tauri")
    return set(v.split())


def real_home_prefixes():
    """Paths that mean "this is the operator's own instance, not a test one".

    NARROW ON PURPOSE. It is NOT "anything under $HOME": the executable of a
    perfectly ordinary test instance lives under $HOME (a git worktree, or
    ~/Applications/RichOS.app launched against a scratch HOME), so a broad
    $HOME test would classify every instance as the CEO's and collect nothing.
    These are the places the app keeps its STATE, which is what actually
    distinguishes whose instance it is.
    """
    home = os.path.realpath(os.path.expanduser("~"))
    ident = declared("APP_TEST_INSTANCE_BUNDLE_ID", "com.richos.app")
    out = [
        os.path.join(home, "Library", "Application Support", ident),
        os.path.join(home, "Library", "Caches", ident),
        os.path.join(home, "Library", "WebKit", ident),
        os.path.join(home, "Library", "Preferences", ident + ".plist"),
        os.path.join(home, "Library", "HTTPStorages", ident),
        os.path.join(home, ".richos"),
        os.path.join(home, ".richos-nightly"),
        os.path.join(home, ".richos-signing"),
        os.path.join(home, "RichOS"),
    ]
    extra = declared("APP_TEST_INSTANCE_REAL_HOME_PATHS", "")
    out.extend(_expand(p) for p in extra.split())
    return [os.path.realpath(p) for p in out]


def inside(child, parent):
    child, parent = child.rstrip("/"), parent.rstrip("/")
    return child == parent or child.startswith(parent + "/")


def _under_any(path, prefixes):
    for p in prefixes:
        if inside(path, p):
            return p
    return None


# ---------------------------------------------------------------------------
# reading the machine
# ---------------------------------------------------------------------------

def candidate_pids():
    """{pid: argv} for every process whose executable IS an app binary.

    ps first, lsof second, and never the other way round: lsof is asked ONLY
    about this handful of pids. A whole-machine lsof to find two processes is
    what made the first version of the widened scratch sweep too slow to
    finish -- it was killed at 120 s with exit 144, the same signal that killed
    the harness that left 105 GB. Cheap here means it stays wired in.
    """
    names = app_process_names()
    try:
        r = subprocess.run(["ps", "-axo", "pid=,comm=,args="],
                           capture_output=True, text=True, timeout=30,
                           env=_env())
    except (OSError, subprocess.TimeoutExpired):
        return None          # cannot tell: NOT "nothing is running"
    if r.returncode != 0:
        return None
    out = {}
    mypid = os.getpid()
    for line in r.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        pid = int(parts[0])
        if pid == mypid:
            continue
        rest = parts[1]
        # `comm` is the first field and may itself contain no spaces on macOS;
        # the basename of either comm or argv[0] is enough to shortlist, and a
        # false shortlist costs one lsof and is then denied for lack of
        # evidence.
        first = rest.split(None, 1)[0]
        tokens = {os.path.basename(first)}
        for tok in rest.split():
            tokens.add(os.path.basename(tok))
            if len(tokens) > 8:
                break
        if tokens & names:
            out[pid] = rest
    return out


# The lsof `f` (file descriptor) values that describe the program's own IMAGE
# rather than its data: the executable, memory-mapped files, the root directory.
#
# THESE ARE EXCLUDED FROM THE EVIDENCE, and that is a correction the test suite
# forced. The first version of this module counted every open path equally, and
# three cases failed as one defect: a stand-in app whose BINARY sat in a scratch
# sandbox but whose STATE was the operator's real app-support directory came out
# INDETERMINATE, a binary in a scratch sandbox writing to an undeclared /tmp file
# came out COLLECT, and the derivation test could not tell a declared family from
# an undeclared one because the executable matched either way.
#
# The principle the failures taught: THE EXECUTABLE'S LOCATION SAYS WHICH BUILD
# IS RUNNING, NEVER WHOSE INSTANCE IT IS. `~/Applications/RichOS.app` launched
# against a scratch home is a test instance; a scratch-built binary launched
# against the operator's real home is HIS instance and must be left alone. Only
# the working directory and the data files it actually holds open answer the
# question this module asks.
_IMAGE_FDS = frozenset(("txt", "mem", "rtd", "DEL", "ltx", "mmap"))


def _lsof_for(pids):
    """{pid: [(fd, absolute path)]} -- cwd, executable and every open file.

    The fd column is read (`-F pfn`, not `-F pn`) because the KIND of handle
    decides whether a path is evidence at all. See _IMAGE_FDS.
    """
    if not pids:
        return {}
    args = ["lsof", "-n", "-P", "-w", "-F", "pfn", "-p",
            ",".join(str(p) for p in sorted(pids))]
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=60,
                           env=_env())
    except (OSError, subprocess.TimeoutExpired):
        return None
    # lsof exits 1 when some of what it was asked about could not be listed,
    # which is normal; its stdout is still the answer for everything it COULD
    # read. Treating a partial answer as no answer would make every instance
    # permanently INDETERMINATE, and an alert that always fires is an alert
    # nobody reads.
    if r.returncode not in (0, 1):
        return None
    out, pid, fd = {}, None, ""
    for line in r.stdout.splitlines():
        if line.startswith("p"):
            try:
                pid = int(line[1:])
            except ValueError:
                pid = None
            if pid is not None:
                out.setdefault(pid, [])
            fd = ""
        elif line.startswith("f"):
            fd = line[1:]
        elif line.startswith("n") and pid is not None:
            p = line[1:]
            if p.startswith("/"):
                out[pid].append((fd, p))
    return out


class Instance(object):
    """One app process, its verdict, and the evidence for it."""

    def __init__(self, pid, argv, verdict, why, root=None, evidence=None):
        self.pid = pid
        self.argv = argv
        self.verdict = verdict
        self.why = why
        self.root = root
        self.evidence = evidence or []

    def __repr__(self):
        return "<Instance %d %s %s>" % (self.pid, self.verdict, self.root)

    def as_dict(self):
        return {"pid": self.pid, "verdict": self.verdict, "why": self.why,
                "root": self.root, "argv": self.argv,
                "evidence": self.evidence[:8]}


def classify(pid, argv, paths, roots, home_prefixes):
    """COLLECT / LEAVE / INDETERMINATE for one app process.

    `paths` is [(fd, path)] as _lsof_for returns it: cwd, executable, open
    files. `roots` is a RootSet.
    """
    if paths is None:
        return Instance(pid, argv, INDETERMINATE,
                        "its open files could not be read, so it cannot be "
                        "shown to be a test instance OR the operator's own")
    scratch, home = [], []
    root = None
    # realpath() is a stat per call and an app process's open-file list runs to
    # thousands of entries, nearly all of them shared libraries under /usr and
    # /System that no scratch root and no home prefix can ever match. Those are
    # rejected on a string test and never stat'ed; realpath is paid only for the
    # few paths that could still go either way, so a symlinked scratch dir is
    # still resolved and the common case costs nothing.
    for fd, p in paths:
        if fd in _IMAGE_FDS or p.startswith(_NEVER_RELEVANT):
            continue
        hit = roots.match(p)
        if hit is None:
            rp = os.path.realpath(p)
            hit = roots.match(rp)
        else:
            rp = p
        if hit:
            scratch.append(p)
            if root is None:
                root = hit
            continue
        if _under_any(p, home_prefixes) or _under_any(rp, home_prefixes):
            home.append(p)
    if scratch and home:
        return Instance(pid, argv, INDETERMINATE,
                        "it holds paths under a scratch root (%s) AND under "
                        "the operator's own app state (%s) — whose instance "
                        "this is cannot be decided, so it is left running"
                        % (scratch[0], home[0]), root, scratch + home)
    if home:
        return Instance(pid, argv, LEAVE,
                        "its app state is the operator's own (%s)" % home[0],
                        None, home)
    if scratch:
        return Instance(pid, argv, COLLECT,
                        "%d of its paths lie under the scratch root %s (e.g. "
                        "%s), and none lies under the operator's own app state"
                        % (len(scratch), root, scratch[0]), root, scratch)
    return Instance(pid, argv, LEAVE,
                    "nothing it holds lies under any declared scratch root, "
                    "so it is not a test instance", None, [])


def find(extra_roots=(), roots=None):
    """Every app process on this machine, classified.

    `extra_roots` is for the land step: an agent's own workspaces are scratch
    for the purposes of ITS land even though they are not under a scratch root.
    """
    all_roots = roots if roots is not None else RootSet(extra=extra_roots)
    home_prefixes = real_home_prefixes()

    cands = candidate_pids()
    if cands is None:
        return None          # the process table could not be read
    if not cands:
        return []
    seen = _lsof_for(list(cands))
    out = []
    for pid, argv in sorted(cands.items()):
        paths = None if seen is None else seen.get(pid, [])
        out.append(classify(pid, argv, paths, all_roots, home_prefixes))
    return out


# ---------------------------------------------------------------------------
# ending one
# ---------------------------------------------------------------------------

def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True
    return True


def _graceful(pid, timeout):
    """Ask the app to quit, addressed BY PID.

    System Events is the only quit channel that takes a pid. `tell application
    id "com.richos.app" to quit` and `tell application "RichOS" to quit` both
    address whichever instance the window server has registered for that
    name -- which, on a machine where the CEO has his own copy open, is HIS
    copy. The bundled binary and a test build share both the name and the
    identifier (see the module header), so addressing by either is the one
    mistake this whole mechanism must not make.

    A failure here is not an error: a headless or non-scriptable instance
    simply does not answer, and SIGTERM is next. Returns True only if the pid
    is actually gone afterwards.
    """
    script = ('tell application "System Events" to '
              'if exists (first process whose unix id is %d) then '
              'tell (first process whose unix id is %d) to quit' % (pid, pid))
    try:
        subprocess.run(["osascript", "-e", script], capture_output=True,
                       text=True, timeout=max(5, int(timeout)), env=_env())
    except (OSError, subprocess.TimeoutExpired):
        pass
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not alive(pid):
            return True
        time.sleep(0.1)
    return not alive(pid)


def quit_instance(pid, grace=None, kill_grace=None):
    """Graceful, then TERM, then KILL, then VERIFY. (gone, how).

    The order and the final verification are gui-launch.sh's gui_kill and
    workspaces.py's stop_processes, kept identical on purpose: a signal sent is
    not a process ended, and every other collector in this engine already
    proves the pid is gone rather than assuming it.
    """
    if grace is None:
        grace = float(declared("APP_TEST_INSTANCE_QUIT_GRACE_SECONDS", "8"))
    if kill_grace is None:
        kill_grace = float(declared("APP_TEST_INSTANCE_KILL_GRACE_SECONDS", "3"))
    if not alive(pid):
        return True, "already gone"
    if _graceful(pid, grace):
        return True, "quit gracefully within %gs" % grace
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass
    deadline = time.time() + kill_grace
    while time.time() < deadline:
        if not alive(pid):
            return True, "ended on SIGTERM after declining to quit"
        time.sleep(0.1)
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    deadline = time.time() + kill_grace
    while time.time() < deadline:
        if not alive(pid):
            return True, "killed after declining SIGTERM"
        time.sleep(0.1)
    return False, ("SURVIVED the quit request, SIGTERM and SIGKILL")


def collect(extra_roots=(), roots=None, dry_run=False):
    """Quit every collectable test instance. The one entry point for callers.

    Returns {"collected": [...], "survivors": [...], "left": [...],
             "undecided": [...], "unreadable": bool}

    `survivors` is the §54 failure case: garbage that could not be collected,
    which is the condition the CEO's ruling says must reach Rich as a MASSIVE
    ALERT rather than be silently dropped.
    """
    res = {"collected": [], "survivors": [], "left": [], "undecided": [],
           "unreadable": False}
    found = find(extra_roots=extra_roots, roots=roots)
    if found is None:
        res["unreadable"] = True
        return res
    for inst in found:
        if inst.verdict == LEAVE:
            res["left"].append(inst.as_dict())
            continue
        if inst.verdict == INDETERMINATE:
            res["undecided"].append(inst.as_dict())
            continue
        if dry_run:
            d = inst.as_dict()
            d["how"] = "would be quit (dry run)"
            res["collected"].append(d)
            continue
        gone, how = quit_instance(inst.pid)
        d = inst.as_dict()
        d["how"] = how
        (res["collected"] if gone else res["survivors"]).append(d)
    return res


def _main(argv):
    import argparse
    ap = argparse.ArgumentParser(
        description="Find, and optionally quit, test instances of the app.")
    ap.add_argument("--apply", action="store_true",
                    help="quit them; without this, only report")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--root", action="append", default=[],
                    help="an extra root to treat as scratch (repeatable)")
    a = ap.parse_args(argv)
    res = collect(extra_roots=a.root, dry_run=not a.apply)
    if a.json:
        print(json.dumps(res, indent=2, sort_keys=True))
    else:
        print("scratch roots: %s" % RootSet(extra=a.root).describe())
        if res["unreadable"]:
            print("INDETERMINATE: the process table could not be read")
        for key in ("collected", "survivors", "undecided", "left"):
            for d in res[key]:
                print("%-12s pid %-7d %s" % (key.upper(), d["pid"],
                                             d.get("how") or d["why"]))
        print("verdict: collected=%d survivors=%d undecided=%d left=%d"
              % (len(res["collected"]), len(res["survivors"]),
                 len(res["undecided"]), len(res["left"])))
    # 3 mirrors the reaper: anything undecided or surviving is a failure, never
    # a footnote beside a success-shaped count.
    if res["survivors"] or res["unreadable"]:
        return 1
    if res["undecided"]:
        return 3
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(_main(sys.argv[1:]))
