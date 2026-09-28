#!/usr/bin/env python3
"""stall_watch.py: THE LEAD IS WOKEN THE MOMENT TEAMMATE WORK STALLS.

===========================================================================
WHAT THIS EXISTS FOR
===========================================================================
The CEO, 2026-09-28, after three teammates made no commit for 70 to 85 minutes
while he was away: "everyone is fucking WAITING ALL THE FUCKING TIME AND
NOTHING EVER MOVES FORWARD", "WHY THE FUCK DO I ALWAYS HAVE TO MANAGE ALL THIS
FUCKSHIT??? IS THAT MY FUCKING JOB???" and "WHERE THE FUCK WAS THAT FUCKING
WATCHER BEFORE???". His build points (2026-09-25): "He never has to ask; every
step and failure reaches him unprompted." "A free Mac is used whole; nothing
waits in a line."

What happened: the three were queued behind the Mac's single proof-run slot
(limit 1, one holder, three waiting 32 to 41 minutes) while the Mac sat at 26
to 38% CPU, and one of them (buildguard1) was queued behind its OWN proof run.
Nothing woke the lead: no teammate finished, guard-resource-waits.sh fires only
when the lead ends a turn, and the lead had no turn. A watcher that must be
started by hand is the same defect one step later, so this one is started by
Claude Code itself with every interactive session: the engine's plugin monitor
(monitors/monitors.json), exactly as quota-watch is.

===========================================================================
WHAT IS A STALL (every threshold, and why)
===========================================================================
1. A RESOURCE WAIT OVER 10 MINUTES (RICHOS_RESOURCE_WAIT_MINUTES, the same
   number and the same variable as the turn-end gate, resource_waits.py).
   Read from the records waiters write themselves (resource_waits.py: CPU
   admission, the test VM slot, a go-file, and any other resource a waiter
   names, such as a device), from the escalation ledger's stated waits, and
   from the proof-run slot line itself (app/scripts/lib/proof_slots.py
   status), which says who holds each slot and where each waiter stands.
   A wait is recorded, never inferred from process names.

2. A SILENT TEAMMATE: a live teammate of THIS session (the workspace registry
   says its run has not ended and it is not paused) with no new commit on any
   of its workspaces AND no new write to its transcript for 20 minutes
   (STALL_WATCH_SILENT_MINUTES). Why 20: a working teammate writes its
   transcript at every tool result. The longest honest gap between two is one
   tool call: the Bash tool's ceiling is 600 s (a longer foreground command is
   moved to the background at 600 s and the move is a result), and a teammate
   waiting on a background command runs `agent_hold.py wait`, which returns at
   most every 270 s. So a long honest test run keeps writing the transcript at
   least every ten minutes however long the run itself takes, and twenty is
   twice the longest honest silence. A commit is not required: a teammate that
   is working but has not committed for an hour is not silent.

3. A SELF-WAIT: a teammate process waiting for a proof-run slot or a test VM
   slot that another process of the SAME teammate holds, reported after 2
   minutes (STALL_WATCH_SELF_WAIT_MINUTES): the Mac getting freer never ends
   it, only its own other run ending does. Ownership is read, in order, from
   the process's inherited owner tag (agent_hold.py's RICHOS_AGENT_OWNER,
   captured at spawn), from the registered workspace its recorded working
   directory is in, and from the waiter name the slot library recorded. When
   the holder is the waiter's own ANCESTOR it is a DEADLOCK: a nested run that
   did not borrow its caller's slot, which only the 3-hour timeout ends.

===========================================================================
HOW OFTEN IT SPEAKS (nothing spams)
===========================================================================
It looks every 60 s (STALL_WATCH_POLL_SECONDS). A stall is announced ONCE when
it is first seen, again only when it has lasted another 30 minutes since the
last notice (STALL_WATCH_REPEAT_MINUTES), and once more, in one line, when it
has been gone for two consecutive looks (one look that misses it is not an end:
a source can fail to read once). Everything due in one look is ONE notification
block. What was announced is kept in its session's state directory, so a
restarted monitor does not repeat itself.

===========================================================================
IT ONLY REPORTS
===========================================================================
It never kills, stops, pauses, signals or messages anything, and it takes no
lock that anything else waits for (the slot library's own status probe is a
shared, non-blocking lock dropped at once). Each notice names the teammate,
what it waits on, who holds it, since when, and what the lead can do. The lead
acts.

===========================================================================
COMMANDS (stall-watch.sh passes --engine-root, --config and --command)
===========================================================================
  --monitor  the plugin monitor's body: runs for the whole session and prints
             each notification block; ends with its session
  --alive    one line: is this session watched, and when did it last look.
             0 watched; 1 nothing is watching (or the watcher stopped
             looking); 2 no session here to check
  --watch    the fallback where plugin monitors do not run: the same loop, run
             as a BACKGROUND command; it exits after the first notification,
             so start it again after each one
  --once     every stall right now, whatever was announced; 0 none, 1 some,
             2 could not look at all. Keeps no state
  --notice   the SessionStart notice body (session-start-stall.sh wraps it)
  --tick     one look against the session's state, printing what the monitor
             would print (the test suite's clock is STALL_WATCH_NOW)
"""

