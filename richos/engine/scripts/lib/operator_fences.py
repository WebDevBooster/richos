#!/usr/bin/env python3
"""operator_fences.py: the land lease, the Git fence and the merge-ownership record.

Spec: richos-hq docs/plans/2026-09-24-operator-back-end-spec-r3.md (Sage, e1, e2,
e6, e7, e8), with Frank's final check G1-G12 applied on top of it
(docs/plans/2026-09-24-operator-back-end-spec-r3-frank-check.md). The as-built
record, including every deviation from r3, is richos-hq
docs/verification/2026-09-24-operator-fences/README.md.

WHY ONE FILE. The same code runs in three places:
  * from the engine, as `land-lease.sh` and `operator-fences.sh`;
  * from the engine, inside Claude Code hooks (the turn-end release, the early
    Bash check, the unfinished-land guard's ownership question);
  * inside Git, as the fence step of the `reference-transaction` launcher. For
    that one, `operator-fences.sh install` COPIES this file into
    <common>/hooks/operator-fences/, the same way install-ref-forensics.sh copies
    the recorder: a Git hook must not depend on where an engine checkout happens
    to be standing today. `operator-fences.sh status` compares the copy's digest
    with this file, so a stale copy is reported, never silently trusted.
So the file imports nothing outside the standard library at module level. The
one engine import (mega-lander/workspaces.py, for the lease's keying rule) is
made only by the admin and lease commands, which always run from the engine.

WHAT NEVER HAPPENS HERE. Nothing is ever signaled. Every process identity is a
pid PLUS its start time, read from the kernel (libproc on macOS, /proc on
Linux), so a recycled pid is never mistaken for the holder. Ancestry decides
ownership; a process name never does. The argv of the writing Git process is
read in exactly two places (G4's pack-refs, and `git worktree add`), and only to
PASS an update, never to select anything.

THE SWITCH. Every decision here is reachable only when the repository's
launcher says OPERATOR_FENCES_STATE="on" (G12). With it off, the lease commands
are no-ops that say so, the hooks return at once, and the launcher never calls
this file at all.
"""
import calendar
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time

MAIN = "refs/heads/main"
MAIN_SYMREF = "ref:" + MAIN
MARKER = "richos-operator-fence-launcher"
EXIT_HELD = 75
DEFAULT_WAIT = 90.0     # G7: the Claude Code Bash tool's own default is 120 s
MAX_WAIT = 540.0        # e1: one call, its start-up and its report fit in 600 s
DEFAULT_TTL = 1800.0    # e1: a non-Claude lease lives 30 minutes past each acquire
CHAIN_DIR = "reference-transaction.d"
RECORDER_SLOT = "20-ref-transaction-forensics.sh"
REPOSITORY_SLOT = "50-repository-hook"
_ZERO = re.compile(r"^0+$")
_CONF = re.compile(r'^OPERATOR_FENCES_([A-Z_]+)="([^"]*)"\s*$')


def is_zero(value):
    return bool(_ZERO.match(value or ""))


# ---------------------------------------------------------------------------
# processes, read from the kernel in process
# ---------------------------------------------------------------------------

