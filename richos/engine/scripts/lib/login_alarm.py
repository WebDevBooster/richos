#!/usr/bin/env python3
"""login_alarm.py: the logic behind scripts/login-alarm.sh.

WHAT THIS IS FOR
================
CEO, 2026-09-26: "Fucking "login expired" fuckshit!" and "what must be done
about that "login expired" shitfuck?" His standing rule (ruling §90, point 6):
"He never has to ask; every step and failure reaches him unprompted."

At 09:26:11Z the lead session answered "Login expired · Please run /login"; at
09:30:44Z a teammate died mid-turn with the same error; the lead's next two
turns failed the same way. Nothing told him. He found it himself and ran
/login at 11:02Z, about 97 minutes later.

The one thing that cannot raise this alarm is a Claude session: when the login
is dead, every session's model calls fail, the orchestrator's included. So the
alarm is a plain program, run by launchd every LOGIN_ALARM_SECONDS, that needs
no model, no session and no network.

WHAT IT READS, AND WHAT IT NEVER READS
======================================
1. The transcripts Claude Code writes under ~/.claude/projects. Every session
   and every teammate records a failed turn there as an assistant row with
   `"error": "authentication_failed"` and the text it showed ("Login expired ·
   Please run /login"). Measured on 2026-09-26: the lead at 09:26:11.840Z and
   the teammate at 09:30:44.916Z both wrote that row. Only files changed since
   the previous scan are opened, and only their last TAIL_BYTES.
2. Reports handed to it with --report (the quota watcher's get_usage, or any
   check that knows it was refused for authentication).
3. The MODIFICATION TIME of the "Claude Code-credentials" keychain item, read
   with `security find-generic-password` WITHOUT -w or -g: attributes only.
   That item is rewritten by every /login and every successful renewal, and by
   Claude Code itself when it marks a refresh token dead (just BEFORE it shows
   the error). So an error that is NEWER than the item's last write means the
   login is still broken, and a write more than RENEW_MARGIN seconds after the
   error means it has been renewed.

It never reads, prints, copies or stores a credential or a token.

ONE ALARM PER EXPIRY, NEVER A LOOP
==================================
The first qualifying error opens an EPISODE: one macOS notification to the CEO
(the engine's CEO channel, as disk-watchdog.sh uses: osascript needs no app,
no session and no login), and one escalation row for the lead (state stopped,
for ceo) in the engine ledger that the lead's session reads at every session
start and every turn end, getting louder until acknowledged. Further errors in
the same episode add nothing. When the credential item is rewritten after the
error (his /login), the episode closes: an EscalationAck is appended saying so,
and the next failure is a new episode.

"Not logged in" is NOT this alarm: it is what a sandbox with no credential store
says (the engine's own suites produced six on 2026-09-10). His login dying says
"Login expired" or "OAuth token revoked".
"""

import argparse
import calendar
import fcntl
import getpass
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import escalations  # noqa: E402  (the engine's own ledger, one place)

SERVICE = "Claude Code-credentials"
TAIL_BYTES = 262144
FIRST_LOOKBACK = 900        # a first scan looks back 15 minutes, never at history
OVERLAP = 120               # rescans the last two minutes: a row appended late is not missed
RENEW_MARGIN = 5            # seconds: keychain times have one-second resolution
TEAMMATE = "login-alarm"

# Texts that mean HIS saved login is dead. Claude Code 2.1.283's own strings.
# Deliberately absent: "Not logged in" (a store with no credential at all, see
# the header) and "Authentication error · This may be a temporary network
# issue" (transient; Claude Code itself says to retry).
DEAD_LOGIN = ("Login expired", "OAuth token revoked", "OAuth session expired")


def now_epoch():
    v = os.environ.get("LOGIN_ALARM_NOW")
    return float(v) if v else time.time()


def projects_dir():
    return os.path.expanduser(os.environ.get("LOGIN_ALARM_PROJECTS_DIR")
                              or "~/.claude/projects")


def state_path():
    return os.path.expanduser(os.environ.get("LOGIN_ALARM_STATE")
                              or "~/.claude/state/login-alarm.json")


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def hhmm(epoch):
    return time.strftime("%H:%MZ", time.gmtime(epoch))


