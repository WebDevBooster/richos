#!/usr/bin/env python3
"""operator_leads.py: the engine side of several operator leads on one Mac.

Spec: richos-hq docs/plans/2026-09-24-operator-back-end-spec-r3.md (Sage), (e)
"The claim", e3 and e5, with r4 §2.4 (the claim hook is idempotent for the
SessionStart sources `compact` and `resume`) and Frank's G11 (the terminal test
is a denylist on `entrypoint`). The as-built record, with the contracts the app
side builds to, is richos-hq docs/verification/2026-09-24-operator-fences/
README.md, §10.

THREE PIECES, ONE FILE, because they share the switch, the caller's identity and
the question "is this path in a fenced main checkout?":

  the claim (e)   His terminal and the app never run his team at once. A terminal
                  session in his entity claims at SessionStart; while a live app
                  claim exists, it refuses Agent and SendMessage (never TaskStop:
                  a stop only removes, ceo-decisions §67), the
                  land lease, and writes to the record and to his memory.
  e3              Shared writes. A write into his memory directory takes a short
                  lease, so two leads never interleave there; a write into a main
                  checkout of a fenced repository needs that repository's land
                  lease.
  e5              A spawn is refused when a live agent of ANOTHER session holds
                  the same name in the machine-wide registry.

WITH THE SWITCH OFF, NOTHING HERE DOES ANYTHING. The switch is the entity's own
launcher (OPERATOR_FENCES_STATE, Frank G12), the same one the fence reads. Every
verb returns before it reads a claim, takes a lease or writes a file, and the
bash wrappers do not even start this interpreter while it is off
(scripts/lib/operator-mode.sh). His terminal behaves exactly as it does today.

WHAT NEVER HAPPENS HERE. Nothing is signaled. Nothing is written into
~/.claude/sessions/, which Claude Code owns (r3 F6). A process identity is a
pid PLUS its start time from the kernel (operator_fences.proc), never a name.
"""
import errno
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import operator_fences as OF  # noqa: E402  (the one shared identity and switch reader)

CLAIM_FILE = "operator-lead.json"
CLAIM_LOCK = "operator-lead.lock"
CLAIM_SCHEMA = 1
CLAIM_LOCK_WAIT = 5.0          # seconds; a claim write takes milliseconds
MEMORY_LEASE_WAIT = 10.0       # e3: wait up to 10 s, then refuse naming the holder
MEMORY_LEASE_STALE = 5.0       # e3: no longer than the wait; a Write takes milliseconds
WRITE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")
# TaskStop is deliberately NOT here. r3 (e) item 7 lists it, but a stop only
# removes capability (§67; r3 (d) item 7 accepts a stop from every channel for
# that reason), a terminal's TaskStop reaches only that terminal's own tasks,
# and refusing it would block him stopping his own agents whenever the claim file
# is unreadable. As-built deviation, recorded in the fence record.
TEAM_TOOLS = ("Agent", "SendMessage")
EXIT_REFUSE = 2
EXIT_INTERNAL = 3


# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

def claude_dir():
    """The one Claude configuration directory, computed the way the platform
    and operator_fences.sessions_dir() compute it."""
    return os.path.dirname(OF.sessions_dir())


def claim_paths():
    state = os.path.join(claude_dir(), "state")
    return os.path.join(state, CLAIM_FILE), os.path.join(state, CLAIM_LOCK)


