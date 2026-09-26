#!/usr/bin/env python3
"""quota_watch.py — the CEO's 93% quota rule, as one reusable reader and watcher.

HIS WORDS ARE THE WHOLE BEHAVIOR (ruling §87, richos-hq/wiki/ceo-decisions.md):

    "quota polling: every 5 minutes from now. And once it crosses the 93%
    threshold: PAUSE subagents. Then resume after quota rest."

HIS UPDATE, 2026-09-25 (ruling §87, and the boundary cases in
richos-hq/docs/plans/claude-five-hour-quota-rule-2026-09-25.md). At or above
the threshold, do NOT pause when the reset is LESS than 20 minutes away;
exactly 20 minutes still pauses. A hold already in place releases inside that
window, keeping the same agent. The same day he dropped the adaptive schedule
he had also given: "Well, I've changed my mind. Let's drop the 30-minute check
nonsense. Keep it consistent at 5 minutes." So polling is 300 s at every
usage level, and the stale bound stays one 300 s poll.

The five-hour policy below is retained. Weekly support is in quota_weekly.py:
all reported windows are printed; at 99% overall weekly use, the shared reset
service consumes a prior user approval or the lead receives the standard pause
message. Weekly holds release only after fresh weekly allowance and an allowing
five-hour verdict. The twenty-minute exception applies only to five-hour quota.

The original five-hour watcher READS the five-hour window,
it POLLS every 300 seconds, and it WAKES THE LEAD at the threshold, at the
hold's release (the reset less than 20 minutes away) and at the reset, with
the exact messages to send. The lead does the pausing and the resuming; this
file never messages, stops or spawns anything.

THE LAST 20 MINUTES, and how it matches the desktop app (Codex, branch
codex/claude-quota-settings, richos-core/src/quota.rs: RESET_EXEMPTION_MS and
its threshold_and_twenty_minute_boundaries test): the exception applies when
0 < resets_at - now < 1200 s. It applies to a stale reading too, because
resets_at does not move inside one window. A window that has ended is
UNKNOWN, as before, never "inside the exception".

PAUSE MESSAGES ARE NOT WRITTEN BY THE LEAD. scripts/lib/pause_protocol.py renders
the one standard message used here and by manual pauses. The terminal and desktop
SendMessage gates validate its complete text before delivery. The lead may not
append termination, cancellation, hand-in or restart instructions. The pause-until
line retains the existing registry binding; delivery is a request, not evidence
that execution is already held. No subagent implementation is changed here.

THE READING, FIRST: CLAUDE CODE'S OWN `get_usage` (2026-09-25). Each poll starts
`claude` as a CONTROL-ONLY connection and asks it for the account's usage,
exactly as the desktop app does (Codex, codex/claude-quota-settings at
c53f85c9, richos-core/src/quota/probe.rs; spec: richos-hq
docs/plans/desktop-claude-quota-settings-2026-09-25.md, "Data source and
process ownership"): stream-json in and out, no setting sources, no session
persistence, no tools, strict and empty MCP config, CLAUDECODE removed, an
`initialize` then a `get_usage` control request, each bounded at 20 s, frames
capped at 256 KiB. It never sends a user message, so it is not a model turn.
One difference, on purpose: the desktop keeps one connection open; this
watcher is a short-lived script with 5 minutes between polls, so it starts
the process in its own process group, captured at spawn, and ends that group
on every read. The working directory is `/`, which this user cannot write, so
a read cannot leave anything behind. Measured here on 2026-09-25 with claude
2.1.282: initialize 1.2 s, get_usage 7.2 s, five_hour answered, the only
message type on stdout `control_response`, nothing written to the working
directory and no transcript under ~/.claude/projects.

Why it is first: the status-line file below re-renders only when the lead
speaks, so an idle lead left the reading 10 minutes old at the 91%/95%
readings of 07:57Z and 08:07Z. get_usage is fresh at every poll. When it
fails (no `claude`, a timeout, an error, no subscription limits reported, or
an answer this file cannot read), the watcher says why and falls back to the
status-line file, where every rule below still applies, including waking the
lead to refresh it.

THE FALLBACK READING (design notes: richos-hq/docs/plans/budget-self-management-2026-09-10.md)
  ~/.claude/statusline-payload.json -> rate_limits.five_hour.used_percentage and
  .resets_at (epoch seconds). ~/.claude/statusline.sh copies the host's payload
  there on every status-line render (since 2026-09-10). Nothing else is read,
  and no credential is ever touched.

  R6 of the design notes: a reading that is missing, stale or unreadable is its
  OWN state and is never rounded to "plenty left". The file only refreshes when
  a status line renders, so its AGE is checked on EVERY poll.

  HOW THE RULE FAILED ON 2026-09-25, AND WHY STALE IS ONE POLL. The lead's own
  one-off watcher read five_hour stuck at 56% from 00:43Z to 01:08Z, at 71%
  from 01:13Z to 01:33Z and at 89% from 01:53Z to 02:13Z, then 100% at 02:18Z.
  The lead was idle waiting on teammates, its status line did not render, the
  payload did not refresh, and the 93% crossing was never seen. The threshold
  was right; the reading was old. So a reading older than ONE poll interval is
  UNKNOWN — never the current value — and the watcher wakes the lead with
  QUOTA-STALE, because the lead's own reply is what re-renders the status line
  (the host runs it when "a new assistant message arrives"). The replay of
  that log is quota-watch.test.sh case R01.

  WHAT ELSE REFRESHES IT, checked 2026-09-25: only ~/.claude/statusline.sh
  writes the file (grep over ~/.claude's scripts and settings, and this engine,
  which only reads it). The host runs that script at session start, on a new
  assistant message, after /compact, on a permission or vim mode change, when a
  rate-limit window's resets_at passes, and on an optional statusLine
  `refreshInterval` timer (code.claude.com/docs/en/statusline, "When it
  updates"; not set on this machine). Teammate activity is not on that list.
  A refreshInterval would re-render while the lead is idle, but whether the
  host's rate_limits figure moves with teammates' API responses is NOT
  verified, and a re-render that rewrites an old figure would make the file's
  age a false freshness signal. So nothing here depends on it.

  Within one window usage only grows, so a STALE reading at or above the
  threshold is still at or above it: it is reported as "at least", and the
  lead is woken to pause. A stale reading BELOW the threshold proves nothing
  and is UNKNOWN. A reading whose window has already ended describes a window
  that no longer exists and is UNKNOWN.

THE THRESHOLD is data, declared once: QUOTA_PAUSE_PERCENT in the entity's
orchestration.config, beside MODEL_CEILING. quota-watch.sh resolves the entity
and hands the raw value in; an undeclared or malformed value is UNKNOWN, never
a default, because a second place holding 93 is how the number drifts.

EXIT CODES
  --once    0 below the threshold, 1 at or above it (pause), 2 unknown,
            3 at or above it with the reset less than 20 minutes away (no
            pause; a hold in place releases)
  --status  the same codes as --once
  --watch   0 after printing one event (QUOTA-THRESHOLD, QUOTA-RELEASE,
            WINDOW-RESET, QUOTA-REFRESH, QUOTA-STALE or QUOTA-UNKNOWN), 2 when
            it cannot watch at all
  --notice  always 0 (it is a SessionStart hook's body)
"""

