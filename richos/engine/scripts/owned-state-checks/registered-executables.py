#!/usr/bin/env python3
"""registered-executables.py — IS EVERY SCRIPT SOMETHING IS CONFIGURED TO RUN
                               ACTUALLY RUNNABLE?

===========================================================================
THE DAY THIS EARNED ITS ROW
===========================================================================
2026-09-10, three times, in three different landings:

  guard-ci-red-lands.sh        committed 644. Wired in hooks.json, counted in
                               the denominator of the session banner, and it
                               loaded nothing. The banner read a confident
                               "60/62 guards".
  session-start-ci-surface.sh  the same, in the same commit.
  ci-surface-watch.sh          committed 644 as the entry point of a SCHEDULED
                               job, and every caller happened to route around
                               the bit — so it worked, until the one caller
                               that would not have.

None of them was red. None of them was reported. Every test that ran, ran. A
missing executable bit is invisible to everything that READS the file and fatal
to the one thing that RUNS it, which is exactly the shape this inventory exists
for: a state that is nobody's assignment to notice.

===========================================================================
WHAT IT READS, AND WHY ALL THREE
===========================================================================
  the plugin hook table   <engine>/hooks/hooks.json
  the seated hook table   <entity>/.claude/settings.local.json
  the scheduled jobs      launchd plists under ~/Library/LaunchAgents whose
                          program arguments point INTO the engine

The two hook tables are the two ways the host loads a hook, and this engine has
already shipped a hook present in one and absent from the other. The scheduled
jobs are here because the third instance above WAS a scheduled entry point, and
because a scheduled job is the only kind that runs with no session at all — the
kind whose failure nobody is in the room for.

Only paths that resolve through this engine's own placeholders, or that point
into the engine, are judged. The rest of the operator's machine is not this
check's business.

===========================================================================
EXIT CODES
===========================================================================
  0  every configured script exists and is executable
  1  at least one does not, each named with what is wrong with it
  2  UNKNOWN — no registration surface could be read at all. Never 0: a
     question that could not be asked and a clean answer must not look alike.
"""

import argparse
import glob
import json
import os
import plistlib
import subprocess
import sys

PLACEHOLDERS = ("${CLAUDE_PLUGIN_ROOT}", "$CLAUDE_PLUGIN_ROOT",
                "${CLAUDE_PROJECT_DIR}", "$CLAUDE_PROJECT_DIR")


def read_hook_table(path, where, root, paths):
    """Returns True if the surface was READ, whatever it contained.

    An empty-but-present table is a surface that was read and configures
    nothing; an unreadable one is a surface that was not read. Collapsing those
    two would let a corrupt hooks.json report a clean bill of health."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        return False
    for event, matchers in (doc.get("hooks") or {}).items():
        for m in matchers or []:
            for h in (m.get("hooks") or []):
                cmd = str(h.get("command", "") or "")
                for token in cmd.replace('"', " ").replace("'", " ").split():
                    for ph in PLACEHOLDERS:
                        if token.startswith(ph):
                            p = os.path.normpath(root + token[len(ph):])
                            paths.setdefault(p, set()).add("%s[%s]" % (where, event))
                            break
    return True


def read_launchd(engine, paths):
    read = 0
    for plist in sorted(glob.glob(os.path.expanduser("~/Library/LaunchAgents/*.plist"))):
        try:
            with open(plist, "rb") as fh:
                doc = plistlib.load(fh)
        except Exception:
            continue
        args = doc.get("ProgramArguments") or []
        if not args and doc.get("Program"):
            args = [doc["Program"]]
        hit = False
        for a in args:
            a = str(a)
            if a.startswith("/") and (a.startswith(engine + os.sep)
                                      or "/engine/scripts/" in a):
                paths.setdefault(os.path.normpath(a), set()).add(
                    "launchd:" + os.path.basename(plist))
                hit = True
        if hit:
            read += 1
    return read


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--entity", default="")
    ap.add_argument("--engine", default=os.path.normpath(os.path.join(here, "..", "..")))
    ap.add_argument("--launch-agents", default=None,
                    help="override the scheduled-job directory (tests point this at a sandbox)")
    args = ap.parse_args(argv)

    engine = os.path.abspath(args.engine)
    entity = args.entity
    if not entity:
        try:
            entity = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                    check=True).stdout.decode().strip()
        except Exception:
            entity = os.getcwd()
    entity = os.path.abspath(entity)

    paths = {}
    surfaces = 0
    if read_hook_table(os.path.join(engine, "hooks", "hooks.json"), "hooks.json",
                       engine, paths):
        surfaces += 1
    if read_hook_table(os.path.join(entity, ".claude", "settings.local.json"),
                       "settings.local.json", entity, paths):
        surfaces += 1
    if args.launch_agents is None:
        surfaces += read_launchd(engine, paths)
    else:
        for plist in sorted(glob.glob(os.path.join(args.launch_agents, "*.plist"))):
            try:
                with open(plist, "rb") as fh:
                    doc = plistlib.load(fh)
            except Exception:
                continue
            for a in (doc.get("ProgramArguments") or []):
                a = str(a)
                if a.startswith("/"):
                    paths.setdefault(os.path.normpath(a), set()).add(
                        "launchd:" + os.path.basename(plist))
                    surfaces += 1

    if surfaces == 0:
        sys.stderr.write(
            "UNKNOWN: no registration surface could be read (looked for "
            "%s/hooks/hooks.json and %s/.claude/settings.local.json)\n"
            % (engine, entity))
        return 2

    bad = 0
    for p in sorted(paths):
        where = ", ".join(sorted(paths[p]))
        if not os.path.exists(p):
            print("MISSING      %s — configured by %s, and it is not on disk" % (p, where))
            bad += 1
        elif not os.access(p, os.X_OK):
            print("NOT RUNNABLE %s — configured by %s, and it carries no executable "
                  "bit. It is counted, it is loaded, and it runs nothing." % (p, where))
            bad += 1

    if not bad:
        print("all %d configured script(s) across %d surface(s) exist and are executable"
              % (len(paths), surfaces))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