def inside(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def realish(path):
    """realpath of the deepest existing ancestor, with the rest appended: a
    Write names a file that may not exist yet."""
    path = os.path.abspath(path)
    rest = []
    probe = path
    while probe and not os.path.exists(probe):
        parent, leaf = os.path.split(probe)
        if parent == probe:
            break
        rest.insert(0, leaf)
        probe = parent
    return os.path.join(os.path.realpath(probe), *rest) if rest else os.path.realpath(probe)


def refuse(message):
    sys.stderr.write(message.rstrip("\n") + "\n")
    return EXIT_REFUSE


def system_message(text):
    sys.stdout.write(json.dumps({"systemMessage": text}) + "\n")
    return 0


def entity_root():
    return os.path.realpath(os.environ.get("OPERATOR_ENTITY_ROOT") or os.getcwd())


def operator_on(entity):
    """The switch: the entity repository's own launcher says on (G12)."""
    conf, _paths = OF.launcher_for(entity)
    return OF.fenced(conf)


def read_payload():
    raw = sys.stdin.read()
    try:
        value = json.loads(raw or "{}")
    except ValueError:
        return None
    return value if isinstance(value, dict) else None


# ---------------------------------------------------------------------------
# who is calling
# ---------------------------------------------------------------------------

def me():
    """This hook's Claude session (operator_fences.claude_session: the nearest
    ancestor with a session record whose procStart matches the kernel), or
    None. A CLAUDE_PID disagreement is returned as None: an identity that
    contradicts itself decides nothing."""
    who = OF.claude_session()
    if not who or "error" in who:
        return None
    return who


def entrypoint_of(who):
    """The session record's entrypoint; CLAUDE_CODE_ENTRYPOINT only when the
    record carries none (r3 (e) item 4: the record decides, the environment is
    the cross-check). A print-mode claude started from a terminal's tool shell
    inherits `cli` in its environment and records `sdk-cli` (r4 §2.2, P2), so
    the record must win."""
    recorded = (who or {}).get("entrypoint") or ""
    return recorded or (os.environ.get("CLAUDE_CODE_ENTRYPOINT") or "").strip()


def is_terminal(who, entity, fallback_cwd=""):
    """r3 (e) item 1 with Frank G11: a live session whose entrypoint does not
    start with `sdk-` (so `cli`, and the IDE and desktop entrypoints too), whose
    cwd is the entity root or under it, excluding .claude/worktrees/."""
    entry = entrypoint_of(who)
    if not entry or entry.startswith("sdk-"):
        return False
    cwd = (who or {}).get("cwd") or fallback_cwd
    if not cwd or not inside(cwd, entity):
        return False
    return not inside(cwd, os.path.join(entity, ".claude", "worktrees"))


# ---------------------------------------------------------------------------
# the claim record (r3 (e) "The claim", items 2-7)
# ---------------------------------------------------------------------------

def read_claim(path=None):
    """('absent', None, '') | ('ok', record, '') | ('unreadable', None, reason).
    Only a missing file is absent. Unreadable means held, on both sides (item 6)."""
    path = path or claim_paths()[0]
    try:
        st = os.lstat(path)
    except OSError as error:
        if error.errno == errno.ENOENT:
            return "absent", None, ""
        return "unreadable", None, "it could not be read (%s)" % error.strerror
    if not os.path.isfile(path) or os.path.islink(path):
        return "unreadable", None, "it is not a plain file"
    if st.st_size > 65536:
        return "unreadable", None, "it is too large to be a claim"
    rec = OF.read_json(path)
    if rec is None:
        return "unreadable", None, "it is not a JSON object"
    if rec.get("schema") != CLAIM_SCHEMA or rec.get("owner") not in ("app", "terminal") \
            or not isinstance(rec.get("processes"), list):
        return "unreadable", None, "it is not a schema-%d claim with an owner and a process list" % CLAIM_SCHEMA
    for p in rec["processes"]:
        if not isinstance(p, dict) or not isinstance(p.get("pid"), int) or not isinstance(p.get("start"), int):
            return "unreadable", None, "a listed process has no integer pid and start"
    return "ok", rec, ""


def live_processes(rec):
    return [p for p in (rec or {}).get("processes") or [] if OF.alive(p["pid"], p["start"])]


def claim_state(path=None):
    """('none'|'app'|'terminal'|'unreadable', record, reason). A claim is live
    while any listed process runs with its recorded start (item 3)."""
    kind, rec, reason = read_claim(path)
    if kind == "absent":
        return "none", None, ""
    if kind == "unreadable":
        return "unreadable", None, reason
    return (rec["owner"] if live_processes(rec) else "none"), rec, ""


def is_app_lead(who, state, rec):
    """Item 4: a session carrying RICHOS_OPERATOR_LEAD that matches a live app
    claim listing its pid is one of the app's own leads."""
    claim_id = (os.environ.get("RICHOS_OPERATOR_LEAD") or "").strip()
    if not claim_id or not who or state != "app" or rec.get("claim_id") != claim_id:
        return False
    listed = list(rec.get("processes") or []) + list(rec.get("leads") or [])
    return any(isinstance(p, dict) and p.get("pid") == who["pid"] and p.get("start") == who["start"]
               for p in listed)


class ClaimLock(object):
    """fcntl.flock on operator-lead.lock (item 2). Busy past the wait is a
    refusal, never a guess."""

    def __init__(self, path, wait=CLAIM_LOCK_WAIT):
        self.path, self.wait, self.fh = path, wait, None

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), mode=0o700, exist_ok=True)
        self.fh = os.fdopen(os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "r+")
        deadline = time.monotonic() + self.wait
        while True:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError as error:
                if error.errno not in (errno.EAGAIN, errno.EACCES):
                    raise
            if time.monotonic() >= deadline:
                self.fh.close()
                self.fh = None
                raise TimeoutError("the claim lock %s stayed busy for %d s" % (self.path, int(self.wait)))
            time.sleep(0.05)

    def __exit__(self, *_exc):
        if self.fh is not None:
            try:
                fcntl.flock(self.fh, fcntl.LOCK_UN)
            finally:
                self.fh.close()
                self.fh = None
        return False


