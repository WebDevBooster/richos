#!/usr/bin/env python3
"""scratch-reaper.py — the scan, the verdict and the deletion. No schedule here.

===========================================================================
WHAT THIS IS FOR
===========================================================================
On 2026-09-17 macOS said "Your disk is almost full" — 1.8 GB free of 460 GB.
19 GB of it was scratch that nothing was using, and it was reclaimed because a
person read the warning and deleted it by hand. That is the failure: not the
garbage, THE PERSON. The CEO's words the same morning: "There needs to be a
mechanism to make sure that scratch directories get deleted on a regular
basis. I don't want piles of garbage to pile up endlessly."

===========================================================================
THE ONE RULE THAT DECIDES EVERYTHING HERE
===========================================================================
A scratch directory is deleted because SOMETHING PROVED NOBODY OWNS IT, never
because it looks old. Age is a floor applied AFTER the proof, and it exists
only to cover the seconds between a session starting and recording itself.

The proof has three possible answers and THREE is not folded into two:

  RUNNING        a session file names this session and its process, and that
                 process is still the same process. Kept, always.
  ENDED          no running `claude` process on this machine is this session,
                 established by EXHAUSTION: every running claude process is
                 named by a session file, and none of them names this one.
  INDETERMINATE  a claude process is running that NO session file names, and
                 it started early enough that it could be the owner. Kept,
                 counted, and named in the verdict line.

INDETERMINATE is never collapsed into ENDED. The whole reason this engine
carries an agent-liveness module at all is the 2026-08-31 incident in which a
confident wrong answer beat an honest "I cannot tell" — absence prompts a
check, a false positive does not.

The liveness primitive is NOT reimplemented here. process_start() comes from
mega-lander/workspaces.py, which is where "ended is read from the operating
system, never guessed" already lives (spec point 12). If that import fails
this module FAILS LOUD rather than falling back to a weaker test: a reaper
that silently downgrades its own liveness check is the one shape of this
program nobody could ever notice was broken.

===========================================================================
WHAT IT WILL DELETE, AND THE FOUR WALLS IT GOES THROUGH FIRST
===========================================================================
Classes (each named in the log line, so every deletion says why):

  claude-session   <root>/<slug>/<session-uuid> whose session is ENDED
  claude-husk      a <root>/<slug> directory left empty by the above
  claude-orphan    a file or non-session directory sitting directly in a
                   scratch root whose mtime PREDATES THE START OF EVERY
                   RUNNING claude PROCESS — so no running session can have
                   written it, and none can write it again
  tmp-workspace    a $TMPDIR directory matching a declared pattern that no
                   process holds open
  nightly-release  / nightly-log  beyond the declared retention

Walls, applied to every candidate, in order, after the verdict and before the
unlink. Any wall that trips makes the entry INDETERMINATE — never a silent
skip, because a candidate that cannot be deleted for a structural reason is
exactly the thing somebody needs to read:

  1. CONTAINMENT   the real path must sit strictly inside a declared root,
                   and at least one component below it. A symlink is never
                   followed; the link itself is what would be removed.
  2. NO REPOSITORY the tree must contain no .git anywhere. A scratch
                   directory holding a checkout is somebody's work.
  3. NOT REGISTERED no registered workspace path may be the candidate, sit
                   inside it, or contain it. Read from the workspace registry
                   and the worktree ledger — the same two files the worktree
                   reaper reads.
  4. NEVER-TOUCH   $HOME, ~/.claude, ~/RichOS, ~/.richos-signing, the nightly
                   source worktree and the nightly runtime, by name.

===========================================================================
WHAT IT WILL NOT DELETE, MEASURED RATHER THAN PROMISED (2026-09-17)
===========================================================================
  * The live session's own scratchpad — 4,270 MB of the 5.2 GB under
    /private/tmp/claude-501 on the morning this was written. The reaper that
    would have prevented that morning's disk-full warning does not exist,
    because the biggest pile belonged to a session that was RUNNING.
  * ~/.richos-nightly/source — 5.89 GB, and A REGISTERED GIT WORKTREE. Walls
    2 and 3 both refuse it and the config never nominates it.
  * The 244 loose *.out files in the scratch root that morning: every one had
    an mtime AFTER the live session's process started, so the claude-orphan
    rule kept all of them. A rule that deletes nothing on the day it ships is
    a rule whose safety is measurable.
"""

