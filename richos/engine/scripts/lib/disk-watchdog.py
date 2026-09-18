#!/usr/bin/env python3
"""disk-watchdog.py — the reading, the arithmetic, the alert and the notification.

Invoked by scripts/disk-watchdog.sh, which sources orchestration.config first so
every threshold arrives in the environment already declared. The header on that
file carries the reasoning; this one carries the mechanism.

WHY ONE PROGRAM AND NOT A PIPELINE OF SHELL STEPS: the state file is a
read-modify-write. It holds the previous reading (which the drop arithmetic
subtracts from) and the time each notification level was last sent (which makes
"once a day" possible for a job that has no memory between runs). Split across
processes, two overlapping launchd ticks would each read the file before the
other wrote it, and the CEO would be notified twice for one event.
"""

import json
import os
import subprocess
import sys
import time

GB = 1024 ** 3


def env(name, default=""):
    v = (os.environ.get(name) or "").strip()
    return v if v else default


def env_num(name, default):
    v = env(name, "")
    if not v:
        return default
    try:
        return float(v)
    except ValueError:
        return default


def expand(p):
    return os.path.expanduser(os.path.expandvars(p))


# ---------------------------------------------------------------------------
# reading a volume
# ---------------------------------------------------------------------------

def read_volume(mount):
    """(capacity_bytes, free_bytes) or None if it is not mounted.

    os.statvfs, not `df`: one syscall, no parsing, no locale, and no subprocess
    on a job that runs every 15 minutes. f_bavail rather than f_bfree, because
    f_bfree includes blocks reserved for root that nothing else can use — the
    number that matters is the one an ordinary write can reach.

    A VOLUME THAT IS NOT MOUNTED IS None AND NEVER ZERO. An unplugged external
    disk reporting 0 bytes free would be an instant, permanent, false alarm.
    """
    try:
        st = os.statvfs(mount)
    except OSError:
        return None
    return st.f_frsize * st.f_blocks, st.f_frsize * st.f_bavail


# ---------------------------------------------------------------------------
# attribution — only ever when an alert is firing
# ---------------------------------------------------------------------------

def top_consumers(candidates, limit=3):
    """The biggest declared candidate directories, largest first.

    MEASURED ONLY WHEN AN ALERT IS FIRING, which is what makes it affordable at
    all: `du` over these paths costs real I/O and this job runs every quarter
    hour. The cheap check (statvfs) always runs; this runs when there is
    something to explain.

    A DECLARED CANDIDATE LIST, not a walk of the volume. Walking 460 GB to find
    the top three would take minutes and would be the single most expensive
    thing on the machine at the exact moment the machine is in trouble.
    """
    out = []
    for path in candidates:
        path = expand(path)
        if not path or not os.path.isdir(path):
            continue
        try:
            r = subprocess.run(["du", "-sk", path], capture_output=True,
                               text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired):
            continue
        first = (r.stdout or "").split("\n")[0].split("\t")
        if not first or not first[0].strip().isdigit():
            continue
        out.append((int(first[0].strip()) * 1024, path))
    out.sort(reverse=True)
    return out[:limit]


def richos_garbage_bytes():
    """How much of the shortfall is OUR OWN scratch.

    CEO addendum 2: the watchdog should never bark because RichOS failed to clean
    up after itself, so an alert has to say whether that is what happened. This
    is the number that decides between "RichOS garbage (DEFECT)" and "other".

    Counted from the allocator root and the claude scratch roots only — the two
    places whose entire contents are, by construction, ours. The legacy $TMPDIR
    families are deliberately NOT counted: their names are shared with fixtures
    this program does not own, and a classification that overstated our share
    would send somebody hunting a defect in RichOS for a disk filled by Xcode.
    """
    total = 0
    roots = []
    tmp = os.environ.get("TMPDIR") or "/tmp"
    roots.append(os.path.join(os.path.realpath(tmp),
                              env("SCRATCH_ROOT_NAME", "richos-scratch")))
    uid = str(os.getuid())
    for r in env("SCRATCH_CLAUDE_ROOTS", "").split():
        roots.append(r.replace("%u", uid))
    seen = set()
    for root in roots:
        real = os.path.realpath(root)
        if real in seen or not os.path.isdir(real):
            continue
        seen.add(real)
        try:
            r = subprocess.run(["du", "-sk", real], capture_output=True,
                               text=True, timeout=120)
        except (OSError, subprocess.TimeoutExpired):
            continue
        first = (r.stdout or "").split("\n")[0].split("\t")
        if first and first[0].strip().isdigit():
            total += int(first[0].strip()) * 1024
    return total