def app_label(rec):
    titles = [str(lead.get("title"))[:80] for lead in (rec or {}).get("leads") or []
              if isinstance(lead, dict) and lead.get("title")]
    if titles:
        return "the RichOS app (%s)" % ", ".join('"%s"' % t for t in titles[:3])
    return "the RichOS app"


def app_running_text(rec, what):
    return ("Your team is running in %s, so this terminal does not %s: the terminal and the app never run "
            "your team at once. End it in the app first (quit the app, or wait until its conversations are "
            "done), then run this again." % (app_label(rec), what))


def unreadable_text(reason, what):
    path = claim_paths()[0]
    return ("The operator claim file %s is unreadable (%s), so this terminal treats your team as running "
            "elsewhere and does not %s. Rich checks that the RichOS app is not running your team, then removes "
            "that file: rm '%s'" % (path, reason, what, path))


# ---------------------------------------------------------------------------
# the claim at SessionStart
# ---------------------------------------------------------------------------

def cmd_claim_start(payload):
    """SessionStart. Idempotent for every source (r4 §2.4): a session that
    already holds its claim, or already carries a matching
    RICHOS_OPERATOR_LEAD, writes nothing."""
    entity = entity_root()
    if not operator_on(entity):
        return 0
    who = me()
    if who is None:
        return 0
    state, rec, _reason = claim_state()
    if is_app_lead(who, state, rec):
        return 0
    if not is_terminal(who, entity, payload.get("cwd") or ""):
        return 0
    path, lock = claim_paths()
    try:
        with ClaimLock(lock):
            state, rec, reason = claim_state(path)     # re-read inside the critical section
            if state == "unreadable":
                return system_message(unreadable_text(reason, "run your team"))
            if state == "app":
                return system_message(app_running_text(rec, "start agents, message teammates, "
                                                            "take the land lease or write the record and memory"))
            entry = {"role": "terminal", "pid": who["pid"], "start": who["start"],
                     "session_id": who.get("session_id") or ""}
            if state == "terminal":
                alive = live_processes(rec)
                if any(p["pid"] == who["pid"] and p["start"] == who["start"] for p in alive):
                    return 0                            # compact, resume, clear: already claimed
                rec["processes"] = alive + [entry]
            else:
                rec = {"schema": CLAIM_SCHEMA, "owner": "terminal", "claim_id": "terminal-%d-%d"
                       % (who["pid"], who["start"]), "claimed_at": OF.iso(), "processes": [entry], "leads": []}
            OF.write_json_atomic(path, rec)
    except TimeoutError as error:
        return system_message("The operator claim could not be checked (%s). This terminal is treated as not "
                              "holding your team until its next start." % error)
    return 0


# ---------------------------------------------------------------------------
# what the claim refuses in a terminal while the app runs his team (item 7)
# ---------------------------------------------------------------------------

def target_path(tool_input):
    return str((tool_input or {}).get("file_path") or (tool_input or {}).get("notebook_path") or "")


