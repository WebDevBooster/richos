#!/usr/bin/env python3
"""quota_watch.py — the CEO's 93% quota rule, as one reusable reader and watcher.

HIS WORDS ARE THE WHOLE BEHAVIOR (ruling §87, richos-hq/wiki/ceo-decisions.md):

    "quota polling: every 5 minutes from now. And once it crosses the 93%
    threshold: PAUSE subagents. Then resume after quota rest."

So this file does three things and no fourth: it READS the five-hour window,
it POLLS every 300 seconds, and it WAKES THE LEAD at the threshold and at the
reset with the exact messages to send. The lead does the pausing and the
resuming; this file never messages, stops or spawns anything.

What "pause" means is his too, confirmed on 2026-09-10 (session d0eef867,
09:28Z): commit what you have, then hold — end your turn, do nothing further,
wait to be messaged. The same agent keeps its context and its workspace, and
the lead's message at the reset wakes it. The workspace registry
(mega-lander/workspaces.py, point 11) already records exactly that state, and
the trigger is a `pause-until:` line in the lead's message. On 2026-09-18 the
three hold messages carried no such line, so each SubagentStop recorded a
FINISHED agent, and the wake at 15:09Z was refused. The pause message printed
below carries the line, and quota-watch.test.sh proves it end to end.

THE READING (design notes: richos-hq/docs/plans/budget-self-management-2026-09-10.md)
  ~/.claude/statusline-payload.json -> rate_limits.five_hour.used_percentage and
  .resets_at (epoch seconds). ~/.claude/statusline.sh copies the host's payload
  there on every status-line render (since 2026-09-10). Nothing else is read,
  and no credential is ever touched.

  R6 of the design notes: a reading that is missing, stale or unreadable is its
  OWN state and is never rounded to "plenty left". The file only refreshes when
  a status line renders, so its AGE is always printed. Measured over the 149
  samples in ~/.claude/state/quota-samples.jsonl (2026-09-10): median payload
  age 282 s, p90 1495 s, max 3103 s. Staleness is therefore normal, which is
  why it is reported rather than hidden, and why a stale reading only wakes the
  lead when there is a worker whose spend it could be hiding.

  Within one window usage only grows, so a STALE reading at or above the
  threshold is still at or above it. A stale reading BELOW the threshold proves
  nothing and is UNKNOWN. A reading whose window has already ended describes a
  window that no longer exists and is UNKNOWN.

THE THRESHOLD is data, declared once: QUOTA_PAUSE_PERCENT in the entity's
orchestration.config, beside MODEL_CEILING. quota-watch.sh resolves the entity
and hands the raw value in; an undeclared or malformed value is UNKNOWN, never
a default, because a second place holding 93 is how the number drifts.

EXIT CODES
  --once    0 below the threshold, 1 at or above it, 2 unknown
  --status  the same codes as --once
  --watch   0 after printing one event (QUOTA-THRESHOLD, WINDOW-RESET or
            QUOTA-UNKNOWN), 2 when it cannot watch at all
  --notice  always 0 (it is a SessionStart hook's body)
"""

import argparse
import datetime as _dt
import importlib.util
import json
import os
import sys
import time

HIS_WORDS = ('"quota polling: every 5 minutes from now. And once it crosses the 93% '
             'threshold: PAUSE subagents. Then resume after quota rest."')
RULING = "ruling §87, richos-hq/wiki/ceo-decisions.md"

# His "every 5 minutes". The environment override exists for the test suite
# only, which cannot wait five minutes per case.
POLL_SECONDS = 300
# A reading older than three polls is stale. Three, not one: the 2026-09-10
# samples put the median age at 282 s, so one poll would call half of all
# healthy readings stale and the word would stop meaning anything.
STALE_SECONDS = 900

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


def describe(r, threshold, now):
    if r["state"] != "ok":
        return "UNKNOWN: %s" % r["why"]
    bits = ["%s%% of the five-hour window" % fmt_pct(r["used"]),
            "threshold %s%%" % fmt_pct(threshold) if threshold is not None else "threshold UNDECLARED",
            "read %s ago" % span(r["age"] or 0)]
    if r["ended"]:
        bits.append("window ended at %s" % hhmm(r["resets_at"]))
    else:
        bits.append("resets %s (in %s)" % (hhmm(r["resets_at"]), span(r["resets_at"] - now)))
    return ", ".join(bits)


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
    out = {"known": False, "why": "", "session": "", "working": [], "quota_paused": [], "other_paused": []}
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
                (out["quota_paused"] if until.startswith(PAUSE_UNTIL_PREFIX) else out["other_paused"]).append(name)
            else:
                out["working"].append(name)
        out["known"] = True
    except Exception as e:  # noqa: BLE001
        out["why"] = "the workspace registry could not be read (%s)" % e.__class__.__name__
    for k in ("working", "quota_paused", "other_paused"):
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