# ---------------------------------------------------------------------------
# the CEO's channel
# ---------------------------------------------------------------------------

def notify_ceo(title, message):
    """A macOS user notification. True if it was posted.

    osascript `display notification` NEEDS NO APP AND NO SESSION, which is the
    entire reason it is the channel: this fires from launchd with nobody logged
    into anything and no RichOS window open. A notification that required the
    app to be running would be absent exactly on the night the disk fills.

    Quotes are stripped rather than escaped. The text is assembled here from
    numbers and paths, so there is nothing to preserve, and AppleScript string
    escaping is a place to introduce a bug rather than a feature to support.
    """
    safe_t = title.replace('"', "'").replace("\\", "")
    safe_m = message.replace('"', "'").replace("\\", "")
    script = ('display notification "%s" with title "%s"' % (safe_m, safe_t))
    try:
        r = subprocess.run(["osascript", "-e", script],
                           capture_output=True, text=True, timeout=30)
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return ("%d %s" % (int(n), unit)) if unit == "B" else ("%.1f %s" % (n, unit))
        n /= 1024.0
    return str(n)


# ---------------------------------------------------------------------------
# state
# ---------------------------------------------------------------------------

def read_state(path):
    try:
        with open(path, encoding="utf-8") as fh:
            obj = json.load(fh)
        return obj if isinstance(obj, dict) else {}
    except (OSError, ValueError):
        return {}


def write_state(path, obj):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=1, sort_keys=True)
        os.replace(tmp, path)          # atomic: a reader never sees half a file
    except OSError as exc:
        sys.stderr.write("disk-watchdog: could not write %s: %s\n" % (path, exc))


def log(path, line):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


# ---------------------------------------------------------------------------
# the run
# ---------------------------------------------------------------------------