def memory_dir_of(path):
    """The memory directory a path is in, <claude dir>/projects/<slug>/memory,
    or ''. Any entity's memory: the rule is the same for each."""
    if not path:
        return ""
    real = realish(path)
    projects = os.path.realpath(os.path.join(claude_dir(), "projects"))
    if not inside(real, projects):
        return ""
    parts = os.path.relpath(real, projects).split(os.sep)
    if len(parts) >= 3 and parts[1] == "memory":
        return os.path.join(projects, parts[0], "memory")
    return ""


def fenced_main_checkout(path):
    """(conf, paths) when `path` is inside the MAIN checkout of a repository
    whose launcher is on, decided by the checkout that contains it (r3 e3,
    Frank G1 point 3), never by a path prefix: a native worktree under
    .claude/worktrees/ has its own top level. Gitignored paths are exempt."""
    if not path:
        return None
    real = realish(path)
    probe = real if os.path.isdir(real) else os.path.dirname(real)
    while probe and not os.path.isdir(probe):
        probe = os.path.dirname(probe)
    if not probe:
        return None
    paths = OF.repo_paths(probe)
    if not paths or not paths["main"] or paths["gitdir"] != paths["common"]:
        return None
    conf = OF.read_launcher(os.path.join(paths["common"], "hooks", "reference-transaction"))
    if not OF.fenced(conf):
        return None
    rc, _out, _err = OF.git(paths["main"], "check-ignore", "-q", "--", real)
    if rc == 0:
        return None
    return conf, paths


def claim_blocks(payload):
    """What of this call the claim governs, as a phrase, or ''."""
    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    if tool in TEAM_TOOLS:
        return {"Agent": "start agents", "SendMessage": "message teammates"}[tool]
    if tool in WRITE_TOOLS:
        path = target_path(tool_input)
        if memory_dir_of(path):
            return "write to your memory"
        if fenced_main_checkout(path):
            return "write to the record"
        return ""
    if tool == "Bash":
        command = str(tool_input.get("command") or "")
        if "land-lease.sh" in command and any(v in command for v in (" acquire", " takeover")):
            return "take the land lease"
    return ""


def cmd_claim_guard(payload):
    entity = entity_root()
    if not operator_on(entity):
        return 0
    state, rec, reason = claim_state()
    if state not in ("app", "unreadable"):
        return 0
    who = me()
    if who is None or is_app_lead(who, state, rec) or not is_terminal(who, entity, payload.get("cwd") or ""):
        return 0
    what = claim_blocks(payload)
    if not what:
        return 0
    if state == "unreadable":
        return refuse(unreadable_text(reason, what))
    return refuse(app_running_text(rec, what))


def lease_refusal(holder):
    """Why this land-lease holder may not take a lease right now, or ''. Asked
    by land-lease.sh acquire and takeover themselves (r3 (e) item 7), so a lease
    taken by a program (commit-ceo-inputs.py, a script) is refused as surely as
    one typed in a Bash command. Only a Claude holder whose entrypoint is not
    `sdk-*` is ever refused, and only while the app's claim is live or the claim
    is unreadable. There is no cwd rule here: the lease is per repository, and
    any interactive session landing into it while the app runs his team is the
    collision the claim exists to prevent. A declared non-Claude holder (Codex)
    is not governed by the claim."""
    if not holder or holder.get("kind") != "claude":
        return ""
    entry = holder.get("entrypoint") or ""
    if not entry or entry.startswith("sdk-"):
        return ""
    state, rec, reason = claim_state()
    if state not in ("app", "unreadable"):
        return ""
    who = {"pid": holder.get("pid"), "start": holder.get("start")}
    if is_app_lead(who, state, rec):
        return ""
    if state == "unreadable":
        return unreadable_text(reason, "take the land lease")
    return app_running_text(rec, "take the land lease")


# ---------------------------------------------------------------------------
# e3: shared writes
# ---------------------------------------------------------------------------

def memory_lease_path(memory_dir):
    digest = hashlib.sha256(os.path.realpath(memory_dir).encode("utf-8")).hexdigest()[:16]
    return os.path.join(claude_dir(), "state", "shared-writes", "memory-%s.lease" % digest)