import argparse
import fnmatch
import glob
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

RUNNING = "RUNNING"
ENDED = "ENDED"
INDETERMINATE = "INDETERMINATE"

DELETE = "DELETE"
KEEP = "KEEP"

UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                     r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


class Fatal(Exception):
    """Something this program refuses to work around."""


class Deadline(Exception):
    """The scan ran out of the budget its caller gave it.

    Only --notice sets one. A SessionStart notice that adds seconds to every
    session start is a notice somebody removes, and the honest failure is to
    say the scan could not finish rather than to hold the session open."""


_DEADLINE = [None]


def check_deadline():
    if _DEADLINE[0] is not None and time.time() > _DEADLINE[0]:
        raise Deadline("the scan exceeded its budget")


# ---------------------------------------------------------------------------
# the liveness primitive, borrowed rather than rewritten
# ---------------------------------------------------------------------------

def load_workspaces():
    """mega-lander/workspaces.py, or Fatal. ONE PREDICATE, MANY CALLERS."""
    lib = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "..", "mega-lander", "workspaces.py")
    lib = os.path.normpath(lib)
    if not os.path.exists(lib):
        raise Fatal("the liveness primitive is missing: %s. Nothing here may "
                    "guess at whether a session is alive." % lib)
    try:
        spec = importlib.util.spec_from_file_location("sr_workspaces", lib)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as exc:                                  # pragma: no cover
        raise Fatal("the liveness primitive could not be loaded from %s: %s"
                    % (lib, exc))
    for fn in ("process_start", "session_state"):
        if not hasattr(mod, fn):
            raise Fatal("%s carries no %s(); the liveness contract this reaper "
                        "depends on has moved." % (lib, fn))
    return mod


def sessions_dir():
    """The platform's session registry — the same resolution workspaces.py
    uses, spelled out here because this module may run with no session at
    all (launchd), where CLAUDE_CONFIG_DIR is not exported."""
    d = (os.environ.get("RICHOS_SESSIONS_DIR") or "").strip()
    if d:
        return d
    base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() \
        or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "sessions")


def _ps_env():
    return dict(os.environ, LC_ALL="C", LANG="C", TZ="UTC0")


def session_process_names():
    v = (os.environ.get("SCRATCH_SESSION_PROCESS_NAMES") or "").strip()
    if not v:
        raise Fatal(
            "SCRATCH_SESSION_PROCESS_NAMES is not declared. The reaper decides "
            "that a session is gone by accounting for every session process on "
            "the machine; without the list of names that ARE sessions it would "
            "be accounting for nothing and calling it proof.")
    return set(v.split())


def claude_processes():
    """[(pid, lstart)] for every session process of THIS user.

    TZ=UTC0 is not cosmetic: the session files record `ps -o lstart=` under
    that environment, and a start time read in local time never compares equal
    to the one on disk. Measured 2026-09-17: the same process reads
    "Thu 17 Sep 00:31:27 2026" locally and "Wed Sep 16 23:31:27 2026" under
    TZ=UTC0, which is what the registration holds."""
    try:
        r = subprocess.run(["ps", "-Ao", "pid=,uid=,lstart=,comm="],
                           capture_output=True, text=True, timeout=20,
                           env=_ps_env())
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Fatal("the process table could not be read (%s), so nothing can "
                    "be shown to be dead." % exc)
    if r.returncode != 0:
        raise Fatal("ps exited %d reading the process table: %s"
                    % (r.returncode, r.stderr.strip()[:200]))
    uid = str(os.getuid())
    names = session_process_names()
    out = []
    for line in r.stdout.splitlines():
        parts = line.split()
        # pid uid <lstart: 5 fields> comm...
        if len(parts) < 8 or parts[1] != uid:
            continue
        comm = " ".join(parts[7:])
        if os.path.basename(comm) not in names:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        out.append((pid, " ".join(parts[2:7])))
    return out