def main():
    mode = env("MODE", "check")
    state_path = expand(env("STATE", "~/.claude/state/disk-watchdog.json"))
    log_path = expand(env("LOG", "~/.claude/state/disk-watchdog.log"))

    primary = env("DISK_PRIMARY_VOLUME", "/System/Volumes/Data")
    extras = env("DISK_EXTRA_VOLUMES", "").split()
    rich_gb = env_num("DISK_RICH_ALERT_GB", 60)
    drop_gb = env_num("DISK_DROP_ALERT_GB", 20)
    ceo_gb = env_num("DISK_CEO_NOTIFY_GB", 50)
    urgent_gb = env_num("DISK_CEO_URGENT_GB", 25)
    repeat_h = env_num("DISK_CEO_REPEAT_HOURS", 24)
    scale = env("DISK_SCALE_EXTRA_VOLUMES", "1") == "1"
    candidates = env("DISK_CONSUMER_CANDIDATES", "").split()

    prev = read_state(state_path)
    now = time.time()
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now))

    pv = read_volume(primary)
    if pv is None:
        sys.stderr.write("disk-watchdog: cannot read %s\n" % primary)
        return 2
    p_cap, _p_free = pv

    volumes = []
    for mount in [primary] + extras:
        v = read_volume(mount)
        if v is None:
            continue                # not mounted: skipped, never zero
        cap, free = v
        if mount == primary or not scale:
            t_rich, t_ceo, t_urgent = rich_gb, ceo_gb, urgent_gb
        else:
            # SCALED BY CAPACITY. 25 GB free on a 954 GB disk is a much more
            # urgent situation than 25 GB on a 460 GB one, so the FRACTION is
            # what carries over, not the absolute number. The arithmetic is
            # written out in orchestration.config.
            factor = (cap / float(p_cap)) if p_cap else 1.0
            t_rich, t_ceo, t_urgent = (rich_gb * factor, ceo_gb * factor,
                                       urgent_gb * factor)
        volumes.append({
            "mount": mount,
            "capacity_bytes": cap,
            "free_bytes": free,
            "free_gb": round(free / float(GB), 1),
            "capacity_gb": round(cap / float(GB), 1),
            "percent_free": round(100.0 * free / cap, 1) if cap else 0.0,
            "rich_alert_gb": round(t_rich, 1),
            "ceo_notify_gb": round(t_ceo, 1),
            "ceo_urgent_gb": round(t_urgent, 1),
            "below_rich": free < t_rich * GB,
            "below_ceo": free < t_ceo * GB,
            "below_urgent": free < t_urgent * GB,
        })

    # --- the drop, per volume, against the previous reading -----------------
    prev_vols = {v.get("mount"): v for v in (prev.get("volumes") or [])
                 if isinstance(v, dict)}
    for v in volumes:
        old = prev_vols.get(v["mount"]) or {}
        old_free = old.get("free_bytes")
        v["previous_free_bytes"] = old_free
        if isinstance(old_free, (int, float)) and old_free > 0:
            v["drop_bytes"] = int(old_free - v["free_bytes"])
        else:
            # NO PREVIOUS READING IS NOT A DROP OF THE WHOLE DISK. The very
            # first run of this job, and the first run after the state file is
            # removed, must not alert on an imaginary fall from zero.
            v["drop_bytes"] = 0
        v["drop_alert"] = v["drop_bytes"] >= drop_gb * GB

    # --- the sweeper's standing failures, which are Rich's business too ------
    # Addendum 1: the alert covers "every sweep failure" as well as the space
    # thresholds. Read from the sweeper's own state file rather than by running
    # it: this job must never depend on the sweeper, only observe it.
    fails_path = expand(env("SCRATCH_FAILURES_STATE",
                            "~/.claude/state/scratch-failures.json"))
    sweep_failures = read_state(fails_path)
    n_fail = len(sweep_failures) if isinstance(sweep_failures, dict) else 0

    # --- test instances that would not close (§54 addendum 4) ---------------
    # CEO: "Test app windows must always close/quit when testing is finished.
    # Same hygiene as with any other garbage." So an instance that survived a
    # quit request, a SIGTERM and a SIGKILL is a failed clean-up and belongs in
    # this alert beside an undeletable directory.
    #
    # A SEPARATE FILE FROM THE SWEEPER'S, and deliberately so: rows there are
    # keyed by path and resolved when the path stops existing, which would
    # resolve a pid-keyed row on its very next read and clear the alert while
    # the window was still on his screen. This file's rows resolve when the
    # PROCESS is gone. Read, never run -- the same rule as above.
    inst_path = expand(env("APP_INSTANCE_FAILURES_STATE",
                           "~/.claude/state/app-instance-failures.json"))
    inst_failures = read_state(inst_path)
    n_inst = len(inst_failures) if isinstance(inst_failures, dict) else 0

    alerting = [v for v in volumes if v["below_rich"] or v["drop_alert"]]
    condition = bool(alerting) or n_fail > 0 or n_inst > 0

    # --- attribution and classification, ONLY when something is wrong -------
    consumers, classification, garbage = [], "", 0
    if condition and mode in ("check", "status"):
        consumers = [{"path": p, "bytes": b, "human": human(b)}
                     for b, p in top_consumers(candidates)]
        garbage = richos_garbage_bytes()
        worst = min((v["free_bytes"] for v in volumes), default=0)
        # "RichOS garbage (DEFECT)" when our own scratch is a material part of
        # what is missing. The comparison is against the SHORTFALL rather than
        # against the disk: 5 GB of our scratch on a disk 200 GB short is not
        # our defect, and the same 5 GB on a disk 6 GB short is.
        shortfall = max(rich_gb * GB - worst, 1)
        classification = ("RichOS garbage (DEFECT)"
                          if garbage >= 0.25 * shortfall else "other")
    elif condition:
        classification = prev.get("classification") or "other"
        garbage = prev.get("richos_garbage_bytes") or 0
        consumers = prev.get("top_consumers") or []

    notified = dict(prev.get("notified") or {})

    # --- the CEO's notifications, at most once a day per level ---------------
    posted = []
    if mode == "check":
        for v in volumes:
            for level, flag in (("urgent", v["below_urgent"]),
                                ("notify", v["below_ceo"])):
                if not flag:
                    continue
                key = "%s:%s" % (v["mount"], level)
                last = notified.get(key) or 0
                if now - last < repeat_h * 3600:
                    continue
                top = ", ".join("%s %s" % (c["human"], os.path.basename(c["path"]) or c["path"])
                                for c in consumers[:3]) or "not measured"
                title = ("RichOS: disk space CRITICAL" if level == "urgent"
                         else "RichOS: disk space low")
                msg = ("%s free on %s (%.0f%%). Top: %s. %s"
                       % (human(v["free_bytes"]), v["mount"],
                          v["percent_free"], top, classification))
                if notify_ceo(title, msg):
                    notified[key] = now
                    posted.append(key)
                    log(log_path, "%s NOTIFIED ceo level=%s mount=%s free=%s "
                                  "class=%s" % (stamp, level, v["mount"],
                                                human(v["free_bytes"]),
                                                classification))
                else:
                    log(log_path, "%s NOTIFY-FAILED ceo level=%s mount=%s "
                                  "(osascript would not post)"
                                  % (stamp, level, v["mount"]))
                # ONLY THE MOST SEVERE LEVEL PER VOLUME PER RUN. Below 25 GB
                # both levels are true, and sending both would be two
                # notifications for one event.
                break

    # --- Rich's alert block -------------------------------------------------
    lines = []
    if condition:
        lines.append("=" * 72)
        lines.append("  MASSIVE ALERT — DISK SPACE")
        lines.append("=" * 72)
        for v in alerting:
            why = []
            if v["below_rich"]:
                why.append("below the declared %.0f GB floor" % v["rich_alert_gb"])
            if v["drop_alert"]:
                why.append("DROPPED %s since the last reading"
                           % human(v["drop_bytes"]))
            lines.append("  %s — %s FREE of %s (%.1f%%): %s"
                         % (v["mount"], human(v["free_bytes"]),
                            human(v["capacity_bytes"]), v["percent_free"],
                            "; ".join(why)))
        if n_fail > 0:
            lines.append("")
            lines.append("  %d GARBAGE PATH(S) COULD NOT BE DELETED. The CEO's rule:"
                         % n_fail)
            lines.append("  if the clean-up fails, Rich deletes it BY HAND.")
            for path, row in sorted(sweep_failures.items())[:5]:
                if not isinstance(row, dict):
                    continue
                lines.append("    %s" % path)
                lines.append("      first seen %s, %s attempt(s), %s"
                             % (row.get("first", "?"), row.get("attempts", "?"),
                                str(row.get("error", "?"))[:90]))
        if n_inst > 0:
            lines.append("")
            lines.append("  %d TEST APP INSTANCE(S) WOULD NOT CLOSE. The CEO's rule"
                         % n_inst)
            lines.append("  (§54 addendum 4): a test app window is garbage when the")
            lines.append("  test is over. Rich ends these BY HAND:")
            for key, row in sorted(inst_failures.items())[:5]:
                if not isinstance(row, dict):
                    continue
                pid = row.get("pid", key)
                lines.append("    kill -9 %s" % pid)
                lines.append("      %s" % str(row.get("argv", "?"))[:90])
                lines.append("      first seen %s, %s attempt(s), %s"
                             % (row.get("first", "?"), row.get("attempts", "?"),
                                str(row.get("why", "?"))[:90]))
        if consumers:
            lines.append("")
            lines.append("  BIGGEST MEASURED CONSUMERS:")
            for c in consumers:
                lines.append("    %-10s %s" % (c["human"], c["path"]))
        if classification:
            lines.append("")
            lines.append("  CLASSIFICATION: %s" % classification)
            if classification.startswith("RichOS"):
                lines.append("  RichOS's own scratch is %s of this. THE APP IS"
                             % human(garbage))
                lines.append("  SUPPOSED TO CLEAN THIS UP ITSELF — the CEO's words:")
                lines.append("  \"the disk watchdog will NEVER bark because the RichOS")
                lines.append("  app failed to clean up its garbage\". So this is a DEFECT")
                lines.append("  REPORT, not a disk warning.")
        lines.append("")
        lines.append("  WHAT TO DO:")
        lines.append("    scripts/scratch-sweep.sh          reclaim what nothing owns")
        lines.append("    scripts/disk-watchdog.sh --status a reading per volume")
        if n_fail > 0:
            lines.append("    then delete the paths above BY HAND")
        lines.append("=" * 72)

    # --- THE WATCHMAN'S OWN ABSENCE, which is an alert of its own ------------
    # A watchdog that was never scheduled, or whose timer somebody removed,
    # looks EXACTLY like a disk that never gets low. This is the only condition
    # here that cannot be detected by the job itself — it is detected by whoever
    # asks for the alert block, which is the session hook.
    plist = os.path.join(expand(env("RICHOS_LAUNCH_AGENTS_DIR",
                                    "~/Library/LaunchAgents")),
                         "com.richos.disk-watchdog.plist")
    installed = os.path.isfile(plist)
    if mode == "alert" and not installed:
        lines = (["=" * 72,
                  "  MASSIVE ALERT — THE DISK WATCHDOG IS NOT INSTALLED",
                  "=" * 72,
                  "  Nothing is watching this machine's free space. A watchdog that",
                  "  was never scheduled looks exactly like a disk that never gets",
                  "  low, which is why its absence is itself an alert.",
                  "",
                  "  Install it FROM THE MAIN CHECKOUT:",
                  "    scripts/disk-watchdog.sh --install",
                  "=" * 72] + lines)

    stale = False
    last_reading = prev.get("reading_epoch") or 0
    if mode == "alert" and installed and last_reading:
        # A timer that is installed but has not fired for many intervals is
        # suppressed in all but name — launchd will not run a job whose plist
        # is loaded but disabled. Ten intervals is generous enough that a closed
        # laptop does not produce a false alarm.
        interval = env_num("DISK_WATCHDOG_MINUTES", 15) * 60
        if now - last_reading > interval * 10:
            stale = True
            lines = (["=" * 72,
                      "  MASSIVE ALERT — THE DISK WATCHDOG HAS STOPPED REPORTING",
                      "=" * 72,
                      "  Its timer is installed but its last reading is %d minutes old"
                      % int((now - last_reading) / 60),
                      "  and the declared interval is %d minutes. A loaded-but-disabled"
                      % int(interval / 60),
                      "  launchd job fires on time, every time, and executes nothing.",
                      "",
                      "    launchctl list | grep com.richos.disk-watchdog",
                      "    scripts/disk-watchdog.sh --install",
                      "=" * 72] + lines)

    out = {
        "reading": stamp,
        "reading_epoch": int(now),
        "volumes": volumes,
        "alerting": bool(condition),
        "classification": classification,
        "richos_garbage_bytes": garbage,
        "top_consumers": consumers,
        "sweep_failures": n_fail,
        "test_instance_failures": n_inst,
        "notified": notified,
        "timer_installed": installed,
        "thresholds": {
            "rich_alert_gb": rich_gb, "drop_alert_gb": drop_gb,
            "ceo_notify_gb": ceo_gb, "ceo_urgent_gb": urgent_gb,
            "ceo_repeat_hours": repeat_h,
            "interval_minutes": env_num("DISK_WATCHDOG_MINUTES", 15),
        },
    }

    # THE STATE FILE IS WRITTEN ONLY BY A READING. `--alert` and `--json` are
    # consumers and must never move the previous reading forward: a turn end
    # that overwrote it would destroy the baseline the drop arithmetic subtracts
    # from, and the 15-minute rate alarm would silently become a
    # per-turn-end one.
    if mode == "check":
        write_state(state_path, out)
        log(log_path, "%s reading %s" % (stamp, " ".join(
            "%s=%s free" % (v["mount"], human(v["free_bytes"])) for v in volumes)))
        if posted:
            log(log_path, "%s posted=%s" % (stamp, ",".join(posted)))

    if mode == "json":
        json.dump(out, sys.stdout, indent=1, sort_keys=True)
        sys.stdout.write("\n")
    elif mode == "alert":
        if lines:
            sys.stdout.write("\n".join(lines) + "\n")
    elif mode == "status":
        for v in volumes:
            flag = "ALERT" if (v["below_rich"] or v["drop_alert"]) else "ok   "
            sys.stdout.write("%s  %-26s %9s free of %9s (%5.1f%%)  floor %.0f GB\n"
                             % (flag, v["mount"], human(v["free_bytes"]),
                                human(v["capacity_bytes"]), v["percent_free"],
                                v["rich_alert_gb"]))
        if n_fail:
            sys.stdout.write("ALERT  %d garbage path(s) could not be deleted\n"
                             % n_fail)
        if not installed:
            sys.stdout.write("ALERT  the launchd timer is NOT installed\n")
    elif mode == "check":
        for v in volumes:
            sys.stdout.write("%s: %s free of %s (%.1f%%)\n"
                             % (v["mount"], human(v["free_bytes"]),
                                human(v["capacity_bytes"]), v["percent_free"]))
        if lines:
            sys.stdout.write("\n".join(lines) + "\n")

    # THE EXIT CODE AGREES WITH WHAT WAS PRINTED, on every mode. The first
    # version returned 0 from --status while printing
    # "ALERT the launchd timer is NOT installed", which is the shape of failure
    # that teaches a caller to ignore exit codes.
    if condition or stale:
        return 1
    if not installed and mode in ("alert", "status"):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