import argparse
import datetime as _dt
import fcntl
import glob
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import resource_waits  # noqa: E402  (sibling in scripts/lib)

POLL_SECONDS = 60
SILENT_MINUTES = 20
SELF_WAIT_MINUTES = 2
REPEAT_MINUTES = 30
CLEAR_AFTER_MISSES = 2
STATE_KEEP_SECONDS = 2 * 86400
PROOF_SLOT_REASON = "proof-run: waiting for a proof-run slot"
OWNER_TAG = "RICHOS_AGENT_OWNER"
GIT_SECONDS = 5
CPU_LINE = 80


# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

def _env_float(name, default):
    raw = (os.environ.get(name) or "").strip()
    try:
        value = float(raw) if raw else float(default)
    except ValueError:
        value = float(default)
    return value if value > 0 else float(default)


def clock():
    """Now, as stalls are judged. STALL_WATCH_NOW (epoch seconds) exists for
    stall-watch.test.sh, which cannot make a real process wait ten minutes;
    nothing else sets it. Process identities are always read against the real
    clock, so moving this cannot bring a dead wait back."""
    raw = (os.environ.get("STALL_WATCH_NOW") or "").strip()
    try:
        return float(raw) if raw else time.time()
    except ValueError:
        return time.time()


def hhmm(epoch):
    return _dt.datetime.fromtimestamp(epoch, _dt.timezone.utc).strftime("%H:%MZ")


def hms(epoch):
    return _dt.datetime.fromtimestamp(epoch, _dt.timezone.utc).strftime("%H:%M:%SZ")


def span(seconds):
    return resource_waits.minutes(max(0, seconds))