def pause_until_line(resets_at):
    return "pause-until: %s at %s" % (PAUSE_UNTIL_PREFIX, hhmm(resets_at))


def pause_message(r, threshold):
    return "\n".join([
        "PAUSE: the CEO's quota rule (%s), in his words: %s" % (RULING, HIS_WORDS),
        "The five-hour window is at %s%% (threshold %s%%) and resets at %s."
        % (fmt_pct(r["used"]), fmt_pct(threshold), hhmm(r["resets_at"])),
        "Commit what you have, then hold: end your turn, do nothing further, and wait to be messaged.",
        "Do not hand off and do not mark your task complete: a hand-in finishes you, and a finished "
        "agent cannot be woken. Your context and your workspace stay exactly as they are.",
        pause_until_line(r["resets_at"]),
    ])


def resume_message(reset_at):
    # NEVER a `pause-until:` line: a message without one is what resumes a
    # paused agent in the registry.
    return ("RESUME: the five-hour quota window reset at %s. Continue exactly where you stopped."
            % hhmm(reset_at))


# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

def _exit_for(verdict):
    return {"below": 0, "at-or-above": 1}.get(verdict, 2)


def mode_once(a, now):
    r = read_reading(a.payload, now)
    if a.threshold is None:
        print("quota: UNKNOWN: %s is %s in %s" % (CONFIG_KEY, a.threshold_problem, a.config or "(no config)"))
        return 2
    verdict, why = classify(r, a.threshold, a.stale)
    line = describe(r, a.threshold, now)
    if verdict == "unknown" and r["state"] == "ok":
        line += "  [UNKNOWN: %s]" % why
    elif verdict == "at-or-above":
        line += "  [AT OR ABOVE THE THRESHOLD]"
    print("quota: " + line)
    return _exit_for(verdict)


def mode_status(a, now):
    r = read_reading(a.payload, now)
    print("THE 93%% QUOTA RULE (%s)" % RULING)
    print("  his words : %s" % HIS_WORDS)
    if a.threshold is None:
        print("  threshold : UNKNOWN: %s is %s in %s" % (CONFIG_KEY, a.threshold_problem, a.config or "(no config)"))
    else:
        print("  threshold : %s%%  (%s=%s in %s)" % (fmt_pct(a.threshold), CONFIG_KEY, a.threshold_raw, a.config))
    print("  payload   : %s" % a.payload)
    if r["state"] != "ok":
        print("  reading   : UNKNOWN: %s" % r["why"])
    else:
        print("  reading   : %s%% of the five-hour window" % fmt_pct(r["used"]))
        print("  age       : %s (the payload refreshes only when a status line renders)" % span(r["age"] or 0))
        if r["ended"]:
            print("  window    : ENDED at %s; this reading describes a window that no longer exists"
                  % hhmm(r["resets_at"]))
        else:
            print("  resets    : %s, in %s" % (hhmm(r["resets_at"]), span(r["resets_at"] - now)))
    w = workers(a.engine_root)
    print("  %s" % worker_line(w))
    if a.threshold is None:
        print("  verdict   : UNKNOWN")
        return 2
    verdict, why = classify(r, a.threshold, a.stale)
    print("  verdict   : %s%s" % ({"below": "below the threshold", "at-or-above": "AT OR ABOVE the threshold",
                                    "unknown": "UNKNOWN"}[verdict], (": " + why) if why and r["state"] == "ok" else ""))
    print("  watcher   : %s --watch   (as a background command)" % a.command)
    return _exit_for(verdict)


def _emit_threshold(a, r, now, w):
    print("QUOTA-THRESHOLD %s%%" % fmt_pct(r["used"]))
    print("  %s" % describe(r, a.threshold, now))
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
    print("  The last line is what records the PAUSE (mega-lander point 11): without it the agent's end of")
    print("  run is recorded as FINISHED and the wake at the reset is refused (2026-09-18).")
    print("  Then start the watcher again; with nothing working it waits for the reset and wakes you there:")
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