import argparse
import datetime as _dt
import importlib.util
import json
import math
import os
import selectors
import shutil
import signal
import subprocess
import sys
import time

# Shared with the terminal and desktop SendMessage delivery guards.
import pause_protocol
import quota_weekly

HIS_WORDS = ('"quota polling: every 5 minutes from now. And once it crosses the 93% '
             'threshold: PAUSE subagents. Then resume after quota rest."')
RULING = "ruling §87, richos-hq/wiki/ceo-decisions.md"
# His 2026-09-25 update, as the rule now stands. Not a quotation: the record
# of it is §87 and docs/plans/claude-five-hour-quota-rule-2026-09-25.md.
RULE_UPDATE = ("Updated 2026-09-25: at or above the threshold, do not pause when the reset is less than "
               "20 minutes away (exactly 20 minutes still pauses), and a hold already in place is released "
               "inside that window, keeping the same agent. Polling stays every 5 minutes at every usage level.")

# His "every 5 minutes". The environment override exists for the test suite
# only, which cannot wait five minutes per case.
POLL_SECONDS = 300
# A reading older than ONE poll interval is stale (see "HOW THE RULE FAILED"
# above): the stale bound IS the poll interval, set in main(). The test suite
# may override it separately, only so that its accelerated clock is not at the
# mercy of a one-second scheduler.

# His 2026-09-25 update: at or above the threshold, no pause when the reset is
# LESS than this far away; exactly this far still pauses. The same seconds
# release a hold already in place. The desktop app's RESET_EXEMPTION_MS.
RESET_EXEMPTION_SECONDS = 20 * 60

# WAKE THE LEAD BEFORE THE READING TURNS ONE POLL OLD (2026-09-25, measured).
# The lead read 91% at 07:57Z and 95% at 08:07Z: the pause fired at 95, not 93.
# A reading is current up to one poll (300 s) old, so a loop that polls every
# 300 s first saw it as stale at its SECOND poll, about 600 s after the render.
# With the lead idle, only the lead's reply re-renders the payload, so the
# effective refresh was every 10 minutes against his "Keep it consistent at 5
# minutes". Below the threshold, with a worker running, the watcher wakes the
# lead (QUOTA-REFRESH) this many seconds BEFORE the reading turns one poll old,
# and schedules its poll for that moment. A tenth of the bound when the bound
# is shorter (the suite's accelerated clock).
REFRESH_AHEAD_SECONDS = 30