class _BSDInfo(ctypes.Structure):
    # struct proc_bsdinfo, <sys/proc_info.h>; 136 bytes, asserted at load.
    _fields_ = [("flags", ctypes.c_uint32), ("status", ctypes.c_uint32), ("xstatus", ctypes.c_uint32),
                ("pid", ctypes.c_uint32), ("ppid", ctypes.c_uint32), ("uid", ctypes.c_uint32),
                ("gid", ctypes.c_uint32), ("ruid", ctypes.c_uint32), ("rgid", ctypes.c_uint32),
                ("svuid", ctypes.c_uint32), ("svgid", ctypes.c_uint32), ("rfu", ctypes.c_uint32),
                ("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32), ("nfiles", ctypes.c_uint32),
                ("pgid", ctypes.c_uint32), ("pjobc", ctypes.c_uint32), ("tdev", ctypes.c_uint32),
                ("tpgid", ctypes.c_uint32), ("nice", ctypes.c_int32), ("start_sec", ctypes.c_uint64),
                ("start_usec", ctypes.c_uint64)]


_LIB = False
_SZOMB = 5


def _libproc():
    global _LIB
    if _LIB is False:
        _LIB = None
        if sys.platform == "darwin":
            try:
                lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
                if ctypes.sizeof(_BSDInfo) == 136:
                    _LIB = lib
            except OSError:
                _LIB = None
    return _LIB


def _linux_btime():
    try:
        with open("/proc/stat") as fh:
            for line in fh:
                if line.startswith("btime "):
                    return int(line.split()[1])
    except (OSError, ValueError):
        pass
    return 0


def proc(pid):
    """{pid, ppid, pgid, start, zombie} for a live pid, else None. `start` is
    whole seconds since the epoch, which is the resolution the platform's own
    session record (`procStart`) carries."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return None
    if pid <= 0:
        return None
    lib = _libproc()
    if lib is not None:
        info = _BSDInfo()
        n = lib.proc_pidinfo(pid, 3, ctypes.c_uint64(0), ctypes.byref(info), ctypes.sizeof(info))
        if n != ctypes.sizeof(info):
            return None
        return {"pid": pid, "ppid": int(info.ppid), "pgid": int(info.pgid),
                "start": int(info.start_sec), "zombie": int(info.status) == _SZOMB}
    try:
        with open("/proc/%d/stat" % pid) as fh:
            raw = fh.read()
        rest = raw[raw.rindex(")") + 2:].split()
        ticks = os.sysconf("SC_CLK_TCK")
        return {"pid": pid, "ppid": int(rest[1]), "pgid": int(rest[2]),
                "start": int(_linux_btime() + int(rest[19]) // ticks), "zombie": rest[0] == "Z"}
    except (OSError, ValueError, IndexError):
        return None


def proc_path(pid):
    lib = _libproc()
    if lib is not None:
        buf = ctypes.create_string_buffer(4096)
        if lib.proc_pidpath(int(pid), buf, 4096) > 0:
            return os.path.realpath(buf.value.decode("utf-8", "replace"))
        return ""
    try:
        return os.path.realpath(os.readlink("/proc/%d/exe" % int(pid)))
    except OSError:
        return ""


def proc_argv(pid):
    """The argv of a process, split. Read with `ps` (the kernel's KERN_PROCARGS2
    layout is not worth a second parser for the two rare questions that ask)."""
    try:
        r = subprocess.run(["ps", "-o", "command=", "-p", str(int(pid))], capture_output=True,
                           text=True, timeout=10, env=dict(os.environ, LC_ALL="C"))
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return []
    return r.stdout.strip().split()


def alive(pid, start):
    p = proc(pid)
    return bool(p) and not p["zombie"] and int(p["start"]) == int(start)


def ancestors(pid=None):
    """[(pid, start)] from `pid`'s parent (default: this process's parent) up
    to, not including, pid 1."""
    out, seen = [], set()
    cur = proc(pid if pid is not None else os.getpid())
    while cur and cur["ppid"] > 1 and cur["ppid"] not in seen:
        seen.add(cur["ppid"])
        cur = proc(cur["ppid"])
        if not cur:
            break
        out.append((cur["pid"], cur["start"]))
    return out


def is_ancestor(pid, start, chain=None):
    chain = ancestors() if chain is None else chain
    return any(p == int(pid) and s == int(start) for p, s in chain)


def lstart_epoch(text):
    """`procStart` ("Thu Sep 24 17:49:33 2026", UTC, as ps prints it under
    TZ=UTC0) to epoch seconds, or None."""
    try:
        return calendar.timegm(time.strptime(" ".join(str(text).split()), "%a %b %d %H:%M:%S %Y"))
    except (ValueError, OverflowError):
        return None


# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

def now():
    return time.time()


def iso(t=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now() if t is None else t))


def age_text(seconds):
    seconds = max(0, int(seconds))
    if seconds < 90:
        return "%d s" % seconds
    minutes = seconds // 60
    if minutes < 90:
        return "%d min" % minutes
    return "%d h %d min" % (minutes // 60, minutes % 60)


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.loads(fh.read(65536))
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None


def write_json_atomic(path, value):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(value, sort_keys=True) + "\n")
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)


def append_jsonl(path, value):
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(value, sort_keys=True) + "\n")
    except OSError:
        pass


def git(cwd, *args, **kw):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
    for name in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"):
        if kw.get("keep_git_env"):
            break
        env.pop(name, None)
    try:
        r = subprocess.run(["git", "-C", cwd] + list(args), capture_output=True, text=True,
                           timeout=kw.get("timeout", 60), env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        return 127, "", str(error)
    return r.returncode, r.stdout, r.stderr


def file_digest(path):
    try:
        with open(path, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()
    except OSError:
        return ""


# ---------------------------------------------------------------------------
# the launcher: the single runtime source of the switch and the lease home (G10, G12)
# ---------------------------------------------------------------------------

def read_launcher(path):
    """The OPERATOR_FENCES_* assignments of a launcher, or None when the file is
    absent or not ours."""
    try:
        # errors="replace": a hook that is not UTF-8 is not ours (Frank's #13).
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read(65536)
    except OSError:
        return None
    if MARKER not in text:
        return None
    conf = {"LAUNCHER": path}
    for line in text.splitlines():
        m = _CONF.match(line)
        if m:
            conf[m.group(1)] = m.group(2)
    return conf


def repo_paths(repo):
    """(main checkout, common dir, this checkout's git dir) for a path inside a
    repository, all absolute and realpath'd, or None."""
    rc, out, _ = git(repo, "rev-parse", "--path-format=absolute", "--show-toplevel",
                     "--git-common-dir", "--absolute-git-dir")
    lines = out.splitlines()
    if rc != 0 or len(lines) < 3:
        rc, out, _ = git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir", "--absolute-git-dir")
        lines = out.splitlines()
        if rc != 0 or len(lines) < 2:
            return None
        lines = [""] + lines
    common = os.path.realpath(lines[1])
    gitdir = os.path.realpath(lines[2])
    main = os.path.dirname(common) if os.path.basename(common) == ".git" else ""
    return {"top": os.path.realpath(lines[0]) if lines[0] else "", "common": common,
            "gitdir": gitdir, "main": main}


def launcher_for(repo):
    paths = repo_paths(repo)
    if not paths:
        return None, None
    return read_launcher(os.path.join(paths["common"], "hooks", "reference-transaction")), paths


def fenced(conf):
    return bool(conf) and conf.get("STATE") == "on"


class Files(object):
    """Every per-repository file the fence and the lease share, named from the
    launcher's baked home and key and never from the caller's environment."""

    def __init__(self, conf):
        self.home = conf["HOME"]
        self.key = conf["KEY"]
        self.lease = os.path.join(self.home, self.key + ".lease")
        self.lock = os.path.join(self.home, self.key + ".lock")
        self.in_progress = os.path.join(self.home, "in-progress", self.key + ".json")
        self.restore_intent = os.path.join(self.home, "restore-intents", self.key + ".json")
        self.refusals = os.path.join(self.home, "fence-refusals.jsonl")
        self.preserved = os.path.join(self.home, "preserved")
        # The repository name a refusal record carries (cmd_fence writes the same value).
        self.repo = conf.get("REPO") or conf.get("COMMON") or ""


def declared_holders(conf):
    """{kind: executable} from the launcher's OPERATOR_FENCES_HOLDERS line,
    which the installer copies from the entity's LAND_LEASE_HOLDERS."""
    out = {}
    for item in (conf.get("HOLDERS") or "").split():
        kind, _, exe = item.partition("=")
        if kind and exe:
            out[kind] = os.path.realpath(exe)
    return out


# ---------------------------------------------------------------------------
# who is calling: a Claude session or a declared holder, found by ancestry (e1, F1)
# ---------------------------------------------------------------------------

def sessions_dir():
    base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "sessions")


def claude_session(chain=None):
    """The nearest ancestor that the platform's own session record names, with
    its recorded start time matching the kernel's. Returns a holder dict or
    None. `CLAUDE_PID`, when set, must agree."""
    chain = ancestors() if chain is None else chain
    sd = sessions_dir()
    for pid, start in chain:
        rec = read_json(os.path.join(sd, "%d.json" % pid))
        if not rec or str(rec.get("pid")) != str(pid):
            continue
        recorded = lstart_epoch(rec.get("procStart"))
        if recorded is None or abs(recorded - start) > 1:
            continue
        claimed = (os.environ.get("CLAUDE_PID") or "").strip()
        if claimed and claimed != str(pid):
            return {"error": "this shell says it belongs to Claude process %s, but the nearest session "
                             "record in its own ancestry is process %d" % (claimed, pid)}
        return {"kind": "claude", "pid": pid, "start": start, "session_id": str(rec.get("sessionId") or ""),
                "entrypoint": str(rec.get("entrypoint") or ""), "cwd": str(rec.get("cwd") or "")}
    return None


def declared_holder(kind, conf, chain=None, holder_pid=None):
    exe = declared_holders(conf).get(kind)
    if not exe:
        return {"error": "no holder of kind %r is declared for this repository (LAND_LEASE_HOLDERS)" % kind}
    chain = ancestors() if chain is None else chain
    if holder_pid is not None:
        found = [(p, s) for p, s in chain if p == int(holder_pid)]
        if not found:
            return {"error": "--holder-pid %s is not an ancestor of this command, so it cannot be its holder"
                             % holder_pid}
        chain = found
    for pid, start in chain:
        if proc_path(pid) == exe:
            return {"kind": kind, "pid": pid, "start": start, "executable": exe}
    return {"error": "no ancestor of this command is the declared %s executable (%s)" % (kind, exe)}


def caller_identity(conf, chain=None):
    """Who is behind this Git call, for a record: a Claude session, else any
    declared holder, else None. Never used to authorize anything."""
    chain = ancestors() if chain is None else chain
    who = claude_session(chain)
    if who and "error" not in who:
        return who
    for kind in sorted(declared_holders(conf)):
        who = declared_holder(kind, conf, chain)
        if who and "error" not in who:
            return who
    return None


