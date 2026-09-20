#!/usr/bin/env python3
"""stop.py — THE MECHANISM BEHIND `scripts/stop.sh`: ONE COMMAND THAT STOPS THE
TEAMMATES THE CEO NAMED, AND NOT ONE MORE.

===========================================================================
WHY THIS FILE EXISTS
===========================================================================
2026-09-20, ~05:30Z. Three engineers were running. The CEO objected to the
spend: "And those 3 are gonna keep running and burning my tokens OR WHAT???"
Rich's `TaskStop` on each was refused by `guard-stop-live-work.sh` — correctly,
because his sentence carried no unconditional stop imperative and no
`stop-work-ack.sh` line existed on disk. The way through takes seconds. Rich
sent "commit and hold" messages instead, which stop nothing until an agent
happens to read one, and the CEO killed all three from his own screen a minute
later: "DID YOU SUDDENLY FORGET HOW TO FUCKING STOP AN AGENT OR FUCKING WHAT?"
Then: "In the 'same minute'? or in the same second?"

Forty minutes later, after he had killed one agent himself, Rich stopped a
SECOND one on the inference that everything should stop: "WHEN THE FUCK DID I
SAY THAT 'EVERYTHING RUNNING' NEEDS TO STOP???"

So the mechanism has to answer BOTH halves at once, and they pull in opposite
directions: a stop must go through in seconds, and it must reach exactly the
agents his words name. Ruling: richos-hq wiki/ceo-decisions.md §67.

===========================================================================
IT TAKES NAMES. THERE IS NO "EVERYTHING" MODE, AND THERE NEVER WILL BE
===========================================================================
An earlier draft of this work was called `stop-all.sh`, and the 05:15Z sentence
above is the answer to it. A flag that enumerates every running teammate is a
flag that converts "those 3" into "all of them" at the moment somebody is in a
hurry — which is the exact condition this command is built for. `stop.test.sh`
greps this file and its shell entry point for such a mode and goes red if one
appears; that test is not decoration, it is the design.

Nothing is guessed, either. A name that is not provably running is REPORTED AND
SKIPPED, never widened into a neighbor.

===========================================================================
WHAT IT DOES, AND WHAT IT DELIBERATELY DOES NOT DO
===========================================================================
For each NAME, in the order given:

  1. Finds its record in the workspace registry (mega-lander/workspaces.py),
     which is where a hand-rolled cross-repo `cc/` workspace lives as well as a
     native one. READ-ONLY: this never calls the registry's `_resolve`, because
     that observes and WRITES; a command run in a panic must not mutate the
     store it is reading.
  2. Asks the ONE liveness resolver (scripts/lib/agent-liveness.py) whether it
     is running. Not a second implementation — the same one
     `guard-stop-live-work.sh` asks, so this command's prediction and the
     guard's decision cannot disagree. That identity is the whole point: a stop
     that this command says will go through, goes through.
  3. Reads what would be destroyed — commits on each of its branches past the
     ref its work integrates on, and uncommitted paths in each workspace — and
     puts the MEASUREMENT in the ack rather than a phrase.
  4. Writes one `stop-work-ack.sh` per target, with `--why` carrying the CEO's
     sentence verbatim.
  5. Verifies the ack is findable by the guard's own `find_live_ack`, and says
     so. "I ran the command" is not evidence; the record on disk is.
  6. Prints the exact `TaskStop` target for each name, in the order given, and
     the `workspaces.sh` commands to run afterwards.

IT DOES NOT CALL `TaskStop`. It cannot: `TaskStop` is a tool of the assistant's
harness and no script can reach it (measured 2026-09-10 across 100 real calls —
`stop-work-ack.sh` header). So the last step is Rich's, and this command's job
is to leave that step with nothing to decide.

IT DOES NOT RECORD THE END IN THE REGISTRY EITHER, and that is deliberate
rather than an omission. `workspaces.sh stop <name>` marks a record ended, and
a record that reads ended makes `finished_state` say FINISHED, which makes the
liveness resolver say NOT-ALIVE, which makes the guard allow the stop silently.
Writing it BEFORE the kill would therefore clear the way by making the system
believe something that has not happened yet — a laundering of liveness dressed
as hygiene. The registry is told after the fact, by the commands printed at the
end.

===========================================================================
TWO SPELLINGS OF ONE TARGET — MEASURED, NOT ASSUMED
===========================================================================
`find_live_ack` matches `task_id` by EXACT STRING. So an ack keyed on the
teammate's name does not cover a `TaskStop` made with its raw agent id. Every
real `TaskStop` call in every transcript on this machine, read 2026-09-20:

    116 calls, tool_input `{"task_id": ...}` in 116 of 116
    103 carried the teammate NAME          (89%)
      7 carried a raw agent id             (6%)
      6 neither shape (session-qualified or other)

So the name is the dominant form and the id form is real. Both are written when
the agent id is known and differs from the name, and BOTH NAME THE SAME SINGLE
AGENT — which is what `stop-work-ack.sh`'s one-target rule protects. That rule
exists because a blanket ack would wave two DIFFERENT teammates through on one
sentence (two were killed 2.7 seconds apart on 2026-09-10). N single-target
acks, one per named teammate, honor it; so do two spellings of one target.

===========================================================================
EXIT CODES
===========================================================================
    0   every named teammate was DECIDED: each is either running with a live
        ack written for it, or provably not running and skipped.
    1   at least one could not be decided. INDETERMINATE is said, never
        collapsed into either other answer (CLAUDE.md, the liveness rule).
        THE ACK IS STILL WRITTEN IN THAT CASE and the stop still goes through —
        exit 1 reports what is unknown, it never withholds a stop.
    2   usage: no names, or no --ceo-word.

The brief for this work wrote "no names -> usage, exit 1". It is 2 here, with
the deviation stated rather than silently taken: 2 is usage across this engine
(`stop-work-ack.sh`, `spawn.sh`, `agent-liveness.sh`), and a caller that cannot
tell "you typed it wrong" from "one agent's state is unknown" has lost the
distinction this file spent its INDETERMINATE handling to keep.
"""

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time

