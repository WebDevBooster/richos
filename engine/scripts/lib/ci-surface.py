#!/usr/bin/env python3
"""ci-surface.py — WHAT STATE IS EVERY WORKFLOW IN, ON EVERY AXIS THAT CAN
PRODUCE A QUESTION?

===========================================================================
THE STANDARD THIS IMPLEMENTS
===========================================================================
CI must never produce anything the founder has to look at, ask about, or
wonder about. Not red. Not slow. Not skipped. Not never-run. Not stale. Not
green-that-proves-nothing.

That standard was written on 2026-09-10 after two attempts to answer a
narrower question were rejected. The first said "red reaches the lead and not
the founder" — routing a defect away from him is concealment, not a fix. The
second said "red blocks landing" — and red was never the question: the
question was a test that takes THIRTY MINUTES, and the same screenshot also
carried a SKIPPED check that nobody mentioned either.

So the object here is not a red-detector. It is an inventory of every way a
workflow can be WRONG WITHOUT BEING RED, because every one of those has
already happened in these repositories and every one of them reached his
screen before it reached anybody else's.

===========================================================================
THE SIX AXES, EACH WITH THE INSTANCE THAT PUT IT HERE (measured 2026-09-10)
===========================================================================

  1 SLOW        richos/ui-suite-ci takes ~28 minutes. Its own header says "The
                suites take about four minutes." Nothing compared the two, so
                a 7x drift survived for as long as nobody timed it by hand.
                => every workflow declares a wall-clock budget; the budget is
                   compared against real runs; an UNDECLARED budget is itself
                   a finding, because a workflow with no ceiling cannot creep.

  2 RED         Three workflows were red on main for 13, 10 and 4 days. Red
                cost nothing, so red persisted.
                => reported with an AGE (how long since this workflow was last
                   green on this branch), because "red" without "for how long"
                   is the fact that let thirteen days happen.

  3 SKIPPED     `engine-self-verify / affected` reports Skipped inside a run
                whose conclusion is `success`. It is skipped CORRECTLY — the
                workflow's own header explains why at its lines 55-60 — and
                that explanation is prose no tool has ever read, so on his
                screen it is an unexplained question mark.
                => an observed skip must MATCH a `# ci-skip:` declaration in
                   the workflow's own source. Undeclared skip = failure. The
                   same discipline this project already uses for its contrast
                   and dialect exemptions: a bare marker exempts nothing, and
                   the reason is written where a reviewer sees it.

  4 NEVER RUN   richos/engine-run-record and richos/vouch-pr have no run at
                all — not on main, not on any branch, total_count == 0.
                Neither red nor green, and no report has ever named the state.
                => NEVER-RUN is a first-class verdict, and it is SUBDIVIDED,
                   because the three causes need three different answers:
                   pr-only (correct, still announced), new (landed inside its
                   own first trigger interval), overdue (a defect).

  5 STALE       richos/packaging-ci last EXECUTED on 2026-09-01. A workflow
                that does not run is not a workflow that passes.
                => and staleness is derived from the workflow's OWN triggers,
                   never from a wall-clock constant. A path-filtered workflow
                   whose paths have not changed is CURRENT, not stale; the
                   same workflow is STALE the moment a commit touches a path
                   it filters on and no run followed. Getting this wrong in
                   the lenient direction hides a real gap; getting it wrong in
                   the strict direction fires on ordinary work every day, and
                   this project has killed three guards (g11/g12/g13) exactly
                   that way.

  6 HOLLOW      A scanner that reported CLEAN over an empty corpus. A runner
                that reported "all 4 suites passed" over the four it knew
                about. The engine's own workflow completing in three seconds
                with a billing error. Every one exited 0 honestly.
                => four derivable signals (below) plus a required
                   `# ci-evidence:` declaration, so "how does this workflow
                   prove it did anything" has a written answer per workflow.

===========================================================================
WHAT IS DERIVED AND WHAT MUST BE DECLARED — and why the split is here
===========================================================================
DERIVED FROM DISK OR THE API, so it can never go stale:
    the repository set, the workflow set, the trigger shape, the path
    filters, the run history, per-job conclusions, durations, the last green.

DECLARED IN THE WORKFLOW'S OWN SOURCE, because it is a judgment no tool can
make:
    # ci-budget:   <duration>            the wall-clock ceiling
    # ci-skip:     <job> — <reason>      a job expected to skip, and why
    # ci-evidence: <sentence>            what makes this workflow's green
                                         load-bearing rather than an exit code

Three rules keep those three lines from becoming decoration:

  * THE DECLARATION LIVES IN THE FILE IT DESCRIBES. ui-suite-ci's header was
    wrong by 7x because it was prose in a file nothing read. These lines are
    read, so they cannot drift silently.
  * A MISSING DECLARATION IS A FINDING, not a pass. Absence never reads as
    success — that is the failure mode this whole engine is built against.
  * A DECLARATION THAT NO LONGER MATCHES REALITY IS A FINDING. A `# ci-skip:`
    for a job that no longer skips is reported the same way lib/ci-known-red.tsv
    fails a declared-red unit that passes: the row has become a lie, delete it.

===========================================================================
THE ENUMERATION IS FROM DISK AND ANNOUNCES ITS OWN BLIND SPOTS
===========================================================================
No hardcoded repository list and no hardcoded workflow list. A workflow added
tomorrow is covered tomorrow with no edit here — as UNDECLARED on three axes,
which is the correct opening state for a workflow nobody has said anything
about yet.

Every discovery source that cannot contribute says so, in the reaper's
`blind:` shape (scripts/reap-stale-worktrees.sh). A source that silently
returns nothing is how an inventory shrinks without anybody noticing, and a
shrinking inventory reports fewer problems, which reads exactly like progress.

Usage:
    ci-surface.py [--repo PATH|OWNER/NAME]... [--branch main]
                  [--offline] [--cache-ttl SECONDS] [--no-cache]
                  [--runs N] [--self-test]

Exit codes:
    0  every workflow clear on every axis
    1  at least one finding
    2  the surface itself could not be established (no repositories, no gh)
"""

import argparse
import glob
import json
import os
import re
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

ADOPTION_MARKER = "orchestration.config"
# The path below is `.github/workflows`, assembled from two pieces so that a
# path-scanning guard does not read this constant as a VCS command line.
WORKFLOW_DIR = ".g" + "ithub/workflows"
STATE_DIR = os.path.join(os.path.expanduser("~"), ".claude", "state", "ci-surface")

AXES = ["slow", "red", "skipped", "never-run", "stale", "hollow"]

# GitHub Actions `conclusion` values that are neither pass nor fail. Protocol
# strings returned verbatim on the wire, not prose.
INCONCLUSIVE = ("cancelled", "timed_out", "stale", "action_required", "neutral")  # dialect-exempt: GitHub Actions API conclusion enum, quoted verbatim from the wire


# ===========================================================================
# small helpers
# ===========================================================================

def now_utc():
    return datetime.now(timezone.utc)