def holder_label(holder):
    if not holder:
        return "an unknown holder"
    kind = holder.get("kind")
    if kind == "claude":
        title = _app_conversation_title(holder)
        if title:
            return "the conversation %s" % title
        if holder.get("entrypoint") == "cli":
            return "your terminal"
        return "a Claude session (process %s)" % holder.get("pid")
    return "%s (process %s)" % ((kind or "a holder").capitalize(), holder.get("pid"))


def _app_conversation_title(holder):
    """The app's claim record lists each lead with its conversation's title
    (spec r3 (e) the claim, item 3). Read only; absent until the app side lands."""
    rec = read_json(os.path.join(os.path.dirname(sessions_dir()), "state", "operator-lead.json"))
    for lead in (rec or {}).get("leads") or []:
        try:
            if int(lead.get("pid")) == int(holder.get("pid")) and lead.get("title"):
                return '"%s"' % str(lead["title"])[:120]
        except (TypeError, ValueError):
            continue
    return ""


# ---------------------------------------------------------------------------
# the lease record
# ---------------------------------------------------------------------------

def read_lease(files):
    return read_json(files.lease)


def same_holder(a, b):
    return bool(a and b) and int(a.get("pid", -1)) == int(b.get("pid", -2)) \
        and int(a.get("start", -1)) == int(b.get("start", -2))


def lease_state(lease):
    """'none' | 'live' | 'expired' (a live non-Claude holder past its time) |
    'dead' (the holder's pid no longer runs with its recorded start)."""
    if not lease or not isinstance(lease.get("holder"), dict):
        return "none"
    h = lease["holder"]
    if not alive(h.get("pid"), h.get("start", -1)):
        return "dead"
    if h.get("kind") != "claude" and lease.get("expires") and now() > float(lease["expires"]):
        return "expired"
    return "live"


def authorized(files, chain=None):
    """G1/e2: the caller holds the lease when a lease exists whose holder is
    alive and is an ancestor of this process, pid and start time both.

    A non-Claude lease past its time STILL authorizes its own holder: e1 says it
    "stays held" until it is taken at rest or taken over (G5). Only once another
    holder has it does the old holder's next move meet a refusal."""
    lease = read_lease(files)
    if lease_state(lease) not in ("live", "expired"):
        return False, lease
    h = lease["holder"]
    return is_ancestor(h["pid"], h["start"], chain), lease


# ---------------------------------------------------------------------------
# at rest (e6)
# ---------------------------------------------------------------------------

def in_progress_files(gitdir):
    found = []
    for name, what in (("MERGE_HEAD", "merge in progress"), ("CHERRY_PICK_HEAD", "cherry-pick in progress"),
                       ("REVERT_HEAD", "revert in progress"), ("rebase-merge", "rebase in progress"),
                       ("rebase-apply", "rebase or am in progress")):
        if os.path.exists(os.path.join(gitdir, name)):
            found.append((name, what))
    return found


def head_value(gitdir, name):
    try:
        with open(os.path.join(gitdir, name), encoding="utf-8") as fh:
            return fh.read().split()[0].strip()
    except (OSError, IndexError):
        return ""


def at_rest(main_checkout, gitdir):
    """(True, [], []) or (False, [reason, ...], [dirty path, ...])."""
    reasons, dirty = [], []
    for _name, what in in_progress_files(gitdir):
        reasons.append(what)
    rc, out, _ = git(main_checkout, "diff", "--name-only", "--diff-filter=U")
    if rc == 0 and out.strip():
        reasons.append("unmerged paths")
    rc, out, _ = git(main_checkout, "status", "--porcelain", "--untracked-files=no")
    if rc != 0:
        reasons.append("git status failed")
    else:
        dirty = [line[3:] for line in out.splitlines() if line.strip()]
        if dirty:
            reasons.append("uncommitted changes (%s)" % ", ".join(dirty[:6] + (["..."] if len(dirty) > 6 else [])))
    rc, out, _ = git(main_checkout, "rev-list", "--count", "main@{upstream}..main")
    if rc != 0:
        reasons.append("main has no upstream, so 'pushed' cannot be decided")
    else:
        try:
            n = int(out.strip())
        except ValueError:
            n = -1
        if n:
            reasons.append("%s commit%s not pushed" % (n, "" if n == 1 else "s"))
    return (not reasons), reasons, dirty


# ---------------------------------------------------------------------------
# preservation before a takeover or an abort (G5 point 2)
# ---------------------------------------------------------------------------

def preserve(files, paths, why):
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    target = os.path.join(files.preserved, "%s-%s-%d" % (files.key, stamp, os.getpid()))
    os.makedirs(target, mode=0o700, exist_ok=True)
    main, gitdir = paths["main"], paths["gitdir"]
    for name, args in (("diff-binary-HEAD.patch", ["diff", "--binary", "HEAD"]),
                       ("status-porcelain-v2.txt", ["status", "--porcelain=v2"]),
                       ("ls-files-unmerged.txt", ["ls-files", "-u"])):
        _rc, out, err = git(main, *args)
        with open(os.path.join(target, name), "w", encoding="utf-8") as fh:
            fh.write(out if out else err)
    for name in ("MERGE_HEAD", "MERGE_MSG", "CHERRY_PICK_HEAD", "REVERT_HEAD"):
        src = os.path.join(gitdir, name)
        if os.path.isfile(src):
            with open(src, "rb") as a, open(os.path.join(target, name), "wb") as b:
                b.write(a.read())
    write_json_atomic(os.path.join(target, "why.json"), {"why": why, "at": iso(), "repository": main})
    return target


# ---------------------------------------------------------------------------
# the fence (e2, F2, G1, G3, G4; Frank §4 (B) HEAD)
# ---------------------------------------------------------------------------

def current_main(common):
    """C: what refs/heads/main resolves to right now: the loose ref if present,
    else its packed-refs entry, else None. At `prepared` the loose ref still
    holds the old value (measured by Frank on both gits)."""
    try:
        with open(os.path.join(common, "refs", "heads", "main"), encoding="utf-8") as fh:
            value = fh.read().strip()
        if value and not value.startswith("ref:"):
            return value
    except OSError:
        pass
    try:
        with open(os.path.join(common, "packed-refs"), encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) == 2 and parts[1] == MAIN and not line.startswith(("#", "^")):
                    return parts[0]
    except OSError:
        pass
    return None


def writer_git_argv(chain):
    """argv of the nearest ancestor whose executable is git, skipping git's own
    global options, so argv[0] is the subcommand."""
    for pid, _start in chain:
        argv = proc_argv(pid)
        if not argv or os.path.basename(argv[0]) != "git":
            continue
        rest, i = argv[1:], 0
        while i < len(rest):
            a = rest[i]
            if a in ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path") and i + 1 < len(rest):
                i += 2
                continue
            if a.startswith("-"):
                i += 1
                continue
            break
        return rest[i:]
    return []