def _lease_holder(payload):
    who = me() or {}
    return {"pid": who.get("pid"), "start": who.get("start"),
            "session_id": str(payload.get("session_id") or who.get("session_id") or ""),
            "tool_use_id": str(payload.get("tool_use_id") or "")}


def _stale(lease):
    try:
        age = OF.now() - float(lease.get("at"))
    except (TypeError, ValueError):
        return True
    if age > MEMORY_LEASE_STALE or age < -60:
        return True
    pid, start = lease.get("pid"), lease.get("start")
    if isinstance(pid, int) and isinstance(start, int) and not OF.alive(pid, start):
        return True
    return False


def take_memory_lease(path, holder, wait=MEMORY_LEASE_WAIT):
    """(True, None) once this call holds it; (False, current holder) after the
    wait. O_EXCL create; a stale file (its holder dead, or older than 5 s) is
    removed and the create retried."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    deadline = time.monotonic() + wait
    body = dict(holder, at=OF.now())
    last = None
    while True:
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as fh:
                fh.write(json.dumps(body, sort_keys=True) + "\n")
            return True, None
        except OSError as error:
            if error.errno != errno.EEXIST:
                raise
        current = OF.read_json(path)
        if current and holder.get("tool_use_id") and current.get("tool_use_id") == holder["tool_use_id"] \
                and current.get("session_id") == holder.get("session_id"):
            return True, None                           # the same call, delivered again
        if current is None or _stale(current):
            try:
                os.unlink(path)
            except OSError:
                pass
            continue
        last = current
        if time.monotonic() >= deadline:
            return False, last
        time.sleep(0.05)


def release_memory_lease(path, payload):
    current = OF.read_json(path)
    if not current:
        return False
    tuid = str(payload.get("tool_use_id") or "")
    if not tuid or current.get("tool_use_id") != tuid:
        return False
    try:
        os.unlink(path)
        return True
    except OSError:
        return False


def cmd_shared_writes_pre(payload):
    entity = entity_root()
    if not operator_on(entity):
        return 0
    if payload.get("tool_name") not in WRITE_TOOLS:
        return 0
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    path = target_path(tool_input)
    if not path:
        return 0
    memory = memory_dir_of(path)
    if memory:
        ok, holder = take_memory_lease(memory_lease_path(memory), _lease_holder(payload))
        if ok:
            return 0
        return refuse(
            "=== OPERATOR SHARED WRITES: %s is being written by another session ===\n"
            "  Session %s (process %s) has held the memory write lease for more than %d s. Two leads never\n"
            "  write his memory at the same moment, so one line is never lost to the other. Run the same\n"
            "  write again; a lease older than %d s, or one whose session has ended, is taken over."
            % (memory, (holder.get("session_id") or "?")[:8], holder.get("pid"), int(MEMORY_LEASE_WAIT),
               int(MEMORY_LEASE_STALE)))
    found = fenced_main_checkout(path)
    if not found:
        return 0
    conf, paths = found
    ok, lease = OF.authorized(OF.Files(conf))
    if ok:
        return 0
    held = "the lease is free" if OF.lease_state(lease) == "none" else \
        "the lease is held by %s" % OF.holder_label((lease or {}).get("holder"))
    engine = conf.get("ENGINE") or os.path.realpath(os.path.join(os.path.dirname(__file__), "..", ".."))
    return refuse(
        "=== OPERATOR SHARED WRITES: %s is in the main checkout %s, which needs the land lease ===\n"
        "  This session does not hold it (%s). The shared checkout is written only by the lease\n"
        "  holder, so another conversation's land never picks up a half-made change.\n"
        "  Take it first, then write again:\n"
        "      %s/scripts/land-lease.sh acquire --repo %s\n"
        "  Or make the change in your own worktree, which needs no lease."
        % (path, paths["main"], held, engine, paths["main"]))


def cmd_shared_writes_post(payload):
    """PostToolUse and PostToolUseFailure: release this call's memory lease.
    Never blocks, never speaks. Runs whatever the switch says, so a lease
    taken just before the switch went off is still released; with the switch
    off no lease was taken, and there is nothing to find."""
    if payload.get("tool_name") not in WRITE_TOOLS:
        return 0
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    memory = memory_dir_of(target_path(tool_input))
    if memory:
        release_memory_lease(memory_lease_path(memory), payload)
    return 0


# ---------------------------------------------------------------------------
# e5: live names are unique across sessions
# ---------------------------------------------------------------------------

def _workspaces():
    engine = os.path.realpath(os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", ".."))
    sys.path.insert(0, os.path.join(engine, "mega-lander"))
    try:
        import workspaces as W   # noqa: E402  (engine-only import)
    finally:
        sys.path.pop(0)
    return W


def live_holders_of(name, session_id):
    """[(record, why)] for every agent of ANOTHER session in the machine-wide
    registry that carries `name` and has not finished (finished_state, point
    11: running or paused both hold their name)."""
    W = _workspaces()
    cache, out = {}, []
    for rec in W.all_agents(include_done=False):
        if rec.get("name") != name or not rec.get("session_id") or rec.get("session_id") == session_id:
            continue
        finished, _paused, why = W.finished_state(rec, cache)
        if not finished:
            out.append((rec, why))
    return out


def cmd_live_names(payload):
    entity = entity_root()
    if not operator_on(entity):
        return 0
    if payload.get("tool_name") not in (None, "Agent"):
        return 0
    tool_input = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    name = str(tool_input.get("name") or "")
    session_id = str(payload.get("session_id") or "")
    if not name or not session_id:
        return 0
    holders = live_holders_of(name, session_id)
    if not holders:
        return 0
    rec, why = holders[0]
    _state, claim, _reason = claim_state()
    title = ""
    for lead in (claim or {}).get("leads") or []:
        if isinstance(lead, dict) and lead.get("session_id") == rec.get("session_id") and lead.get("title"):
            title = ' ("%s")' % str(lead["title"])[:80]
    return refuse(
        "=== OPERATOR LIVE NAMES: the name %s is held by a live agent of another session ===\n"
        "  Session %s%s has an agent named %s that has not finished (%s). While it runs, a\n"
        "  stop, a message or a land naming %s would reach two agents, so the name is refused\n"
        "  here. Identifiers are free: pick a fresh one (for example %s-2)."
        % (name, str(rec.get("session_id"))[:8], title, name, why, name, name))


# ---------------------------------------------------------------------------
# read-only answers, for enable.sh and for the app side's own checks
# ---------------------------------------------------------------------------

def cmd_claim_paths(_argv):
    path, lock = claim_paths()
    print(json.dumps({"claude_dir": claude_dir(), "file": path, "lock": lock}, sort_keys=True))
    return 0


def cmd_claim_status(_argv):
    state, rec, reason = claim_state()
    out = {"state": state, "reason": reason, "file": claim_paths()[0]}
    if rec:
        out["owner"] = rec.get("owner")
        out["live_processes"] = live_processes(rec)
    print(json.dumps(out, sort_keys=True))
    return 0 if state != "unreadable" else 1


VERBS = {"claim-start": cmd_claim_start, "claim-guard": cmd_claim_guard,
         "shared-writes-pre": cmd_shared_writes_pre, "shared-writes-post": cmd_shared_writes_post,
         "live-names": cmd_live_names}


def main(argv):
    if not argv:
        sys.stderr.write("usage: operator_leads.py claim-start|claim-guard|shared-writes-pre|"
                         "shared-writes-post|live-names|claim-paths|claim-status\n")
        return 2
    verb = argv[0]
    if verb == "claim-paths":
        return cmd_claim_paths(argv[1:])
    if verb == "claim-status":
        return cmd_claim_status(argv[1:])
    if verb not in VERBS:
        sys.stderr.write("operator_leads.py: unknown verb %r\n" % verb)
        return 2
    payload = read_payload()
    if payload is None:
        sys.stderr.write("operator_leads.py %s: the hook payload is not a JSON object\n" % verb)
        return EXIT_INTERNAL
    try:
        return VERBS[verb](payload)
    except Exception as error:   # noqa: BLE001  the wrapper announces it; a bug never blocks a call
        sys.stderr.write("operator_leads.py %s failed: %s: %s\n" % (verb, type(error).__name__, error))
        return EXIT_INTERNAL


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