def parse_iso(text):
    try:
        return _dt.datetime.strptime(str(text), "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=_dt.timezone.utc).timestamp()
    except (TypeError, ValueError):
        return None


def _short(command, limit=100):
    return resource_waits.short(command or "", limit)


def _read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            v = json.load(fh)
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_json(path, data):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _load(name, path):
    """A module from a file path, or None. Never raises."""
    if not path or not os.path.isfile(path):
        return None
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:  # noqa: BLE001: a module that cannot load is "not read", reported
        return None


# ---------------------------------------------------------------------------
# the sources: registry, proof-run slots, the admission sampler, ownership
# ---------------------------------------------------------------------------

class Sources(object):
    """Everything a look reads, loaded once per process."""

    def __init__(self, engine_root):
        self.engine_root = engine_root or os.path.dirname(os.path.dirname(HERE))
        self.ws = _load("stall_watch_workspaces", os.path.join(self.engine_root, "mega-lander", "workspaces.py"))
        app = os.path.join(os.path.dirname(os.path.realpath(self.engine_root)), "app", "scripts")
        self.proof_slots_path = os.path.join(app, "lib", "proof_slots.py")
        self.proof_slots = _load("stall_watch_proof_slots", self.proof_slots_path)
        self._reserve_path = os.path.join(app, "testvm", "reserve.py")
        self._reserve = None
        try:
            import agent_hold  # noqa: WPS433 (sibling in scripts/lib)
            self.agent_hold = agent_hold
        except Exception:  # noqa: BLE001
            self.agent_hold = None
        self.transcripts = {}

    def cpu_busy(self):
        """(percent, how) from the admission rule's own one-second sample, or
        (None, why). STALL_WATCH_CPU_BUSY pins it for the test suite."""
        pinned = (os.environ.get("STALL_WATCH_CPU_BUSY") or "").strip()
        if pinned:
            try:
                return float(pinned), "pinned"
            except ValueError:
                pass
        if self._reserve is None:
            self._reserve = _load("stall_watch_reserve", self._reserve_path) or False
        if not self._reserve:
            return None, "the admission sampler (app/scripts/testvm/reserve.py) is not beside this engine"
        try:
            s = self._reserve.host_sample(1.0)
            return s["cpu_user_percent"] + s["cpu_system_percent"], "sampled"
        except Exception as exc:  # noqa: BLE001: unmeasured is said, never guessed
            return None, "the CPU could not be sampled (%s)" % exc

    def session(self):
        """(session id, claude pid) of the session this runs in, or ('', None)."""
        if self.ws is None:
            return "", None
        try:
            sid = self.ws.current_session() or ""
            pid = self.ws.session_pid(sid) if sid else self.ws.session_pid()
        except Exception:  # noqa: BLE001
            return "", None
        return sid, pid

    def owner_tag(self, pid):
        """The agent id in the process's inherited owner tag, or ''."""
        if self.agent_hold is None or not pid:
            return ""
        try:
            env = self.agent_hold._environment(int(pid)) or []
        except Exception:  # noqa: BLE001
            return ""
        want = (OWNER_TAG + "=").encode()
        for item in env:
            if item.startswith(want):
                return item[len(want):].decode("utf-8", "replace")
        return ""


class Registry(object):
    """The workspace registry, read once per look: names by agent id and by path."""

    def __init__(self, src):
        self.src = src
        self.recs = []
        self.problem = ""
        self.by_agent = {}
        self.paths = []
        if src.ws is None:
            self.problem = "the workspace registry library (mega-lander/workspaces.py) could not be loaded"
            return
        try:
            self.recs = src.ws.all_agents()
        except Exception as exc:  # noqa: BLE001
            self.problem = "the workspace registry could not be read (%s)" % exc.__class__.__name__
        for r in sorted(self.recs, key=lambda r: str(r.get("registered_at") or "")):
            if r.get("agent_id"):
                self.by_agent[str(r["agent_id"])] = r
            for w in r.get("workspaces") or []:
                if w.get("path") and not w.get("deleted_at"):
                    self.paths.append((os.path.realpath(w["path"]), r))
        self.paths.sort(key=lambda p: len(p[0]), reverse=True)
        self.names = set(str(r.get("name") or "") for r in self.recs)

    def name_for_path(self, cwd):
        if not cwd:
            return ""
        real = os.path.realpath(cwd)
        for path, r in self.paths:
            if real == path or real.startswith(path + os.sep):
                return str(r.get("name") or r.get("key") or "")
        return ""

    def name_for_waiter(self, waiter):
        """A recorded waiter name as a teammate name: a registry name as is,
        `agent-<id>` through the registry, anything path-like is no name."""
        waiter = str(waiter or "")
        if not waiter or waiter.startswith(os.sep) or waiter.startswith("pid "):
            return ""
        if waiter.startswith("agent-") and waiter[len("agent-"):] in self.by_agent:
            return str(self.by_agent[waiter[len("agent-"):]].get("name") or waiter)
        return waiter

    def owner(self, pid, cwd="", waiter=""):
        """(teammate name, how it is known) for a process, or ('', '')."""
        tag = self.src.owner_tag(pid)
        if tag:
            rec = self.by_agent.get(tag)
            return (str(rec.get("name")) if rec and rec.get("name") else "agent-" + tag), "its owner tag"
        name = self.name_for_path(cwd)
        if name:
            return name, "its working directory"
        name = self.name_for_waiter(waiter)
        if name:
            return name, "the name its slot record carries"
        return "", ""


# ---------------------------------------------------------------------------
# one stall
# ---------------------------------------------------------------------------

class Stall(object):
    def __init__(self, key, kind, who, since, what, lines, action):
        self.key, self.kind, self.who, self.since = key, kind, who, since
        self.what, self.lines, self.action = what, list(lines), list(action)

    def render(self, now, notice_no=1, first_at=None):
        head = "  [%s] %s" % (self.kind, self.headline(now))
        if notice_no > 1:
            head += "  (still, notice %d; first announced %s)" % (notice_no, hhmm(first_at or now))
        out = [head]
        out += ["      " + ln for ln in self.lines]
        for i, a in enumerate(self.action):
            out.append(("      You can: " if i == 0 else "               ") + a)
        return out

    def headline(self, now):
        return "%s: %s, for %s (since %s)" % (self.who, self.what, span(now - self.since), hhmm(self.since))


# ---------------------------------------------------------------------------
# the look
# ---------------------------------------------------------------------------

def thresholds():
    return {"wait": resource_waits.wait_minutes() * 60,
            "silent": _env_float("STALL_WATCH_SILENT_MINUTES", SILENT_MINUTES) * 60,
            "self": _env_float("STALL_WATCH_SELF_WAIT_MINUTES", SELF_WAIT_MINUTES) * 60,
            "repeat": _env_float("STALL_WATCH_REPEAT_MINUTES", REPEAT_MINUTES) * 60}


def _ancestors(pid, table):
    out, seen = [], set()
    p = table.get(pid) if table else None
    while p is not None and p.ppid not in seen and p.ppid > 1:
        seen.add(p.ppid)
        out.append(p.ppid)
        p = table.get(p.ppid)
    return out


def _proc_words(pid, table):
    p = table.get(pid) if table else None
    return "`%s`" % _short(p.command, 90) if p is not None else "(command not read)"


def _slot_lines(src, now):
    """(status dict or None, problem)."""
    if src.proof_slots is None:
        return None, "the proof-run slot library (app/scripts/lib/proof_slots.py) is not beside this engine"
    try:
        return src.proof_slots.status(), ""
    except Exception as exc:  # noqa: BLE001
        return None, "the proof-run slots could not be read (%s)" % exc


def look(src, now, session_id, th=None):
    """(stalls, problems): every stall right now. Never raises for a source it
    cannot read; that source is named in problems and the rest is still read."""
    th = th or thresholds()
    reg = Registry(src)
    problems = [reg.problem] if reg.problem else []
    stalls = []
    deadline = time.time() + resource_waits.BUDGET_SECONDS
    table = None

    # -- proof-run slots: the line, its holders, and whose each one is --------
    slots, why = _slot_lines(src, now)
    if why:
        problems.append(why)
    slot_waiter_pids = set()
    watched = []  # (kind, waiter dict, holders)
    if slots:
        for w in slots.get("waiting") or []:
            try:
                slot_waiter_pids.add(int(w.get("pid")))
            except (TypeError, ValueError):
                pass
            since = w.get("since") if isinstance(w.get("since"), (int, float)) else now
            if now - since >= min(th["self"], th["wait"]):
                watched.append(("proof", w, slots.get("holders") or []))

    # -- every other recorded wait (and the ledger's) -------------------------
    reading = resource_waits.collect(now=now, threshold_seconds=min(th["self"], th["wait"]))
    problems += reading["problems"]
    # A proof-run slot waiter also records itself as a CPU-admission wait; with
    # the slot line read, that record is the same wait and is told once.
    others = [w for w in reading["waits"]
              if not (w.get("pid") in slot_waiter_pids or
                      (slots is not None and w["source"] == "record" and w["reason"].startswith(PROOF_SLOT_REASON)))]

    if watched or any(now - w["since"] >= min(th["self"], th["wait"]) for w in others):
        table, why = resource_waits.ps_table(deadline)
        if table is None:
            problems.append(why)

    for _kind, w, holders in watched:
        stalls += _proof_stall(src, reg, w, holders, slots, now, th, table)

    vm_slots = None
    for w in others:
        age = now - w["since"]
        if w["resource"] == resource_waits.VM and w["source"] == "record":
            if vm_slots is None:
                _lines, vm_slots, _g = resource_waits.vm_facts(resource_waits.testvm_root(), table, reading["waits"])
            own = _vm_self_wait(src, reg, w, vm_slots, table)
            if own and age >= th["self"]:
                stalls.append(own)
                continue
        if age < th["wait"]:
            continue
        stalls.append(_wait_stall(reg, w, now, table, reading["waits"]))

    # -- silent teammates of this session ------------------------------------
    s, why = _silent(src, reg, now, session_id, th, reading["waits"])
    stalls += s
    if why:
        problems.append(why)
    return stalls, [p for p in problems if p]


def _proof_stall(src, reg, w, holders, slots, now, th, table):
    pid = w.get("pid")
    since = w.get("since") if isinstance(w.get("since"), (int, float)) else now
    who, how = reg.owner(pid, w.get("cwd") or "", w.get("waiter") or "")
    who = who or str(w.get("waiter") or "pid %s" % pid)
    limit = slots.get("limit")
    held = []
    mine = []
    for h in holders:
        hname, hhow = reg.owner(h.get("pid"), h.get("cwd") or "", h.get("waiter") or "")
        hsince = h.get("since") if isinstance(h.get("since"), (int, float)) else now
        desc = "%s (pid %s, %s) for %s since %s" % (hname or h.get("waiter") or "?", h.get("pid"),
                                                    _proc_words(h.get("pid"), table), span(now - hsince), hhmm(hsince))
        held.append(desc)
        if hname and hname == who:
            mine.append((h, hhow))
        elif table and isinstance(h.get("pid"), int) and h["pid"] in _ancestors(pid, table):
            mine.append((h, "its process ancestry"))
    ps = src.proof_slots_path
    place = "#%s in line, this Mac runs %s at once" % (w.get("position", "?"), limit)
    key = "wait:proof:%s:%d" % (pid, int(since))
    if mine and now - since >= th["self"]:
        h, hhow = mine[0]
        deadlock = bool(table) and isinstance(h.get("pid"), int) and h["pid"] in _ancestors(pid, table)
        lines = ["waiting: pid %s %s (%s)" % (pid, _proc_words(pid, table), place),
                 "held by: pid %s %s, which is ALSO %s's (known from %s)" % (
                     h.get("pid"), _proc_words(h.get("pid"), table), who, hhow)]
        if deadlock:
            lines.append("DEADLOCK: the holder is the waiter's own ancestor, so the waiter is never admitted while "
                         "it waits: a nested run that did not borrow its caller's slot (RICHOS_PROOF_RUN_SLOT_HELD). "
                         "Only its 3-hour timeout ends it.")
        else:
            lines.append("It waits on itself: the Mac getting freer never ends this wait, only its own run ending does.")
        action = ["tell %s to run it inside its proof run, or after that run ends" % who]
        if deadlock:
            action.append("or have %s end the nested wait (pid %s) and rerun it through its caller's slot" % (who, pid))
        elif isinstance(limit, int):
            action.append("or, if the Mac has headroom: python3 %s set %d  (`set default` puts it back)" % (ps, limit + 1))
        return [Stall(key, "SELF-WAIT", who, since, "waits for a proof-run slot its own process holds", lines, action)]
    if now - since < th["wait"]:
        return []
    lines = ["waiting: pid %s %s (%s)" % (pid, _proc_words(pid, table), place),
             "held by: " + ("; ".join(held) if held else "nobody holds a slot right now (it should be admitted at its next poll)")]
    busy, how = src.cpu_busy()
    action = []
    if busy is None:
        lines.append("Mac CPU: unknown (%s)" % how)
        action.append("check the CPU, then if there is headroom: python3 %s set %s" % (
            ps, (limit + 1) if isinstance(limit, int) else "N"))
    elif busy < CPU_LINE:
        lines.append("Mac CPU now: %.0f%% busy, under the %d%% admission line: there is headroom" % (busy, CPU_LINE))
        if isinstance(limit, int) and limit < (os.cpu_count() or 1):
            action.append("python3 %s set %d  (lets the next run in now; `set default` puts it back)" % (ps, limit + 1))
        action.append("or reorder: ask the holder's owner whether its run can end sooner")
    else:
        lines.append("Mac CPU now: %.0f%% busy, at or over the %d%% line: another slot would not run faster" % (
            busy, CPU_LINE))
        action.append("reorder: defer or end the holder's run (%s), or tell %s to do other work meanwhile" % (
            "; ".join("pid %s" % h.get("pid") for h in holders) or "no holder", who))
    action.append("the whole line: python3 %s status" % ps)
    return [Stall(key, "WAIT", who, since, "waits for a proof-run slot", lines, action)]


def _vm_self_wait(src, reg, w, vm_slots, table):
    who, _how = reg.owner(w["pid"], "", w["waiter"])
    if not who:
        return None
    for s in vm_slots or []:
        if not s.get("pid"):
            continue
        hname, hhow = reg.owner(s["pid"], "", "")
        anc = bool(table) and s["pid"] in _ancestors(w["pid"], table)
        if (hname and hname == who) or anc:
            lines = ["waiting: pid %s %s" % (w["pid"], _proc_words(w["pid"], table)),
                     "held by: %s held by pid %s %s, which is ALSO %s's (known from %s)" % (
                         s["name"], s["pid"], _proc_words(s["pid"], table), who,
                         hhow or "its process ancestry")]
            return Stall("wait:rec:%d:%d" % (w["pid"], int(w["since"])), "SELF-WAIT", who, w["since"],
                         "waits for the test VM that its own process holds", lines,
                         ["tell %s to let its own walk finish first, or to end the walk it no longer needs" % who,
                          "every current wait: python3 %s list" % os.path.join(HERE, "resource_waits.py")])
    return None


def _wait_stall(reg, w, now, table, waits):
    label = resource_waits.LABELS.get(w["resource"], w["resource"])
    name = reg.name_for_waiter(w["waiter"]) or w["waiter"]
    rw = os.path.join(HERE, "resource_waits.py")
    lines = []
    if w["source"] == "record":
        lines.append("waiting: pid %d %s" % (w["pid"], _proc_words(w["pid"], table)))
        key = "wait:rec:%d:%d" % (w["pid"], int(w["since"]))
    else:
        lines.append("from the escalation ledger: %s" % ", ".join(w.get("escalations") or []))
        key = "wait:esc:%s:%s" % (w["waiter"], w["resource"])
    if w.get("reason"):
        lines.append("last refusal: %s" % w["reason"][:220])
    action = []
    if w["resource"] == resource_waits.VM:
        facts = resource_waits.vm_facts(resource_waits.testvm_root(), table, waits)[0]
        lines += ["held by: " + f for f in facts]
        action.append("reclaim a slot whose holder is not using it, or stop or defer the holder")
    elif w["resource"] == resource_waits.CPU:
        facts = resource_waits.cpu_facts(table)
        lines += ["CPU: " + f for f in facts]
        action.append("stop or defer the largest CPU user above, or tell %s to do other work meanwhile" % name)
    else:
        lines.append("held by: not recorded by the waiter")
        action.append("find the holder of %s, or tell %s to do other work meanwhile" % (label, name))
    action.append("every current wait: python3 %s list" % rw)
    return Stall(key, "WAIT", name, w["since"], "waits for %s" % label, lines, action)


def _git_last_commit(path):
    """(committer epoch, short sha, branch) of the workspace's HEAD, or None."""
    if not path or not os.path.isdir(path):
        return None
    try:
        r = subprocess.run(["git", "-C", path, "log", "-1", "--format=%ct %h", "HEAD"],
                           capture_output=True, text=True, timeout=GIT_SECONDS)
    except (OSError, subprocess.TimeoutExpired):
        return None
    parts = r.stdout.strip().split(" ")
    if r.returncode != 0 or len(parts) < 2 or not parts[0].isdigit():
        return None
    return int(parts[0]), parts[1]


def _transcript(src, rec):
    aid = str(rec.get("agent_id") or "")
    if not aid:
        return ""
    path = src.transcripts.get(aid)
    if path and os.path.isfile(path):
        return path
    try:
        path = src.ws.platform_agent_transcript(rec) or ""
    except Exception:  # noqa: BLE001
        path = ""
    if path:
        src.transcripts[aid] = path
    return path


def _running(src, rec, now):
    """Up to three of the teammate's own recorded commands still running."""
    ah = src.agent_hold
    if ah is None or not rec.get("agent_id") or not rec.get("session_id"):
        return []
    try:
        table = ah.snapshot()
        calls = ah.calls(str(rec["session_id"]), str(rec["agent_id"]), table)
    except Exception:  # noqa: BLE001
        return []
    out = []
    for c in sorted(calls, key=lambda c: c["at"])[:3]:
        out.append("running: `%s` (pid %d, for %s)" % (_short(c["command"], 90), c["pid"], span(time.time() - c["at"])))
    return out


def _silent(src, reg, now, session_id, th, waits):
    if src.ws is None or reg.problem:
        return [], ""
    if not session_id:
        return [], "no session here, so no teammate of it can be named"
    out = []
    cache = {}
    for rec in reg.recs:
        if rec.get("session_id") != session_id or rec.get("disposition"):
            continue
        try:
            fin, paused, _why = src.ws.finished_state(rec, cache)
        except Exception:  # noqa: BLE001
            continue
        if fin or paused:
            continue
        name = str(rec.get("name") or rec.get("key") or "?")
        start = None
        for k in ("started_at", "spawned_at", "registered_at"):
            start = parse_iso(rec.get(k))
            if start is not None:
                break
        marks = [start or now]
        commit_line = "no commit since it started"
        best = None
        for w in rec.get("workspaces") or []:
            if w.get("deleted_at"):
                continue
            c = _git_last_commit(w.get("path"))
            if c and (best is None or c[0] > best[0][0]):
                best = (c, w.get("branch") or "?")
        if best and start is not None and best[0][0] > start:
            marks.append(best[0][0])
            commit_line = "last commit %s %s on %s" % (hhmm(best[0][0]), best[0][1], best[1])
        path = _transcript(src, rec)
        tline = "no transcript found for it"
        if path:
            try:
                mt = os.path.getmtime(path)
                marks.append(mt)
                tline = "last transcript write %s (%s)" % (hhmm(mt), path)
            except OSError:
                pass
        last = max(marks)
        if now - last < th["silent"]:
            continue
        lines = [commit_line, tline]
        own_waits = [w for w in waits if reg.name_for_waiter(w["waiter"]) == name]
        for w in own_waits[:2]:
            lines.append("recorded wait: %s for %s" % (resource_waits.LABELS.get(w["resource"], w["resource"]),
                                                       span(now - w["since"])))
        lines += _running(src, rec, now)
        action = ["ask %s where it is (SendMessage to %s)" % (name, name),
                  "read the end of its transcript (above)",
                  "check it: %s %s" % (os.path.join(src.engine_root, "scripts", "agent-liveness.sh"),
                                       rec.get("agent_id") or name)]
        out.append(Stall("silent:%s" % rec.get("key"), "SILENT", name, last,
                         "no commit and no transcript activity" if not own_waits else
                         "no commit and no transcript activity (it has a recorded wait)", lines, action))
    return out, ""


# ---------------------------------------------------------------------------
# what is announced, and when
# ---------------------------------------------------------------------------

def announce(state, stalls, problems, now, th):
    """(lines to print, new state). A stall is announced when first seen, again
    after th['repeat'] since its last notice, and cleared (one line) after
    CLEAR_AFTER_MISSES looks without it. A source that cannot be read is
    announced the same way, as a stall of the watcher itself."""
    opened = dict(state.get("open") or {})
    current = {s.key: s for s in stalls}
    for p in problems:
        key = "blind:" + p[:80]
        current[key] = Stall(key, "NOT READ", "stall-watch", now, "cannot read a source", [p],
                             ["stalls that depend on it are not seen until it reads again"])
    new, again, cleared = [], [], []
    for key, s in current.items():
        prev = opened.get(key)
        if prev is None:
            opened[key] = {"first": now, "last": now, "count": 1, "since": s.since, "who": s.who,
                           "what": s.what, "missed": 0}
            new.append((s, 1, now))
            continue
        prev["missed"] = 0
        if now - prev["last"] >= th["repeat"]:
            prev["last"] = now
            prev["count"] = int(prev.get("count") or 1) + 1
            again.append((s, prev["count"], prev["first"]))
    for key in list(opened):
        if key in current:
            continue
        prev = opened[key]
        prev["missed"] = int(prev.get("missed") or 0) + 1
        if prev["missed"] >= CLEAR_AFTER_MISSES:
            cleared.append(opened.pop(key))
    lines = []
    if new or again:
        n = len(new) + len(again)
        lines.append("STALL-WATCH %s: %d stall%s%s (this only reports: nothing was paused, stopped or killed)" % (
            hhmm(now), n, "" if n == 1 else "s",
            "" if not again else ", %d still going since an earlier notice" % len(again)))
        for s, no, first in new + again:
            lines += s.render(now, no, first)
    for c in cleared:
        lines.append("STALL-CLEARED %s: %s: %s, over after about %s" % (
            hhmm(now), c.get("who"), c.get("what"), span(now - float(c.get("since") or now))))
    return lines, {"open": opened, "at": now}


# ---------------------------------------------------------------------------
# state, the session, and the loop
# ---------------------------------------------------------------------------

def state_root():
    return (os.environ.get("STALL_WATCH_STATE_DIR") or "").strip() or os.path.join(
        os.path.expanduser("~"), ".claude", "state", "stall-watch")


def session_dir(sid):
    d = os.path.join(state_root(), sid or "no-session")
    os.makedirs(d, exist_ok=True)
    return d


def _try_lock(path):
    try:
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return fd
    except OSError:
        os.close(fd)
        return None


def lock_held(path):
    """True when a live process holds the lock at path. Takes nothing that lasts."""
    if not os.path.exists(path):
        return False
    fd = _try_lock(path)
    if fd is None:
        return True
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)
    return False