def _refusals_of(files, head, started_at):
    """Refusal records of ONE unfinished operation, newest first: this
    repository, carrying its head, and no older than its head file. The same
    commit can be merged or cherry-picked again later, so an older refusal of
    the same head never describes a newer operation (measured in F13)."""
    out = []
    if not head:
        return out
    for rec in reversed(_read_refusals(files)):
        if rec.get("repository") != files.repo:
            continue
        if head not in (rec.get("merge_head"), rec.get("cherry_pick_head"), rec.get("revert_head")):
            continue
        try:
            if started_at is None or float(rec.get("epoch")) < started_at - 0.5:
                continue
        except (TypeError, ValueError):
            continue
        out.append(rec)
    return out


def _cap(text):
    return text[:1].upper() + text[1:]


def _writer_text(rec):
    argv = rec.get("writer_argv") or []
    caller = rec.get("caller") or {}
    return "a refused `git %s` from %s at %s" % (
        " ".join(argv[:8]) or "(argv not recorded)",
        holder_label(caller) if caller.get("pid") else "a caller with no recorded identity", rec.get("at", "?"))


def fence_decide(lines, common, gitdir, files, chain, argv_of_writer=None):
    """[(line, why)] of refused updates, [] when everything passes.

    `lines` are (old, new, ref). A refusal is only ever a missing lease; every
    rule below decides whether an update NEEDS one."""
    main_worktree = os.path.realpath(gitdir) == os.path.realpath(common)
    held = None
    writer = None
    refused = []

    def lease_held():
        nonlocal held
        if held is None:
            held = authorized(files, chain)[0]
        return held

    def writer_argv():
        nonlocal writer
        if writer is None:
            writer = argv_of_writer() if argv_of_writer else writer_git_argv(chain)
        return writer

    for old, new, ref in lines:
        need, why = False, ""
        if ref == MAIN:
            current = current_main(common)
            if not is_zero(new):
                if current is not None and new == current:
                    need = False              # packing, or a rewrite to the same value (F2)
                elif current is None and _restore_intent_matches(files, new, chain):
                    need = False              # the engine's create-only restore (G3)
                else:
                    need, why = True, "a move of main"
            else:
                if writer_argv()[:1] == ["pack-refs"]:
                    need = False              # the second half of packing (G4)
                else:
                    need, why = True, "a deletion of main"
        elif ref == "ORIG_HEAD" and main_worktree:
            need, why = True, ("ORIG_HEAD in the main checkout: a merge, reset, pull, rebase or "
                               "merge --abort, refused before the tree is touched (G1)")
        elif ref == "HEAD" and main_worktree:
            leaves_main = (new.startswith("ref:") and new != MAIN_SYMREF) or \
                          (not new.startswith("ref:") and not is_zero(new))
            if leaves_main and writer_argv()[:2] != ["worktree", "add"]:
                need, why = True, "switching the main checkout away from main"
        if need and not lease_held():
            refused.append(((old, new, ref), why))
    return refused


def _restore_intent_matches(files, new, chain):
    intent = read_json(files.restore_intent)
    if not intent or intent.get("ref") != MAIN or intent.get("value") != new:
        return False
    try:
        return is_ancestor(int(intent["pid"]), int(intent["start"]), chain)
    except (KeyError, TypeError, ValueError):
        return False


def fence_refusal_text(conf, files, refused, lease, repo):
    engine = conf.get("ENGINE") or "<engine>"
    state = lease_state(lease)
    if state == "none":
        held = "The land lease for this repository is free."
    else:
        h = lease.get("holder") or {}
        held = "The land lease is held by %s, taken %s ago%s." % (
            holder_label(h), age_text(now() - float(lease.get("acquired_epoch") or now())),
            {"dead": " (its holder has ended)", "expired": " (past its time)"}.get(state, ""))
    what = "; ".join(sorted(set(why for _l, why in refused)))
    return "\n".join([
        "=== OPERATOR FENCE: refused in %s ===" % repo,
        "  What: %s." % what,
        "  Why: this process does not hold the land lease. %s" % held,
        "  The way through: take the lease first, then run the same command again:",
        "      %s/scripts/land-lease.sh acquire --repo %s" % (engine, repo),
        "    (Codex adds --holder codex.) Exit 75 means another holder is landing:",
        "    run it again. Wait for it to exit; it can take 90 seconds.",
        "  Abort a merge only if you started it.",
        "  Never get around this with `git -c core.hooksPath=...` or a direct ref write.",
        "  If this refusal is a defect in the fence itself, Rich turns it off with one",
        "  command: %s/scripts/operator-fences.sh off" % engine,
    ])


def cmd_fence(argv):
    """Called by the launcher: `fence <launcher> <phase>` with the transaction
    on stdin. Exit 0 pass, 1 refuse. In `committed` it only records."""
    if len(argv) < 2:
        return 2
    conf = read_launcher(argv[0])
    phase = argv[1]
    if not fenced(conf):
        return 0
    files = Files(conf)
    lines = []
    for raw in sys.stdin.read().splitlines():
        parts = raw.split(" ", 2)
        if len(parts) == 3:
            lines.append(tuple(parts))
    common = conf.get("COMMON") or ""
    rc, out, _ = git(os.getcwd(), "rev-parse", "--absolute-git-dir", keep_git_env=True)
    gitdir = os.path.realpath(out.strip()) if rc == 0 and out.strip() else common
    chain = ancestors()
    if phase == "prepared":
        refused = fence_decide(lines, common, gitdir, files, chain)
        if not refused:
            return 0
        lease = read_lease(files)
        repo = conf.get("REPO") or common
        who = caller_identity(conf, chain) or {}
        for (old, new, ref), why in refused:
            append_jsonl(files.refusals, {
                "at": iso(), "epoch": now(), "repository": repo, "ref": ref, "old": old, "new": new, "why": why,
                "caller": {k: who.get(k) for k in ("kind", "pid", "start", "session_id") if k in who},
                "writer_pid": chain[1][0] if len(chain) > 1 else None,
                "merge_head": head_value(gitdir, "MERGE_HEAD"),
                "cherry_pick_head": head_value(gitdir, "CHERRY_PICK_HEAD"),
                "revert_head": head_value(gitdir, "REVERT_HEAD")})
        sys.stderr.write(fence_refusal_text(conf, files, refused, lease, repo) + "\n")
        return 1
    if phase == "committed" and os.path.realpath(gitdir) == os.path.realpath(common):
        started = [(r, n) for _o, n, r in lines if r in ("ORIG_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD")
                   and not is_zero(n)]
        if started:
            who = caller_identity(conf, chain)
            try:
                write_json_atomic(files.in_progress, {
                    "at": iso(), "epoch": now(), "repository": conf.get("REPO") or common,
                    "refs": {r: n for r, n in started},
                    "owner": {k: who.get(k) for k in ("kind", "pid", "start", "session_id", "entrypoint")
                              if k in who} if who else None})
            except OSError:
                pass
    return 0


# ---------------------------------------------------------------------------
# whose unfinished merge is this? (e7 item 2, G6)
# ---------------------------------------------------------------------------