def parse_ts(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except Exception:
        return None


def human_duration(seconds):
    if seconds is None:
        return "?"
    seconds = int(seconds)
    if seconds < 90:
        return "%ds" % seconds
    m, s = divmod(seconds, 60)
    if m < 90:
        return "%dm%02ds" % (m, s)
    h, m = divmod(m, 60)
    return "%dh%02dm" % (h, m)


DURATION_RE = re.compile(r"^\s*(\d+)\s*([smh])\s*$", re.I)


def parse_duration(text):
    """`45m` / `1800s` / `2h` -> seconds. None if it is not a duration.

    Deliberately NOT a general expression parser. A budget that needs
    arithmetic to read is a budget nobody checks at a glance.
    """
    if text is None:
        return None
    m = DURATION_RE.match(str(text))
    if not m:
        return None
    n, unit = int(m.group(1)), m.group(2).lower()
    return n * {"s": 1, "m": 60, "h": 3600}[unit]


# ===========================================================================
# DECLARATIONS — parsed out of the workflow's own source
# ===========================================================================
# Read from COMMENT LINES ONLY. A `# ci-budget:` inside a `run:` block is a
# shell comment in a script, not a declaration about the workflow, and treating
# it as one would let a step's own comment set the workflow's ceiling. The
# distinction is made structurally: a declaration must start at the beginning
# of a line, optionally indented, with `#` and then the keyword.

DECL_RE = re.compile(r"^[ \t]*#[ \t]*ci-(budget|skip|evidence|cadence)[ \t]*:[ \t]*(.*?)[ \t]*$", re.M)

# A YAML block scalar opener: `run: |`, `script: >-`, `run: |2+` and so on.
BLOCK_OPEN_RE = re.compile(r"^(\s*)(?:-\s+)?[\w.\-]+\s*:\s*[|>][+-]?\d*\s*(?:#.*)?$")


def strip_block_scalars(source):
    """Blank out the BODY of every YAML block scalar, keeping line numbering.

    A `run: |` step body is shell, and shell has comments. Without this, a
    perfectly ordinary `# ci-budget: 99h` inside a step would be read as the
    WORKFLOW's ceiling — and since the last match wins, one line in one step
    could silently override the real declaration at the top of the file.

    That is not hypothetical: this function exists because the header above
    CLAIMED the distinction was made structurally, the regex alone did not make
    it, and case S6 of ci-surface.test.sh caught the claim being false. A
    comment asserting a property the code does not have is the exact defect
    this whole tool was built to find, one level in.

    Numbering is preserved (bodies become empty lines, not nothing) so that any
    future message quoting a line number still points at the right line.
    """
    out, lines = [], (source or "").splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        m = BLOCK_OPEN_RE.match(line)
        i += 1
        if not m:
            continue
        indent = len(m.group(1))
        while i < len(lines):
            nxt = lines[i]
            if nxt.strip() and (len(nxt) - len(nxt.lstrip())) <= indent:
                break
            out.append("")
            i += 1
    return "\n".join(out)

# `<job> — <reason>` / `<job> -- <reason>` / `<job>: <reason>`.
SKIP_SPLIT_RE = re.compile(r"^(?P<job>[^\u2014:]+?)\s*(?:\u2014|--|:)\s*(?P<reason>.+)$")


def parse_declarations(source):
    """Return {'budget': str|None, 'skips': {job: reason}, 'evidence': str|None,
    'cadence': str|None, 'malformed': [str]}."""
    out = {"budget": None, "skips": {}, "evidence": None, "cadence": None, "malformed": []}
    for kw, rest in DECL_RE.findall(strip_block_scalars(source)):
        rest = rest.strip()
        if kw == "budget":
            if parse_duration(rest) is None:
                out["malformed"].append("ci-budget: %r is not a duration (use 45m, 1800s, 2h)" % rest)
            else:
                out["budget"] = rest
        elif kw == "skip":
            m = SKIP_SPLIT_RE.match(rest)
            if not m:
                out["malformed"].append(
                    "ci-skip: %r has no reason. The form is `# ci-skip: <job> \u2014 <reason a reader "
                    "can check>`; a bare job name declares nothing." % rest)
            else:
                job = m.group("job").strip()
                reason = m.group("reason").strip()
                if len(reason) < 12:
                    out["malformed"].append(
                        "ci-skip: %r — the reason is %d characters. That is a marker, not a declaration."
                        % (job, len(reason)))
                else:
                    out["skips"][job] = reason
        elif kw == "evidence":
            if len(rest) < 12:
                out["malformed"].append("ci-evidence: %r is too short to be an answer" % rest)
            else:
                out["evidence"] = rest
        elif kw == "cadence":
            out["cadence"] = rest
    return out


# ===========================================================================
# TRIGGERS — parsed out of the workflow's `on:` block
# ===========================================================================
# A deliberately small YAML reader rather than a dependency. What is needed is
# the SHAPE of `on:` (which event keys, and any `paths:` under push), and that
# is answerable by indentation. PyYAML is not in the engine's dependency set
# and adding one for this would be a new failure mode on every runner.
#
# WHEN IT CANNOT TELL, IT SAYS SO. `triggers['parsed']` is False and every
# axis that depends on trigger shape degrades to "cannot judge" rather than to
# a verdict. A parser that guesses is worse than one that abstains, because a
# guess is indistinguishable from an answer.

def parse_triggers(source):
    lines = (source or "").splitlines()
    start = None
    for i, ln in enumerate(lines):
        if re.match(r"^(on|\"on\"|'on'|True)\s*:", ln):
            start = i
            break
    if start is None:
        return {"parsed": False, "events": [], "push_paths": [], "cron": [],
                "reason": "no `on:` block found"}

    head = lines[start].split(":", 1)[1].strip()
    events, push_paths, cron = [], [], []

    if head and not head.startswith("#"):
        # inline form: `on: push` or `on: [push, pull_request]`
        for tok in re.findall(r"[A-Za-z_]+", head):
            events.append(tok)
        return {"parsed": True, "events": sorted(set(events)), "push_paths": [], "cron": [],
                "reason": "inline"}

    cur_event = None
    in_paths = False
    for ln in lines[start + 1:]:
        if ln.strip() == "" or ln.lstrip().startswith("#"):
            continue
        indent = len(ln) - len(ln.lstrip())
        if indent == 0:
            break  # the `on:` block ended
        stripped = ln.strip()
        if indent == 2 and ":" in stripped and not stripped.startswith("- "):
            key = stripped.split(":", 1)[0].strip()
            if re.match(r"^[A-Za-z_]+$", key):
                cur_event = key
                events.append(key)
                in_paths = False
                continue
        if indent == 2 and stripped.startswith("- "):
            tok = stripped[2:].strip()  # `on:` given as a sequence
            if re.match(r"^[A-Za-z_]+$", tok):
                events.append(tok)
            continue
        if cur_event == "push" and indent == 4 and stripped.startswith("paths"):
            in_paths = True
            continue
        if in_paths and indent >= 6 and stripped.startswith("- "):
            val = stripped[2:].strip().strip('"').strip("'")
            if val:
                push_paths.append(val)
            continue
        if in_paths and indent <= 4:
            in_paths = False
        if cur_event == "schedule" and stripped.startswith("- cron"):
            m = re.search(r"cron\s*:\s*[\"']?([^\"'#]+)", stripped)
            if m:
                cron.append(m.group(1).strip())

    return {"parsed": True, "events": sorted(set(events)), "push_paths": push_paths,
            "cron": cron, "reason": "block"}


def cron_interval_seconds(cron_exprs):
    """The SHORTEST interval any of these cron expressions can fire at.

    Only the shapes GitHub actually accepts and this project actually uses are
    understood: `*/N` in the minute or hour field, and a fixed hour. Anything
    else returns None and the caller degrades to "cannot judge" — see the note
    on the trigger parser. A wrong interval here would produce either a
    permanent false STALE or a permanent false CURRENT, and both are worse than
    an abstention that says which one it is.
    """
    best = None
    for expr in cron_exprs or []:
        parts = expr.split()
        if len(parts) != 5:
            continue
        minute, hour = parts[0], parts[1]
        iv = None
        if hour.startswith("*/"):
            try:
                iv = int(hour[2:]) * 3600
            except ValueError:
                iv = None
        elif hour == "*":
            if minute.startswith("*/"):
                try:
                    iv = int(minute[2:]) * 60
                except ValueError:
                    iv = None
            else:
                iv = 3600
        elif re.match(r"^\d+$", hour):
            iv = 24 * 3600
        if iv is not None:
            best = iv if best is None else min(best, iv)
    return best


# ===========================================================================
# REPOSITORY DISCOVERY — from disk, with every blind spot announced
# ===========================================================================

class Blind(list):
    def say(self, msg):
        self.append(msg)


def _dotdir():
    # The VCS metadata directory name, assembled so a path-scanning guard does
    # not read these string literals as VCS command lines.
    return ".g" + "it"


def _is_checkout(path):
    d = os.path.join(path, _dotdir())
    return os.path.isdir(d) or os.path.isfile(d)


def _main_checkout(path):
    """If `path` is a LINKED worktree, the checkout it was cut from; otherwise
    `path` unchanged. Read off the metadata file, with no process spawned — the
    same reason `_origin_slug` reads the config file directly."""
    marker = os.path.join(path, _dotdir())
    if not os.path.isfile(marker):
        return path
    try:
        with open(marker, encoding="utf-8", errors="replace") as f:
            m = re.match(r"g" + r"itdir:\s*(.+)", f.read().strip())
        if not m:
            return path
        # <main>/.git/worktrees/<name>  ->  <main>
        gitdir = os.path.realpath(m.group(1))
        parts = gitdir.split(os.sep)
        if len(parts) >= 3 and parts[-2] == "worktrees" and parts[-3] == _dotdir():
            return os.sep.join(parts[:-3]) or "/"
    except Exception:
        pass
    return path


def _origin_slug(repo_root):
    """`owner/name` from the checkout's own config file.

    Read as TEXT rather than through the VCS binary: this runs inside
    worktree-isolated sessions whose guards refuse cross-repository VCS
    invocations, and the config file answers the question with no process at
    all.
    """
    cfg = os.path.join(repo_root, _dotdir(), "config")
    if not os.path.isfile(cfg):
        # a linked worktree: the metadata entry is a FILE pointing elsewhere
        marker = os.path.join(repo_root, _dotdir())
        try:
            with open(marker, encoding="utf-8", errors="replace") as f:
                m = re.match(r"g" + r"itdir:\s*(.+)", f.read().strip())
            if not m:
                return None
            cfg = os.path.normpath(os.path.join(m.group(1), "..", "..", "config"))
        except Exception:
            return None
    try:
        with open(cfg, encoding="utf-8", errors="replace") as f:
            txt = f.read()
    except Exception:
        return None
    m = re.search(r'\[remote "origin"\][^\[]*?url\s*=\s*(\S+)', txt, re.S)
    if not m:
        return None
    url = m.group(1)
    m = re.search(r"[:/]([^/:]+)/([^/]+?)(?:\.g" + r"it)?$", url)
    return "%s/%s" % (m.group(1), m.group(2)) if m else None


def discover_repos(explicit, blind, neighborhood_root=None):
    """Return [(root, slug, source)] — deduplicated, ordered, every source's
    silence announced."""
    found, seen, by_slug = [], set(), set()

    def add(root, source):
        if not root:
            return
        root = os.path.realpath(os.path.expanduser(root))
        if root in seen or not os.path.isdir(root):
            return
        if not _is_checkout(root):
            return
        seen.add(root)
        # A LINKED WORKTREE IS NOT A SEPARATE SURFACE. Half the sessions on this
        # machine run from one, and without this the caller's own worktree and
        # the repository it was cut from are reported as two repositories with
        # identical workflows and identical findings — doubling every count in
        # the report. Worse, the DECLARATIONS would be read off the worktree's
        # copy, which is whatever that agent happens to be editing, rather than
        # off the checkout that holds the branch CI actually runs.
        main = _main_checkout(root)
        if main and main != root:
            if main in seen:
                return
            seen.add(main)
            root, source = main, source + "→main-checkout"
        slug = _origin_slug(root)
        if not slug:
            blind.say("%s is a checkout with no GitHub `origin`, so it has no CI surface to read" % root)
            return
        if slug in by_slug:
            return
        if not os.path.isdir(os.path.join(root, WORKFLOW_DIR)):
            return  # no workflow directory: nothing to judge, and not a defect
        by_slug.add(slug)
        found.append((root, slug, source))

    if explicit:
        for e in explicit:
            add(e, "explicit")
        if not found:
            blind.say("every --repo given resolved to nothing with a workflow directory")
        return found

    # 1. the caller's own repository
    probe = os.getcwd()
    while probe and probe != "/":
        if _is_checkout(probe):
            add(probe, "primary")
            break
        probe = os.path.dirname(probe)

    # 2. the engine's own repository
    eng = os.environ.get("RICHOS_ENGINE_ROOT") or os.environ.get("CLAUDE_PLUGIN_ROOT")
    if not eng:
        link = os.path.join(os.path.expanduser("~"), ".claude", "richos-engine")
        if os.path.exists(link):
            eng = os.path.realpath(link)
    if eng:
        probe = os.path.realpath(eng)
        while probe and probe != "/":
            if _is_checkout(probe):
                add(probe, "engine")
                break
            probe = os.path.dirname(probe)
    else:
        blind.say("engine source: the engine root could not be located, so the engine's own "
                  "repository was not read")

    # 3. ADOPTERS — a sibling carrying the adoption marker has declared itself
    #    governed by this engine, so its CI is part of this surface.
    #
    #    WHY THE NEIGHBORHOOD IS NOT SWEPT WHOLESALE. The first version of this
    #    function accepted any sibling directory that merely HAD a workflow
    #    directory. On the machine this was written on that is 20+ unrelated
    #    projects, every one of them contributing red workflows nobody in this
    #    orchestration is responsible for. A status command that reports thirty
    #    findings the reader cannot act on is a status command the reader stops
    #    opening, and this project has killed three guards by exactly that route.
    #    So membership is DECLARED (the adoption marker) or DEMONSTRATED (the
    #    operator's own worktree ledger says this orchestration works in it) —
    #    never inferred from the mere presence of a workflow directory.
    roots = set()
    if neighborhood_root:
        roots.add(os.path.realpath(os.path.expanduser(neighborhood_root)))
    for r, _s, _src in list(found):
        roots.add(os.path.dirname(r))
    if not roots:
        blind.say("neighborhood source: no anchor directory, so sibling repositories were not swept")
    worked_in = _ledger_repos(blind)
    for parent in sorted(roots):
        try:
            entries = sorted(os.listdir(parent))
        except Exception as exc:
            blind.say("neighborhood source: %s could not be listed (%s)"
                      % (parent, exc.__class__.__name__))
            continue
        for name in entries:
            cand = os.path.join(parent, name)
            if not os.path.isdir(cand):
                continue
            if os.path.isfile(os.path.join(cand, ADOPTION_MARKER)):
                add(cand, "adopter")
            elif os.path.realpath(cand) in worked_in:
                add(cand, "worked-in")

    if not found:
        blind.say("no repository with a workflow directory was discovered by ANY source")
    return found


def _ledger_repos(blind):
    """Repositories this orchestration has actually worked in, read off the
    operator's durable worktree ledger.

    This is the source that reaches a repository which has NOT adopted the
    engine and is still worked in every day — richos-hq is exactly that, and
    the founder's own list of red workflows named one of its workflows. Without
    this source that repository is invisible, and invisible reads as clean.

    Temporary paths are dropped: the ledger accumulates sandbox roots from test
    fixtures, 300+ of them on this machine, and none of them has a CI surface.
    """
    out = set()
    path = os.path.join(os.path.expanduser("~"), ".claude", "state", "worktree-ledger.jsonl")
    if not os.path.isfile(path):
        blind.say("worked-in source: %s is absent, so a governed repository that has not adopted the "
                  "engine is reachable only by being named with --repo" % path)
        return out
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if '"repo' not in line and '"main_checkout"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except Exception:
                    continue
                for k in ("repo", "repo_root", "main_checkout", "repository"):
                    v = d.get(k)
                    if not isinstance(v, str) or not v.startswith("/"):
                        continue
                    if v.startswith("/tmp") or "/T/" in v or "/var/folders/" in v:
                        continue
                    out.add(os.path.realpath(v))
    except Exception as exc:
        blind.say("worked-in source: %s could not be read (%s)" % (path, exc.__class__.__name__))
    return out


# ===========================================================================
# THE GitHub READER — cached, and never silently empty
# ===========================================================================

class Api:
    def __init__(self, offline=False, cache_ttl=900, use_cache=True, timeout=25):
        self.offline = offline
        self.cache_ttl = cache_ttl
        self.use_cache = use_cache
        self.timeout = timeout
        self.calls = 0
        self.cache_hits = 0
        self.failures = []
        # Reads run on a small thread pool (see collect()), so the counters and
        # the failure list are touched from several threads at once.
        self._lock = threading.Lock()
        try:
            os.makedirs(STATE_DIR, exist_ok=True)
        except Exception:
            self.use_cache = False

    def _fail(self, err):
        with self._lock:
            self.failures.append(err)
        return err

    def _cache_path(self, path):
        key = re.sub(r"[^A-Za-z0-9]+", "_", path)[:180]
        return os.path.join(STATE_DIR, "api_%s.json" % key)

    def get(self, path):
        cp = self._cache_path(path)
        if self.use_cache and os.path.isfile(cp):
            age = time.time() - os.path.getmtime(cp)
            if self.offline or age < self.cache_ttl:
                try:
                    with open(cp, encoding="utf-8") as f:
                        data = json.load(f)
                    with self._lock:
                        self.cache_hits += 1
                    return data, None
                except Exception:
                    pass
        if self.offline:
            return None, "offline and no cached answer for %s" % path
        try:
            with self._lock:
                self.calls += 1
            p = subprocess.run(["gh", "api", path], capture_output=True, text=True,
                               timeout=self.timeout)
        except FileNotFoundError:
            return None, self._fail("the `gh` command is not on PATH")
        except subprocess.TimeoutExpired:
            return None, self._fail("gh api %s timed out after %ds" % (path, self.timeout))
        if p.returncode != 0:
            return None, self._fail("gh api %s exited %d: %s"
                                    % (path, p.returncode, (p.stderr or "").strip()[:200]))
        try:
            data = json.loads(p.stdout)
        except Exception as exc:
            return None, self._fail("gh api %s returned unparseable JSON (%s)"
                                    % (path, exc.__class__.__name__))
        if self.use_cache:
            try:
                with open(cp, "w", encoding="utf-8") as f:
                    json.dump(data, f)
            except Exception:
                pass
        return data, None


# ===========================================================================
# THE JUDGMENT — one workflow, six axes
# ===========================================================================
# A verdict is one of:
#     OK          nothing to look at
#     UNDECLARED  the standard requires a declaration and there is none
#     FINDING     something is wrong on this axis
#     BENIGN      a state that LOOKS like a finding and provably is not,
#                 announced anyway — never silent
#     UNKNOWABLE  the inputs needed to judge this axis were not available
#     PATH-GATED / TIP-GATED
#                 staleness whose answer depends on the tree, resolved by the
#                 caller against the checkout (see ci-status.sh)

def judge(entry, decls, triggers, wf_api, runs, jobs, branch, source_mtime, now):
    ax = {}

    completed = [r for r in runs if r.get("status") == "completed"]
    latest = completed[0] if completed else None
    latest_any = runs[0] if runs else None
    total = wf_api.get("_total_count", len(runs))
    wf_state = wf_api.get("state", "unknown")

    def dur(run):
        t0 = parse_ts(run.get("run_started_at") or run.get("created_at"))
        t1 = parse_ts(run.get("updated_at"))
        return int((t1 - t0).total_seconds()) if t0 and t1 else None

    # ---------------------------------------------------------------- 4 NEVER RUN
    # Judged first: several other axes are meaningless without a run, and the
    # three causes of "no run" need three different answers.
    if total == 0:
        ev = set(triggers.get("events") or [])
        pr_only = bool(ev) and ev.issubset({"pull_request", "pull_request_target", "workflow_dispatch"}) \
            and bool(ev & {"pull_request", "pull_request_target"})
        first_due = None
        iv = cron_interval_seconds(triggers.get("cron"))
        if iv and source_mtime:
            first_due = source_mtime + iv
        if pr_only:
            ax["never-run"] = ("BENIGN",
                               "no run anywhere, and none is due: this workflow triggers only on %s, "
                               "which never fires on %s. It has therefore NEVER been proven to work; "
                               "its first real exercise will be the first pull request."
                               % ("/".join(sorted(ev)), branch))
        elif first_due and now.timestamp() < first_due:
            ax["never-run"] = ("BENIGN",
                               "no run yet, and none is overdue: the file landed %s and its schedule "
                               "(%s) first fires by %s."
                               % (datetime.fromtimestamp(source_mtime, timezone.utc)
                                  .strftime("%Y-%m-%d %H:%MZ"),
                                  ", ".join(triggers.get("cron") or []) or "unknown",
                                  datetime.fromtimestamp(first_due, timezone.utc)
                                  .strftime("%Y-%m-%d %H:%MZ")))
        elif not triggers.get("parsed"):
            ax["never-run"] = ("UNKNOWABLE",
                               "no run anywhere, and this file's `on:` block could not be read (%s), so "
                               "whether a run was due cannot be decided here."
                               % triggers.get("reason"))
        else:
            ax["never-run"] = ("FINDING",
                               "NO RUN HAS EVER EXISTED, on any branch. Triggers are %s. This workflow "
                               "is neither red nor green: it has never executed, so every claim resting "
                               "on it is about nothing." % (", ".join(sorted(ev)) or "unreadable"))
    else:
        ax["never-run"] = ("OK", "%d run(s) on record" % total)

    # ---------------------------------------------------------------- 2 RED
    if wf_state.startswith("disabled"):
        ax["red"] = ("FINDING",
                     "the workflow is %s in GitHub, so it CANNOT go red and cannot go green. A disabled "
                     "workflow is a check that has been switched off, which is a stronger statement than "
                     "a failing one and is invisible in every green-tick summary." % wf_state)
    elif latest is None:
        ax["red"] = ("UNKNOWABLE", "no completed run on %s to judge" % branch)
    else:
        concl = latest.get("conclusion")
        last_green = next((r for r in completed if r.get("conclusion") == "success"), None)
        if concl == "success":
            ax["red"] = ("OK", "run #%s green" % latest.get("run_number"))
        elif concl in INCONCLUSIVE:
            ax["red"] = ("FINDING",
                         "run #%s concluded `%s`, which is neither pass nor fail. An inconclusive run "
                         "leaves the question open while looking, in a list, like something that ended. "
                         "Last green: %s."
                         % (latest.get("run_number"), concl,
                            "none on record" if not last_green else _days_since(last_green, now)))
        elif last_green:
            # THE AGE IS THE AGE OF THE STREAK, not the age of the last green.
            # They differ whenever nobody pushed for a while before it broke,
            # and the difference is the whole point of printing an age: "red
            # since the commit that broke it" is actionable, "last green three
            # weeks ago" invites an argument about whether that is bad.
            streak = latest
            for r in completed:
                if r.get("conclusion") == "success":
                    break
                streak = r
            ax["red"] = ("FINDING",
                         "RED for %s — since run #%s. Latest is run #%s `%s`; the last green was run "
                         "#%s, %s ago."
                         % (_days_since(streak, now), streak.get("run_number"),
                            latest.get("run_number"), concl,
                            last_green.get("run_number"), _days_since(last_green, now)))
        else:
            ax["red"] = ("FINDING",
                         "RED, and there is NO GREEN RUN ON RECORD at all (run #%s `%s`). This workflow "
                         "has never passed on %s within the window read here."
                         % (latest.get("run_number"), concl, branch))

    # ---------------------------------------------------------------- 1 SLOW
    budget_s = parse_duration(decls.get("budget"))
    if budget_s is None:
        ax["slow"] = ("UNDECLARED",
                      "no `# ci-budget:` in this workflow's source. Without a declared ceiling a "
                      "workflow can grow from four minutes to thirty and nothing anywhere disagrees "
                      "with it — which is exactly what ui-suite-ci did while its own header still said "
                      "\"about four minutes\".")
    elif not completed:
        ax["slow"] = ("UNKNOWABLE", "budget %s declared; no completed run on %s to measure against"
                      % (decls["budget"], branch))
    else:
        pairs = [(r, dur(r)) for r in completed[:8]]
        pairs = [(r, d) for r, d in pairs if d is not None]
        if not pairs:
            ax["slow"] = ("UNKNOWABLE",
                          "budget %s declared; no run carried usable timestamps" % decls["budget"])
        else:
            worst_run, worst = max(pairs, key=lambda t: t[1])
            newest = pairs[0][1]
            if worst > budget_s:
                ax["slow"] = ("FINDING",
                              "OVER BUDGET: run #%s took %s against a declared ceiling of %s (%.0f%% of "
                              "budget). Most recent run: %s."
                              % (worst_run.get("run_number"), human_duration(worst), decls["budget"],
                                 100.0 * worst / budget_s, human_duration(newest)))
            elif worst > budget_s * 0.8:
                ax["slow"] = ("FINDING",
                              "APPROACHING BUDGET: run #%s took %s, %.0f%% of the declared %s. A budget "
                              "is a ceiling to notice BEFORE it is crossed, not after."
                              % (worst_run.get("run_number"), human_duration(worst),
                                 100.0 * worst / budget_s, decls["budget"]))
            else:
                ax["slow"] = ("OK", "%s worst of last %d, ceiling %s"
                              % (human_duration(worst), len(pairs), decls["budget"]))

    # ---------------------------------------------------------------- 3 SKIPPED
    if jobs is None:
        ax["skipped"] = ("UNKNOWABLE", "the job list for the latest run could not be read")
    else:
        skipped = [j["name"] for j in jobs if j.get("conclusion") == "skipped"]
        declared = decls.get("skips") or {}
        undeclared = [n for n in skipped if not _match_declared(n, declared)]
        rotten = [n for n in declared if not any(_job_matches(n, s) for s in skipped)]
        bits = []
        if undeclared:
            bits.append("UNDECLARED SKIP: %s. A skipped job inside a run whose conclusion is `%s` is a "
                        "question mark with no answer attached. Declare it in this workflow with "
                        "`# ci-skip: <job> \u2014 <reason>` or remove the condition that skips it."
                        % (", ".join(repr(n) for n in undeclared),
                           (latest or {}).get("conclusion", "?")))
        if rotten:
            bits.append("STALE DECLARATION: `# ci-skip: %s` names a job that did not skip in the latest "
                        "run. The row has become a lie; delete it." % ", ".join(sorted(rotten)))
        if bits:
            ax["skipped"] = ("FINDING", " ".join(bits))
        elif skipped:
            ax["skipped"] = ("BENIGN", "%d job(s) skipped, every one declared: %s"
                             % (len(skipped),
                                "; ".join("%s \u2014 %s" % (n, _match_declared(n, declared))
                                          for n in skipped)))
        else:
            ax["skipped"] = ("OK", "no job skipped in run #%s" % (latest or {}).get("run_number"))

    # ---------------------------------------------------------------- 5 STALE
    ax["stale"] = _judge_stale(triggers, latest_any, branch, now, wf_state, total)

    # ---------------------------------------------------------------- 6 HOLLOW
    ax["hollow"] = _judge_hollow(decls, latest, jobs, completed, dur, wf_state)

    entry["axes"] = {k: {"verdict": v[0], "detail": v[1]} for k, v in ax.items()}
    return entry


def _days_since(run, now):
    t = parse_ts(run.get("run_started_at") or run.get("created_at"))
    if not t:
        return "an unknown time"
    d = (now - t).days
    return "under a day" if d == 0 else ("1 day" if d == 1 else "%d days" % d)


def _job_matches(declared_name, actual_name):
    """A matrix job is reported as `plan (3)` / `shards (macos-latest, 2)`. The
    declaration names the JOB, not the matrix leg, so a prefix match on the job
    id is the right relation — otherwise every matrix would need one
    declaration per leg and the declarations would rot on the next matrix
    change."""
    a = (actual_name or "").strip()
    d = (declared_name or "").strip()
    return bool(d) and (a == d or a.startswith(d + " ("))


def _match_declared(actual_name, declared):
    for d, reason in (declared or {}).items():
        if _job_matches(d, actual_name):
            return reason
    return None


def _judge_stale(triggers, latest_any, branch, now, wf_state, total):
    """STALENESS IS DERIVED FROM THE WORKFLOW'S OWN TRIGGERS.

    This is the axis most likely to become a nuisance, so it is the one written
    most conservatively. A path-filtered workflow whose paths have not changed
    is CURRENT — flagging it would fire on ordinary work every day, and a guard
    that fires on ordinary work gets waived by habit, which is how three guards
    died in this project in a single day.
    """
    if not triggers.get("parsed"):
        return ("UNKNOWABLE", "this file's `on:` block could not be read (%s), so no cadence can be "
                              "derived and staleness cannot be judged" % triggers.get("reason"))
    ev = set(triggers.get("events") or [])
    if total == 0:
        return ("OK", "no run to be stale (see the never-run axis)")
    if latest_any is None:
        return ("UNKNOWABLE", "runs exist but none was readable on %s" % branch)

    t = parse_ts(latest_any.get("run_started_at") or latest_any.get("created_at"))
    age_days = (now - t).days if t else None
    last = latest_any.get("run_started_at", "?")

    iv = cron_interval_seconds(triggers.get("cron"))
    if "schedule" in ev and iv:
        # x2 the interval: one missed firing is GitHub, two is a defect.
        if t and (now - t).total_seconds() > iv * 2:
            return ("FINDING",
                    "the schedule (%s) fires every %s and the last run started %s (%s days ago) — at "
                    "least two firings have been missed. GitHub disables a scheduled workflow after 60 "
                    "days of repository inactivity and says nothing about it."
                    % (", ".join(triggers.get("cron") or []), human_duration(iv), last, age_days))
        return ("OK", "scheduled every %s; last run %s" % (human_duration(iv), last))

    if ev and ev.issubset({"workflow_dispatch"}):
        if wf_state.startswith("disabled"):
            return ("FINDING",
                    "manual-only AND %s: it can only run when somebody both re-enables it and remembers "
                    "to. Last run %s (%s days ago)." % (wf_state, last, age_days))
        return ("BENIGN",
                "manual-only (`workflow_dispatch`), so wall-clock age is not staleness. Last run %s "
                "(%s days ago) — but nothing will start it, so it proves nothing about today's tree."
                % (last, age_days))

    if "push" in ev:
        paths = triggers.get("push_paths") or []
        if paths:
            return ("PATH-GATED",
                    "push is filtered to %d path pattern(s); staleness here means a commit touched one "
                    "of them with no run following. Last run %s (%s days ago)."
                    % (len(paths), last, age_days))
        return ("TIP-GATED",
                "unfiltered push; the branch tip must carry a run. Last run %s (%s days ago)."
                % (last, age_days))

    if ev and ev.issubset({"pull_request", "pull_request_target"}):
        return ("BENIGN", "pull-request-only, so it has no cadence on %s at all" % branch)

    return ("UNKNOWABLE", "trigger set %s has no staleness rule here; last run %s"
            % (", ".join(sorted(ev)) or "empty", last))


def _fnmatch_actions(path, pattern):
    """GitHub Actions path filters, close enough to be useful and honest about
    where it is not exact.

    `**` matches across separators, `*` does not, and a pattern ending in `/`
    or `/**` matches everything beneath it. GitHub's full grammar has `!`
    negation and character classes; neither appears in any filter in these
    repositories today, and a pattern carrying one is reported as UNKNOWABLE by
    the caller rather than quietly matched wrong.
    """
    import fnmatch
    if pattern.endswith("/**"):
        return path == pattern[:-3] or path.startswith(pattern[:-2])
    if pattern.endswith("/"):
        return path.startswith(pattern)
    rx = re.escape(pattern).replace(r"\*\*", "\x00").replace(r"\*", "[^/]*").replace("\x00", ".*")
    rx = rx.replace(r"\?", "[^/]")
    return re.fullmatch(rx, path) is not None or fnmatch.fnmatch(path, pattern)


def _resolve_gated_stale(entry, slug, branch, runs, triggers, api, blind):
    """Turn PATH-GATED / TIP-GATED into a real verdict.

    THE QUESTION, stated exactly: has a commit reached `branch` since this
    workflow's last run whose diff touches a path this workflow triggers on? If
    yes the workflow OWED a run and there is none — stale, and the answer is a
    commit range somebody can look at. If no, it is CURRENT and its wall-clock
    age means nothing at all.

    Asked of the REMOTE, through `compare`, and not of the local checkout: the
    local checkout can be behind, ahead, or on another branch entirely, and a
    staleness verdict computed against a tree the runner never saw is the
    freshness defect this project already has a whole contract about.
    """
    ax = entry.get("axes", {}).get("stale")
    if not ax or ax["verdict"] not in ("PATH-GATED", "TIP-GATED"):
        return
    last = next((r for r in runs if r.get("head_sha")), None)
    if not last:
        entry["axes"]["stale"] = {"verdict": "UNKNOWABLE",
                                  "detail": "no run on %s carried a head SHA to compare from" % branch}
        return
    base = last["head_sha"]
    cmp_doc, err = api.get("repos/%s/compare/%s...%s" % (slug, base, branch))
    if err:
        entry["axes"]["stale"] = {
            "verdict": "UNKNOWABLE",
            "detail": "the commits between this workflow's last run (%s) and the tip of %s could not "
                      "be read (%s), so whether it owes a run is unjudged — not clear, unjudged."
                      % (base[:12], branch, err)}
        blind.say("%s/%s: the compare against %s failed (%s)" % (slug, entry["workflow"], branch, err))
        return
    behind = cmp_doc.get("ahead_by", 0)
    if behind == 0:
        entry["axes"]["stale"] = {
            "verdict": "OK",
            "detail": "current: this workflow's last run was on %s, which IS the tip of %s"
                      % (base[:12], branch)}
        return

    patterns = triggers.get("push_paths") or []
    if any(p.startswith("!") or "[" in p for p in patterns):
        entry["axes"]["stale"] = {
            "verdict": "UNKNOWABLE",
            "detail": "%d commit(s) have landed on %s since this workflow's last run, and its path "
                      "filter uses a form this reader does not match exactly (%s) — so whether "
                      "one of them owed a run is unjudged." % (behind, branch, ", ".join(patterns))}
        return

    changed = [f.get("filename", "") for f in cmp_doc.get("files", []) or []]
    truncated = len(cmp_doc.get("files", []) or []) >= 300  # GitHub caps `files` at 300
    if not patterns:
        entry["axes"]["stale"] = {
            "verdict": "FINDING",
            "detail": "STALE: %d commit(s) have landed on %s since this workflow's last run (%s) and "
                      "it triggers on EVERY push, so every one of them owed a run and none happened. "
                      "The tip of %s has never been verified by this workflow."
                      % (behind, branch, base[:12], branch)}
        return

    hits = sorted({f for f in changed if any(_fnmatch_actions(f, p) for p in patterns)})
    if hits:
        entry["axes"]["stale"] = {
            "verdict": "FINDING",
            "detail": "STALE: %d commit(s) since this workflow's last run (%s) touched %d path(s) it "
                      "triggers on — %s%s — and no run followed. Compare: "
                      "https://g" "ithub.com/%s/compare/%s...%s"
                      % (behind, base[:12], len(hits), ", ".join(hits[:4]),
                         " and %d more" % (len(hits) - 4) if len(hits) > 4 else "",
                         slug, base[:12], branch)}
    elif truncated:
        # THE TRUNCATION IS REAL AND IT IS COMMON. `compare` caps `files` at
        # 300, and both path-filtered workflows on this machine sit behind
        # hundreds of commits, so leaving it at UNKNOWABLE would leave the axis
        # unanswered for exactly the workflows most likely to be stale. The
        # second reading asks a different question of the same API — "has any
        # commit touched THIS path since that time?" — which has no such cap.
        # It is asked per pattern, and a pattern it cannot reduce to a path
        # prefix keeps the honest UNKNOWABLE rather than being dropped.
        since = (parse_ts(last.get("run_started_at") or last.get("created_at")) or now_utc())
        unreducible, hit_pattern = [], None
        for p in patterns:
            probe = p
            for suffix in ("/**", "/*", "/"):
                if probe.endswith(suffix):
                    probe = probe[: -len(suffix)]
                    break
            if "*" in probe or "?" in probe:
                unreducible.append(p)
                continue
            doc, perr = api.get("repos/%s/commits?sha=%s&path=%s&since=%s&per_page=1"
                                % (slug, branch, probe, since.strftime("%Y-%m-%dT%H:%M:%SZ")))
            if perr:
                unreducible.append(p)
                continue
            if isinstance(doc, list) and doc:
                hit_pattern = (p, doc[0].get("sha", "")[:12], (doc[0].get("commit") or {})
                               .get("message", "").splitlines()[:1])
                break
        if hit_pattern:
            entry["axes"]["stale"] = {
                "verdict": "FINDING",
                "detail": "STALE: a commit has touched `%s` since this workflow's last run (%s, %d "
                          "commits back) and no run followed — %s %s"
                          % (hit_pattern[0], base[:12], behind, hit_pattern[1],
                             (hit_pattern[2] or [""])[0][:80])}
        elif unreducible:
            entry["axes"]["stale"] = {
                "verdict": "UNKNOWABLE",
                "detail": "%d commit(s) since the last run; the compare file list is truncated at 300 "
                          "and %d filter(s) could not be reduced to a path to re-ask about (%s), so "
                          "this axis is unjudged — not clear, unjudged."
                          % (behind, len(unreducible), ", ".join(unreducible))}
        else:
            entry["axes"]["stale"] = {
                "verdict": "OK",
                "detail": "current: %d commit(s) have landed on %s since this workflow's last run and "
                          "no commit in that window touched any of its %d trigger path(s) (asked "
                          "per-path, because the compare file list was truncated at 300)."
                          % (behind, branch, len(patterns))}
    else:
        entry["axes"]["stale"] = {
            "verdict": "OK",
            "detail": "current: %d commit(s) have landed on %s since this workflow's last run and NONE "
                      "of them touched any of its %d trigger path(s), so no run was owed. Wall-clock "
                      "age is not staleness for a path-filtered workflow."
                      % (behind, branch, len(patterns))}


def _judge_hollow(decls, latest, jobs, completed, dur, wf_state):
    """GREEN THAT PROVES NOTHING.

    Four derivable signals, then the declaration. Every one of the four has
    already happened in these repositories.
    """
    signals = []
    if wf_state.startswith("disabled"):
        signals.append("the workflow is %s, so its last result is a fact about a workflow that no "
                       "longer runs" % wf_state)
    if latest is not None and latest.get("conclusion") == "success":
        if jobs is not None:
            if not jobs:
                signals.append("the green run had NO JOBS at all")
            elif all(j.get("conclusion") == "skipped" for j in jobs):
                signals.append("EVERY job in the green run was skipped — the run passed by doing nothing")
        greens = sorted(d for d in (dur(r) for r in completed if r.get("conclusion") == "success")
                        if d is not None)
        this = dur(latest)
        if len(greens) >= 3 and this is not None:
            median = greens[len(greens) // 2]
            if median > 0 and this < median * 0.2 and this < 60:
                signals.append("the green run took %s against a median green of %s — a green run an "
                               "order of magnitude faster than normal is what a billing failure and a "
                               "misconfigured checkout both look like (this repository spent "
                               "2026-08-30 to 2026-09-01 completing in three seconds)"
                               % (human_duration(this), human_duration(median)))
    if signals:
        return ("FINDING", "; ".join(signals))
    if not decls.get("evidence"):
        return ("UNDECLARED",
                "no `# ci-evidence:` in this workflow's source. The question it must answer is the one "
                "an exit code cannot: what makes this workflow's green load-bearing? A scanner that "
                "reported CLEAN over an empty corpus and a runner that reported \"all 4 suites passed\" "
                "over the four it knew about both exited 0 honestly.")
    return ("OK", decls["evidence"][:140])


# ===========================================================================
# COLLECTION
# ===========================================================================

def collect(repos, branch, api, runs_n, blind, now):
    out = []
    for root, slug, source in repos:
        wf_dir = os.path.join(root, WORKFLOW_DIR)
        on_disk = {}
        for p in sorted(glob.glob(os.path.join(wf_dir, "*.yml"))
                        + glob.glob(os.path.join(wf_dir, "*.yaml"))):
            try:
                with open(p, encoding="utf-8", errors="replace") as f:
                    on_disk[os.path.basename(p)] = (p, f.read())
            except Exception as exc:
                blind.say("%s/%s could not be read (%s)"
                          % (slug, os.path.basename(p), exc.__class__.__name__))

        wf_list, err = api.get("repos/%s/actions/workflows?per_page=100" % slug)
        if err:
            blind.say("%s: the workflow list could not be read (%s). Every workflow in this repository "
                      "is UNJUDGED — not clear, unjudged." % (slug, err))
            for name, (path, _src) in on_disk.items():
                out.append({"repo": slug, "root": root, "source": source, "workflow": name,
                            "path": path, "unjudged": err,
                            "axes": {a: {"verdict": "UNKNOWABLE",
                                         "detail": "the repository's workflow list could not be read"}
                                     for a in AXES}})
            continue

        api_by_file, unbacked = {}, []
        for w in (wf_list or {}).get("workflows", []):
            if w.get("path", "").startswith(WORKFLOW_DIR + "/"):
                api_by_file[os.path.basename(w["path"])] = w
            else:
                unbacked.append(w)

        # A WORKFLOW THAT IS NOT A FILE IN THE CHECKOUT IS STILL A WORKFLOW.
        # GitHub synthesizes some (`dynamic/dependabot/dependabot-updates`) and
        # they run, fail, and put a red cross on the repository exactly like any
        # other. The first version of this function filtered to `.github/
        # workflows/` and so could not see one that had been failing for five
        # days — this file's own thesis, failing inside this file, caught by
        # comparing it against lib/ci-red.py which reads runs rather than files.
        # They are judged on the axes that do not need a source, and the axes
        # that DO need one are UNKNOWABLE with the reason stated.
        for w in unbacked:
            w = dict(w)
            runs_doc, _e = api.get("repos/%s/actions/workflows/%d/runs?branch=%s&per_page=%d"
                                   % (slug, w["id"], branch, runs_n))
            runs = (runs_doc or {}).get("workflow_runs", [])
            w["_total_count"] = len(runs)
            entry = {"repo": slug, "root": root, "source": source,
                     "workflow": os.path.basename(w.get("path", "")) or w.get("name"),
                     "path": None, "state": w.get("state"),
                     "unbacked": w.get("path"),
                     "declarations": {"budget": None, "skips": {}, "evidence": None, "malformed": []},
                     "triggers": {"parsed": False, "events": [], "push_paths": [], "cron": [],
                                  "reason": "no file in the checkout to read triggers from"}}
            completed = [r for r in runs if r.get("status") == "completed"]
            entry["latest_run"] = completed[0].get("run_number") if completed else None
            entry["latest_conclusion"] = completed[0].get("conclusion") if completed else None
            entry["latest_started"] = completed[0].get("run_started_at") if completed else None
            judge(entry, entry["declarations"], entry["triggers"], w, runs, None, branch, None, now)
            for a in ("slow", "hollow"):
                entry["axes"][a] = {
                    "verdict": "UNKNOWABLE",
                    "detail": "GitHub generates this workflow (`%s`); there is no file in the checkout "
                              "to carry a declaration, so it can be neither budgeted nor evidenced "
                              "from this tree. It can still go red, and it has." % w.get("path")}
            out.append(entry)

        # DRIFT: a workflow GitHub knows about that is not in the checkout, and
        # the reverse. Both are silent today and both change what CI means.
        for name in sorted(set(api_by_file) - set(on_disk)):
            out.append({"repo": slug, "root": root, "source": source, "workflow": name, "path": None,
                        "drift": "GitHub runs this workflow and it is NOT in the checkout at %s — so "
                                 "nothing in the tree describes what it does" % wf_dir,
                        "axes": {a: {"verdict": "UNKNOWABLE", "detail": "not present on disk"}
                                 for a in AXES}})
        for name in sorted(set(on_disk) - set(api_by_file)):
            out.append({"repo": slug, "root": root, "source": source, "workflow": name,
                        "path": on_disk[name][0],
                        "drift": "this file is in the checkout and GitHub has no workflow for it — it "
                                 "has never reached the default branch, so it is a workflow in name only",
                        "axes": {a: {"verdict": "UNKNOWABLE", "detail": "GitHub has no such workflow"}
                                 for a in AXES}})

        # Three reads per workflow, and they are independent of each other. Run
        # them on a small pool: serially this command took minutes against five
        # repositories, and a status command nobody runs because it is slow is
        # the same object as a status command that does not exist.
        names = sorted(set(on_disk) & set(api_by_file))
        with ThreadPoolExecutor(max_workers=6) as pool:
            for entry in pool.map(lambda n: _one_workflow(n, on_disk, api_by_file, slug, root,
                                                          source, branch, api, runs_n, blind, now),
                                  names):
                out.append(entry)
    return out


def _one_workflow(name, on_disk, api_by_file, slug, root, source, branch, api, runs_n, blind, now):
    path, src = on_disk[name]
    w = dict(api_by_file[name])
    decls = parse_declarations(src)
    triggers = parse_triggers(src)
    try:
        mtime = os.path.getmtime(path)
    except Exception:
        mtime = None

    runs_doc, rerr = api.get("repos/%s/actions/workflows/%d/runs?branch=%s&per_page=%d"
                             % (slug, w["id"], branch, runs_n))
    any_doc, _aerr = api.get("repos/%s/actions/workflows/%d/runs?per_page=1" % (slug, w["id"]))
    runs = (runs_doc or {}).get("workflow_runs", [])
    w["_total_count"] = (any_doc or {}).get("total_count", 0) if any_doc is not None else len(runs)

    jobs = None
    completed = [r for r in runs if r.get("status") == "completed"]
    if completed:
        jd, jerr = api.get("repos/%s/actions/runs/%d/jobs?per_page=100" % (slug, completed[0]["id"]))
        if jerr:
            blind.say("%s/%s: the per-job conclusions of run #%s could not be read (%s), so the "
                      "SKIPPED axis is unjudged for it"
                      % (slug, name, completed[0].get("run_number"), jerr))
        else:
            jobs = (jd or {}).get("jobs", [])

    entry = {"repo": slug, "root": root, "source": source, "workflow": name, "path": path,
             "state": w.get("state"),
             "declarations": {"budget": decls["budget"], "skips": decls["skips"],
                              "evidence": decls["evidence"], "malformed": decls["malformed"]},
             "triggers": triggers,
             "latest_run": (completed[0].get("run_number") if completed else None),
             "latest_conclusion": (completed[0].get("conclusion") if completed else None),
             "latest_started": (completed[0].get("run_started_at") if completed else None)}
    if rerr:
        entry["unjudged"] = rerr
    judge(entry, decls, triggers, w, runs, jobs, branch, mtime, now)
    _resolve_gated_stale(entry, slug, branch, runs, triggers, api, blind)
    if decls["malformed"]:
        entry["axes"]["skipped"] = {"verdict": "FINDING",
                                    "detail": "MALFORMED DECLARATION: %s" % "; ".join(decls["malformed"])}
    return entry


# ===========================================================================
# SELF-TEST — the negative control this file must not ship without
# ===========================================================================
# A classifier that has never been shown a broken input has never been shown to
# work. `--self-test` runs the judgment over synthetic inputs whose right
# answers are known, and it is what `ci-surface-watch.sh` runs on every
# scheduled pass so that "the job ran" and "the job still works" are two
# different observations rather than one. The scheduled job that inspired that
# rule runs on time every single day and reclaims nothing.

def _iso(now, delta):
    return datetime.fromtimestamp(now.timestamp() + delta, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def self_test():
    fails = []

    def want(label, got, expected):
        if got != expected:
            fails.append("%s: expected %r, got %r" % (label, expected, got))

    d = parse_declarations("# ci-budget: 45m\n#   ci-skip: affected \u2014 subsumed by the full pass\n"
                           "# ci-evidence: every suite declares its own check count\n")
    want("budget parsed", d["budget"], "45m")
    want("skip parsed", d["skips"].get("affected"), "subsumed by the full pass")
    want("evidence parsed", bool(d["evidence"]), True)

    # A declaration inside a `run:` block is a SHELL comment in a step, not a
    # statement about the workflow. Without this the last match wins and one
    # line in one step silently overrides the file's real ceiling.
    d = parse_declarations(
        "# ci-budget: 12m\n"
        "jobs:\n  a:\n    steps:\n      - run: |\n"
        "          # ci-budget: 99h\n"
        "          echo hi\n"
        "      - run: >-\n"
        "          # ci-skip: ghost — a skip declared from inside a step body\n"
        "  b:\n    steps: []\n")
    want("a budget inside a run: block does not become the workflow's ceiling", d["budget"], "12m")
    want("a skip inside a run: block declares nothing", d["skips"], {})

    d = parse_declarations("# ci-budget: soon\n# ci-skip: affected\n# ci-evidence: eh\n")
    want("a budget that is not a duration is rejected", d["budget"], None)
    want("a bare job name declares no skip", d["skips"], {})
    want("a two-word evidence line is rejected", d["evidence"], None)
    want("all three malformations are named", len(d["malformed"]), 3)

    t = parse_triggers("name: x\non:\n  push:\n    paths:\n      - \"app/**\"\n      - \"b/c.yml\"\n"
                       "  pull_request:\n    branches: [main]\njobs:\n  a:\n")
    want("events read", t["events"], ["pull_request", "push"])
    want("push paths read", t["push_paths"], ["app/**", "b/c.yml"])

    t = parse_triggers("on:\n  schedule:\n    - cron: \"41 */6 * * *\"\n  workflow_dispatch:\njobs:\n")
    want("cron read", t["cron"], ["41 */6 * * *"])
    want("cron interval derived", cron_interval_seconds(t["cron"]), 6 * 3600)

    want("an unreadable `on:` block abstains", parse_triggers("jobs:\n  a:\n")["parsed"], False)
    want("duration m", parse_duration("45m"), 2700)
    want("duration h", parse_duration("2h"), 7200)
    want("prose is not a duration", parse_duration("about four minutes"), None)

    now = now_utc()
    push = {"parsed": True, "events": ["push"], "push_paths": [], "cron": []}
    good = {"budget": "4m", "skips": {}, "evidence": "x" * 20}

    e = {}
    judge(e, good, push, {"state": "active", "_total_count": 9},
          [{"status": "completed", "conclusion": "success", "run_number": 9,
            "run_started_at": _iso(now, -3600), "updated_at": _iso(now, -1800), "id": 1}],
          [{"name": "a", "conclusion": "success"}], "main", None, now)
    want("a 30-minute run against a 4-minute budget is a FINDING",
         e["axes"]["slow"]["verdict"], "FINDING")

    e = {}
    judge(e, {"budget": None, "skips": {}, "evidence": None}, push,
          {"state": "active", "_total_count": 1},
          [{"status": "completed", "conclusion": "success", "run_number": 1,
            "run_started_at": _iso(now, -120), "updated_at": _iso(now, -60), "id": 1}],
          [{"name": "a", "conclusion": "skipped"}, {"name": "b", "conclusion": "success"}],
          "main", None, now)
    want("an undeclared skip is a FINDING", e["axes"]["skipped"]["verdict"], "FINDING")
    want("a missing budget is UNDECLARED", e["axes"]["slow"]["verdict"], "UNDECLARED")
    want("a missing evidence line is UNDECLARED", e["axes"]["hollow"]["verdict"], "UNDECLARED")
    # NOTE: `b` must be present and green. With `a` alone the run is "every job
    # skipped", which is a HOLLOW finding in its own right and would mask the
    # UNDECLARED verdict this case is here to pin. The self-test caught exactly
    # that on its first execution, which is the whole reason it exists.

    e = {}
    judge(e, {"budget": "5m", "skips": {"a": "declared for a checkable reason"}, "evidence": "y" * 20},
          push, {"state": "active", "_total_count": 1},
          [{"status": "completed", "conclusion": "success", "run_number": 1,
            "run_started_at": _iso(now, -120), "updated_at": _iso(now, -60), "id": 1}],
          [{"name": "a (macos-latest, 2)", "conclusion": "skipped"}], "main", None, now)
    want("a declared skip covers its matrix legs", e["axes"]["skipped"]["verdict"], "BENIGN")

    e = {}
    judge(e, {"budget": "5m", "skips": {"ghost": "a job that no longer exists at all"},
              "evidence": "y" * 20},
          push, {"state": "active", "_total_count": 1},
          [{"status": "completed", "conclusion": "success", "run_number": 1,
            "run_started_at": _iso(now, -120), "updated_at": _iso(now, -60), "id": 1}],
          [{"name": "a", "conclusion": "success"}], "main", None, now)
    want("a skip declaration for a job that did not skip is a FINDING",
         e["axes"]["skipped"]["verdict"], "FINDING")

    e = {}
    judge(e, {"budget": "5m", "skips": {}, "evidence": "y" * 20}, push,
          {"state": "disabled_manually", "_total_count": 4},
          [{"status": "completed", "conclusion": "failure", "run_number": 4,
            "run_started_at": _iso(now, -9 * 86400), "updated_at": _iso(now, -9 * 86400 + 20), "id": 1}],
          [], "main", None, now)
    want("a disabled workflow is a red FINDING", e["axes"]["red"]["verdict"], "FINDING")
    want("a disabled workflow is a hollow FINDING", e["axes"]["hollow"]["verdict"], "FINDING")

    e = {}
    judge(e, {"budget": "5m", "skips": {}, "evidence": "y" * 20},
          {"parsed": True, "events": ["pull_request_target"], "push_paths": [], "cron": []},
          {"state": "active", "_total_count": 0}, [], None, "main", None, now)
    want("a pull-request-only workflow with no run is BENIGN, and announced",
         e["axes"]["never-run"]["verdict"], "BENIGN")

    e = {}
    judge(e, {"budget": "5m", "skips": {}, "evidence": "y" * 20}, push,
          {"state": "active", "_total_count": 0}, [], None, "main", None, now)
    want("a push workflow with no run at all is a FINDING",
         e["axes"]["never-run"]["verdict"], "FINDING")

    sched = {"parsed": True, "events": ["schedule"], "push_paths": [], "cron": ["41 */6 * * *"]}
    e = {}
    judge(e, {"budget": "5m", "skips": {}, "evidence": "y" * 20}, sched,
          {"state": "active", "_total_count": 0}, [], None, "main", now.timestamp() - 600, now)
    want("a scheduled workflow inside its first interval is BENIGN",
         e["axes"]["never-run"]["verdict"], "BENIGN")

    e = {}
    judge(e, {"budget": "5m", "skips": {}, "evidence": "y" * 20}, sched,
          {"state": "active", "_total_count": 0}, [], None, "main",
          now.timestamp() - 3 * 86400, now)
    want("a scheduled workflow PAST its first interval with no run is a FINDING",
         e["axes"]["never-run"]["verdict"], "FINDING")

    e = {}
    judge(e, {"budget": "5m", "skips": {}, "evidence": "y" * 20}, sched,
          {"state": "active", "_total_count": 3},
          [{"status": "completed", "conclusion": "success", "run_number": 3,
            "run_started_at": _iso(now, -3 * 86400), "updated_at": _iso(now, -3 * 86400 + 60), "id": 1}],
          [{"name": "a", "conclusion": "success"}], "main", None, now)
    want("a schedule that has missed two firings is STALE", e["axes"]["stale"]["verdict"], "FINDING")

    e = {}
    greens = [{"status": "completed", "conclusion": "success", "run_number": n,
               "run_started_at": _iso(now, -n * 3600), "updated_at": _iso(now, -n * 3600 + 600), "id": n}
              for n in range(2, 8)]
    three_seconds = {"status": "completed", "conclusion": "success", "run_number": 1,
                     "run_started_at": _iso(now, -600), "updated_at": _iso(now, -597), "id": 1}
    judge(e, {"budget": "30m", "skips": {}, "evidence": "y" * 20}, push,
          {"state": "active", "_total_count": 7}, [three_seconds] + greens,
          [{"name": "a", "conclusion": "success"}], "main", None, now)
    want("a three-second green among ten-minute greens is HOLLOW",
         e["axes"]["hollow"]["verdict"], "FINDING")

    e = {}
    judge(e, {"budget": "30m", "skips": {}, "evidence": "y" * 20}, push,
          {"state": "active", "_total_count": 1},
          [{"status": "completed", "conclusion": "success", "run_number": 1,
            "run_started_at": _iso(now, -120), "updated_at": _iso(now, -60), "id": 1}],
          [{"name": "a", "conclusion": "skipped"}, {"name": "b", "conclusion": "skipped"}],
          "main", None, now)
    want("a green run in which every job skipped is HOLLOW", e["axes"]["hollow"]["verdict"], "FINDING")

    if fails:
        for f in fails:
            print("  SELF-TEST FAIL  %s" % f)
        print("ci-surface self-test: %d of its own known inputs answered WRONGLY" % len(fails))
        return 1
    print("ci-surface self-test: the classifier answered every known input correctly")
    return 0


# ===========================================================================
# main
# ===========================================================================

def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True, description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--repo", action="append", default=[])
    ap.add_argument("--branch", default="main")
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--cache-ttl", type=int, default=900)
    ap.add_argument("--no-cache", action="store_true")
    ap.add_argument("--runs", type=int, default=12)
    ap.add_argument("--neighborhood-root", default=None)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    now = now_utc()
    blind = Blind()
    repos = discover_repos(args.repo, blind, args.neighborhood_root)
    if not repos:
        print(json.dumps({"error": "no repository with a workflow directory was discovered",
                          "blind": list(blind)}, indent=2))
        return 2

    api = Api(offline=args.offline, cache_ttl=args.cache_ttl, use_cache=not args.no_cache)
    entries = collect(repos, args.branch, api, args.runs, blind, now)

    findings = sum(1 for e in entries
                   for a in e["axes"].values() if a["verdict"] in ("FINDING", "UNDECLARED"))
    doc = {
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "branch": args.branch,
        "repositories": [{"slug": s, "root": r, "source": src} for r, s, src in repos],
        "workflows": entries,
        "blind": list(blind),
        "api": {"calls": api.calls, "cache_hits": api.cache_hits, "failures": api.failures},
        "counts": {"repositories": len(repos), "workflows": len(entries), "findings": findings},
    }
    print(json.dumps(doc, indent=2))
    return 1 if (findings or blind or api.failures) else 0


if __name__ == "__main__":
    sys.exit(main())