def prune_state(keep):
    """Section 54: a session's directory goes once nothing holds its lock and it
    has not been written for two days. Never the one in use."""
    root = state_root()
    try:
        names = os.listdir(root)
    except OSError:
        return
    now = time.time()
    for n in names:
        d = os.path.join(root, n)
        if d == keep or not os.path.isdir(d) or lock_held(os.path.join(d, "monitor.lock")):
            continue
        try:
            newest = max([os.path.getmtime(os.path.join(d, f)) for f in os.listdir(d)] + [os.path.getmtime(d)])
        except OSError:
            continue
        if now - newest > STATE_KEEP_SECONDS:
            shutil.rmtree(d, ignore_errors=True)


def session_alive_check(pid):
    """Is the session's claude process still the one this started for? Its pid
    every call, and its start time once a minute (a reused pid is not it)."""
    def _start(p):
        try:
            r = subprocess.run(["ps", "-o", "lstart=", "-p", str(int(p))], capture_output=True, text=True, timeout=10)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return ""
        return r.stdout.strip() if r.returncode == 0 else ""
    first = _start(pid)
    calls = [0]

    def alive():
        try:
            os.kill(int(pid), 0)
        except PermissionError:
            pass
        except (OSError, ValueError, TypeError):
            return False
        calls[0] += 1
        if first and calls[0] % 12 == 0:
            now_start = _start(pid)
            if now_start and now_start != first:
                return False
        return True
    return alive