def lstart_epoch(text):
    """`ps -o lstart=` under TZ=UTC0 -> epoch seconds, or None."""
    try:
        return int(time.mktime(time.strptime(text, "%a %b %d %H:%M:%S %Y"))
                   - time.timezone)
    except (ValueError, OverflowError):
        return None


class Liveness(object):
    """Who is running, and what that lets us say about who is not."""

    def __init__(self, ws):
        self.ws = ws
        self.registered = {}     # pid -> sessionId, from the session files
        self.running = {}        # sessionId -> (pid, why)
        self.unattributed = []   # [(pid, lstart, epoch)]
        self.notes = []
        self._processes = claude_processes()
        self._oldest = False     # False = not read yet; None = unreadable
        self._read()

    def _read(self):
        sd = sessions_dir()
        for path in sorted(glob.glob(os.path.join(sd, "*.json"))):
            try:
                with open(path, encoding="utf-8") as fh:
                    rec = json.load(fh)
            except (OSError, ValueError):
                continue
            pid, sid = rec.get("pid"), str(rec.get("sessionId") or "")
            if not pid or not sid:
                continue
            self.registered[int(pid)] = sid
            state, text = self.ws.process_start(pid)
            if state == "ok" and text == str(rec.get("procStart") or ""):
                self.running[sid] = (int(pid), "process %d of session %s runs"
                                     % (int(pid), sid[:8]))
            elif state == "ok":
                # The pid was reused. The session is gone; the file is stale.
                self.notes.append(
                    "session file %s names pid %s, which is now a different "
                    "process — the registration is stale, not live"
                    % (os.path.basename(path), pid))

        for pid, lstart in self._processes:
            if pid in self.registered:
                continue
            self.unattributed.append((pid, lstart, lstart_epoch(lstart)))

        if self.unattributed:
            self.notes.append(
                "%d running claude process(es) are named by NO session file "
                "(%s) — anything they could own is INDETERMINATE"
                % (len(self.unattributed),
                   ", ".join(str(p) for p, _, _ in self.unattributed)))

    def oldest_unattributed_start(self):
        eps = [e for _, _, e in self.unattributed if e is not None]
        if len(eps) < len(self.unattributed):
            return 0          # a start time we could not parse: assume ancient
        return min(eps) if eps else None

    def oldest_start(self):
        """The start of the EARLIEST running claude process, attributed or
        not. Nothing written before this can have been written by anything
        that is still running. Read ONCE: the process table is a snapshot, and
        two readings of it inside one pass could disagree with each other."""
        if self._oldest is not False:
            return self._oldest
        eps = []
        for pid, lstart in self._processes:
            e = lstart_epoch(lstart)
            if e is None:
                self._oldest = None
                return None
            eps.append(e)
        self._oldest = min(eps) if eps else None
        return self._oldest

    def verdict(self, session_id, newest_mtime):
        """(RUNNING|ENDED|INDETERMINATE, why) for one session's scratch."""
        if session_id in self.running:
            return RUNNING, self.running[session_id][1]
        state, why = self.ws.session_state(session_id)
        if state == "running":
            return RUNNING, "the workspace registry says " + why
        cutoff = self.oldest_unattributed_start()
        if cutoff is not None and newest_mtime >= cutoff:
            return (INDETERMINATE,
                    "a running claude process is named by no session file and "
                    "started before this scratch was last written, so it could "
                    "own it")
        if state == "ended":
            return ENDED, why + ", and no running claude process is this session"
        return (ENDED,
                "no running claude process is session %s: every claude process "
                "on this machine is named by a session file and none names it"
                % session_id[:8])


# ---------------------------------------------------------------------------
# the walls
# ---------------------------------------------------------------------------

