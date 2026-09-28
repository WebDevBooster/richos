#!/usr/bin/env python3
"""import-setup.py: the one-time import of the owner's own setup into his daily-driver RichOS.

    import-setup.py [--home DIR] [--record DIR] [--name "Full Name"] [--company NAME]
                    [--team-folder DIR] [--roster RELPATH] [--go]

Without --go it only READS: it prints what it would bring over, what it checks and what it
leaves alone, and changes nothing. With --go it takes a backup of everything it is about to
change, makes the change, then reads everything back and says whether the result is right.
Run it twice and the second run finds nothing to do and writes nothing, not even a backup.

The spec is richos-hq `docs/plans/two-installs-and-import-spec-2026-09-17.md` Part B (points
12-16), as corrected by `docs/plans/2026-09-24-daily-driver-readiness.md` §6 step 7 for the
owner's §86 choice ("your setup as-is"): nothing of his memory is converted or copied,
because his team's lead reads it where it is.

WHAT IT BRINGS OVER (writes, each backed up first)
  1. His name, into the install's `config.json` `user_name` (and `company_name` when
     --company is given). Every other key in the file is kept exactly as it was.
  2. The memory pointer, `~/Library/Application Support/RichOS/loro-root`, a link to his
     record repository. Already there on his Mac today (spec point 15); here it is made
     deliberate and verified rather than assumed.

WHAT IT CHECKS (reads only)
  3. Nothing outranks that pointer: the resolver's candidate 3 is not a usable corpus
     (spec point 16), launchd hands a double-clicked app no LORO_CORPUS / LORO_ROOT, and
     the resolver, mirrored here, lands on his record.
  4. The roster page is in the record (readiness §6 step 4), so "who is Frank?" has an
     answer (acceptance check 35).
  5. His memory index is where his team's lead reads it, in place.
  6. Whether his team is switched on in this install (`operator.json`). Reported, never
     written: the operator declaration has its own enable script, run from his terminal.

It refuses to write while this install's app is running, because the app rewrites the whole
`config.json` on every settings change (`config.rs` `ConfigStore::persist`) and would put
the old name back. "Running" is read from the app's own launch record, `launches.json`
`open_run`, whose token is the app's process id (`main.rs` `begin_run`), never from a
process name.

The way back is the backup (spec point 13): `<data>/import-backups/<UTC time>/` holds the
files as they were and a `manifest.json` that says what each change was and how to undo it.
There is deliberately no undo command.

Exit status: 0 plan printed with every check passing, or import done and verified;
1 a check failed or a write was refused; 2 usage error.
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys

APP_ID = "com.richos.app"
CONFIG_SCHEMA_VERSION = 1  # richos-core config.rs CONFIG_SCHEMA_VERSION
DEFAULT_ROSTER = "wiki/team-roster.md"


# ---------------------------------------------------------------------------------------
# Paths, all derived from one home
# ---------------------------------------------------------------------------------------

class Paths:
    def __init__(self, home):
        self.home = home
        support = os.path.join(home, "Library", "Application Support")
        self.data = os.path.join(support, APP_ID)
        self.config = os.path.join(self.data, "config.json")
        self.launches = os.path.join(self.data, "launches.json")
        self.operator = os.path.join(self.data, "operator.json")
        self.backups = os.path.join(self.data, "import-backups")
        self.richos_support = os.path.join(support, "RichOS")
        self.candidate3 = os.path.join(self.richos_support, "corpus")
        self.loro_root = os.path.join(self.richos_support, "loro-root")
        self.candidate5 = os.path.join(home, "RichOS", "corpus")


# ---------------------------------------------------------------------------------------
# The resolver, mirrored (richos-core loro.rs resolve_corpus, candidates 3-5)
# ---------------------------------------------------------------------------------------

def corpus_shaped(d):
    """loro.rs provisioned_corpus_looks_valid: `ceo/` and `companies/`."""
    return os.path.isdir(os.path.join(d, "ceo")) and os.path.isdir(os.path.join(d, "companies"))


def record_shaped(d):
    """loro.rs repo_root_looks_valid: `wiki/` and `loro/`."""
    return os.path.isdir(os.path.join(d, "wiki")) and os.path.isdir(os.path.join(d, "loro"))


def resolve_memory(p):
    """What a double-clicked app resolves, with no LORO_* in its environment.

    Same order and same validity rule as `resolve_corpus`: the first VALID candidate wins,
    and a present-but-invalid one is passed over.
    """
    for path, label, valid in (
        (p.candidate3, "the corpus pointer in Application Support", corpus_shaped),
        (p.loro_root, "the loro-root pointer in Application Support", record_shaped),
        (p.candidate5, "~/RichOS/corpus", corpus_shaped),
    ):
        if valid(path):
            return path, label
    return None, None


# ---------------------------------------------------------------------------------------
# Small readers
# ---------------------------------------------------------------------------------------

def same_place(a, b):
    try:
        return os.path.realpath(a) == os.path.realpath(b)
    except OSError:
        return False


def read_json_object(path):
    """(object, None) | (None, reason). An absent file is ({}, None)."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return {}, None
    except OSError as e:
        return None, "cannot be read (%s)" % e.strerror
    try:
        value = json.loads(text)
    except ValueError as e:
        # Line and column only: this file holds his name, and a parser message quotes values.
        return None, "is not readable JSON (line %d, column %d)" % (e.lineno, e.colno)
    if not isinstance(value, dict):
        return None, "is not a JSON object"
    return value, None