def mode_watch(a):
    if a.threshold is None:
        print("QUOTA-UNKNOWN: cannot watch: %s is %s in %s" % (CONFIG_KEY, a.threshold_problem, a.config or "(no config)"))
        return 2
    now = int(time.time())
    r = read_reading(a.payload, now)
    if r["state"] == "missing":
        print("QUOTA-UNKNOWN: cannot watch: %s" % r["why"])
        return 2
    window_end = None
    if r["state"] == "ok" and not r["ended"]:
        window_end = r["resets_at"]
    elif a.until_reset and r["state"] == "ok" and r["ended"]:
        # The reset this run was asked to wait for has already happened.
        _emit_reset(a, r["resets_at"], workers(a.engine_root))
        return 0
    elif a.until_reset:
        print("QUOTA-UNKNOWN: cannot wait for the reset: %s" % r["why"])
        return 2
    blind_since = None
    print("quota-watch: polling every %d s; threshold %s%%%s" % (
        a.poll, fmt_pct(a.threshold), "; waking only at the reset" if a.until_reset else ""), flush=True)
    while True:
        now = int(time.time())
        if window_end is not None and now >= window_end:
            _emit_reset(a, window_end, workers(a.engine_root))
            return 0
        r = read_reading(a.payload, now)
        if window_end is None and r["state"] == "ok" and not r["ended"]:
            window_end = r["resets_at"]
        verdict, why = classify(r, a.threshold, a.stale)
        print("%s  %s" % (_dt.datetime.fromtimestamp(now, _dt.timezone.utc).strftime("%H:%M:%SZ"),
                          describe(r, a.threshold, now) + ("  [UNKNOWN: %s]" % why if verdict == "unknown" and r["state"] == "ok" else "")),
              flush=True)
        if not a.until_reset:
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
                # A STALE reading has been blind for its whole age already. Any
                # other unknown (missing, malformed, a window that has ended)
                # counts from this watcher's own clock, so a payload that has
                # not yet re-rendered after a reset gets three polls to do so.
                stale_age = int(r["age"] or 0) if (r["state"] == "ok" and not r["ended"]) else 0
                blind = max(now - blind_since, stale_age)
                if blind >= a.stale:
                    w = workers(a.engine_root)
                    if w["known"] and not w["working"]:
                        print("  the reading is unknown but nothing is working: no spend it could hide", flush=True)
                    else:
                        print("QUOTA-UNKNOWN: %s" % (why or r["why"]))
                        print("  The watcher is blind and cannot tell whether the threshold was crossed.")
                        print("  %s" % worker_line(w))
                        print("  Your own next turn refreshes the payload (the status line renders); then start the")
                        print("  watcher again:  %s --watch" % a.command)
                        return 0
            else:
                blind_since = None
        sleep_for = a.poll
        if window_end is not None:
            sleep_for = max(1, min(a.poll, window_end - now))
        time.sleep(sleep_for)


def mode_notice(a, now):
    """The SessionStart notice body. Printed as plain text; the hook wraps it.
    Silent (prints nothing) only where the rule cannot apply at all: a
    repository that never adopted the engine has no orchestration.config, and
    engine-status.sh already announces the stand-down there."""
    if not a.config:
        return 0
    lines = ["=== THE 93%% QUOTA RULE applies to this session (%s) ===" % RULING,
             "  His words: %s" % HIS_WORDS]
    if a.threshold is None:
        lines.append("  THE WATCHER CANNOT RUN HERE: %s is %s in %s. Declare it there, e.g. %s=93."
                     % (CONFIG_KEY, a.threshold_problem, a.config or "(no orchestration.config)", CONFIG_KEY))
    else:
        r = read_reading(a.payload, now)
        verdict, why = classify(r, a.threshold, a.stale)
        lines.append("  Threshold: %s=%s (%s)" % (CONFIG_KEY, a.threshold_raw, a.config))
        now_line = describe(r, a.threshold, now)
        if verdict == "unknown" and r["state"] == "ok":
            now_line += " [UNKNOWN: %s]" % why
        elif verdict == "at-or-above":
            now_line += " [ALREADY AT OR ABOVE THE THRESHOLD]"
        lines.append("  Now: %s" % now_line)
        lines.append("  Start the watcher as a background command (Bash with run_in_background: true):")
        lines.append("    %s --watch" % a.command)
        lines.append("  It polls every 5 minutes and wakes you at the threshold with the pause message and the")
        lines.append("  names to send it to, and at the reset with the resume message and the names to wake.")
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
    a.stale = _env_int("QUOTA_WATCH_STALE_SECONDS", STALE_SECONDS)
    a.threshold_raw = (a.threshold_raw or "").strip()
    a.threshold, a.threshold_problem = parse_threshold(a.threshold_raw)
    a.engine_root = a.engine_root or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    now = int(time.time())
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