def merge_owner(conf, paths, chain=None, consider_lease=True):
    """The ownership verdict for an in-progress merge, cherry-pick or revert in
    a fenced main checkout, as a dict:
      verdict  mine | other-holder | refused-mine | refused-other |
               owner-ended | owner-live | unknown | none
      label, head, kind
    With consider_lease (the turn-end guard's question), a live lease decides
    first: `mine` when this session holds it, `other-holder` otherwise. Without
    it (abort-orphan's question, asked BY the lease holder), only the positive
    records decide who started it (G6): a refusal carrying this head, or the
    in-progress record the launcher wrote at the start."""
    chain = ancestors() if chain is None else chain
    files = Files(conf)
    gitdir = paths["gitdir"]
    kinds = [n for n, _w in in_progress_files(gitdir) if n in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD")]
    rc, out, _ = git(paths["main"], "diff", "--name-only", "--diff-filter=U")
    unmerged = rc == 0 and bool(out.strip())
    if not kinds and not unmerged:
        return {"verdict": "none"}
    kind = kinds[0] if kinds else ""
    head = head_value(gitdir, kind) if kind else ""
    me = caller_identity(conf, chain)
    if consider_lease:
        lease = read_lease(files)
        if lease_state(lease) in ("live", "expired"):
            h = lease["holder"]
            if is_ancestor(h["pid"], h["start"], chain):
                return {"verdict": "mine", "kind": kind, "head": head, "label": holder_label(h)}
            return {"verdict": "other-holder", "kind": kind, "head": head, "label": holder_label(h)}
    rec = read_json(files.in_progress)
    owner = (rec or {}).get("owner")
    starter = owner if owner and _record_matches(rec, kind, head, gitdir) else None
    # A refusal describes THIS operation only if it came after the head file
    # appeared (_refusals_of). And it ORPHANS the operation only when it really
    # does (Fix 3): an ORIG_HEAD refusal, whose writer had already rewritten the
    # index (Fix 1's case), or a refusal of the operation's own recorded
    # starter, which cannot conclude what it started. Another writer's refused
    # `git commit` during a healthy, resolved merge by the holder orphans nothing.
    for ref_rec in _refusals_of(files, head, _head_mtime(gitdir, kind)):
        caller = ref_rec.get("caller") or {}
        rewrote = ref_rec.get("ref") == "ORIG_HEAD"
        if not rewrote and not same_holder(caller, starter):
            continue
        mine = bool(me) and caller.get("pid") == me["pid"] and caller.get("start") == me["start"]
        return {"verdict": "refused-mine" if mine else "refused-other", "kind": kind, "head": head,
                "label": holder_label(caller) if caller else "an unknown caller",
                "rewrote": _writer_text(ref_rec) if rewrote else ""}
    if starter:
        if not alive(owner.get("pid"), owner.get("start", -1)):
            return {"verdict": "owner-ended", "kind": kind, "head": head, "label": holder_label(owner)}
        if me and same_holder(me, owner):
            return {"verdict": "mine", "kind": kind, "head": head, "label": holder_label(owner)}
        return {"verdict": "owner-live", "kind": kind, "head": head, "label": holder_label(owner)}
    return {"verdict": "unknown", "kind": kind, "head": head, "label": "an unrecorded starter"}


def _record_matches(rec, kind, head, gitdir):
    """Does the in-progress record describe THIS unfinished operation?

    A cherry-pick or revert records its own head, so the match is exact. A merge
    writes no MERGE_HEAD ref (measured, both gits: MERGE_HEAD is a plain file),
    only ORIG_HEAD a moment before, so a merge matches an ORIG_HEAD record
    written within 120 s before MERGE_HEAD appeared. An older record is some
    earlier reset or merge, and matching it would name the wrong starter."""
    refs = rec.get("refs") or {}
    appeared = _head_mtime(gitdir, kind)
    try:
        written = float(rec.get("epoch"))
    except (TypeError, ValueError):
        return False
    if appeared is None:
        return False
    if kind in ("CHERRY_PICK_HEAD", "REVERT_HEAD"):
        # The record is written in the same second the head file appears.
        return bool(head) and refs.get(kind) == head and abs(appeared - written) <= 5.0
    if kind == "MERGE_HEAD" and "ORIG_HEAD" in refs:
        return -5.0 <= appeared - written <= 120.0
    return False


def _head_mtime(gitdir, kind):
    try:
        return os.path.getmtime(os.path.join(gitdir, kind)) if kind else None
    except OSError:
        return None


def _read_refusals(files):
    out = []
    try:
        with open(files.refusals, encoding="utf-8") as fh:
            for line in fh.readlines()[-500:]:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    return out


def cmd_merge_owner(argv):
    repo = argv[argv.index("--repo") + 1] if "--repo" in argv else os.getcwd()
    conf, paths = launcher_for(repo)
    if not fenced(conf) or not paths or not paths["main"]:
        print(json.dumps({"verdict": "off"}))
        return 0
    main_paths = repo_paths(paths["main"])
    print(json.dumps(merge_owner(conf, main_paths)))
    return 0


# ---------------------------------------------------------------------------
# the lease commands (e1, F1, F3, G5, G7, G10)
# ---------------------------------------------------------------------------

def _engine_root():
    return os.path.realpath(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", ".."))


def _workspaces():
    sys.path.insert(0, os.path.join(_engine_root(), "mega-lander"))
    try:
        import workspaces as W          # noqa: E402  (engine-only import)
    finally:
        sys.path.pop(0)
    return W


def _default_home():
    return _workspaces().land_locks_dir()


def keyed_paths(main_checkout):
    """The lease's keying rule is workspaces.py's, and only workspaces.py's:
    land_lock_path(), with the `.lock` suffix. Imported, never copied."""
    lock = _workspaces().land_lock_path(main_checkout)
    return os.path.dirname(lock), os.path.basename(lock)[:-len(".lock")]


def _parse(argv, flags, valued):
    opts = {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in valued and i + 1 < len(argv):
            opts[a] = argv[i + 1]
            i += 2
        elif a in flags:
            opts[a] = True
            i += 1
        else:
            raise SystemExit("land-lease: unknown argument %r" % a)
    return opts


def _say(text):
    sys.stdout.write(text.rstrip("\n") + "\n")
    sys.stdout.flush()


def _lease_context(opts):
    repo = opts.get("--repo") or os.getcwd()
    conf, paths = launcher_for(repo)
    if not paths or not paths["main"]:
        raise SystemExit("land-lease: %s is not inside a repository with a main checkout" % repo)
    if not fenced(conf):
        return None, None, None, paths
    try:
        home, key = keyed_paths(paths["main"])
    except Exception as error:    # noqa: BLE001  (any failure here is a refusal, said out loud)
        raise SystemExit("land-lease: cannot verify the lease home (%s); refusing rather than guessing" % error)
    if os.path.realpath(home) != os.path.realpath(conf.get("HOME", "")) or key != conf.get("KEY"):
        raise SystemExit(
            "land-lease: REFUSED (G10). This command resolves the lease to %s/%s, but the fence installed in "
            "%s reads %s/%s. Two callers with different homes would each see their own lease as free. Run it "
            "without RICHOS_LAND_LOCKS_DIR or CLAUDE_CONFIG_DIR overriding the home the installer used."
            % (home, key, paths["main"], conf.get("HOME"), conf.get("KEY")))
    return conf, Files(conf), repo, repo_paths(paths["main"])


def _identify(opts, conf):
    chain = ancestors()
    kind = opts.get("--holder")
    if kind:
        who = declared_holder(kind, conf, chain, opts.get("--holder-pid"))
    else:
        if opts.get("--holder-pid"):
            return {"error": "--holder-pid needs --holder <kind>"}
        who = claude_session(chain)
        if who is None:
            who = {"error": "this command runs under no Claude session with a session record, and no "
                            "--holder <kind> was given. A Claude session is found from its own ancestry; "
                            "a declared non-Claude holder (for example Codex) passes --holder <kind>."}
    return who


def _state_text(paths):
    ok, reasons, _dirty = at_rest(paths["main"], paths["gitdir"])
    return "at rest" if ok else "; ".join(reasons)


def _wait_budget(opts):
    raw = opts.get("--wait") or (os.environ.get("LAND_LEASE_WAIT") or "").strip()
    try:
        wait = float(raw) if raw else DEFAULT_WAIT
    except ValueError:
        raise SystemExit("land-lease: the wait must be a number of seconds")
    if wait < 0 or wait > MAX_WAIT:
        raise SystemExit("land-lease: REFUSED: a wait of %s s is above the %d s ceiling. One call, its start-up and "
                         "its report must fit inside the 600-second command cap; run the command again instead "
                         "of waiting longer in one call." % (raw, int(MAX_WAIT)))
    return wait


def _ttl():
    raw = (os.environ.get("LAND_LEASE_TTL") or "").strip()
    try:
        return float(raw) if raw else DEFAULT_TTL
    except ValueError:
        return DEFAULT_TTL


class _Flock(object):
    def __init__(self, path):
        self.path = path
        self.fh = None

    def try_take(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        if self.fh is None:
            self.fh = os.fdopen(os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "r+")
        try:
            fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError as error:
            if error.errno in (errno.EAGAIN, errno.EACCES):
                return False
            raise

    def release(self):
        if self.fh is not None:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_UN)
            finally:
                self.fh.close()
                self.fh = None


def _new_lease(holder, repo_main, previous=None, preserved=None):
    t = now()
    lease = {"schema": 1, "repository": repo_main, "holder": holder, "acquired": iso(t),
             "acquired_epoch": t, "renewed_epoch": t, "expires": None}
    if holder.get("kind") != "claude":
        lease["expires"] = t + _ttl()
    if previous:
        lease["took_from"] = previous.get("holder")
    if preserved:
        lease["preserved"] = preserved
    return lease


def _held_line(lease, state, paths, wait, allow_takeover, repo):
    h = lease.get("holder") or {}
    age = age_text(now() - float(lease.get("acquired_epoch") or now()))
    tail = {"dead": ", and its holder has ended", "expired": ", held past its time"}.get(state, "")
    line = ("land-lease: HELD. %s holds the land lease for %s, taken %s ago%s; %s. Waited %d s. "
            "Run this command again." % (holder_label(h), repo, age, tail, _state_text(paths), int(wait)))
    if allow_takeover:
        line += (" Its holder can no longer finish it, so it can also be taken over: "
                 "land-lease.sh takeover --repo %s (the state is preserved first)." % repo)
    return line


def cmd_acquire(opts):
    conf, files, repo, paths = _lease_context(opts)
    if conf is None:
        _say("land-lease: operator fences are off for %s. There is no lease to take and none is needed."
             % paths["main"])
        return 0
    holder = _identify(opts, conf)
    if not holder or "error" in holder:
        _say("land-lease: REFUSED. %s" % (holder or {}).get("error", "no holder could be identified"))
        return 2
    wait = _wait_budget(opts)
    deadline = time.monotonic() + wait
    flock = _Flock(files.lock)
    last = None
    try:
        while True:
            if flock.try_take():
                try:
                    lease = read_lease(files)
                    state = lease_state(lease)
                    if state == "none" or same_holder(lease["holder"], holder):
                        renewed = state != "none"
                        new = _new_lease(holder, paths["main"])
                        if renewed:
                            new["acquired"] = lease.get("acquired")
                            new["acquired_epoch"] = lease.get("acquired_epoch")
                        write_json_atomic(files.lease, new)
                        _say("land-lease: %s the land lease for %s as %s."
                             % ("RENEWED" if renewed else "ACQUIRED", paths["main"], holder_label(holder)))
                        _report_in_progress(conf, paths)
                        return 0
                    if state in ("dead", "expired"):
                        rest, _r, _d = at_rest(paths["main"], paths["gitdir"])
                        if rest:
                            write_json_atomic(files.lease, _new_lease(holder, paths["main"], previous=lease))
                            _say("land-lease: ACQUIRED the land lease for %s as %s (the previous holder, %s, %s, "
                                 "and the repository was at rest)."
                                 % (paths["main"], holder_label(holder), holder_label(lease["holder"]),
                                    "had ended" if state == "dead" else "was past its time"))
                            return 0
                    last = (lease, state)
                finally:
                    flock.release()
            if time.monotonic() >= deadline:
                break
            time.sleep(min(2.0, max(0.05, deadline - time.monotonic())))
    finally:
        flock.release()
    if last is None:
        _say("land-lease: HELD. Another land of %s (the engine's own integrate) holds the land lock; waited %d s. "
             "Run this command again." % (paths["main"], int(wait)))
        return EXIT_HELD
    lease, state = last
    _say(_held_line(lease, state, paths, wait, state in ("dead", "expired"), paths["main"]))
    return EXIT_HELD


def _report_in_progress(conf, paths):
    verdict = merge_owner(conf, paths, consider_lease=False)
    if verdict.get("verdict") in (None, "none", "mine"):
        return
    head = verdict.get("head") or "(no head recorded)"
    what = {"MERGE_HEAD": "a merge", "CHERRY_PICK_HEAD": "a cherry-pick",
            "REVERT_HEAD": "a revert"}.get(verdict.get("kind"), "an unfinished operation")
    if verdict["verdict"] in ("owner-ended", "refused-mine", "refused-other"):
        if verdict["verdict"] == "owner-ended":
            why = "its owner has ended"
        elif verdict.get("rewrote"):
            why = ("%s had already rewritten its index before the fence refused it, so its staged resolution "
                   "is gone. Do not commit on top of it" % verdict["rewrote"])
        else:
            why = "the fence refused its own starter's move"
        _say("land-lease: %s is in progress in %s (%s), started by %s, and it can never finish: %s. Preserve and "
             "abort it with: land-lease.sh abort-orphan --repo %s, and name %s in your land's report."
             % (what, paths["main"], head, verdict.get("label"), why, paths["main"], head))
    else:
        _say("land-lease: %s is in progress in %s (%s), started by %s, who may still be finishing it. "
             "Leave it: never abort a merge you did not start." % (what, paths["main"], head, verdict.get("label")))


def cmd_release(opts):
    conf, files, repo, paths = _lease_context(opts)
    if conf is None:
        _say("land-lease: operator fences are off for %s. There is no lease to release." % paths["main"])
        return 0
    holder = _identify(opts, conf)
    if not holder or "error" in holder:
        _say("land-lease: REFUSED. %s" % (holder or {}).get("error", "no holder could be identified"))
        return 2
    flock = _Flock(files.lock)
    deadline = time.monotonic() + 30
    while not flock.try_take():
        if time.monotonic() >= deadline:
            _say("land-lease: the land lock stayed busy for 30 s; the lease was not released. Run it again.")
            return EXIT_HELD
        time.sleep(0.2)
    try:
        lease = read_lease(files)
        if not lease:
            _say("land-lease: no lease is held for %s." % paths["main"])
            return 0
        if not same_holder(lease.get("holder"), holder):
            _say("land-lease: the lease for %s is held by %s, not by this caller. It was left untouched."
                 % (paths["main"], holder_label(lease.get("holder"))))
            return 1
        os.unlink(files.lease)
        _say("land-lease: RELEASED the land lease for %s." % paths["main"])
        return 0
    finally:
        flock.release()


def cmd_status(opts):
    repo = opts.get("--repo") or os.getcwd()
    conf, paths = launcher_for(repo)
    if not paths:
        _say("land-lease: %s is not a repository" % repo)
        return 2
    if not fenced(conf):
        _say("land-lease: operator fences are %s for %s." % ("off" if conf else "not installed", paths["main"]))
        return 0
    files = Files(conf)
    lease = read_lease(files)
    state = lease_state(lease)
    main_paths = repo_paths(paths["main"])
    _say("land-lease: repository %s; lease %s%s; %s." % (
        paths["main"], state,
        "" if state == "none" else ", held by %s for %s%s" % (
            holder_label(lease["holder"]), age_text(now() - float(lease.get("acquired_epoch") or now())),
            "" if not lease.get("expires") else ", expires in %s" % age_text(float(lease["expires"]) - now())
            if float(lease["expires"]) > now() else ", past its time"),
        _state_text(main_paths)))
    return 0


def cmd_takeover(opts):
    """G5: allowed only when the recorded holder is dead, or a non-Claude lease
    is past its time. The state is preserved BEFORE the lease changes hands."""
    conf, files, repo, paths = _lease_context(opts)
    if conf is None:
        _say("land-lease: operator fences are off for %s. There is nothing to take over." % paths["main"])
        return 0
    holder = _identify(opts, conf)
    if not holder or "error" in holder:
        _say("land-lease: REFUSED. %s" % (holder or {}).get("error", "no holder could be identified"))
        return 2
    flock = _Flock(files.lock)
    deadline = time.monotonic() + 30
    while not flock.try_take():
        if time.monotonic() >= deadline:
            _say("land-lease: the land lock stayed busy for 30 s. Run it again.")
            return EXIT_HELD
        time.sleep(0.2)
    try:
        lease = read_lease(files)
        state = lease_state(lease)
        if state == "none":
            _say("land-lease: no lease is held for %s; use acquire." % paths["main"])
            return 1
        if state == "live":
            _say("land-lease: REFUSED. %s is alive and within its time, so its lease cannot be taken over. "
                 "Wait for it: land-lease.sh acquire --repo %s." % (holder_label(lease["holder"]), paths["main"]))
            return 1
        kept = preserve(files, paths, "takeover of a lease whose holder %s" % (
            "has ended" if state == "dead" else "is past its time"))
        write_json_atomic(files.lease, _new_lease(holder, paths["main"], previous=lease, preserved=kept))
        _say("land-lease: TOOK OVER the land lease for %s from %s (%s). The repository's state was preserved "
             "first, in %s; name that directory in your land's report. Nothing in the tree was changed."
             % (paths["main"], holder_label(lease["holder"]),
                "its holder had ended" if state == "dead" else "it was past its time", kept))
        _report_in_progress(conf, paths)
        return 0
    finally:
        flock.release()


def cmd_abort_orphan(opts):
    """e7 item 3 with G5 and G6: abort a merge, cherry-pick or revert only when
    it can never finish (its recorded owner has ended, or the fence refused it),
    only by the lease holder, and only after preserving it."""
    conf, files, repo, paths = _lease_context(opts)
    if conf is None:
        _say("land-lease: operator fences are off for %s. Nothing is aborted by this command." % paths["main"])
        return 0
    ok, _lease = authorized(files)
    if not ok:
        _say("land-lease: REFUSED. Only the holder of the land lease may abort an orphaned merge. Take it first: "
             "land-lease.sh acquire --repo %s" % paths["main"])
        return 1
    verdict = merge_owner(conf, paths, consider_lease=False)
    v = verdict.get("verdict")
    if v == "none":
        _say("land-lease: nothing is in progress in %s." % paths["main"])
        return 0
    if v not in ("owner-ended", "refused-mine", "refused-other"):
        _say("land-lease: REFUSED. The %s in %s was started by %s (%s). Nothing was touched: never abort a merge "
             "you did not start." % (verdict.get("kind") or "operation", paths["main"], verdict.get("label"), v))
        return 1
    kept = preserve(files, paths, "abort of an orphaned %s (%s)" % (verdict.get("kind"), v))
    sub = {"MERGE_HEAD": ["merge", "--abort"], "CHERRY_PICK_HEAD": ["cherry-pick", "--abort"],
           "REVERT_HEAD": ["revert", "--abort"]}.get(verdict.get("kind"))
    if not sub:
        _say("land-lease: the state was preserved in %s, but no abort is defined for it." % kept)
        return 1
    rc, out, err = git(paths["main"], *sub)
    if rc != 0:
        _say("land-lease: the abort failed (%s). The state is preserved in %s." % ((err or out).strip()[:300], kept))
        return 1
    try:
        os.unlink(files.in_progress)
    except OSError:
        pass
    _say("land-lease: ABORTED the orphaned %s in %s. Its head was %s: name it in your land's report so the work "
         "can be landed again. The state before the abort is preserved in %s."
         % (verdict.get("kind"), paths["main"], verdict.get("head"), kept))
    return 0


def cmd_lease(argv):
    if not argv:
        _say("usage: land-lease.sh acquire|release|status|takeover|abort-orphan --repo <path> "
             "[--holder <kind> [--holder-pid <pid>]] [--wait <seconds>]")
        return 2
    sub, rest = argv[0], argv[1:]
    opts = _parse(rest, set(), {"--repo", "--holder", "--holder-pid", "--wait"})
    table = {"acquire": cmd_acquire, "release": cmd_release, "status": cmd_status,
             "takeover": cmd_takeover, "abort-orphan": cmd_abort_orphan}
    if sub not in table:
        _say("land-lease: unknown command %r" % sub)
        return 2
    return table[sub](opts)


# ---------------------------------------------------------------------------
# the turn-end release (e6, F3, G5 point 3)
# ---------------------------------------------------------------------------

def cmd_turn_end(argv):
    """Stop hook body. For every lease THIS session holds: at rest, release it;
    otherwise keep it and say so, once, naming what is unfinished and which
    paths are dirty. Never blocks. A lease it does not hold is never touched."""
    try:
        home = _default_home()
    except Exception:              # noqa: BLE001  a Stop hook never fails the turn
        return 0
    try:
        names = [n for n in os.listdir(home) if n.endswith(".lease")]
    except OSError:
        return 0
    if not names:
        return 0
    chain = ancestors()
    notes = []
    for name in sorted(names):
        lease = read_json(os.path.join(home, name))
        if not lease or not isinstance(lease.get("holder"), dict):
            continue
        h = lease["holder"]
        if not is_ancestor(h.get("pid", -1), h.get("start", -1), chain):
            continue
        conf, paths = launcher_for(lease.get("repository") or "/nonexistent")
        if not fenced(conf) or not paths:
            continue
        files = Files(conf)
        if os.path.realpath(files.lease) != os.path.realpath(os.path.join(home, name)):
            continue
        main_paths = repo_paths(paths["main"])
        rest, reasons, dirty = at_rest(main_paths["main"], main_paths["gitdir"])
        if rest:
            flock = _Flock(files.lock)
            if flock.try_take():
                try:
                    current = read_lease(files)
                    if current and same_holder(current.get("holder"), h):
                        os.unlink(files.lease)
                finally:
                    flock.release()
            continue
        notes.append("Your land in %s from %s is still holding the lock after %s: %s. Other conversations' "
                     "lands wait until it finishes. If some of those paths are not yours, another writer "
                     "dirtied the tree; say so rather than finishing their work."
                     % (paths["main"], holder_label(h),
                        age_text(now() - float(lease.get("acquired_epoch") or now())), "; ".join(reasons)))
    if notes:
        print(json.dumps({"systemMessage": " ".join(notes)}))
    return 0


# ---------------------------------------------------------------------------
# the early Bash check (e7 item 1, G1 points 2 and 3)
# ---------------------------------------------------------------------------

# The verbs the text check refuses in a fenced main checkout without the lease.
# G1 kept cherry-pick, revert, am, rebase, stash and commit here and moved merge,
# pull and reset to the fence alone. MEASURED 2026-09-24 on Homebrew git 2.52.0
# and Apple git 2.50.1 (scratch repositories, ORIG_HEAD refused): merge, merge
# --no-ff and pull ARE stopped before the tree changes, so they stay with the
# fence. But reset (--hard, --keep, --merge, --mixed) exits 128 with main unmoved
# AFTER rewriting the index and tree, and merge --abort (a reset --merge inside)
# exits 128 AFTER discarding a staged resolution, leaving MERGE_HEAD behind. So
# `reset` and `merge --abort`/`--quit` are back in this list, as r3 e7 first had
# them. As-built deviation from G1, recorded and escalated.
TEXT_VERBS = ("cherry-pick", "revert", "am", "rebase", "stash", "commit", "reset", "merge")
_SEP = re.compile(r"&&|\|\||;|\||\n")


def git_invocations(command, cwd):
    """[(directory, subcommand, args)] for each `git` call in a shell command,
    with `cd <dir>` tracked across segments and `-C <dir>` honored. A text
    match, stated as such: `sh -c`, scripts and variables are not seen."""
    out = []
    here = cwd
    for segment in _SEP.split(command or ""):
        try:
            words = shlex.split(segment, comments=True)
        except ValueError:
            continue
        while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
            words = words[1:]
        if not words:
            continue
        if words[0] == "cd":
            target = words[1] if len(words) > 1 else os.path.expanduser("~")
            here = os.path.normpath(os.path.join(here, os.path.expanduser(target)))
            continue
        if os.path.basename(words[0]) != "git":
            continue
        d, i = here, 1
        while i < len(words):
            a = words[i]
            if a == "-C" and i + 1 < len(words):
                d = os.path.normpath(os.path.join(d, os.path.expanduser(words[i + 1])))
                i += 2
            elif a in ("-c", "--git-dir", "--work-tree", "--namespace") and i + 1 < len(words):
                i += 2
            elif a.startswith("-"):
                i += 1
            else:
                break
        if i < len(words):
            out.append((d, words[i], words[i + 1:]))
    return out


def early_check(payload):
    """(exit code, message). 0 = allow; 2 = refuse."""
    tool_input = payload.get("tool_input") or {}
    command = tool_input.get("command") or ""
    cwd = payload.get("cwd") or os.getcwd()
    chain = None
    for directory, sub, args in git_invocations(command, cwd):
        if sub not in TEXT_VERBS:
            continue
        if sub == "stash" and args[:1] in (["list"], ["show"]):
            continue
        if sub == "merge" and not any(a in ("--abort", "--quit") for a in args):
            continue            # a merge itself is stopped cleanly by the fence (G1, measured)
        if not os.path.isdir(directory):
            continue
        paths = repo_paths(directory)
        # G1 point 3: the target's OWN checkout decides, never a path prefix. A
        # native worktree under .claude/worktrees/ has its own top level.
        if not paths or not paths["main"] or paths["gitdir"] != paths["common"]:
            continue
        conf = read_launcher(os.path.join(paths["common"], "hooks", "reference-transaction"))
        if not fenced(conf):
            continue
        chain = ancestors() if chain is None else chain
        ok, lease = authorized(Files(conf), chain)
        if ok:
            continue
        engine = conf.get("ENGINE") or _engine_root()
        held = "the lease is free" if lease_state(lease) == "none" else \
            "the lease is held by %s" % holder_label((lease or {}).get("holder"))
        return 2, "\n".join([
            "=== OPERATOR FENCE: `git %s` in the main checkout %s needs the land lease ===" % (sub, paths["main"]),
            "  This session does not hold it (%s). The shared checkout is written only by the" % held,
            "  lease holder, so another conversation's land is never interleaved with this command.",
            "  Take it first, then run the command again:",
            "      %s/scripts/land-lease.sh acquire --repo %s" % (engine, paths["main"]),
            "  Exit 75 means another holder is landing: run it again. Never abort a merge you did not start.",
            "  (Early check, a text match. The Git fence itself is the backstop.)"])
    return 0, ""


def cmd_early_check(argv):
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return 0
    if not isinstance(payload, dict) or payload.get("tool_name") not in (None, "Bash"):
        return 0
    try:
        rc, message = early_check(payload)
    except Exception:   # noqa: BLE001  the second line never fails a command; the Git fence decides
        return 0
    if rc:
        sys.stderr.write(message + "\n")
    return rc


# ---------------------------------------------------------------------------
# entry
# ---------------------------------------------------------------------------

def main(argv):
    if not argv:
        sys.stderr.write("usage: operator_fences.py fence|lease|merge-owner|turn-end|early-check|admin ...\n")
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == "fence":
        return cmd_fence(rest)
    if cmd == "lease":
        return cmd_lease(rest)
    if cmd == "merge-owner":
        return cmd_merge_owner(rest)
    if cmd == "turn-end":
        try:
            return cmd_turn_end(rest)
        except Exception as error:   # noqa: BLE001  never fails the turn: the hook announces it
            sys.stderr.write("turn-end failed: %s\n" % error)
            return 3
    if cmd == "early-check":
        return cmd_early_check(rest)
    if cmd == "admin":
        sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
        import operator_fences_admin as admin   # noqa: E402  (engine-only)
        return admin.main(rest)
    sys.stderr.write("operator_fences.py: unknown command %r\n" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