def tick(src, sd, sid, now=None, out=None):
    """One look against the session's state: prints what is due, returns the
    number of lines printed. A look that raises is announced once as a stall
    of the watcher and changes nothing else."""
    out = out or sys.stdout
    now = clock() if now is None else now
    th = thresholds()
    path = os.path.join(sd, "announced.json")
    state = _read_json(path)
    try:
        stalls, problems = look(src, now, sid, th)
    except Exception as exc:  # noqa: BLE001: one failed look is reported, never the end of watching
        stalls, problems = [], []
        problems.append("a look failed (%s: %s)" % (exc.__class__.__name__, str(exc)[:160]))
        keep = dict(state.get("open") or {})
        lines, _new = announce({"open": {}}, [], problems, now, th)
        key = "blind:" + problems[0][:80]
        if key in keep:
            lines = []
        else:
            keep[key] = {"first": now, "last": now, "count": 1, "since": now, "who": "stall-watch",
                         "what": "a look failed", "missed": 0}
        state = {"open": keep, "at": now}
    else:
        lines, state = announce(state, stalls, problems, now, th)
    _write_json(path, state)
    if lines:
        out.write("\n".join(lines) + "\n")
        out.flush()
    return len(lines), len(state.get("open") or {})


def _nap(seconds, alive):
    left = seconds
    while left > 0:
        step = min(5.0, left)
        time.sleep(step)
        left -= step
        if alive is not None and not alive():
            return