def parse_iso(s):
    if not isinstance(s, str) or len(s) < 19:
        return None
    try:
        base = calendar.timegm(time.strptime(s[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None
    frac = 0.0
    m = re.match(r"\.(\d+)", s[19:])
    if m:
        frac = float("0." + m.group(1))
    return base + frac


# ---------------------------------------------------------------------------
# the credential's last write: attributes only, never the value
# ---------------------------------------------------------------------------
def credential_written_at():
    """Epoch of the keychain item's last modification, or None if unknown.

    `find-generic-password` WITHOUT -w or -g prints the item's attributes and
    not its secret, so this needs no keychain permission and puts no token in
    this process. None means unknown, never "renewed"."""
    sec = os.environ.get("LOGIN_ALARM_SECURITY") or "/usr/bin/security"
    try:
        user = os.environ.get("USER") or getpass.getuser()
    except Exception:
        user = ""
    args = [sec, "find-generic-password", "-s", SERVICE]
    if user:
        args += ["-a", user]
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if r.returncode != 0:
        return None
    m = re.search(r'"mdat"<timedate>=\S*\s*"(\d{14})Z', r.stdout)
    if not m:
        return None
    try:
        return float(calendar.timegm(time.strptime(m.group(1), "%Y%m%d%H%M%S")))
    except ValueError:
        return None


# ---------------------------------------------------------------------------
# the transcripts
# ---------------------------------------------------------------------------
def _row_event(line, path):
    if "authentication_failed" not in line:
        return None
    try:
        row = json.loads(line)
    except ValueError:
        return None
    if not isinstance(row, dict) or row.get("type") != "assistant":
        return None
    if row.get("error") != "authentication_failed":
        return None
    text = ""
    content = (row.get("message") or {}).get("content")
    if isinstance(content, list) and content and isinstance(content[0], dict):
        text = str(content[0].get("text") or "")
    # Only a DEAD saved login. "Not logged in" (no store) and "Authentication
    # error · This may be a temporary network issue" are not in DEAD_LOGIN.
    if not any(p in text for p in DEAD_LOGIN):
        return None
    ts = parse_iso(row.get("timestamp"))
    if ts is None:
        return None
    return {"ts": ts, "text": text.splitlines()[0][:160], "source": "transcript",
            "where": path}


def scan_transcripts(since):
    """Every dead-login row written at or after `since` in a transcript that
    changed at or after `since`."""
    out = []
    root = projects_dir()
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(dirpath, name)
            try:
                st = os.stat(path)
            except OSError:
                continue
            if st.st_mtime < since:
                continue
            try:
                with open(path, "rb") as fh:
                    if st.st_size > TAIL_BYTES:
                        fh.seek(st.st_size - TAIL_BYTES)
                        fh.readline()  # a partial first line is dropped, not misread
                    data = fh.read()
            except OSError:
                continue
            for raw in data.decode("utf-8", "replace").splitlines():
                ev = _row_event(raw, path)
                if ev and ev["ts"] >= since:
                    out.append(ev)
    out.sort(key=lambda e: e["ts"])
    return out


# ---------------------------------------------------------------------------
# the two channels
# ---------------------------------------------------------------------------
NOTIFY_TITLE = "Claude login expired"


def notify_ceo(message):
    """A macOS notification with a sound. True if it was posted.

    LOGIN_ALARM_NOTIFY_CMD replaces osascript (the suites point it at a
    recorder; it is called with the title and the message as two arguments)."""
    cmd = os.environ.get("LOGIN_ALARM_NOTIFY_CMD")
    try:
        if cmd:
            r = subprocess.run([cmd, NOTIFY_TITLE, message], capture_output=True,
                               text=True, timeout=30)
        else:
            safe = message.replace('"', "'").replace("\\", "")
            script = ('display notification "%s" with title "%s" sound name "Basso"'
                      % (safe, NOTIFY_TITLE))
            r = subprocess.run(["osascript", "-e", script], capture_output=True,
                               text=True, timeout=30)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def raise_escalation(first, count):
    args = argparse.Namespace(
        title="Claude login expired at %s: no agent can make a model call until /login is run"
              % hhmm(first["ts"]),
        state="stopped",
        audience="ceo",
        question="The CEO runs /login in the Claude terminal. This alarm closes itself "
                 "when the login is renewed.",
        tried="Detected by login-alarm from %s: \"%s\" (%s). %d failure(s) so far."
              % (first["source"], first["text"], first.get("where") or "no file", count),
        meanwhile="",
        teammate=TEAMMATE, worktree="", branch="", repo="", head="", record="",
        session="")
    row = escalations.build_row(args)
    escalations.append_row(row)
    return row["id"]


def close_escalation(esc_id, renewed_at):
    if not esc_id:
        return
    rows, _bad = escalations.read_rows()
    if rows is None:
        return
    if esc_id not in [e["id"] for e in escalations.outstanding(rows)]:
        return
    escalations.append_row({
        "event": "EscalationAck",
        "id": esc_id,
        "acked": escalations.iso(escalations.utcnow()),
        "disposition": "The Claude login was renewed at %s (the credential was rewritten "
                       "after the failure); closed by login-alarm." % hhmm(renewed_at),
        "actor": TEAMMATE,
        "session_id": "",
    })


# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------
def read_state():
    try:
        with open(state_path(), encoding="utf-8") as fh:
            d = json.load(fh)
        return d if isinstance(d, dict) else {}
    except (OSError, ValueError):
        return {}


def write_state(d):
    p = state_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(d, fh, indent=1, sort_keys=True)
    os.replace(tmp, p)


# ---------------------------------------------------------------------------
# one tick
# ---------------------------------------------------------------------------
def tick(reports):
    now = now_epoch()
    lock_path = state_path() + ".lock"
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    with open(lock_path, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _tick_locked(now, reports)


def _tick_locked(now, reports):
    st = read_state()
    last = st.get("last_scan")
    since = (last - OVERLAP) if isinstance(last, (int, float)) else (now - FIRST_LOOKBACK)
    events = scan_transcripts(since) + list(reports)
    events.sort(key=lambda e: e["ts"])
    written = credential_written_at()
    lines = []
    episode = st.get("open")

    if episode:
        first_ts = episode.get("first_error", now)
        newer = [e for e in events if written is None or e["ts"] >= written - RENEW_MARGIN]
        if written is not None and written > first_ts + RENEW_MARGIN and not newer:
            close_escalation(episode.get("escalation"), written)
            episode["renewed_at"] = written
            st.setdefault("closed", []).append(episode)
            st["closed"] = st["closed"][-20:]
            st["open"] = None
            lines.append("LOGIN-RENEWED at %s: the episode opened at %s is closed"
                         % (iso(written), iso(first_ts)))
        else:
            # The overlap rescans rows already counted; only newer ones add.
            seen = episode.get("last_error", first_ts)
            fresh = [e for e in events if e["ts"] > seen]
            if fresh:
                episode["failures"] = episode.get("failures", 1) + len(fresh)
                episode["last_error"] = fresh[-1]["ts"]
            if not episode.get("notified"):
                # Posting failed last time (osascript refused): retried, never repeated.
                episode["notified"] = notify_ceo(episode.get("message", ""))
            if not episode.get("escalation"):
                # The ledger write failed when the episode opened: retried on each
                # tick until it lands, once (an id is then recorded), never repeated.
                try:
                    episode["escalation"] = raise_escalation(
                        {"ts": first_ts, "source": episode.get("source", "transcript"),
                         "text": episode.get("text", ""), "where": episode.get("where", "")},
                        episode["failures"])
                    lines.append("login-alarm: the escalation ledger recovered; "
                                 "escalation %s written" % episode["escalation"])
                except Exception as exc:
                    episode["escalation"] = ""
                    lines.append("login-alarm: COULD NOT WRITE THE ESCALATION LEDGER (%s)" % exc)
            lines.append("LOGIN-EXPIRED (already alarmed at %s): %d failure(s) in this episode"
                         % (iso(episode.get("alarmed_at", now)), episode["failures"]))
    else:
        live = [e for e in events if written is None or e["ts"] >= written - RENEW_MARGIN]
        if live:
            first = live[0]
            message = ("No Claude agent on this Mac can work since %s. "
                       "Run /login in the Claude terminal." % hhmm(first["ts"]))
            notified = notify_ceo(message)
            try:
                esc_id = raise_escalation(first, len(live))
            except Exception as exc:  # the notification still went; say the ledger did not
                esc_id = ""
                lines.append("login-alarm: COULD NOT WRITE THE ESCALATION LEDGER (%s)" % exc)
            st["open"] = {"first_error": first["ts"], "alarmed_at": now, "source": first["source"],
                          "text": first["text"], "where": first.get("where", ""),
                          "failures": len(live), "last_error": live[-1]["ts"],
                          "notified": notified, "message": message,
                          "escalation": esc_id}
            lines.append("LOGIN-EXPIRED at %s (%s: %s): CEO notified=%s, escalation %s, "
                         "%.1f s after the failure"
                         % (iso(first["ts"]), first["source"], first["text"],
                            "yes" if notified else "NO", esc_id or "NOT WRITTEN",
                            now - first["ts"]))
        elif events:
            lines.append("login-alarm: %d failure(s) predate the credential's last write at %s: "
                         "already renewed, no alarm" % (len(events), iso(written)))
    st["last_scan"] = now
    write_state(st)
    return lines


def status():
    st = read_state()
    ep = st.get("open")
    out = ["login-alarm state: %s" % state_path()]
    last = st.get("last_scan")
    out.append("  last scan : %s" % (iso(last) if isinstance(last, (int, float)) else "never"))
    if ep:
        out.append("  OPEN      : login failed at %s (%s), alarmed at %s, CEO notified: %s, "
                   "escalation %s"
                   % (iso(ep["first_error"]), ep.get("text", ""), iso(ep["alarmed_at"]),
                      "yes" if ep.get("notified") else "NO", ep.get("escalation") or "none"))
    else:
        out.append("  open      : none (the login has not failed since the last renewal)")
    for ep in (st.get("closed") or [])[-3:]:
        out.append("  closed    : failed %s, alarmed %s, renewed %s"
                   % (iso(ep["first_error"]), iso(ep["alarmed_at"]),
                      iso(ep["renewed_at"]) if ep.get("renewed_at") else "?"))
    return out


def main(argv):
    ap = argparse.ArgumentParser(prog="login-alarm.sh")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--source", default="report")
    ap.add_argument("--detail", default="")
    ap.add_argument("--status", action="store_true")
    a = ap.parse_args(argv)
    if a.status:
        print("\n".join(status()))
        return 0
    reports = []
    if a.report:
        text = (a.detail or "authentication failure").strip().splitlines()[0][:160]
        reports.append({"ts": now_epoch(), "text": text, "source": a.source, "where": ""})
    lines = tick(reports)
    for line in lines:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