# get_usage: one control request's bound (the desktop's DEADLINE) and the
# largest frame read (its MAX_FRAME). The environment override is for the test
# suite's hanging fixture only.
GET_USAGE_SECONDS = 20
MAX_FRAME = 256 * 1024
CONTROL_ARGS = ["--print", "--input-format=stream-json", "--output-format=stream-json", "--verbose",
                "--setting-sources", "", "--no-session-persistence", "--tools", "",
                "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']

PAUSE_UNTIL_PREFIX = "the five-hour quota reset"
CONFIG_KEY = "QUOTA_PAUSE_PERCENT"


def _env_int(name, default):
    v = (os.environ.get(name) or "").strip()
    if v.isdigit() and int(v) > 0:
        return int(v)
    return default


def default_payload_path():
    return (os.environ.get("QUOTA_PAYLOAD") or "").strip() or os.path.join(
        os.path.expanduser("~"), ".claude", "statusline-payload.json")


def hhmm(epoch):
    return _dt.datetime.fromtimestamp(epoch, _dt.timezone.utc).strftime("%H:%MZ")


def span(seconds):
    s = max(0, int(seconds))
    if s < 90:
        return "%d s" % s
    m = (s + 30) // 60
    if m < 120:
        return "%d min" % m
    return "%d h %02d min" % (m // 60, m % 60)


# ---------------------------------------------------------------------------
# the threshold
# ---------------------------------------------------------------------------

def parse_threshold(raw):
    """(value, problem). The raw string exactly as the config declares it."""
    raw = (raw or "").strip()
    if not raw:
        return None, "not declared"
    try:
        v = float(raw)
    except ValueError:
        return None, "%s=%r is not a number" % (CONFIG_KEY, raw)
    if not (0 < v <= 100):
        return None, "%s=%r is outside 1..100" % (CONFIG_KEY, raw)
    return v, ""


def fmt_pct(v):
    return ("%d" % v) if float(v).is_integer() else ("%g" % v)


# ---------------------------------------------------------------------------
# the reading
# ---------------------------------------------------------------------------

def read_reading(path, now):
    """One read of the payload. Never raises.

    The status line writes the file with `cp`, which is not atomic, so a read
    can land mid-write and see truncated JSON. One retry after a short pause
    separates that race from a file that is really malformed."""
    r = {"path": path, "state": "", "why": "", "used": None, "resets_at": None,
         "age": None, "ended": False}
    data = None
    for attempt in (0, 1):
        try:
            st = os.stat(path)
        except FileNotFoundError:
            r["state"], r["why"] = "missing", "no payload at %s (the status line has never written one)" % path
            return r
        except OSError as e:
            r["state"], r["why"] = "unreadable", "cannot read %s: %s" % (path, e)
            return r
        r["age"] = max(0.0, now - st.st_mtime)
        try:
            with open(path, "rb") as fh:
                data = json.loads(fh.read().decode("utf-8"))
            break
        except (ValueError, UnicodeDecodeError) as e:
            if attempt == 0:
                time.sleep(0.25)
                continue
            r["state"], r["why"] = "malformed", "%s is not valid JSON (%s)" % (path, e.__class__.__name__)
            return r
        except OSError as e:
            r["state"], r["why"] = "unreadable", "cannot read %s: %s" % (path, e)
            return r
    fh5 = None
    if isinstance(data, dict):
        rl = data.get("rate_limits")
        if isinstance(rl, dict):
            r["windows"] = quota_weekly.windows(rl, _parse_reset, fallback=True)
            fh5 = rl.get("five_hour")
    if not isinstance(fh5, dict):
        r["state"], r["why"] = "malformed", "%s carries no rate_limits.five_hour" % path
        return r
    used, resets = fh5.get("used_percentage"), fh5.get("resets_at")
    if isinstance(used, bool) or not isinstance(used, (int, float)) or used < 0:
        r["state"], r["why"] = "malformed", "rate_limits.five_hour.used_percentage is %r" % (used,)
        return r
    if isinstance(resets, bool) or not isinstance(resets, (int, float)) or resets <= 0:
        r["state"], r["why"] = "malformed", "rate_limits.five_hour.resets_at is %r" % (resets,)
        return r
    r["state"], r["used"], r["resets_at"] = "ok", used, int(resets)
    r["ended"] = int(resets) <= now
    return r


def claude_binary():
    """QUOTA_CLAUDE_BIN (tests point it at a fixture or at nothing), else
    `claude` on PATH."""
    return (os.environ.get("QUOTA_CLAUDE_BIN") or "").strip() or shutil.which("claude") or ""


def _parse_reset(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)) and v > 0:
        return int(v)
    if isinstance(v, str):
        try:
            d = _dt.datetime.fromisoformat(v.strip().replace("Z", "+00:00"))
        except ValueError:
            return None
        if d.tzinfo is None:
            return None
        return int(d.timestamp())
    return None


def read_get_usage(now, deadline_s=None):
    """One reading from Claude Code's get_usage control request. Never raises.
    The same shape as read_reading(), with source 'get_usage' and age 0."""
    r = {"path": "get_usage", "source": "get_usage", "state": "", "why": "", "used": None,
         "resets_at": None, "age": 0.0, "ended": False}
    b = claude_binary()
    if not b:
        r["state"], r["why"] = "failed", "no `claude` on PATH"
        return r
    deadline_s = deadline_s or _env_int("QUOTA_WATCH_GET_USAGE_SECONDS", GET_USAGE_SECONDS)
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    try:
        proc = subprocess.Popen([b] + CONTROL_ARGS, cwd="/", env=env, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        r["state"], r["why"] = "failed", "cannot start %s (%s)" % (b, e.__class__.__name__)
        return r
    buf = [b""]
    sel = selectors.DefaultSelector()

    def request(rid, subtype):
        proc.stdin.write((json.dumps({"type": "control_request", "request_id": rid,
                                      "request": {"subtype": subtype, "hooks": {}}}) + "\n").encode())
        proc.stdin.flush()
        until = time.time() + deadline_s
        while True:
            while b"\n" in buf[0]:
                line, buf[0] = buf[0].split(b"\n", 1)
                v = json.loads(line.decode("utf-8"))
                if (isinstance(v, dict) and v.get("type") == "control_response"
                        and isinstance(v.get("response"), dict) and v["response"].get("request_id") == rid):
                    return v["response"]
            if len(buf[0]) > MAX_FRAME:
                raise ValueError("a frame over %d bytes" % MAX_FRAME)
            left = until - time.time()
            if left <= 0 or not sel.select(timeout=left):
                raise TimeoutError("no answer to %s within %d s" % (subtype, deadline_s))
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                raise EOFError("claude closed its output before answering %s" % subtype)
            buf[0] += chunk

    try:
        sel.register(proc.stdout, selectors.EVENT_READ)
        init = request("quota-1", "initialize")
        if init.get("subtype") != "success":
            raise ValueError("initialize was refused")
        usage = request("quota-2", "get_usage")
    except (OSError, ValueError, TimeoutError, EOFError, UnicodeDecodeError) as e:
        r["state"], r["why"] = "failed", "get_usage failed: %s" % (str(e) or e.__class__.__name__)
        return r
    finally:
        # The process group is this call's own (start_new_session, pid captured
        # at spawn): end it on every read, whatever happened.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(proc.pid, sig)
            except (ProcessLookupError, PermissionError):
                break
            try:
                proc.wait(timeout=5)
                break
            except subprocess.TimeoutExpired:
                continue
        sel.close()
        for fh in (proc.stdin, proc.stdout):
            try:
                fh.close()
            except OSError:
                pass
    if usage.get("subtype") != "success":
        r["state"], r["why"] = "failed", "get_usage was refused"
        return r
    body = usage.get("response") if isinstance(usage.get("response"), dict) else {}
    if body.get("rate_limits_available") is False:
        r["state"], r["why"] = "failed", "Claude Code did not report subscription limits for this account"
        return r
    r["windows"] = quota_weekly.windows(body.get("rate_limits", {}), _parse_reset)
    five = (body.get("rate_limits") or {}).get("five_hour") if isinstance(body.get("rate_limits"), dict) else None
    used = five.get("utilization") if isinstance(five, dict) else None
    resets = _parse_reset(five.get("resets_at")) if isinstance(five, dict) else None
    if (body.get("rate_limits_available") is not True or isinstance(used, bool)
            or not isinstance(used, (int, float)) or not (0 <= used <= 100) or resets is None):
        r["state"], r["why"] = "failed", "get_usage answered in a shape this watcher cannot read"
        return r
    r["state"], r["used"], r["resets_at"] = "ok", used, resets
    r["ended"] = resets <= now
    return r


def read_source(a, now):
    """get_usage first; the status-line file when it fails, saying why."""
    g = read_get_usage(now)
    if g["state"] == "ok":
        return g
    f = read_reading(a.payload, now)
    f["source"] = "the status line"
    f["fallback_why"] = g["why"]
    if g.get("windows"):
        f["windows"] = g["windows"]
    return f


def classify(r, threshold, stale_after):
    """('below' | 'at-or-above' | 'unknown', why)."""
    if r["state"] != "ok":
        return "unknown", r["why"]
    if r["ended"]:
        return "unknown", "the reading is from a window that ended at %s" % hhmm(r["resets_at"])
    if r["used"] >= threshold:
        # Monotone within a window: a stale reading at or above is still true.
        return "at-or-above", ""
    if r["age"] is not None and r["age"] > stale_after:
        return "unknown", ("the reading is stale: %s old, and below the threshold a stale reading "
                           "proves nothing" % span(r["age"]))
    return "below", ""


def in_last_twenty(resets_at, now):
    """True when the reset is LESS than 20 minutes away and has not passed.
    Exactly 20 minutes is False: it still pauses (his words, 2026-09-25)."""
    return resets_at is not None and 0 < resets_at - now < RESET_EXEMPTION_SECONDS


def rule_verdict(r, threshold, stale_after, now):
    """classify(), with his near-reset exception applied:
    ('below' | 'at-or-above' | 'near-reset' | 'unknown', why)."""
    verdict, why = classify(r, threshold, stale_after)
    if verdict == "at-or-above" and in_last_twenty(r["resets_at"], now):
        return "near-reset", ("the reset is %s away, less than 20 minutes: no pause, and a hold in place is "
                              "released (%s)" % (span(r["resets_at"] - now), RULING))
    return verdict, why


def describe(r, threshold, now):
    if r["state"] != "ok":
        return "UNKNOWN: %s" % r["why"]
    bits = ["%s%% of the five-hour window" % fmt_pct(r["used"]),
            "threshold %s%%" % fmt_pct(threshold) if threshold is not None else "threshold UNDECLARED",
            "read %s ago" % span(r["age"] or 0) + (" via %s" % r["source"] if r.get("source") else "")]
    if r["ended"]:
        bits.append("window ended at %s" % hhmm(r["resets_at"]))
    else:
        bits.append("resets %s (in %s)" % (hhmm(r["resets_at"]), span(r["resets_at"] - now)))
    extra = quota_weekly.describe(r, now)
    return ", ".join(bits) + ("; " + extra if extra else "")


# ---------------------------------------------------------------------------
# the workers — read from the workspace registry, never written
# ---------------------------------------------------------------------------

def _load_registry(engine_root):
    lib = os.path.join(engine_root, "mega-lander", "workspaces.py")
    if not os.path.isfile(lib):
        return None, "the workspace registry library is missing at %s" % lib
    try:
        spec = importlib.util.spec_from_file_location("quota_watch_workspaces", lib)
        ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ws)
        return ws, ""
    except Exception as e:  # noqa: BLE001 — any failure is "cannot name them"
        return None, "the workspace registry could not be loaded (%s)" % e.__class__.__name__


def workers(engine_root):
    """{'known': bool, 'why', 'session', 'working': [names], 'quota_paused': [names],
    'other_paused': [names]} for THIS session's registered teammates.

    Read-only: finished_state() over the recorded facts. A record the platform
    ended without a hook (a stopped agent) may still read as working here; the
    registry's own pending() reconciles that, and this watcher never writes."""
    out = {"known": False, "why": "", "session": "", "working": [], "quota_paused": [], "weekly_paused": [], "other_paused": []}
    ws, why = _load_registry(engine_root)
    if ws is None:
        out["why"] = why
        return out
    try:
        me = ws.current_session()
        if not me:
            out["why"] = "this command is not running inside a recorded session"
            return out
        out["session"] = me
        for rec in ws.all_agents():
            if rec.get("session_id") != me or rec.get("disposition"):
                continue
            fin, paused, _why = ws.finished_state(rec)
            if fin:
                continue
            name = rec.get("name") or rec.get("key") or "?"
            if paused:
                until = ((rec.get("pause") or {}).get("until") or "")
                (out["quota_paused"] if until.startswith(PAUSE_UNTIL_PREFIX) else
                 out["weekly_paused"] if until.startswith("the weekly quota reset") else out["other_paused"]).append(name)
            else:
                out["working"].append(name)
        out["known"] = True
    except Exception as e:  # noqa: BLE001
        out["why"] = "the workspace registry could not be read (%s)" % e.__class__.__name__
    for k in ("working", "quota_paused", "weekly_paused", "other_paused"):
        out[k] = sorted(set(out[k]))
    return out


def worker_line(w):
    if not w["known"]:
        return "live workers: UNKNOWN (%s)" % w["why"]
    s = "live workers: %d working" % len(w["working"])
    if w["working"]:
        s += " (%s)" % ", ".join(w["working"])
    s += "; %d paused for the quota" % len(w["quota_paused"])
    if w["other_paused"]:
        s += "; %d paused for other reasons" % len(w["other_paused"])
    return s


# ---------------------------------------------------------------------------
# the two messages the lead sends
# ---------------------------------------------------------------------------

def pause_message(r, threshold):
    return pause_protocol.render("quota", hhmm(r["resets_at"]))


def resume_message(reset_at):
    # NEVER a `pause-until:` line: a message without one is what resumes a
    # paused agent in the registry.
    return ("RESUME: the five-hour quota window reset at %s. Continue exactly where you stopped."
            % hhmm(reset_at))


def release_message(reset_at):
    # His 2026-09-25 update: the hold releases when the reset is less than 20
    # minutes away. The same agent resumes, so, like the resume message, this
    # NEVER carries a `pause-until:` line.
    return ("RESUME: the five-hour quota window resets at %s, less than 20 minutes from now, so the quota "
            "hold is released (%s). Continue exactly where you stopped." % (hhmm(reset_at), RULING))


# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

def _exit_for(verdict):
    return {"below": 0, "at-or-above": 1, "near-reset": 3}.get(verdict, 2)


def mode_once(a, now):
    r = read_source(a, now)
    if a.threshold is None:
        print("quota: UNKNOWN: %s is %s in %s" % (CONFIG_KEY, a.threshold_problem, a.config or "(no config)"))
        return 2
    verdict, why = rule_verdict(r, a.threshold, a.stale, now)
    if quota_weekly.held(r, now):
        verdict, why = "at-or-above", "overall weekly usage reached 99%"
    line = describe(r, a.threshold, now)
    if verdict == "unknown" and r["state"] == "ok":
        line += "  [UNKNOWN: %s]" % why
    elif verdict == "at-or-above":
        line += "  [AT OR ABOVE THE THRESHOLD]"
    elif verdict == "near-reset":
        line += "  [AT OR ABOVE THE THRESHOLD, NO PAUSE: %s]" % why
    print("quota: " + line)
    if r.get("fallback_why"):
        print("quota: source: the status-line file, because %s" % r["fallback_why"])
    return _exit_for(verdict)


def mode_status(a, now):
    r = read_source(a, now)
    print("THE 93%% QUOTA RULE (%s)" % RULING)
    print("  his words : %s" % HIS_WORDS)
    print("  update    : %s" % RULE_UPDATE)
    if a.threshold is None:
        print("  threshold : UNKNOWN: %s is %s in %s" % (CONFIG_KEY, a.threshold_problem, a.config or "(no config)"))
    else:
        print("  threshold : %s%%  (%s=%s in %s)" % (fmt_pct(a.threshold), CONFIG_KEY, a.threshold_raw, a.config))
    if r.get("fallback_why"):
        print("  source    : the status-line file %s, because %s" % (a.payload, r["fallback_why"]))
    else:
        print("  source    : Claude Code's get_usage (%s), fresh at this read" % claude_binary())
    if r["state"] != "ok":
        print("  reading   : UNKNOWN: %s" % r["why"])
    else:
        print("  reading   : %s%% of the five-hour window" % fmt_pct(r["used"]))
        print("  age       : %s%s" % (span(r["age"] or 0), " (the payload refreshes only when a status line renders)"
                                       if r.get("fallback_why") else " (read at this poll)"))
        if r["ended"]:
            print("  window    : ENDED at %s; this reading describes a window that no longer exists"
                  % hhmm(r["resets_at"]))
        else:
            print("  resets    : %s, in %s" % (hhmm(r["resets_at"]), span(r["resets_at"] - now)))
    w = workers(a.engine_root)
    print("  windows   : " + quota_weekly.describe(r, now))
    print("  %s" % worker_line(w))
    if a.threshold is None:
        print("  verdict   : UNKNOWN")
        return 2
    verdict, why = rule_verdict(r, a.threshold, a.stale, now)
    if quota_weekly.held(r, now):
        verdict, why = "at-or-above", "overall weekly usage reached 99%"
    print("  verdict   : %s%s" % ({"below": "below the threshold", "at-or-above": "AT OR ABOVE the threshold",
                                    "near-reset": "AT OR ABOVE the threshold, NO PAUSE",
                                    "unknown": "UNKNOWN"}[verdict], (": " + why) if why and r["state"] == "ok" else ""))
    print("  watcher   : %s --watch   (as a background command)" % a.command)
    return _exit_for(verdict)


def _emit_threshold(a, r, now, w):
    print("QUOTA-THRESHOLD %s%%" % fmt_pct(r["used"]))
    print("  %s" % describe(r, a.threshold, now))
    if r["age"] is not None and r["age"] > a.stale:
        print("  The reading is stale, so this is a FLOOR: usage is at least %s%% now (it only grows inside a"
              " window)." % fmt_pct(r["used"]))
    print("  minutes to reset: %d" % max(0, (r["resets_at"] - now) // 60))
    print("  %s" % worker_line(w))
    print("  The CEO's rule (%s): %s" % (RULING, HIS_WORDS))
    if w["known"]:
        names = w["working"]
        print("  Send this message, unchanged, to each working agent: %s" % ", ".join(names))
    else:
        print("  Send this message, unchanged, to each working agent (the registry could not name them).")
    print("  ---- message begins ----")
    for ln in pause_message(r, a.threshold).splitlines():
        print("  " + ln)
    print("  ---- message ends ----")
    print("  Use summary: " + pause_protocol.SUMMARY)
    print("  Delivery is only a request. Check the actual hold before reporting anyone paused.")
    print("  Then start the watcher again; with nothing working it waits, and wakes you with the resume message")
    print("  when the reset is less than 20 minutes away (the hold releases there, %s):" % RULING)
    print("    %s --watch" % a.command)
    print("  If you keep them working this window, wake only at the reset instead:")
    print("    %s --watch --until-reset" % a.command)


def _emit_reset(a, reset_at, w):
    print("WINDOW-RESET at %s" % hhmm(reset_at))
    print("  The CEO's rule (%s): %s" % (RULING, HIS_WORDS))
    print("  %s" % worker_line(w))
    if w["known"]:
        if w["quota_paused"]:
            print("  Wake each quota-paused agent with this message: %s" % ", ".join(w["quota_paused"]))
        else:
            print("  No agent of this session is paused for the quota.")
        if w["other_paused"]:
            print("  Paused for OTHER reasons, not named in this rule's wake: %s" % ", ".join(w["other_paused"]))
    else:
        print("  The registry could not name the paused agents; wake every agent you paused for the quota.")
    print("  ---- message begins ----")
    print("  " + resume_message(reset_at))
    print("  ---- message ends ----")
    print("  Then start the watcher again:")
    print("    %s --watch" % a.command)


def _emit_release(a, reset_at, now, w):
    print("QUOTA-RELEASE at %s" % hhmm(now))
    print("  The five-hour window resets at %s, in %s: less than 20 minutes, so the quota hold releases."
          % (hhmm(reset_at), span(reset_at - now)))
    print("  The CEO's rule (%s): %s" % (RULING, HIS_WORDS))
    print("  %s" % RULE_UPDATE)
    print("  %s" % worker_line(w))
    if w["known"]:
        print("  Wake each quota-paused agent with this message: %s" % ", ".join(w["quota_paused"]))
        if w["other_paused"]:
            print("  Paused for OTHER reasons, not named in this rule's wake: %s" % ", ".join(w["other_paused"]))
    else:
        print("  The registry could not name the paused agents; wake every agent you paused for the quota.")
    print("  ---- message begins ----")
    print("  " + release_message(reset_at))
    print("  ---- message ends ----")
    print("  Then start the watcher again; inside the last 20 minutes it pauses nobody and wakes you at the reset:")
    print("    %s --watch" % a.command)


def refresh_point(stale_after):
    """The age at which a below-threshold reading is refreshed: before it turns
    one poll old, never at or after."""
    return stale_after - min(REFRESH_AHEAD_SECONDS, stale_after // 10)


def _emit_refresh(a, r, w, at):
    print("QUOTA-REFRESH: the reading is %d s old and stops counting as current at %d s (one poll); refresh it now"
          % (int(r["age"] or 0), a.stale))
    if r.get("fallback_why"):
        print("  The reading comes from the status-line file, because %s." % r["fallback_why"])
    print("  Last value: %s%%, below the threshold %s%%. The CEO's rule (%s) checks every 5 minutes, so the"
          % (fmt_pct(r["used"]), fmt_pct(a.threshold), RULING))
    print("  watcher wakes you at %d s, before the reading ages past one poll, not a poll after it." % at)
    print("  %s" % worker_line(w))
    print("  REFRESH THE READING: reply once, in this turn. The payload is rewritten only when your")
    print("  status line renders, and it renders when a new assistant message of yours arrives;")
    print("  teammates' work does not render it. Then start the watcher again:")
    print("    %s --watch" % a.command)


def mode_watch(a):
    if a.threshold is None:
        print("QUOTA-UNKNOWN: cannot watch: %s is %s in %s" % (CONFIG_KEY, a.threshold_problem, a.config or "(no config)"))
        return 2
    now = int(time.time())
    r = read_source(a, now)
    if r["state"] == "missing":
        print("QUOTA-UNKNOWN: cannot watch: %s" % r["why"])
        return 2
    window_end = None
    if r["state"] == "ok" and not r["ended"]:
        window_end = r["resets_at"]
    elif a.until_reset and r["state"] == "ok" and r["ended"]:
        # The reset this run was asked to wait for has already happened.
        # Check weekly holds before releasing an already-ended five-hour window.
        window_end = r["resets_at"]
    elif a.until_reset and not quota_weekly.held(r, now):
        print("QUOTA-UNKNOWN: cannot wait for the reset: %s" % r["why"])
        return 2
    blind_since = None
    refresh_in = None
    print("quota-watch: polling every %d s; threshold %s%%%s" % (
        a.poll, fmt_pct(a.threshold), "; waking only at the reset" if a.until_reset else ""), flush=True)
    while True:
        now = int(time.time())
        reset_status = quota_weekly.reset_tick(a.engine_root)
        r = read_source(a, now)
        w = workers(a.engine_root)
        weekly_blocked, weekly_event = quota_weekly.handle(a, r, now, w, reset_status,
            lambda: rule_verdict(r, a.threshold, a.stale, now)[0])
        if weekly_event:
            return 0
        if weekly_blocked:
            print(quota_weekly.describe(r, now), flush=True)
            time.sleep(a.poll)
            continue
        if window_end is not None and now >= window_end:
            _emit_reset(a, window_end, workers(a.engine_root))
            return 0
        if window_end is not None and in_last_twenty(window_end, now):
            # His 2026-09-25 update: a hold in place releases inside the last
            # 20 minutes. Only when somebody is held (or the registry cannot
            # say): with nobody held there is nothing to release.
            w = workers(a.engine_root)
            if not w["known"] or w["quota_paused"]:
                _emit_release(a, window_end, now, w)
                return 0
        if r.get("fallback_why"):
            print("  source: the status-line file, because %s" % r["fallback_why"], flush=True)
        if window_end is None and r["state"] == "ok" and not r["ended"]:
            window_end = r["resets_at"]
        verdict, why = rule_verdict(r, a.threshold, a.stale, now)
        print("%s  %s" % (_dt.datetime.fromtimestamp(now, _dt.timezone.utc).strftime("%H:%M:%SZ"),
                          describe(r, a.threshold, now) + ("  [UNKNOWN: %s]" % why if verdict == "unknown" and r["state"] == "ok" else "")),
              flush=True)
        if not a.until_reset:
            if verdict == "near-reset":
                print("  at or above the threshold, but %s" % why, flush=True)
            if verdict == "at-or-above":
                w = workers(a.engine_root)
                if w["known"] and not w["working"]:
                    print("  at the threshold with nothing working: nothing to pause; waiting for the reset", flush=True)
                else:
                    _emit_threshold(a, r, now, w)
                    return 0
            if verdict == "unknown":
                if blind_since is None:
                    blind_since = now
                # A STALE reading (older than one poll) is blind NOW: it is the
                # 2026-09-25 failure, and waiting another poll on it is how the
                # 93% crossing went unseen. Any other unknown (missing,
                # malformed, a window that has ended) counts from this
                # watcher's own clock, so a payload that has not yet
                # re-rendered after a reset gets one poll to do so.
                stale = r["state"] == "ok" and not r["ended"]
                if stale or now - blind_since >= a.stale:
                    w = workers(a.engine_root)
                    if w["known"] and not w["working"]:
                        print("  the reading is unknown but nothing is working: no spend it could hide", flush=True)
                    else:
                        if stale:
                            print("QUOTA-STALE: the reading is %s old (one poll is %d s), so the current value is UNKNOWN"
                                  % (span(r["age"] or 0), a.poll))
                            if r.get("fallback_why"):
                                print("  It came from the status-line file, because %s." % r["fallback_why"])
                            print("  Last value seen: %s%%. It is NOT the current value: usage has only grown since."
                                  % fmt_pct(r["used"]))
                        else:
                            print("QUOTA-UNKNOWN: %s" % (why or r["why"]))
                        print("  The watcher cannot tell whether the threshold was crossed.")
                        print("  %s" % worker_line(w))
                        print("  REFRESH THE READING: reply once, in this turn. The payload is rewritten only when your")
                        print("  status line renders, and it renders when a new assistant message of yours arrives;")
                        print("  teammates' work does not render it. Then start the watcher again:")
                        print("    %s --watch" % a.command)
                        return 0
            else:
                blind_since = None
            if verdict == "below" and r["age"] is not None and r.get("source") != "get_usage":
                at = refresh_point(a.stale)
                if r["age"] >= at:
                    w = workers(a.engine_root)
                    if w["known"] and not w["working"]:
                        print("  the reading is about to turn one poll old, but nothing is working: no refresh needed",
                              flush=True)
                    else:
                        _emit_refresh(a, r, w, at)
                        return 0
                else:
                    refresh_in = at - r["age"]
        sleep_for = a.poll
        if window_end is not None:
            sleep_for = max(1, min(a.poll, window_end - now))
            # Wake at the first second inside the last 20 minutes, where a
            # hold releases, rather than up to one poll late.
            to_release = window_end - now - (RESET_EXEMPTION_SECONDS - 1)
            if to_release > 0:
                sleep_for = max(1, min(sleep_for, to_release))
        if refresh_in is not None:
            # Poll again when the reading reaches the refresh point, not a full
            # poll later (the 07:57Z/08:07Z defect above).
            sleep_for = max(1, min(sleep_for, int(math.ceil(refresh_in))))
            refresh_in = None
        time.sleep(sleep_for)


def mode_notice(a, now):
    """The SessionStart notice body. Printed as plain text; the hook wraps it.
    Silent (prints nothing) only where the rule cannot apply at all: a
    repository that never adopted the engine has no orchestration.config, and
    engine-status.sh already announces the stand-down there."""
    if not a.config:
        return 0
    lines = ["=== THE 93%% QUOTA RULE applies to this session (%s) ===" % RULING,
             "  His words: %s" % HIS_WORDS,
             "  %s" % RULE_UPDATE]
    if a.threshold is None:
        lines.append("  THE WATCHER CANNOT RUN HERE: %s is %s in %s. Declare it there, e.g. %s=93."
                     % (CONFIG_KEY, a.threshold_problem, a.config or "(no orchestration.config)", CONFIG_KEY))
    else:
        r = read_reading(a.payload, now)
        verdict, why = rule_verdict(r, a.threshold, a.stale, now)
        lines.append("  Threshold: %s=%s (%s)" % (CONFIG_KEY, a.threshold_raw, a.config))
        now_line = describe(r, a.threshold, now)
        if verdict == "unknown" and r["state"] == "ok":
            now_line += " [UNKNOWN: %s]" % why
        elif verdict == "at-or-above":
            now_line += " [ALREADY AT OR ABOVE THE THRESHOLD]"
        elif verdict == "near-reset":
            now_line += " [AT OR ABOVE THE THRESHOLD, NO PAUSE: %s]" % why
        lines.append("  Now: %s" % now_line)
        lines.append("  Weekly: at 99% overall use, consume one eligible user-approved free reset or send the standard pause.")
        lines.append("  There is no weekly 20-minute exception. Resume only after fresh weekly allowance and the five-hour rule both permit work.")
        lines.append("  Only the user can approve through scripts/quota-reset.sh approve <offer-id>; you may read status or revoke, never approve.")
        lines.append("  Start the watcher now as a background command (Bash with run_in_background: true):")
        lines.append("    %s --watch" % a.command)
        lines.append("  Immediately, then every 5 minutes it reads Claude Code's own get_usage (the status-line file only as a fallback;")
        lines.append("  the reading above is that file, read without waiting on a process at session start).")
        lines.append("  For the five-hour rule it wakes you at the threshold with the pause message and the")
        lines.append("  names to send it to (never inside the last 20 minutes before the reset), when the reset is")
        lines.append("  less than 20 minutes away with the resume message and the paused names, and at the reset.")
    print("\n".join(lines))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="quota-watch.sh", add_help=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--once", action="store_true")
    g.add_argument("--watch", action="store_true")
    g.add_argument("--status", action="store_true")
    g.add_argument("--notice", action="store_true")
    ap.add_argument("--until-reset", action="store_true",
                    help="with --watch: wake only at the reset (the lead has decided this window)")
    ap.add_argument("--threshold-raw", default="")
    ap.add_argument("--config", default="")
    ap.add_argument("--engine-root", default="")
    ap.add_argument("--command", default="quota-watch.sh")
    a = ap.parse_args(argv)
    if a.until_reset and not a.watch:
        ap.error("--until-reset goes with --watch")
    a.payload = default_payload_path()
    a.poll = _env_int("QUOTA_WATCH_POLL_SECONDS", POLL_SECONDS)
    a.stale = _env_int("QUOTA_WATCH_STALE_SECONDS", a.poll)
    a.threshold_raw = (a.threshold_raw or "").strip()
    a.threshold, a.threshold_problem = parse_threshold(a.threshold_raw)
    a.engine_root = a.engine_root or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    now = int(time.time())
    # Test only: pins the clock for --once, --status and --notice, so the
    # 19/20/21-minute boundaries are exact to the second. --watch ignores it.
    pinned = (os.environ.get("QUOTA_WATCH_NOW") or "").strip()
    if pinned.isdigit():
        now = int(pinned)
    if a.once:
        return mode_once(a, now)
    if a.status:
        return mode_status(a, now)
    if a.notice:
        return mode_notice(a, now)
    return mode_watch(a)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