def run_loop(a, src, exit_on_notice=False):
    sid, spid = src.session()
    sd = session_dir(sid)
    lock = os.path.join(sd, "monitor.lock")
    fd = _try_lock(lock)
    if fd is None:
        if exit_on_notice:
            mon = _read_json(os.path.join(sd, "monitor.json"))
            print("stall-watch: this session is already watched (pid %s); nothing to start." % mon.get("pid", "?"))
        return 0
    prune_state(sd)
    alive = session_alive_check(spid) if spid else None
    poll = _env_float("STALL_WATCH_POLL_SECONDS", POLL_SECONDS)
    beat = {"pid": os.getpid(), "started": int(time.time()), "poll": poll, "session": sid,
            "mode": "watch" if exit_on_notice else "monitor", "last_look": None, "open": 0}
    try:
        while alive is None or alive():
            printed, open_n = tick(src, sd, sid)
            beat["last_look"] = time.time()
            beat["open"] = open_n
            _write_json(os.path.join(sd, "monitor.json"), beat)
            if printed and exit_on_notice:
                print("  To be told of the next one, start this again as a background command: %s --watch" % a.command)
                return 0
            _nap(poll, alive)
    finally:
        os.close(fd)
    return 0


def mode_alive(a, src):
    sid, spid = src.session()
    if not spid and not sid:
        print("stall-watch: no session here; nothing to check")
        return 2
    sd = os.path.join(state_root(), sid or "no-session")
    beat = _read_json(os.path.join(sd, "monitor.json"))
    held = lock_held(os.path.join(sd, "monitor.lock"))
    poll = float(beat.get("poll") or POLL_SECONDS)
    if not held:
        print("stall-watch: NOT WATCHED: nothing looks for stalls in this session. Start as a background command "
              "(Bash with run_in_background: true): %s --watch" % a.command)
        return 1
    last = beat.get("last_look")
    if not last:
        print("stall-watch: %s pid %s started, no look finished yet" % (beat.get("mode", "monitor"), beat.get("pid")))
        return 0
    age = time.time() - float(last)
    if age > 3 * poll + 30:
        print("stall-watch: STOPPED LOOKING: %s pid %s last looked %s, %s ago (it looks every %.0f s)" % (
            beat.get("mode", "monitor"), beat.get("pid"), hms(last), span(age), poll))
        return 1
    print("stall-watch: watching (%s pid %s, every %.0f s; last look %s, %.0f s ago; %d open stall%s)" % (
        beat.get("mode", "monitor"), beat.get("pid"), poll, hms(last), age, int(beat.get("open") or 0),
        "" if int(beat.get("open") or 0) == 1 else "s"))
    return 0