GIT_TIMEOUT = 10
MAX_COMMITS_SHOWN = 6

ALIVE = "ALIVE"
NOT_ALIVE = "NOT-ALIVE"
INDETERMINATE = "INDETERMINATE"


def _load(path, modname):
    """Import a file by path, or return None. Never raises: this command runs
    when something has already gone wrong, and a missing sibling must degrade
    into a stated unknown rather than a traceback."""
    try:
        if not os.path.isfile(path):
            return None
        spec = importlib.util.spec_from_file_location(modname, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception:
        return None


# ---------------------------------------------------------------------------
# git — bounded, read-only, and never fatal
# ---------------------------------------------------------------------------

def _git(repo, *args):
    """(ok, stdout). A failure is an empty string and a False, never an
    exception: what is destroyed is worth measuring, and NOT worth blocking a
    stop over."""
    try:
        res = subprocess.run(["git", "-C", repo] + list(args),
                             capture_output=True, text=True, timeout=GIT_TIMEOUT)
    except Exception:
        return False, ""
    if res.returncode != 0:
        return False, (res.stderr or "").strip()
    return True, (res.stdout or "").rstrip("\n")


def measure(ws, rec):
    """(text, undecided_reason, short) — what dies with this agent, measured.

    The text goes verbatim into the ack's `--destroying`, so it must say what
    was READ rather than what is assumed. Where a number could not be read, it
    says that instead of reporting zero: on 2026-09-20 the three branches held
    zero commits and nothing was lost, and the only reason anyone knows that is
    that somebody ran `git log`.
    """
    name = rec.get("name") or rec.get("key") or "?"
    parts = []
    undecided = []
    n_commits = 0
    n_dirty = 0
    try:
        chain = ws._chain(rec)
    except Exception:
        chain = [rec]
    for w in (ws.live_workspaces(rec) or []):
        repo = w.get("repo") or ""
        branch = w.get("branch") or ""
        path = w.get("path") or ""
        label = "%s in %s" % (branch or "(no branch)", os.path.basename(repo.rstrip("/")) or repo)

        commits_bit = "commits unread"
        if repo and branch:
            base_branch, base_tip, why_not = "", "", "no registry answer"
            try:
                base_branch, base_tip, why_not = ws.integration_target(chain, repo)
            except Exception as e:
                why_not = "the integration branch could not be read (%r)" % (e,)
            main = ws.main_checkout(repo) or repo
            if base_tip:
                ok, out = _git(main, "log", "--oneline", "--no-decorate",
                               "%s..%s" % (base_tip, branch))
                if ok:
                    lines = [l for l in out.splitlines() if l.strip()]
                    if not lines:
                        commits_bit = "0 commits past %s (%s)" % (base_tip[:8], base_branch)
                    else:
                        n_commits += len(lines)
                        shown = "; ".join(lines[:MAX_COMMITS_SHOWN])
                        more = "" if len(lines) <= MAX_COMMITS_SHOWN else \
                            " (+%d more)" % (len(lines) - MAX_COMMITS_SHOWN)
                        commits_bit = "%d commit(s) past %s: %s%s" % (
                            len(lines), base_tip[:8], shown, more)
                else:
                    commits_bit = "commits could not be counted (git said: %s)" % (out[:120] or "nothing")
                    undecided.append("%s: %s" % (label, commits_bit))
            else:
                commits_bit = "commits could not be counted: %s" % (why_not or "no integration ref")
                undecided.append("%s: %s" % (label, commits_bit))

        dirty_bit = "working tree unread"
        if path and os.path.isdir(path):
            ok, out = _git(path, "status", "--short")
            if ok:
                n = len([l for l in out.splitlines() if l.strip()])
                n_dirty += n
                dirty_bit = "clean tree" if n == 0 else "%d uncommitted path(s)" % n
            else:
                undecided.append("%s: working tree could not be read" % label)
        elif path:
            dirty_bit = "its workspace directory is gone"

        parts.append("%s — %s, %s" % (label, commits_bit, dirty_bit))

    if not parts:
        return ("%s: the registry records no live workspace for it, so there is nothing on disk "
                "to lose and nothing to read" % name), "", "no live workspace"
    text = "%s: %s" % (name, " | ".join(parts))
    short = "%d commit(s), %d uncommitted path(s)%s" % (
        n_commits, n_dirty, " — some of it unread" if undecided else "")
    return text, ("; ".join(undecided) if undecided else ""), short


# ---------------------------------------------------------------------------
# the registry — read-only lookups
# ---------------------------------------------------------------------------

def find_record(ws, cache, name, session):
    """(record, why_not). Read-only by construction.

    The registry's own `_resolve` is NOT used: it wraps the lookup in
    `observe_platform_binding` / `observe_platform_end`, which SAVE. A command
    whose whole purpose is to run in the first seconds of a panic does not get
    to mutate the store every other consumer reads.
    """
    if session:
        try:
            r = ws.load_agent(ws.named_key(session, name))
        except Exception:
            r = None
        if r:
            return r, ""
    hits = [a for a in cache if a.get("name") == name]
    if not hits:
        return None, ("no agent named %r is registered (mega-lander/workspaces.py). It may have been "
                      "spawned outside the registry, or the name may be misspelled." % name)
    if len(hits) == 1:
        return hits[0], ""
    unfinished = [a for a in hits if not _finished(ws, a)[0]]
    if len(unfinished) == 1:
        return unfinished[0], ""
    keys = ", ".join(sorted(h.get("key") or "?" for h in hits))
    return None, ("%r names %d registered agents and more than one is unfinished; nothing guesses "
                  "which. Keys: %s" % (name, len(hits), keys))


def _finished(ws, rec):
    try:
        return ws.finished_state(rec)
    except Exception as e:
        return False, False, "the registry could not decide (%r)" % (e,)


# ---------------------------------------------------------------------------
# liveness — the ONE resolver, never a second one
# ---------------------------------------------------------------------------

def liveness(al, ws, entity, rec, name, transcript):
    """(verdict, detail). Asks scripts/lib/agent-liveness.py, which is what
    guard-stop-live-work.sh asks. Where this command cannot name an agent id to
    ask about, the answer is INDETERMINATE and says so."""
    if al is None:
        return INDETERMINATE, ("the liveness resolver is missing, so whether %s is running could "
                               "not be established" % name)
    agent_id = (rec or {}).get("agent_id") or ""
    if not agent_id and transcript:
        try:
            agent_id = al.names_to_ids(transcript).get(name, "") or ""
        except Exception:
            agent_id = ""
    if not agent_id:
        if rec is not None:
            fin, paused, why = _finished(ws, rec)
            if fin:
                return NOT_ALIVE, "the workspace registry records it FINISHED — %s (point 11)" % why
            return INDETERMINATE, ("it is registered and unfinished (%s) but carries no agent id, so "
                                   "its isolation-worktree lock cannot be read" % why)
        return INDETERMINATE, ("nothing on this machine ties the name %s to an agent id, so its lock "
                               "cannot be read" % name)
    try:
        r = al.resolve(entity, agent_id)
    except Exception as e:
        return INDETERMINATE, "the liveness resolver raised %r" % (e,)
    v = str(r.get("verdict") or INDETERMINATE)
    if v not in (ALIVE, NOT_ALIVE, INDETERMINATE):
        v = INDETERMINATE
    return v, str(r.get("reason") or "")


# ---------------------------------------------------------------------------
# the ack — written by stop-work-ack.sh, and by nothing else
# ---------------------------------------------------------------------------

def compose_why(ceo_word):
    """The ack's `--why`, carrying his sentence verbatim inside a clause that
    says what it is.

    HIS WORDS ARE NOT PADDED TO REACH A FLOOR AND THEY ARE NOT TRIMMED. The
    floor in stop-work-ack.sh is 20 characters, and "stop them" is nine; a
    command that refused his order for being too short would be the guard
    failure of 2026-09-20 rebuilt one layer down. The frame carries the
    citation, the quotation carries him.
    """
    return ("the CEO ordered this agent stopped, in his own words: \"%s\" — his word is "
            "unconditional for the agents it names and is executed first, in seconds "
            "(ceo-decisions §67). Uncommitted work is his to lose and he has said so."
            % ceo_word.strip())


def write_ack(engine_root, entity, task, destroying, why):
    """(ok, message). stop-work-ack.sh is the ONE writer of that ledger; this
    calls it rather than appending a second implementation of the format."""
    script = os.path.join(engine_root, "scripts", "stop-work-ack.sh")
    if not os.path.isfile(script):
        return False, "stop-work-ack.sh is missing at %s" % script
    try:
        res = subprocess.run(
            ["bash", script, "--task", task, "--destroying", destroying,
             "--why", why, "--entity", entity],
            capture_output=True, text=True, timeout=30)
    except Exception as e:
        return False, "stop-work-ack.sh could not be run: %r" % (e,)
    if res.returncode != 0:
        return False, ((res.stderr or res.stdout or "").strip().splitlines() or ["exit %d" % res.returncode])[-1]
    return True, ""


def ack_is_findable(slw, entity, task):
    """The ARTIFACT check. `find_live_ack` is the guard's own reader, so a True
    here means the guard will find what was just written — not that a command
    exited 0."""
    if slw is None:
        return None, "the stop predicate is missing, so the ack could not be verified"
    try:
        ack, why = slw.find_live_ack(entity, task)
    except Exception as e:
        return None, "the ack could not be verified (%r)" % (e,)
    return (ack is not None), (why or "")


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------

def _q(s):
    """A single-quoted shell literal, so a printed command can be pasted."""
    return "'" + str(s).replace("'", "'\\''") + "'"


def main(argv=None):
    ap = argparse.ArgumentParser(prog="stop.sh", add_help=False)
    ap.add_argument("names", nargs="*")
    ap.add_argument("--ceo-word", default="")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--entity", default="")
    ap.add_argument("--engine", default="")
    ap.add_argument("--transcript", default="")
    ap.add_argument("--session", default="")
    ap.add_argument("-h", "--help", action="store_true")
    try:
        a = ap.parse_args(argv)
    except SystemExit:
        return 2

    if a.help:
        return 2

    err = sys.stderr
    out = sys.stdout

    if not a.names:
        print("REFUSED: name the teammates the CEO's words name — one or more.", file=err)
        print("         stop.sh <name> [<name> ...] --ceo-word '<his sentence, verbatim>'", file=err)
        print("         There is no flag that stops everything, and there will not be one:", file=err)
        print("         \"WHEN THE FUCK DID I SAY THAT 'EVERYTHING RUNNING' NEEDS TO STOP???\"", file=err)
        print("         (CEO, 2026-09-20 05:15Z, after a second engineer was stopped on an inference).", file=err)
        return 2

    if not a.ceo_word.strip():
        print("REFUSED: --ceo-word is required, and it is his sentence VERBATIM.", file=err)
        print("         It is what the ack says, and it is the difference between a stop he", file=err)
        print("         ordered and a stop somebody inferred (ceo-decisions §67).", file=err)
        return 2

    engine_root = a.engine or os.path.abspath(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    entity = a.entity
    if not entity or not os.path.isdir(entity):
        print("REFUSED: the governed repository could not be resolved (--entity %r). The ack is"
              % entity, file=err)
        print("         written into its .claude/state, and the guard reads it from there; writing", file=err)
        print("         it anywhere else would be paperwork the guard never finds.", file=err)
        return 2

    ws = _load(os.path.join(engine_root, "mega-lander", "workspaces.py"), "stop_workspaces")
    al = _load(os.path.join(engine_root, "scripts", "lib", "agent-liveness.py"), "stop_liveness")
    slw = _load(os.path.join(engine_root, "scripts", "lib", "stop-live-work.py"), "stop_predicate")

    cache = []
    if ws is not None:
        try:
            cache = ws.all_agents(include_done=True)
        except Exception:
            cache = []

    ceo_word = a.ceo_word.strip()
    why = compose_why(ceo_word)
    started = time.time()

    print("=== stop — %d teammate(s) the CEO named%s ===" % (len(a.names),
          ", DRY RUN (nothing is written)" if a.dry_run else ""), file=out)
    print("    his words: \"%s\"" % ceo_word, file=out)
    print("    entity:    %s" % entity, file=out)
    print("", file=out)

    results = []
    for i, name in enumerate(a.names, 1):
        rec, lookup_why = (None, "the workspace registry could not be read")
        if ws is not None:
            rec, lookup_why = find_record(ws, cache, name, a.session)

        verdict, detail = liveness(al, ws, entity, rec, name, a.transcript)

        if rec is not None and ws is not None:
            destroying, undecided, short = measure(ws, rec)
        else:
            destroying = ("%s: it is not in the workspace registry (%s), so what it has committed "
                          "could not be read — assume everything uncommitted is lost"
                          % (name, lookup_why))
            undecided = lookup_why
            short = "unread: it is not in the registry"

        disposed = bool((rec or {}).get("disposition"))
        already_finished = bool(rec is not None and ws is not None and _finished(ws, rec)[0])

        row = {"name": name, "verdict": verdict, "detail": detail,
               "destroying": destroying, "undecided": undecided, "short": short,
               "disposed": disposed, "already_finished": already_finished,
               "registered": rec is not None,
               "agent_id": (rec or {}).get("agent_id") or "", "acks": [], "skipped": False}

        if verdict == NOT_ALIVE:
            # REPORTED AND SKIPPED, NEVER GUESSED. The guard allows a TaskStop on
            # something that is not running without any ack at all, so an ack here
            # would be paperwork — and a habit of paperwork is how a guard dies.
            row["skipped"] = True
        else:
            targets = [name]
            if row["agent_id"] and row["agent_id"] != name:
                targets.append(row["agent_id"])
            for t in targets:
                if a.dry_run:
                    row["acks"].append((t, "would be written", None))
                    continue
                ok, msg = write_ack(engine_root, entity, t, destroying, why)
                if not ok:
                    row["acks"].append((t, "FAILED: %s" % msg, False))
                    continue
                found, fwhy = ack_is_findable(slw, entity, t)
                if found is True:
                    row["acks"].append((t, "written and verified findable by the guard's own reader", True))
                elif found is None:
                    row["acks"].append((t, "written; could not be verified (%s)" % fwhy, None))
                else:
                    row["acks"].append((t, "written but the guard would NOT find it (%s)" % fwhy, False))

        results.append(row)

        mark = {ALIVE: "RUNNING", NOT_ALIVE: "NOT RUNNING", INDETERMINATE: "UNDECIDED"}[verdict]
        print("  %d. %-28s %s" % (i, name, mark), file=out)
        print("       %s" % (detail or "no detail"), file=out)
        print("       %s" % destroying, file=out)
        if row["skipped"]:
            print("       skipped: no ack is needed to stop something that is not running", file=out)
        for t, msg, _ok in row["acks"]:
            print("       ack [%s]: %s" % (t, msg), file=out)
        if undecided:
            print("       UNREAD: %s" % undecided, file=out)
        print("", file=out)

    print("  NOW, IN THIS SAME RESPONSE, make these calls — in this order, nothing before them:", file=out)
    for row in results:
        note = ""
        if row["skipped"]:
            note = "   (allowed without an ack: it is not running)"
        elif row["verdict"] == INDETERMINATE:
            note = "   (liveness undecided; the ack is written, so it goes through either way)"
        print("       TaskStop(task_id=\"%s\")%s" % (row["name"], note), file=out)
    print("", file=out)

    # The follow-ups, and ONLY the ones that still apply. A `stop` for something
    # the registry already calls finished, or a `discard` of work already
    # disposed of, is a command that refuses — and a printed command that
    # refuses teaches the reader to skim the list.
    wsh = os.path.join(engine_root, "mega-lander", "workspaces.sh")
    follow = []
    for row in results:
        if row["registered"] and not row["already_finished"]:
            follow.append("%s stop %s --why %s" % (wsh, row["name"], _q(ceo_word)))
    for row in results:
        if row["disposed"] or not row["registered"]:
            continue
        follow.append("%s discard %s --reason %s --ceo-word %s"
                      % (wsh, row["name"],
                         _q("stopped on the CEO's word (ceo-decisions §67); it held %s" % row["short"]),
                         _q(ceo_word)))
    if follow:
        print("  AFTERWARDS, once the stops are made — the registry is told what happened,", file=out)
        print("  never before it happens:", file=out)
        for line in follow:
            print("       %s" % line, file=out)
        print("", file=out)

    undecided_rows = [r for r in results
                      if r["verdict"] == INDETERMINATE or r["undecided"]
                      or any(ok is False for _t, _m, ok in r["acks"])]
    acked = sum(1 for r in results if any(ok is not False for _t, _m, ok in r["acks"]))
    skipped = sum(1 for r in results if r["skipped"])
    print("  %d named · %d acked · %d skipped (not running) · %d undecided · %.1fs"
          % (len(results), acked, skipped, len(undecided_rows), time.time() - started), file=out)

    if undecided_rows:
        print("", file=out)
        print("  UNDECIDED, and said rather than collapsed into yes or no:", file=out)
        for r in undecided_rows:
            print("    - %s: %s" % (r["name"], r["undecided"] or r["detail"]), file=out)
        print("  The ack for each of these IS written. Make the stop; this exit code reports", file=out)
        print("  what is unknown, it never withholds a stop.", file=out)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