def never_touch():
    home = os.path.expanduser("~")
    out = [home,
           os.path.join(home, ".claude"),
           os.path.join(home, "RichOS"),
           os.path.join(home, ".richos-signing"),
           os.path.join(home, ".richos-nightly"),
           os.path.join(home, ".richos-nightly", "source"),
           os.path.join(home, ".richos-nightly", "runtime"),
           "/", "/tmp", "/private/tmp", "/var", "/private/var"]
    return set(os.path.realpath(p) for p in out)


def registered_workspaces():
    """Every path the workspace registry or the worktree ledger calls a
    workspace. The reaper reads the SAME two files the worktree reaper does,
    so the two can never disagree about what is registered."""
    base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() \
        or os.path.join(os.path.expanduser("~"), ".claude")
    paths = set()

    def harvest(obj):
        if isinstance(obj, dict):
            for key, val in obj.items():
                if key in ("worktree", "workspaces", "path", "dir") and val:
                    if isinstance(val, str):
                        paths.add(val)
                    elif isinstance(val, list):
                        paths.update(v for v in val if isinstance(v, str))
                elif isinstance(val, (dict, list)):
                    harvest(val)
        elif isinstance(obj, list):
            for item in obj:
                harvest(item)

    for p in glob.glob(os.path.join(base, "state", "workspaces", "agents", "*.json")):
        try:
            with open(p, encoding="utf-8") as fh:
                harvest(json.load(fh))
        except (OSError, ValueError):
            continue
    ledger = os.path.join(base, "state", "worktree-ledger.jsonl")
    try:
        with open(ledger, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    harvest(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    return set(os.path.realpath(p) for p in paths if os.path.isabs(p))


def inside(child, parent):
    child, parent = child.rstrip("/"), parent.rstrip("/")
    return child == parent or child.startswith(parent + "/")


class Walls(object):
    def __init__(self, roots):
        self.roots = [os.path.realpath(r) for r in roots]
        self.never = never_touch()
        self.registered = registered_workspaces()

    def check(self, path, has_git):
        """'' if the path may be deleted, else why it may not."""
        real = os.path.realpath(path)
        if real in self.never:
            return "wall 4: %s is on the never-touch list" % real
        if not any(inside(real, r) and real != r for r in self.roots):
            return ("wall 1: %s is not inside any declared scratch root (%s)"
                    % (real, ", ".join(self.roots) or "none"))
        if has_git:
            return ("wall 2: this tree contains a .git — it is a checkout, not "
                    "scratch. If it is a test fixture, it is yours to delete by "
                    "hand; this program will not.")
        for reg in self.registered:
            if inside(reg, real) or inside(real, reg):
                return ("wall 3: %s is a REGISTERED workspace" % reg)
        return ""


# ---------------------------------------------------------------------------
# measuring
# ---------------------------------------------------------------------------

def measure(path):
    """(bytes_on_disk, newest_mtime, contains_git). Errors are skipped, never
    guessed at: a file that vanished mid-walk was never going to be freed."""
    total, newest, has_git = 0, 0.0, False
    try:
        st = os.lstat(path)
    except OSError:
        return 0, 0.0, False
    newest = st.st_mtime
    total = getattr(st, "st_blocks", 0) * 512 or st.st_size
    if not os.path.isdir(path) or os.path.islink(path):
        return total, newest, False
    stack = [path]
    while stack:
        check_deadline()
        cur = stack.pop()
        try:
            entries = list(os.scandir(cur))
        except OSError:
            continue
        for e in entries:
            if e.name == ".git":
                has_git = True
            try:
                st = e.stat(follow_symlinks=False)
            except OSError:
                continue
            total += getattr(st, "st_blocks", 0) * 512 or st.st_size
            newest = max(newest, st.st_mtime)
            if e.is_dir(follow_symlinks=False):
                stack.append(e.path)
    return total, newest, has_git


def human(n):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" % (n, unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0
    return str(n)


# ---------------------------------------------------------------------------
# the plan
# ---------------------------------------------------------------------------

class Entry(object):
    def __init__(self, path, klass, size, action, why):
        self.path, self.klass, self.size = path, klass, size
        self.action, self.why = action, why

    def key(self):
        return (self.klass, self.path)


class Reaper(object):
    def __init__(self, cfg, ws):
        self.cfg = cfg
        self.ws = ws
        self.live = Liveness(ws)
        self.entries = []
        self.roots = []
        self.floor = cfg["age_floor_minutes"] * 60
        self.now = time.time()

    def add(self, path, klass, size, action, why):
        self.entries.append(Entry(path, klass, size, action, why))

    # --- classes ---------------------------------------------------------

    def scan_claude_roots(self, walls):
        for root in self.cfg["claude_roots"]:
            if not os.path.isdir(root):
                continue
            self.roots.append(root)
            oldest = self.live.oldest_start()
            for name in sorted(os.listdir(root)):
                entry = os.path.join(root, name)
                if os.path.isdir(entry) and not os.path.islink(entry):
                    self.scan_slug(entry, walls)
                else:
                    self.scan_orphan(entry, walls, oldest)

    def scan_slug(self, slug, walls):
        try:
            children = sorted(os.listdir(slug))
        except OSError:
            return
        sessions = [c for c in children if UUID_RE.match(c)]
        if not sessions:
            self.scan_orphan(slug, walls, self.live.oldest_start())
            return
        dead = 0
        for name in sessions:
            path = os.path.join(slug, name)
            # THE LIVE CHECK COMES BEFORE THE WALK, and not for tidiness: the
            # live session's scratchpad was 4.27 GB on the morning this was
            # written, and walking it is most of what a pass costs. A session
            # that is running is not a candidate, so its size is never needed.
            if name in self.live.running:
                self.add(path, "claude-session", 0, KEEP,
                         self.live.running[name][1] + " (not measured: a live "
                         "session is never a candidate)")
                continue
            size, newest, has_git = measure(path)
            state, why = self.live.verdict(name, newest)
            if state == RUNNING:
                self.add(path, "claude-session", size, KEEP, why)
                continue
            if state == INDETERMINATE:
                self.add(path, "claude-session", size, INDETERMINATE, why)
                continue
            age = self.now - newest
            if age < self.floor:
                self.add(path, "claude-session", size, KEEP,
                         "%s, but it was written %d min ago and the floor is "
                         "%d min" % (why, age // 60,
                                     self.cfg["age_floor_minutes"]))
                continue
            refused = walls.check(path, has_git)
            if refused:
                self.add(path, "claude-session", size, INDETERMINATE, refused)
                continue
            self.add(path, "claude-session", size, DELETE, why)
            dead += 1
        if dead == len(children):
            size, _, has_git = measure(slug)
            refused = walls.check(slug, has_git)
            if not refused:
                self.add(slug, "claude-husk", 0, DELETE,
                         "every session directory in this scratch root is "
                         "being deleted, so the root is left empty")

    def scan_orphan(self, path, walls, oldest_start):
        size, newest, has_git = measure(path)
        if oldest_start is None:
            self.add(path, "claude-orphan", size, INDETERMINATE,
                     "no process start time could be read, so it cannot be "
                     "shown that no running session wrote this")
            return
        if newest >= oldest_start:
            self.add(path, "claude-orphan", size, KEEP,
                     "written after the earliest running claude process "
                     "started, so a running session may own it")
            return
        if (self.now - newest) < self.floor:
            self.add(path, "claude-orphan", size, KEEP,
                     "younger than the %d min floor" % self.cfg["age_floor_minutes"])
            return
        refused = walls.check(path, has_git)
        if refused:
            self.add(path, "claude-orphan", size, INDETERMINATE, refused)
            return
        self.add(path, "claude-orphan", size, DELETE,
                 "no claude process running on this machine existed when this "
                 "was last written, so none of them wrote it and none can "
                 "write it again")

    def scan_tmp(self, walls):
        tmp = os.environ.get("TMPDIR") or "/tmp"
        tmp = os.path.realpath(tmp)
        if not os.path.isdir(tmp):
            return
        self.roots.append(tmp)
        for name in sorted(os.listdir(tmp)):
            if not any(fnmatch.fnmatch(name, pat)
                       for pat in self.cfg["tmp_patterns"]):
                continue
            path = os.path.join(tmp, name)
            if not os.path.isdir(path) or os.path.islink(path):
                continue
            size, newest, has_git = measure(path)
            if (self.now - newest) < self.floor:
                self.add(path, "tmp-workspace", size, KEEP,
                         "younger than the %d min floor"
                         % self.cfg["age_floor_minutes"])
                continue
            holder = self.holder(path)
            if holder is None:
                self.add(path, "tmp-workspace", size, INDETERMINATE,
                         "lsof could not answer whether a process holds this "
                         "open, and a temp workspace is only dead when its "
                         "creator is")
                continue
            if holder:
                self.add(path, "tmp-workspace", size, KEEP,
                         "held open by pid %s" % holder)
                continue
            refused = walls.check(path, has_git)
            if refused:
                self.add(path, "tmp-workspace", size, INDETERMINATE, refused)
                continue
            self.add(path, "tmp-workspace", size, DELETE,
                     "matches a declared harness pattern and no process holds "
                     "it open, so its creator is gone")

    def holder(self, path):
        """'' nobody, '<pids>' somebody, None cannot tell."""
        try:
            r = subprocess.run(["lsof", "-t", "--", path], capture_output=True,
                               text=True, timeout=20, env=_ps_env())
        except (OSError, subprocess.TimeoutExpired):
            return None
        if r.returncode not in (0, 1):
            return None
        return " ".join(r.stdout.split())

    def scan_nightly(self, walls):
        base = self.cfg["nightly_dir"]
        keep = self.cfg["nightly_keep"]
        for sub, klass, pattern in (("releases", "nightly-release", "*"),
                                    ("logs", "nightly-log", "*.log")):
            d = os.path.join(base, sub)
            if not os.path.isdir(d):
                continue
            self.roots.append(d)
            items = []
            for name in os.listdir(d):
                if not fnmatch.fnmatch(name, pattern):
                    continue
                path = os.path.join(d, name)
                size, newest, has_git = measure(path)
                items.append((newest, path, size, has_git))
            items.sort(reverse=True)
            for i, (newest, path, size, has_git) in enumerate(items):
                if i < keep:
                    self.add(path, klass, size, KEEP,
                             "one of the %d newest kept by declaration" % keep)
                    continue
                if (self.now - newest) < self.floor:
                    self.add(path, klass, size, KEEP,
                             "younger than the %d min floor"
                             % self.cfg["age_floor_minutes"])
                    continue
                refused = walls.check(path, has_git)
                if refused:
                    self.add(path, klass, size, INDETERMINATE, refused)
                    continue
                self.add(path, klass, size, DELETE,
                         "#%d newest of %d, and the declared retention is %d"
                         % (i + 1, len(items), keep))

    # --- running it ------------------------------------------------------

    def scan(self):
        roots = [r for r in self.cfg["claude_roots"] if os.path.isdir(r)]
        tmp = os.path.realpath(os.environ.get("TMPDIR") or "/tmp")
        nightly = [os.path.join(self.cfg["nightly_dir"], s)
                   for s in ("releases", "logs")]
        walls = Walls(roots + [tmp] + nightly)
        self.scan_claude_roots(walls)
        self.scan_tmp(walls)
        self.scan_nightly(walls)
        self.entries.sort(key=Entry.key)
        return self.entries

    def report(self, verbose=False):
        """The plan, with NO timestamps and no elapsed anything in it, so that
        --dry-run and --apply can be compared byte for byte."""
        out = []
        for line in self.live.notes:
            out.append("note: " + line)
        live = sorted(self.live.running.items())
        out.append("live sessions: %s"
                   % (", ".join("%s (pid %d)" % (s[:8], p)
                                for s, (p, _) in live) or "none"))
        for e in self.entries:
            if e.action == KEEP and not verbose:
                continue
            out.append("%-13s %10s  %s" % (e.action, human(e.size), e.path))
            out.append("%13s %10s  why: %s" % ("", "", e.why))
        out.append(self.verdict_line())
        return "\n".join(out)

    def counts(self):
        d = sum(1 for e in self.entries if e.action == DELETE)
        i = sum(1 for e in self.entries if e.action == INDETERMINATE)
        k = sum(1 for e in self.entries if e.action == KEEP)
        b = sum(e.size for e in self.entries if e.action == DELETE)
        return d, i, k, b

    def undecidable_bytes(self):
        return sum(e.size for e in self.entries if e.action == INDETERMINATE)

    def verdict_line(self):
        d, i, k, b = self.counts()
        return ("verdict: %s deletable=%d reclaimable=%s kept=%d "
                "undecidable=%d" % ("undecided" if i else "decided",
                                    d, human(b), k, i))

    def apply(self, log_path):
        """Delete, one line per deletion, freed bytes counted from what the
        walk measured. Returns (deleted, freed, failures)."""
        import shutil
        deleted, freed, failures = 0, 0, []
        lines = []
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        # DEEPEST FIRST. A husk and the sessions inside it are both on the
        # plan; removing the husk first would leave every child reported as a
        # FAILED deletion that had in fact just succeeded, which is the one
        # kind of log line nobody can act on.
        order = sorted((e for e in self.entries if e.action == DELETE),
                       key=lambda e: (-e.path.count(os.sep), e.path))
        for e in order:
            try:
                if os.path.islink(e.path) or os.path.isfile(e.path):
                    os.unlink(e.path)
                else:
                    shutil.rmtree(e.path)
            except OSError as exc:
                failures.append("%s: %s" % (e.path, exc))
                lines.append("%s FAILED %s bytes=%d class=%s why=%s error=%s"
                             % (stamp, e.path, e.size, e.klass, e.why, exc))
                continue
            deleted += 1
            freed += e.size
            lines.append("%s DELETED %s bytes=%d class=%s why=%s"
                         % (stamp, e.path, e.size, e.klass, e.why))
        lines.append("%s verdict: deleted=%d freed=%d freed_human=%s "
                     "undecidable=%d failures=%d"
                     % (stamp, deleted, freed, human(freed),
                        self.counts()[1], len(failures)))
        write_log(log_path, lines)
        return deleted, freed, failures


def write_log(path, lines):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            for line in lines:
                fh.write(line + "\n")
    except OSError as exc:                                    # pragma: no cover
        sys.stderr.write("scratch-reaper: could not write the log at %s: %s\n"
                         % (path, exc))


# ---------------------------------------------------------------------------
# configuration — declared, never defaulted
# ---------------------------------------------------------------------------

def config_from_env():
    def need(name):
        v = (os.environ.get(name) or "").strip()
        if not v:
            raise Fatal(
                "%s is not declared. Every threshold this program uses is "
                "declared in orchestration.config with the reason beside it; "
                "a value taken from a tool's default is a value nobody chose."
                % name)
        return v

    def number(name):
        v = need(name)
        try:
            return int(v)
        except ValueError:
            raise Fatal("%s is declared as %r, which is not a number." % (name, v))

    uid = str(os.getuid())
    roots = [r.replace("%u", uid) for r in need("SCRATCH_CLAUDE_ROOTS").split()]
    seen, ordered = set(), []
    for r in roots:
        real = os.path.realpath(r)
        if real in seen:
            continue
        seen.add(real)
        ordered.append(real)
    return {
        "claude_roots": ordered,
        "tmp_patterns": need("SCRATCH_TMP_PATTERNS").split(),
        "age_floor_minutes": number("SCRATCH_AGE_FLOOR_MINUTES"),
        "nightly_dir": os.path.expanduser(need("SCRATCH_NIGHTLY_DIR")),
        "nightly_keep": number("SCRATCH_NIGHTLY_KEEP"),
        "notice_bytes": number("SCRATCH_NOTICE_BYTES"),
        "session_process_names": sorted(session_process_names()),
    }


def state_base():
    base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() \
        or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "state")


def default_log():
    return os.environ.get("SCRATCH_REAPER_LOG") \
        or os.path.join(state_base(), "scratch-reaper.log")


def default_state():
    """What the LAST --apply did. The SessionStart notice reads it to answer
    the question the reclaimable byte count cannot: is the scheduled job still
    running at all? A scheduled deleter that quietly stopped looks exactly
    like a machine with no garbage on it."""
    return os.environ.get("SCRATCH_REAPER_STATE") \
        or os.path.join(state_base(), "scratch-reaper-state.json")


def write_state(path, payload):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=1, sort_keys=True)
        os.replace(tmp, path)
    except OSError as exc:                                    # pragma: no cover
        sys.stderr.write("scratch-reaper: could not write %s: %s\n" % (path, exc))


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True, description=__doc__)
    ap.add_argument("--apply", action="store_true",
                    help="delete. Without it nothing is deleted.")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--verbose", action="store_true",
                    help="show the KEEP rows too — the whole reasoning.")
    ap.add_argument("--notice", action="store_true",
                    help="print ONE line if more than the declared threshold "
                         "is reclaimable, and nothing otherwise.")
    ap.add_argument("--log", default=None)
    ap.add_argument("--deadline", type=float, default=None,
                    help="seconds the scan may take before it gives up and "
                         "says so. For --notice only.")
    args = ap.parse_args(argv)

    if args.deadline:
        _DEADLINE[0] = time.time() + args.deadline
    try:
        cfg = config_from_env()
        ws = load_workspaces()
        reaper = Reaper(cfg, ws)
        reaper.scan()
    except Fatal as exc:
        sys.stderr.write("scratch-reaper: %s\n" % exc)
        return 2
    except Deadline:
        if args.notice:
            print("SCRATCH: the reclaimable-scratch scan did not finish within "
                  "%.0fs, so how much dead scratch is on this disk is UNKNOWN. "
                  "Read it by hand: %s --verbose"
                  % (args.deadline, os.path.join(
                      os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "scratch-reaper.sh")))
            return 3
        sys.stderr.write("scratch-reaper: the scan exceeded its %.0fs budget.\n"
                         % args.deadline)
        return 3

    deleted, freed, undecidable = 0, 0, reaper.counts()[1]

    if args.notice:
        d, i, k, b = reaper.counts()
        cmd = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "scratch-reaper.sh")
        if b >= cfg["notice_bytes"]:
            print("SCRATCH: %s of dead scratch in %d place(s) is reclaimable "
                  "now — nothing running owns any of it. Free it: %s --apply"
                  % (human(b), d, cmd))
        # The undecidable pile gets its own line and its own threshold. It is
        # the one thing the scheduled job will NEVER clear on its own, so if
        # nobody is told, it grows forever — which is the exact failure the
        # whole mechanism was ordered to end.
        if reaper.undecidable_bytes() >= cfg["notice_bytes"]:
            print("SCRATCH: %s in %d place(s) could not be decided and will "
                  "never be reclaimed by the scheduled job. Read why: %s "
                  "--verbose" % (human(reaper.undecidable_bytes()), i, cmd))
        return 3 if undecidable else 0

    if args.apply:
        deleted, freed, failures = reaper.apply(args.log or default_log())
        write_state(default_state(), {
            "last_apply": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "deleted": deleted, "freed": freed,
            "undecidable": undecidable, "failures": len(failures),
            "verdict": "undecided" if undecidable else "decided",
        })
    if args.json:
        print(json.dumps({
            "verdict": "undecided" if undecidable else "decided",
            "applied": bool(args.apply),
            "deleted": deleted, "freed": freed,
            "undecidable": undecidable,
            "entries": [{"path": e.path, "class": e.klass, "bytes": e.size,
                         "action": e.action, "why": e.why}
                        for e in reaper.entries],
        }, indent=1, sort_keys=True))
    else:
        print(reaper.report(verbose=args.verbose))
        if args.apply:
            print("applied: deleted=%d freed=%s log=%s"
                  % (deleted, human(freed), args.log or default_log()))
    return 3 if undecidable else 0


if __name__ == "__main__":
    sys.exit(main())