def mode_once(a, src):
    sid, _spid = src.session()
    now = clock()
    try:
        stalls, problems = look(src, now, sid)
    except Exception as exc:  # noqa: BLE001
        print("stall-watch: could not look (%s: %s)" % (exc.__class__.__name__, exc))
        return 2
    if not stalls:
        print("stall-watch %s: no stalls" % hhmm(now))
    for s in stalls:
        print("\n".join(s.render(now)))
    for p in problems:
        print("  not read: " + p)
    return 1 if stalls else 0


def mode_notice(a):
    if not a.config:
        return 0
    th = thresholds()
    lines = [
        "=== STALL WATCH runs with this session (the CEO's build point: \"He never has to ask; every step and failure reaches him unprompted.\") ===",
        "  THE WATCHER STARTS BY ITSELF: the engine's plugin monitor `stall-watch` runs",
        "    %s --monitor" % a.command,
        "  for the whole session and looks every %.0f s for: a resource wait over %.0f min (proof-run slot, CPU admission," % (
            _env_float("STALL_WATCH_POLL_SECONDS", POLL_SECONDS), th["wait"] / 60),
        "  test VM, a device, any recorded wait); a live teammate with no commit AND no transcript write for %.0f min;" % (
            th["silent"] / 60),
        "  a teammate waiting %.0f min on a slot its own other process holds. Each stall reaches you ONCE as a" % (
            th["self"] / 60),
        "  notification naming the teammate, what it waits on, who holds it, since when and what you can do; again only",
        "  after another %.0f min; and in one line when it clears. It only reports: it never pauses, stops or kills." % (
            th["repeat"] / 60),
        "  Do not start it yourself. Check it (one line): %s --alive" % a.command,
        "  Only if --alive says NOT WATCHED (plugin monitors do not run here), start `%s --watch` as a background" % a.command,
        "  command; it exits at each notification, so start it again after each one.",
    ]
    print("\n".join(lines))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="stall-watch.sh")
    g = ap.add_mutually_exclusive_group(required=True)
    for flag in ("--monitor", "--watch", "--alive", "--once", "--notice", "--tick"):
        g.add_argument(flag, action="store_true")
    ap.add_argument("--config", default="")
    ap.add_argument("--engine-root", default="")
    ap.add_argument("--command", default="stall-watch.sh")
    a = ap.parse_args(argv)
    if a.notice:
        return mode_notice(a)
    if a.monitor and not a.config:
        return 0  # a repository that never adopted the engine: nothing to watch, and nothing said
    src = Sources(a.engine_root)
    if a.alive:
        return mode_alive(a, src)
    if a.once:
        return mode_once(a, src)
    if a.tick:
        sid, _spid = src.session()
        tick(src, session_dir(sid), sid)
        return 0
    return run_loop(a, src, exit_on_notice=a.watch)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
