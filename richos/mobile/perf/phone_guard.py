#!/usr/bin/env python3
"""phone_guard.py — stands in front of adb and xcrun for an automatic phone speed run, and refuses
anything that would take the app or its saved data off a phone.

WHY (CEO rule, 2026-10-01, given again on 2026-10-02): the Android phone is NOT a dedicated test
device. Never wipe or reinstall the app on it; an automatic run must never uninstall the app or
clear its data, on either phone; install only over the existing build with its data kept
(`adb install -r`). If a run would need an uninstall, it must refuse and report to Rich. The iPhone
is a dedicated test device whose app and helper are never uninstalled or wiped either (each
reinstall costs the CEO a Touch ID approval). On 2026-10-02 at 00:40Z a measurement uninstalled the
Android app and put back an older debug build with nothing saved; no check ran.

watch.py writes two one-line wrappers, `adb` and `xcrun`, into the run's own directory, puts that
directory first on PATH and hands the `adb` one to perf.py as `--adb`, so every tool the run starts
reaches a phone only through this file. It refuses:

  adb     `uninstall`; `install`, `install-multiple` or `install-multi-package` without `-r`;
          a `shell` or `exec-out` command that runs `pm uninstall`, `pm clear`,
          `cmd package uninstall` or `cmd package clear`
  xcrun   `devicectl ... uninstall`

A refusal prints `PHONE GUARD REFUSED: <what>` on stderr, exits 97 and TRIPS the run: the trip file
($RICHOS_PHONE_GUARD_TRIP) records the refused command, and every later adb or xcrun call of the same
run is refused too. A tool that ignores a failed uninstall (perf.py's seeding does, check=False) and
goes on to install or write the app's files is therefore stopped before it changes anything. The
watcher reads the trip file and reports the run as REFUSED to Rich, naming the command.

Everything else is passed to the real tool unchanged ($RICHOS_PHONE_GUARD_REAL_ADB,
$RICHOS_PHONE_GUARD_REAL_XCRUN), with its exit status.
"""
import os
import re
import sys

REFUSED_EXIT = 97
DESTRUCTIVE_SHELL = re.compile(r"\b(?:pm\s+(?:uninstall|clear)|cmd\s+package\s+(?:uninstall|clear))\b")
INSTALLS = ("install", "install-multiple", "install-multi-package")
# adb's global options that take a value (adb --help, platform-tools 35/36).
ADB_VALUE_OPTIONS = ("-s", "-t", "-H", "-P", "-L")


def adb_subcommand(args):
    """(subcommand, its arguments) after adb's global options."""
    i = 0
    while i < len(args):
        a = args[i]
        if a in ADB_VALUE_OPTIONS:
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        return a, args[i + 1:]
    return "", []


def adb_refusal(args):
    sub, rest = adb_subcommand(args)
    if sub == "uninstall":
        return "adb uninstall (the CEO's rule: never uninstall the app or clear its data)"
    if sub in INSTALLS and "-r" not in rest:
        return f"adb {sub} without -r (only an install over the existing build, data kept, is allowed)"
    if sub in ("shell", "exec-out") and DESTRUCTIVE_SHELL.search(" ".join(rest)):
        return f"adb {sub} {' '.join(rest)[:120]} (uninstalls the app or clears its data)"
    return None


def xcrun_refusal(args):
    if "devicectl" in args and "uninstall" in args:
        return f"xcrun {' '.join(args)[:120]} (the iPhone's app and helper are never uninstalled)"
    return None


def main(argv):
    if len(argv) < 1 or argv[0] not in ("adb", "xcrun"):
        print("usage: phone_guard.py adb|xcrun ARGS...", file=sys.stderr)
        return 2
    tool, args = argv[0], argv[1:]
    trip = os.environ.get("RICHOS_PHONE_GUARD_TRIP", "")
    real = os.environ.get("RICHOS_PHONE_GUARD_REAL_" + tool.upper(), "")
    if not trip or not real:
        print(f"PHONE GUARD REFUSED: {tool}: RICHOS_PHONE_GUARD_TRIP and RICHOS_PHONE_GUARD_REAL_{tool.upper()} "
              "must be set (the guard never guesses which tool it guards)", file=sys.stderr)
        return REFUSED_EXIT
    if os.path.exists(trip):
        with open(trip) as f:
            first = f.readline().strip()
        print(f"PHONE GUARD REFUSED: {tool} {' '.join(args)[:120]}: this run was already stopped by: {first}",
              file=sys.stderr)
        return REFUSED_EXIT
    why = adb_refusal(args) if tool == "adb" else xcrun_refusal(args)
    if why:
        with open(trip, "a") as f:
            f.write(why + "\n")
        print(f"PHONE GUARD REFUSED: {why}", file=sys.stderr)
        return REFUSED_EXIT
    os.execv(real, [real, *args])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