def app_running(p):
    """(running, sentence). From the app's own launch record, never a process name."""
    record, why = read_json_object(p.launches)
    if record is None:
        return True, "its launch record %s, so whether it is running is unknown" % why
    run = record.get("open_run")
    if not run:
        return False, "not running (its launch record has no open run)"
    token = str(run.get("token", "")) if isinstance(run, dict) else ""
    if not token.isdigit():
        return True, "its launch record has an open run with no process id, so it may be running"
    pid = int(token)
    try:
        # Signal 0 delivers nothing: it asks only whether the process the app recorded exists.
        os.kill(pid, 0)
    except ProcessLookupError:
        return False, "not running (process %d, from its last run, is gone; that run did not quit cleanly)" % pid
    except PermissionError:
        return True, "running as process %d" % pid
    return True, "running as process %d" % pid


def launchd_memory_overrides():
    """Names launchd would hand a double-clicked app that take the resolver over (loro.rs 1-2)."""
    launchctl = os.environ.get("RICHOS_IMPORT_LAUNCHCTL", "/bin/launchctl")
    found = []
    for name in ("LORO_CORPUS", "LORO_ROOT"):
        try:
            out = subprocess.run([launchctl, "getenv", name], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return None
        if out.stdout.strip():
            found.append(name)
    return found


def claude_project_dir_name(folder):
    """Claude Code's per-project directory name: every character outside [A-Za-z0-9] is `-`."""
    return re.sub(r"[^A-Za-z0-9]", "-", folder)


# ---------------------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------------------

class Item:
    """One line of the plan. `change` is None when nothing is to be written."""

    def __init__(self, title, status, detail, change=None, blocking=False):
        self.title = title
        self.status = status  # "already there" | "will write" | "ok" | "FAILED" | "note"
        self.detail = detail
        self.change = change
        self.blocking = blocking


def plan(args, p):
    brings, checks = [], []

    # -- 1. his name ------------------------------------------------------------------
    config, why = read_json_object(p.config)
    # An absent schema_version reads as 1 (config.rs config_schema_version_default).
    schema = config.get("schema_version", CONFIG_SCHEMA_VERSION) if config is not None else None
    if config is None:
        brings.append(Item("His name", "FAILED",
                           "the settings file %s %s; it is left exactly as it is" % (p.config, why),
                           blocking=True))
    elif not isinstance(schema, int) or isinstance(schema, bool) or schema > CONFIG_SCHEMA_VERSION:
        brings.append(Item("His name", "FAILED",
                           "the settings file's schema version is not one this import knows (it knows %d); "
                           "it is left exactly as it is" % CONFIG_SCHEMA_VERSION,
                           blocking=True))
    else:
        for key, wanted, label in (("user_name", args.name, "His name"),
                                   ("company_name", args.company, "His company's name")):
            current = config.get(key)
            current = current.strip() if isinstance(current, str) else None
            if wanted is None:
                if key == "user_name":
                    if current:
                        brings.append(Item(label, "already there", "%r, in %s" % (current, p.config)))
                    else:
                        brings.append(Item(label, "FAILED",
                                           "no name is stored and none was given; pass --name", blocking=True))
                continue
            wanted = wanted.strip()
            if not wanted:
                brings.append(Item(label, "FAILED", "an empty name was given", blocking=True))
            elif current == wanted:
                brings.append(Item(label, "already there", "%r, in %s" % (current, p.config)))
            else:
                before = "not set" if not current else "%r" % current
                brings.append(Item(label, "will write", "%s -> %r, in %s" % (before, wanted, p.config),
                                   change=("config", key, wanted)))

    # -- 2. the memory pointer --------------------------------------------------------
    record = args.record
    if record is None and os.path.islink(p.loro_root) and record_shaped(p.loro_root):
        record = os.path.realpath(p.loro_root)
    if record is None:
        brings.append(Item("Memory pointer", "FAILED",
                           "no record was given and none is linked yet; pass --record", blocking=True))
    elif not record_shaped(record):
        brings.append(Item("Memory pointer", "FAILED",
                           "%s is not a record repository (it needs wiki/ and loro/)" % record, blocking=True))
    elif os.path.islink(p.loro_root) or os.path.exists(p.loro_root):
        if os.path.islink(p.loro_root) and same_place(p.loro_root, record):
            brings.append(Item("Memory pointer", "already there", "%s -> %s" % (p.loro_root, os.readlink(p.loro_root))))
        else:
            what = ("a link to %s" % os.readlink(p.loro_root)) if os.path.islink(p.loro_root) else "not a link"
            brings.append(Item("Memory pointer", "FAILED",
                               "%s already exists and is %s; it is his to move, not this import's" % (p.loro_root, what),
                               blocking=True))
    else:
        brings.append(Item("Memory pointer", "will write", "%s -> %s" % (p.loro_root, record),
                           change=("link", p.loro_root, record)))

    # -- 3. nothing outranks it -------------------------------------------------------
    if corpus_shaped(p.candidate3):
        checks.append(Item("Nothing outranks the record", "FAILED",
                           "%s is a usable corpus and is read BEFORE the record; he would get that memory, "
                           "not his record. Move it aside, then run this again" % p.candidate3, blocking=True))
    else:
        overrides = launchd_memory_overrides()
        if overrides is None:
            checks.append(Item("Nothing outranks the record", "FAILED",
                               "could not ask launchd for LORO_CORPUS / LORO_ROOT", blocking=True))
        elif overrides:
            checks.append(Item("Nothing outranks the record", "FAILED",
                               "launchd hands every double-clicked app %s, which takes the memory over; "
                               "`launchctl unsetenv` it, then run this again" % " and ".join(overrides), blocking=True))
        else:
            present = " (present but not a corpus, so passed over)" if os.path.lexists(p.candidate3) else " (absent)"
            checks.append(Item("Nothing outranks the record", "ok",
                               "candidate 3 %s%s; launchd sets no LORO_CORPUS or LORO_ROOT" % (p.candidate3, present)))

    # -- 4. the roster page -----------------------------------------------------------
    if record is not None and record_shaped(record):
        roster = os.path.join(record, args.roster)
        if os.path.isfile(roster) and os.path.getsize(roster) > 0:
            checks.append(Item("Roster page in the record", "ok", roster))
        else:
            checks.append(Item("Roster page in the record", "FAILED",
                               "%s is missing or empty; \"who is Frank?\" would have no answer" % roster,
                               blocking=True))

    # -- 5 and 6. his team ------------------------------------------------------------
    declaration, why = read_json_object(p.operator)
    team_folder = args.team_folder
    if not os.path.lexists(p.operator):
        checks.append(Item("His team in this install", "note",
                           "off: %s is absent. It is written by the operator declaration's own enable script, "
                           "run from his terminal, never by this import" % p.operator))
    elif declaration is None:
        checks.append(Item("His team in this install", "note",
                           "%s %s; the app refuses all background work until it is fixed or removed" % (p.operator, why)))
    else:
        checks.append(Item("His team in this install", "ok",
                           "%s is present; the app checks it at every launch" % p.operator))
        if team_folder is None and isinstance(declaration.get("entity_root"), str):
            team_folder = declaration["entity_root"]
    if team_folder is None:
        checks.append(Item("His memory index, read in place", "note",
                           "not checked: no --team-folder and no operator declaration to read it from"))
    else:
        index = os.path.join(p.home, ".claude", "projects", claude_project_dir_name(team_folder), "memory", "MEMORY.md")
        if os.path.isfile(index):
            checks.append(Item("His memory index, read in place", "ok",
                               "%s; his team's lead reads it there, and nothing is copied" % index))
        else:
            checks.append(Item("His memory index, read in place", "FAILED",
                               "%s is missing; his team's lead would start without his memory" % index,
                               blocking=True))

    # -- the resolver, mirrored -------------------------------------------------------
    return brings, checks, record


# ---------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------

def show(title, items):
    print(title)
    for it in items:
        print("  %-34s %-14s %s" % (it.title, it.status, it.detail))


def verify(p, record, args):
    """Read everything back. Returns a list of failure sentences."""
    failures = []
    config, why = read_json_object(p.config)
    if config is None:
        failures.append("the settings file %s" % why)
    else:
        if args.name is not None and (config.get("user_name") or "").strip() != args.name.strip():
            failures.append("config.json does not hold the name that was written")
        if args.company is not None and (config.get("company_name") or "").strip() != args.company.strip():
            failures.append("config.json does not hold the company name that was written")
    resolved, label = resolve_memory(p)
    if resolved is None:
        failures.append("the app would resolve no memory at all")
    elif record is not None and not same_place(resolved, record):
        failures.append("the app would resolve %s (%s), not the record" % (resolved, label))
    return failures


# ---------------------------------------------------------------------------------------
# Writes
# ---------------------------------------------------------------------------------------

def new_backup_dir(p):
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    base = os.path.join(p.backups, stamp)
    path, n = base, 1
    while os.path.lexists(path):
        n += 1
        path = "%s-%d" % (base, n)
    os.makedirs(path)
    return path


def write_config(p, updates):
    config, why = read_json_object(p.config)
    if config is None:
        raise RuntimeError("the settings file %s" % why)
    existed = os.path.exists(p.config)
    for key, value in updates:
        config[key] = value
    os.makedirs(p.data, exist_ok=True)
    tmp = p.config + ".import-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    if existed:
        shutil.copymode(p.config, tmp)
    os.replace(tmp, p.config)


def apply(p, items):
    changes = [it.change for it in items if it.change]
    backup = new_backup_dir(p)
    manifest = {"made_by": "import-setup.py", "backup": backup, "changes": []}

    config_updates = [(c[1], c[2]) for c in changes if c[0] == "config"]
    if config_updates:
        if os.path.exists(p.config):
            shutil.copy2(p.config, os.path.join(backup, "config.json"))
            before = "config.json in this folder"
            undo = "copy config.json from this folder back over %s while RichOS is quit" % p.config
        else:
            before = "absent"
            undo = "delete %s while RichOS is quit" % p.config
        manifest["changes"].append({"path": p.config, "keys": [k for k, _ in config_updates],
                                    "before": before, "undo": undo})
    for c in changes:
        if c[0] == "link":
            manifest["changes"].append({"path": c[1], "link_to": c[2], "before": "absent",
                                        "undo": "delete the link %s" % c[1]})
    # The manifest is written BEFORE the change, so an interrupted import still says what it began.
    with open(os.path.join(backup, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)

    if config_updates:
        write_config(p, config_updates)
    for c in changes:
        if c[0] == "link":
            os.makedirs(os.path.dirname(c[1]), exist_ok=True)
            os.symlink(c[2], c[1])
    return backup


# ---------------------------------------------------------------------------------------

def main(argv):
    ap = argparse.ArgumentParser(description="The one-time import of the owner's setup into his daily-driver RichOS.")
    ap.add_argument("--home", default=os.path.expanduser("~"),
                    help="the home whose RichOS install is imported into (default: yours)")
    ap.add_argument("--record", help="his record repository (wiki/ + loro/); defaults to where loro-root already points")
    ap.add_argument("--name", help="his name, as the app should address him")
    ap.add_argument("--company", help="his company's name, for the rail header (optional)")
    ap.add_argument("--team-folder", help="the folder his team's lead starts in (default: the operator declaration's)")
    ap.add_argument("--roster", default=DEFAULT_ROSTER, help="the roster page, relative to the record (default: %(default)s)")
    ap.add_argument("--go", action="store_true", help="make the changes; without it nothing is written")
    args = ap.parse_args(argv)

    home = os.path.abspath(args.home)
    if not os.path.isdir(home):
        print("import-setup: %s is not a folder" % home, file=sys.stderr)
        return 2
    if args.record is not None:
        args.record = os.path.abspath(os.path.expanduser(args.record))
    if args.team_folder is not None:
        args.team_folder = os.path.abspath(os.path.expanduser(args.team_folder))
    p = Paths(home)

    brings, checks, record = plan(args, p)
    running, running_sentence = app_running(p)
    print("RichOS one-time import, into %s" % p.data)
    print("  The app in this install: %s" % running_sentence)
    print()
    show("What it brings over:", brings)
    print()
    show("What it checks (read only):", checks)
    print()
    print("What it leaves alone: his record's contents (pointed at, never copied), his memory files "
          "(read in place), his continuity history, his ledgers, and everything in ~/.claude.")
    print()

    blocking = [it for it in brings + checks if it.blocking]
    pending = [it for it in brings if it.change]

    if blocking:
        print("NOT READY: %d check(s) failed above. Nothing was written." % len(blocking))
        return 1
    if not pending:
        failures = verify(p, record, args)
        if failures:
            for f in failures:
                print("VERIFY FAILED: %s" % f)
            return 1
        print("Nothing to change: everything above is already in place, and nothing was written.")
        return 0
    if not args.go:
        print("PLAN ONLY: %d change(s) above would be made. Nothing was written. Run again with --go to make them."
              % len(pending))
        return 0
    if running:
        print("REFUSED: the app in this install is %s. It rewrites its whole settings file on every change "
              "and would put the old values back. Quit it, then run this again. Nothing was written."
              % running_sentence.replace("running as", "running, as"))
        return 1

    backup = apply(p, brings)
    print("Backed up to %s (manifest.json there says how to undo each change)." % backup)
    failures = verify(p, record, args)
    if failures:
        for f in failures:
            print("VERIFY FAILED: %s" % f)
        return 1
    resolved, label = resolve_memory(p)
    print("IMPORT DONE AND VERIFIED: the app will address him by name and resolve his memory from %s (%s)."
          % (os.path.realpath(resolved), label))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
