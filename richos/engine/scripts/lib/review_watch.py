#!/usr/bin/env python3
"""review_watch.py: THE SECOND REVIEW STARTS BY ITSELF, WITH NOBODY ASKING.

===========================================================================
WHAT THIS EXISTS FOR
===========================================================================
On 2026-10-08 the CEO fetched a Codex review of an agent's work by hand four
times, and each one found defects the author's own tests had passed. His words
(ruling §113): "A regular RichOS user can never be expected anything even
remotely close to that. So, this all must be completely automated."

scripts/second-review.sh (slice 1) does one review. This is slice 2 of richos-hq
docs/plans/2026-10-09-automatic-second-review-and-t3-ideas.md (§2.1, §2.4,
§2.5), with Sage's check beside it (...-sage-check.md §2, §4 row 2): the
watcher that starts that command by itself. It is the engine's plugin monitor
`review-watch` (monitors/monitors.json), started by Claude Code with every
interactive session as stall-watch and codex-watch are.

===========================================================================
WHEN A REVIEW STARTS (plan §2.1). Level-triggered: every look compares what
exists (the workspace registry, git, Codex's channel) with what has been
reviewed (the review ledger and the locks). Nothing waits for an event.
===========================================================================
  1. HANDOVER. A teammate's run has ended (the registry's finished_state: its
     SubagentStop, a stop, or its session gone) with commits ahead of its
     base, and no handover verdict exists for its newest commit. A worker that
     dies silently is read from the registry, not from its report, so its
     commits are reviewed anyway. A mid-job verdict does not stand in for the
     handover one: a mid-job reviewer is told to list what is not yet claimed
     instead of reporting it, so it never judged the work as handed over.
  2. A LONG JOB. A teammate still running has commits with no verdict, and 60
     minutes (LONG_JOB_MINUTES, an estimate taken from echo-fable-dict5's run)
     have passed since its clock started. THE CLOCK (Sage §1.2): the
     registry's start for the teammate, then the start of each review of its
     work; where the registry has no start, the moment this watcher first saw
     a commit of it. Never git's commit dates, which an author sets: a
     teammate branched from a day-old main commit is not "long" five minutes
     in.
  3. GONE QUIET. stall-watch's silent-teammate signal (no commit and no
     transcript write for 20 minutes, STALL_WATCH_SILENT_MINUTES) for a
     running teammate with unreviewed commits.
  4. CODEX'S HANDOVER (Sage §2 catch 1). codex/ work never enters the
     registry, so a READY entry in ~/.richos-coordination/rich-codex/to-rich.md
     naming a codex/ branch starts its review (Claude reviews Codex's work;
     second-review decides that from the branch). The original words are the
     to-codex.md entries naming the branch, else the one written just before
     Codex first named it; the READY entry is what the author claims.

THE RANGE IS THE AGENT'S OWN COMMITS: the base is the merge base of the tip and
the integration branch the registry records for the work (workspaces.py
integration_target), passed to second-review explicitly. On 2026-10-09 a run
over richos 2d5aaf844 with a wider range reviewed unrelated main commits.

Only repositories listed in SECOND_REVIEW_REPOS (the governed repository's
orchestration.config) are reviewed; record-only repositories are not (plan §6).

===========================================================================
ONE TIP IS NEVER REVIEWED TWICE AT ONCE (Sage §1.3)
===========================================================================
A file per repository and tip under <state>/locks/, created exclusively, holds
the review's process id and its start time. A watcher's memory is not the
guard, so a second watcher (a twin session, or the lead's own monitor beside a
host child) is harmless. When a handover arrives while a mid-job review of the
same tip runs, that review is stopped by its recorded process id and replaced
by the handover review; nothing else is ever stopped. No cap on how many
reviews run at once: second-review admits each by the engine's CPU rule.

A REVIEW THAT ENDS WITHOUT A VERDICT (crashed, refused, past its own 60-minute
limit, or running past OVERRUN_MINUTES, when it is stopped by its recorded
process id) is started ONCE more; a second loss is told to the lead, once.

===========================================================================
WHAT IS TOLD (plan §2.4, §2.5). Each printed block wakes the lead.
===========================================================================
  * every verdict, once, from the review ledger (second-review's
    reviews.jsonl): what was reviewed, by which model, its findings and what
    the lead can do;
  * a changes-requested handover nobody has acted on (no continuation spawned
    with `continues:`, the work not landed or discarded), again every 30
    minutes (REPEAT_MINUTES);
  * a finding still open through two rechecks in a row ("not converging"),
    once: the lead decides; the CEO is not paged;
  * a second lost review of one commit, once;
  * a Codex handover it could not turn into a review, once.
Starting a review is not told: the verdict is.

It never edits, lands, merges, pauses or messages anything. The only processes
it ever stops are reviews it (or another watcher) started and recorded.

===========================================================================
COMMANDS (review-watch.sh passes --engine-root and --config)
===========================================================================
  --monitor  the plugin monitor's body: one per session, a look every 60 s,
             ends with its session
  --tick     one look, printing what the monitor would print
  --status   one line per running review and the last look's time

Test seams (review-watch.test.sh only): REVIEW_WATCH_STATE_DIR,
REVIEW_WATCH_NOW, REVIEW_WATCH_POLL_SECONDS, REVIEW_WATCH_SECOND_REVIEW,
REVIEW_WATCH_TO_RICH, REVIEW_WATCH_TO_CODEX; second-review's own
SECOND_REVIEW_STATE_DIR places the ledger.
"""

import argparse
import datetime as _dt
import fcntl
import glob
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import stall_watch  # noqa: E402  (sibling: session, lock, JSON and silent-teammate helpers)
import operator_fences as F  # noqa: E402  (sibling: review_repos, the one reader of SECOND_REVIEW_REPOS)

POLL_SECONDS = 60
LONG_JOB_MINUTES = 60
REPEAT_MINUTES = 30
# second-review's own worst case: a 30-minute admission wait, a 60-minute
# Codex run and a 60-minute Claude fallback, with room to spare.
OVERRUN_MINUTES = 160
START_GRACE_SECONDS = 120
MAX_LOSSES = 2
KEEP_SECONDS = 7 * 86400
SESSION_KEEP_SECONDS = 2 * 86400
BLOCK_CHARS = 2000
GIT_SECONDS = 10
CONFIG_KEY = "SECOND_REVIEW_REPOS"
MID_JOB = ("long-job", "quiet")
HANDOVER_KINDS = ("handover", "manual")
DEFAULT_TO_RICH = "~/.richos-coordination/rich-codex/to-rich.md"
DEFAULT_TO_CODEX = "~/.richos-coordination/rich-codex/to-codex.md"
SHA_RE = re.compile(r"\b[0-9a-f]{40}\b")
CODEX_BRANCH_RE = re.compile(r"\bcodex/[A-Za-z0-9._/-]*[A-Za-z0-9_]")


# ---------------------------------------------------------------------------
# small utilities
# ---------------------------------------------------------------------------

def clock():
    raw = (os.environ.get("REVIEW_WATCH_NOW") or "").strip()
    try:
        return float(raw) if raw else time.time()
    except ValueError:
        return time.time()


def hhmm(t):
    return stall_watch.hhmm(t)


def parse_iso(text):
    if not text:
        return None
    try:
        t = str(text)
        if t.endswith("Z"):
            t = t[:-1] + "+00:00"
        return _dt.datetime.fromisoformat(t).timestamp()
    except (TypeError, ValueError):
        return None


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def state_root():
    d = (os.environ.get("REVIEW_WATCH_STATE_DIR") or "").strip()
    if d:
        return d
    base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(base, "state", "review-watch")


def review_ledger():
    """second-review's ledger: the same path its own state_root() gives."""
    d = (os.environ.get("SECOND_REVIEW_STATE_DIR") or "").strip()
    if not d:
        base = (os.environ.get("CLAUDE_CONFIG_DIR") or "").strip() or os.path.join(os.path.expanduser("~"), ".claude")
        d = os.path.join(base, "state")
    return os.path.join(d, "reviews.jsonl")


def _p(*parts):
    return os.path.join(state_root(), *parts)


def read_jsonl(path):
    rows = []
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    rows.append(r)
    except OSError:
        pass
    return rows


def append_jsonl(path, row):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.write(fd, (json.dumps(row, sort_keys=True) + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def git(repo, *args):
    """stdout stripped, or None when git fails."""
    try:
        p = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, timeout=GIT_SECONDS)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def repo_tag(repo):
    return hashlib.sha1(os.path.realpath(repo).encode("utf-8")).hexdigest()[:12]


def configured_repos(config):
    """([repository name], "") from SECOND_REVIEW_REPOS, read by
    F.review_repos, the one reader install and the land check use too, which
    sources the config in a clean bash; (None, "") when the key is absent or
    blank; (None, why) when the config cannot be read or sourced, or its value
    is not names."""
    if not config or not os.path.isfile(config):
        return None, ""
    try:
        with open(config, encoding="utf-8") as f:
            f.read()
    except (OSError, ValueError) as exc:
        return None, "it cannot be read (%s)" % (getattr(exc, "strerror", None) or exc)
    names, why = F.review_repos(config)
    return (names or None), why


# ---------------------------------------------------------------------------
# what could be reviewed
# ---------------------------------------------------------------------------

class Item(object):
    """One piece of work at one tip."""

    def __init__(self, work, name, repo, tip, base, state, started=None, branch="", ref="", quiet=False,
                 continued=False, source="registry", words=(), claims=(), title=""):
        self.work, self.name, self.repo, self.tip, self.base = work, name, repo, tip, base
        self.state, self.started, self.branch, self.ref = state, started, branch, ref
        self.quiet, self.continued, self.source = quiet, continued, source
        self.words, self.claims, self.title = list(words), list(claims), title

    @property
    def key(self):
        return (self.repo, self.tip)

    def args(self, trigger):
        """second-review's arguments for this item."""
        a = ["--repo", self.repo, "--tip", self.tip, "--base", self.base, "--trigger", trigger, "--work", self.work]
        if self.source == "codex":
            a += ["--branch", self.branch, "--author", "codex"]
            for w in self.words:
                a += ["--words-file", w]
            for c in self.claims:
                a += ["--claims-file", c]
        else:
            a = ["--name", self.ref] + a
        return a


class World(object):
    """The real sources: the workspace registry, git and Codex's channel."""

    def __init__(self, engine_root, config):
        self.engine_root = engine_root
        self.config = config
        self.repos, self.repos_error = configured_repos(config)
        self.ws = stall_watch._load("review_watch_workspaces",
                                    os.path.join(engine_root, "mega-lander", "workspaces.py"))
        self.src = stall_watch.Sources(engine_root)
        self._merge_bases = {}

    # -- which repositories ---------------------------------------------------
    def wanted(self, repo):
        return F.review_listed(self.repos, repo)

    def repo_named(self, name):
        try:
            known = self.ws.known_repos() if self.ws else []
        except Exception:  # noqa: BLE001
            known = []
        for k in known:
            if os.path.basename(os.path.realpath(k)) == name:
                return os.path.realpath(k)
        return ""

    # -- git --------------------------------------------------------------------
    def merge_base(self, repo, a, b):
        k = (repo, a, b)
        if k not in self._merge_bases:
            self._merge_bases[k] = git(repo, "merge-base", a, b)
        return self._merge_bases[k]

    def integration_tip(self, chain, repo):
        """(tip, problem): the branch the registry records for this work."""
        ws = self.ws
        try:
            branch, tip, why = ws.integration_target(chain, repo)
            if not tip:
                branch, tip, why2 = ws.integration_for(repo)
                why = why2 or why
        except Exception as exc:  # noqa: BLE001
            tip, why = "", "the integration branch could not be read (%s)" % exc.__class__.__name__
        if tip:
            return tip, ""
        main = git(repo, "rev-parse", "--verify", "-q", "refs/heads/main^{commit}")
        if main:
            return main, ""
        return "", why or "no integration branch is recorded for %s" % repo

    # -- the registry -----------------------------------------------------------
    def registry_items(self, now, seen):
        """(items, problems). seen: {work: first epoch a commit was seen}."""
        ws = self.ws
        if ws is None:
            return [], ["the workspace registry library (mega-lander/workspaces.py) could not be loaded"]
        try:
            recs = ws.all_agents()
        except Exception as exc:  # noqa: BLE001
            return [], ["the workspace registry could not be read (%s)" % exc.__class__.__name__]
        continued = set()
        for r in recs:
            continued.update(r.get("continues") or [])
        items, problems, cache = [], [], {}
        th_silent = stall_watch.thresholds()["silent"]
        for rec in recs:
            if rec.get("disposition"):
                continue
            spaces = [w for w in rec.get("workspaces") or []
                      if w.get("branch") and not w.get("deleted_at") and not w.get("branch_deleted_at")
                      and w.get("repo") and self.wanted(w["repo"])]
            if not spaces:
                continue
            try:
                fin, paused, _why = ws.finished_state(rec, cache)
                chain = ws._chain(rec)
            except Exception:  # noqa: BLE001
                continue
            state = "ended" if fin else ("paused" if paused else "running")
            root = sorted(chain, key=lambda r: str(r.get("registered_at") or ""))[0]
            work = "teammate:%s" % root["key"]
            started = None
            for k in ("started_at", "spawned_at", "registered_at"):
                started = parse_iso(rec.get(k))
                if started is not None:
                    break
            name = str(rec.get("name") or rec["key"])
            for w in spaces:
                repo = os.path.realpath(w["repo"])
                tip = git(repo, "rev-parse", "--verify", "-q", "refs/heads/%s^{commit}" % w["branch"])
                if not tip:
                    continue
                itip, why = self.integration_tip(chain, repo)
                if not itip:
                    problems.append("%s: %s" % (name, why))
                    continue
                base = self.merge_base(repo, itip, tip)
                if not base or base == tip:
                    continue                       # nothing of its own ahead of the integration branch
                seen.setdefault(work, now)
                quiet = False
                if state == "running":
                    marks = [started or seen[work]]
                    c = stall_watch._git_last_commit(w.get("path"))
                    if c and c[0] > marks[0]:
                        marks.append(c[0])
                    t = stall_watch._transcript(self.src, rec)
                    if t:
                        try:
                            marks.append(os.path.getmtime(t))
                        except OSError:
                            pass
                    quiet = now - max(marks) >= th_silent
                items.append(Item(work, name, repo, tip, base, state, started=started, branch=w["branch"],
                                  ref=rec["key"], quiet=quiet, continued=rec["key"] in continued))
        return items, problems

    # -- Codex's handovers --------------------------------------------------------
    def codex_items(self, now, codex_state):
        """(items, problems, notes). codex_state is the shared reading state
        (offset in to-rich.md and the pending handovers), updated in place."""
        to_rich = os.path.expanduser(os.environ.get("REVIEW_WATCH_TO_RICH") or DEFAULT_TO_RICH)
        to_codex = os.path.expanduser(os.environ.get("REVIEW_WATCH_TO_CODEX") or DEFAULT_TO_CODEX)
        problems = []
        pending = codex_state.setdefault("pending", [])
        try:
            st = os.stat(to_rich)
        except OSError:
            st = None
        if st is not None:
            off = codex_state.get("offset")
            if codex_state.get("inode") != st.st_ino or not isinstance(off, int) or off > st.st_size:
                # The first look at this file (or a new file): the backlog is
                # not replayed, as codex-watch does.
                codex_state.update({"inode": st.st_ino, "offset": st.st_size, "seen": st.st_size})
            elif st.st_size > off and st.st_size == codex_state.get("seen"):
                with open(to_rich, "rb") as fh:
                    fh.seek(off)
                    data = fh.read(st.st_size - off)
                end = data.rfind(b"\n") + 1 or len(data)
                text = data[:end].decode("utf-8", "replace")
                codex_state["offset"] = off + end
                for header, body in split_entries(text):
                    got = self.codex_handover(header, body, to_rich, to_codex, now)
                    if isinstance(got, str):
                        problems.append(got)
                    elif got:
                        pending[:] = [p for p in pending if p.get("work") != got["work"] or p.get("tip") == got["tip"]]
                        if not any(p.get("tip") == got["tip"] and p.get("repo") == got["repo"] for p in pending):
                            pending.append(got)
            codex_state["seen"] = st.st_size
        items = []
        keep = []
        for p in pending:
            if now - float(p.get("at") or now) > KEEP_SECONDS:
                continue
            keep.append(p)
            base = self.merge_base_for(p["repo"], p["tip"])
            if not base or base == p["tip"]:
                continue
            items.append(Item(p["work"], "codex", p["repo"], p["tip"], base, "ended", branch=p["branch"],
                              source="codex", words=p.get("words") or [], claims=p.get("claims") or [],
                              title=p.get("title") or ""))
        pending[:] = keep
        return items, problems

    def merge_base_for(self, repo, tip):
        itip, _why = self.integration_tip([], repo)
        return self.merge_base(repo, itip, tip) if itip else None

    def codex_handover(self, header, body, to_rich, to_codex, now):
        """A pending review for a READY entry naming a codex/ branch; a string
        saying why one cannot start; or None for any other entry."""
        if not header or "READY" not in header.upper():
            return None
        text = header + "\n" + body
        m = CODEX_BRANCH_RE.search(header) or CODEX_BRANCH_RE.search(body)
        if not m:
            return None
        branch = m.group(0)
        names = []
        rm = re.search(r"Repositor(?:y|ies):\s*([^\n]+)", text)
        if rm:
            names = [n for n in re.findall(r"[A-Za-z0-9._-]+", rm.group(1))
                     if n in (self.repos or [])]
        if not names and self.repos and len(self.repos) == 1:
            names = [self.repos[0]]
        repo = self.repo_named(names[0]) if names else ""
        if not repo or not self.wanted(repo):
            return None
        cm = re.search(r"Commit:\s*`?([0-9a-f]{40})", text) or SHA_RE.search(text)
        tip = cm.group(1) if cm and cm.groups() else (cm.group(0) if cm else "")
        if not tip:
            tip = git(repo, "rev-parse", "--verify", "-q", "refs/heads/%s^{commit}" % branch) or ""
        if not tip or git(repo, "cat-file", "-e", tip + "^{commit}") is None:
            return ("Codex's handover %r names %s, whose commit %s is not in %s, so no review of it started"
                    % (header[:90], branch, tip[:12] or "(none)", repo))
        words = codex_words(to_codex, to_rich, branch)
        if not words:
            return ("Codex's handover %r: no entry in %s names %s or comes before Codex first named it, so there "
                    "are no original words and no review of it started" % (header[:90], to_codex, branch))
        wdir = _p("codex-words")
        os.makedirs(wdir, exist_ok=True)
        stem = "%s-%s" % (re.sub(r"[^A-Za-z0-9._-]", "_", branch), tip[:12])
        wpath, cpath = os.path.join(wdir, stem + ".words.md"), os.path.join(wdir, stem + ".claims.md")
        with open(wpath, "w", encoding="utf-8") as f:
            f.write("".join("%s\n%s\n" % (h, b) for h, b in words))
        with open(cpath, "w", encoding="utf-8") as f:
            f.write("%s\n%s\n" % (header, body))
        return {"work": "branch:%s:%s" % (repo, branch), "repo": repo, "branch": branch, "tip": tip,
                "words": [wpath], "claims": [cpath], "at": now, "title": header[3:].strip()[:120]}


def split_entries(text):
    """[(header line or '', body)] split at `## ` headers."""
    out = []
    for ln in text.split("\n"):
        if ln.startswith("## ") or not out:
            out.append([ln, []] if ln.startswith("## ") else ["", [ln]])
        else:
            out[-1][1].append(ln)
    return [(h, "\n".join(b).strip("\n")) for h, b in out]


def codex_words(to_codex, to_rich, branch):
    """What Rich asked Codex for: every to-codex.md entry naming the branch;
    else the last one written before Codex first named the branch."""
    try:
        with open(to_codex, encoding="utf-8", errors="replace") as f:
            asks = split_entries(f.read())
    except OSError:
        return []
    named = [(h, b) for h, b in asks if h and branch in h + "\n" + b]
    if named:
        return named
    first = None
    try:
        with open(to_rich, encoding="utf-8", errors="replace") as f:
            for h, b in split_entries(f.read()):
                if h and branch in h + "\n" + b:
                    first = entry_time(h)
                    break
    except OSError:
        return []
    if first is None:
        return []
    before = [(h, b) for h, b in asks if h and entry_time(h) is not None and entry_time(h) <= first]
    return before[-1:]


def entry_time(header):
    m = re.match(r"##\s+(\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?Z)", header or "")
    if not m:
        return None
    t = m.group(1)
    if len(t) == 17:
        t = t[:-1] + ":00Z"
    return parse_iso(t)


# ---------------------------------------------------------------------------
# what has been reviewed: the ledger, the locks and the attempts
# ---------------------------------------------------------------------------

def lock_path(repo, tip):
    return _p("locks", "%s-%s.lock" % (repo_tag(repo), tip))


class Book(object):
    """Everything known about reviews, read once per look."""

    def __init__(self, rows, running, attempts):
        self.rows = rows
        self.running = running                      # {(repo, tip): lock info}
        self.verdicts = {}                          # {(repo, tip): [rows with a verdict]}
        self.by_work = {}
        for r in rows:
            if r.get("verdict"):
                self.verdicts.setdefault((os.path.realpath(r.get("repo") or ""), r.get("tip")), []).append(r)
                self.by_work.setdefault(r.get("work"), []).append(r)
        self.losses = {}
        for a in attempts:
            k = (a.get("repo"), a.get("tip"))
            if a.get("outcome") == "lost":
                self.losses.setdefault(k, []).append(a)
            elif a.get("outcome") == "verdict":
                self.losses.pop(k, None)

    def handover_verdict(self, key):
        return [r for r in self.verdicts.get(key, []) if r.get("trigger") in HANDOVER_KINDS]

    def any_verdict(self, key):
        return self.verdicts.get(key, [])

    def last_review_at(self, work):
        """The start of the newest review of this work, finished or running."""
        ts = [parse_iso(r.get("at")) for r in self.by_work.get(work, [])]
        ts += [float(i.get("started_at") or 0) for i in self.running.values() if i.get("work") == work]
        ts = [t for t in ts if t]
        return max(ts) if ts else None


def due(items, book, now, seen, long_seconds):
    """[(item, trigger, supersede lock info or None)]: the reviews to start now.
    Pure: everything it needs is in its arguments."""
    out = []
    for it in items:
        if it.tip == it.base:
            continue
        key = it.key
        lost = book.losses.get(key) or []
        if len(lost) >= MAX_LOSSES:
            continue                                # told once; nothing more starts by itself
        running = book.running.get(key)
        if it.state == "ended":
            if book.handover_verdict(key):
                continue
            if running and running.get("trigger") in MID_JOB:
                out.append((it, "handover", running))  # the handover replaces a mid-job review of this tip
                continue
            if running:
                continue
            out.append((it, "handover", None))     # a lost one is started once more, as what it now is
            continue
        if running or book.any_verdict(key):
            continue
        if lost:
            out.append((it, lost[-1].get("trigger") or "long-job", None))   # a lost review, started once more
            continue
        anchor = book.last_review_at(it.work)
        start = it.started if it.started is not None else seen.get(it.work, now)
        anchor = max(anchor or start, start)
        if now - anchor >= long_seconds:
            out.append((it, "long-job", None))
        elif it.quiet and it.state == "running":
            out.append((it, "quiet", None))
    return out


# ---------------------------------------------------------------------------
# the watcher
# ---------------------------------------------------------------------------

class Watcher(object):
    def __init__(self, engine_root, config, world=None):
        self.engine_root = engine_root
        self.config = config
        self.world = world or World(engine_root, config)
        self.children = {}                          # pid -> Popen, reaped every look

    # -- processes (overridden by the replay test) ---------------------------------
    def second_review(self):
        return (os.environ.get("REVIEW_WATCH_SECOND_REVIEW") or "").strip() or os.path.join(
            self.engine_root, "scripts", "second-review.sh")

    def spawn(self, item, trigger, log_path):
        """(pid, start identity) of a started review."""
        argv = ["bash", self.second_review()] + item.args(trigger)
        with open(log_path, "ab") as log:
            p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
                                 cwd=state_root())
        self.children[p.pid] = p
        return p.pid, self.process_start(p.pid)

    @staticmethod
    def process_start(pid):
        try:
            r = subprocess.run(["ps", "-o", "lstart=", "-p", str(int(pid))], capture_output=True, text=True,
                               timeout=10, env=dict(os.environ, LC_ALL="C", TZ="UTC0"))
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return ""
        return " ".join(r.stdout.split()) if r.returncode == 0 else ""

    def alive(self, info):
        """Is the review this lock records still running? Its pid, and its start
        time (a reused pid is not it). A child of this watcher is reaped first."""
        pid = info.get("pid")
        if not pid:
            return None
        child = self.children.get(pid)
        if child is not None:
            if child.poll() is not None:
                self.children.pop(pid, None)
                return False
            return True
        try:
            os.kill(int(pid), 0)
        except PermissionError:
            pass
        except (OSError, ValueError, TypeError):
            return False
        start = self.process_start(pid)
        return bool(start) and (not info.get("pid_start") or start == info["pid_start"])

    def stop(self, info):
        """Stop a review by its recorded process id, only while its start time
        still matches: the process group it leads, which second-review's own
        reviewer process group sits under."""
        pid = info.get("pid")
        if not pid or not self.alive(info):
            return
        for sig, grace in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
            try:
                os.killpg(int(pid), sig)
            except (OSError, ValueError):
                return
            end = time.time() + grace
            while time.time() < end:
                if not self.alive(info):
                    return
                time.sleep(0.2)

    # -- locks -------------------------------------------------------------------
    def take_lock(self, item, trigger, now, attempt):
        path = lock_path(item.repo, item.tip)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            return None
        info = {"repo": item.repo, "tip": item.tip, "work": item.work, "name": item.name, "trigger": trigger,
                "started_at": now, "attempt": attempt, "watcher": os.getpid(), "pid": None, "pid_start": ""}
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(info, f)
        return path, info

    def rewrite_lock(self, path, info):
        tmp = "%s.%d.tmp" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(info, f)
        os.replace(tmp, path)

    def settle(self, path, info, now, rows, outcome=None, why=""):
        """The lock's review has ended: one attempt row, then the lock goes.
        Renamed first, so of two watchers exactly one settles it."""
        claimed = "%s.settled.%d" % (path, os.getpid())
        try:
            os.rename(path, claimed)
        except OSError:
            return None
        if outcome is None:
            started = float(info.get("started_at") or 0)
            mine = [r for r in rows if os.path.realpath(r.get("repo") or "") == info.get("repo")
                    and r.get("tip") == info.get("tip") and (parse_iso(r.get("at")) or 0) >= started - 5]
            got = [r for r in mine if r.get("verdict")]
            if got:
                outcome = "verdict"
            else:
                outcome = "lost"
                why = why or (mine[-1].get("why") if mine else "") or self.log_tail(info) or \
                    "the review ended without writing a row to the ledger"
        a = {"repo": info.get("repo"), "tip": info.get("tip"), "work": info.get("work"), "name": info.get("name"),
             "trigger": info.get("trigger"), "started_at": info.get("started_at"), "ended_at": now,
             "outcome": outcome, "why": why, "attempt": info.get("attempt")}
        append_jsonl(_p("attempts.jsonl"), a)
        try:
            os.unlink(claimed)
        except OSError:
            pass
        return a

    @staticmethod
    def log_tail(info):
        try:
            with open(info.get("log") or "", encoding="utf-8", errors="replace") as f:
                lines = [ln.strip() for ln in f.read().splitlines() if ln.strip()]
        except OSError:
            return ""
        return " | ".join(lines[-2:])[:300]

    def reconcile(self, now, rows):
        """{(repo, tip): info} of reviews still running; ended ones settled."""
        running = {}
        for path in sorted(glob.glob(_p("locks", "*.lock"))):
            try:
                with open(path, encoding="utf-8") as f:
                    info = json.load(f)
            except (OSError, ValueError):
                info = None
            if not isinstance(info, dict):
                try:
                    if now - os.path.getmtime(path) > START_GRACE_SECONDS:
                        os.unlink(path)
                except OSError:
                    pass
                continue
            info["path"] = path
            alive = self.alive(info)
            age = now - float(info.get("started_at") or now)
            if alive is None and age < START_GRACE_SECONDS:
                running[(info.get("repo"), info.get("tip"))] = info
                continue
            if alive and age > OVERRUN_MINUTES * 60:
                self.stop(info)
                self.settle(path, info, now, rows, "lost",
                            "it ran %d minutes, past the %d-minute bound, and was stopped by its recorded process id"
                            % (age / 60, OVERRUN_MINUTES))
                continue
            if alive:
                running[(info.get("repo"), info.get("tip"))] = info
                continue
            self.settle(path, info, now, rows)
        return running

    def start(self, item, trigger, now, attempt, supersede=None, rows=()):
        if supersede:
            self.stop(supersede)
            self.settle(supersede["path"], supersede, now, rows, "superseded",
                        "replaced by the handover review of the same commit")
        got = self.take_lock(item, trigger, now, attempt)
        if got is None:
            return None
        path, info = got
        os.makedirs(_p("logs"), exist_ok=True)
        info["log"] = _p("logs", "%s-%s-%d.log" % (repo_tag(item.repo), item.tip[:12], attempt))
        try:
            pid, pstart = self.spawn(item, trigger, info["log"])
        except OSError as exc:
            self.rewrite_lock(path, info)
            self.settle(path, info, now, rows, "lost", "second-review could not be started: %s" % exc)
            return None
        info["pid"], info["pid_start"] = pid, pstart
        self.rewrite_lock(path, info)
        return info

    # -- one look --------------------------------------------------------------------
    def look(self, now, session_state):
        """Lines to print. Starts what is due; settles what ended."""
        if self.world.repos_error:
            if session_state.get("told_unreadable_repos") == self.world.repos_error:
                return []
            session_state["told_unreadable_repos"] = self.world.repos_error
            return ["REVIEW-WATCH %s: %s in %s cannot be read: %s. No second review starts by itself until it "
                    "reads %s=\"name name ...\"." % (hhmm(now), CONFIG_KEY, self.config, self.world.repos_error,
                                                     CONFIG_KEY)]
        if not self.world.repos:
            if session_state.get("told_no_repos"):
                return []
            session_state["told_no_repos"] = now
            return ["REVIEW-WATCH %s: no repository is listed in %s (%s), so no second review starts by itself. "
                    "Add one, e.g. %s=\"richos\"." % (hhmm(now), CONFIG_KEY, self.config or "no orchestration.config",
                                                      CONFIG_KEY)]
        shared = stall_watch._read_json(_p("shared.json"))
        seen = shared.setdefault("seen", {})
        codex_state = shared.setdefault("codex", {})
        rows = read_jsonl(review_ledger())
        running = self.reconcile(now, rows)
        items, problems = self.world.registry_items(now, seen)
        citems, cproblems = self.world.codex_items(now, codex_state)
        items += citems
        problems += cproblems
        attempts = read_jsonl(_p("attempts.jsonl"))
        book = Book(rows, running, attempts)
        for it, trigger, supersede in due(items, book, now, seen, LONG_JOB_MINUTES * 60):
            n = len(book.losses.get(it.key) or []) + 1
            info = self.start(it, trigger, now, n, supersede, rows)
            if info:
                book.running[it.key] = info
        for w in list(seen):
            if now - float(seen[w]) > KEEP_SECONDS:
                del seen[w]
        stall_watch._write_json(_p("shared.json"), shared)
        attempts = read_jsonl(_p("attempts.jsonl"))
        return tell(now, session_state, rows, Book(rows, book.running, attempts), items, problems, attempts)


# ---------------------------------------------------------------------------
# what is told
# ---------------------------------------------------------------------------

def _verdict_file(row):
    try:
        with open(os.path.join(row.get("record") or "", "verdict.json"), encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def _who(row, items_by_key):
    it = items_by_key.get((os.path.realpath(row.get("repo") or ""), row.get("tip")))
    return (it.name if it else row.get("author") or "?"), it


def render_verdict(row, items_by_key, again=None):
    who, it = _who(row, items_by_key)
    trig = row.get("trigger") or "?"
    mid = trig in MID_JOB
    head = "  [%s] %s, %s review, %s@%s by %s (%s): %d finding%s, %d P1%s" % (
        str(row.get("verdict")).upper(), who, "mid-job (%s)" % trig if mid else trig,
        os.path.basename(row.get("repo") or ""), str(row.get("tip"))[:12], row.get("reviewer") or "?",
        row.get("reviewer_model") or "?", int(row.get("findings") or 0), "" if row.get("findings") == 1 else "s",
        int(row.get("p1") or 0), " (forced by its findings)" if row.get("forced") else "")
    if again:
        head += "  (told again, notice %d; first told %s)" % again
    out = [head]
    answer = _verdict_file(row).get("answer") or {}
    for f in (answer.get("findings") or [])[:4]:
        out.append("      P%s %s (%s)" % (f.get("priority"), " ".join(str(f.get("title") or "").split())[:110],
                                         ", ".join(f.get("files") or [])[:80]))
    if len(answer.get("findings") or []) > 4:
        out.append("      ... and %d more" % (len(answer["findings"]) - 4))
    out.append("      record: %s" % os.path.join(row.get("record") or "?", "verdict.json"))
    if row.get("verdict") == "passed":
        out.append("      You can: land it%s." % (" as usual" if not mid else " once it hands over and that review passes"))
    elif mid:
        out.append("      You can: nothing was stopped; tell %s now if it should change course (SendMessage). "
                   "Its handover is reviewed anyway." % who)
    else:
        out.append("      You can: start a fresh continuation with these findings as its input (`continues: %s`); a "
                   "finished agent is never resumed. Told again every %d min until a continuation exists or the "
                   "work is landed or discarded." % (it.ref.split("--")[-1] if it and it.ref else who, REPEAT_MINUTES))
    return out


def not_converging(row, rows):
    """[(finding id, title)] still open in this recheck AND the one before it."""
    work = row.get("work")
    same = [r for r in rows if r.get("work") == work and r.get("verdict")]
    try:
        i = [r.get("id") for r in same].index(row.get("id"))
    except ValueError:
        return []
    if i < 1:
        return []
    now_v, prev_v = _verdict_file(row), _verdict_file(same[i - 1])

    def still(v):
        return set(e.get("id") for e in (v.get("answer") or {}).get("earlier_findings") or []
                   if e.get("status") == "still-open")
    both = still(now_v) & still(prev_v)
    titles = dict((e.get("id"), e.get("title")) for e in now_v.get("earlier_findings_in") or [])
    return [(fid, titles.get(fid) or "") for fid in sorted(both)]


def tell(now, sstate, rows, book, items, problems, attempts):
    items_by_key = dict((it.key, it) for it in items)
    told = sstate.setdefault("told", {})
    body = []
    # -- new verdicts, from where this session last read the ledger ---------------
    start = sstate.get("rows")
    if not isinstance(start, int) or start > len(rows):
        shared = stall_watch._read_json(_p("last-told.json"))
        start = shared.get("rows") if isinstance(shared.get("rows"), int) and shared["rows"] <= len(rows) else len(rows)
    for row in rows[start:]:
        if not row.get("verdict"):
            continue
        body.append(render_verdict(row, items_by_key))
        if row.get("verdict") == "changes-requested" and row.get("trigger") not in MID_JOB:
            told["cr:%s:%s" % (row.get("repo"), row.get("tip"))] = {"first": now, "last": now, "count": 1}
        for fid, title in not_converging(row, rows):
            k = "nc:%s:%s" % (row.get("work"), fid)
            if k in told:
                continue
            told[k] = {"first": now}
            who, _it = _who(row, items_by_key)
            body.append(["  [NOT CONVERGING] %s: finding %s (%s) is still open after two rechecks in a row." % (
                who, fid, " ".join(title.split())[:100]),
                "      You decide: another engineer, another model or a smaller slice. The CEO is not paged."])
    sstate["rows"] = len(rows)
    shared = stall_watch._read_json(_p("last-told.json"))
    shared["rows"] = max(len(rows), int(shared.get("rows") or 0)) if isinstance(shared.get("rows"), int) else len(rows)
    stall_watch._write_json(_p("last-told.json"), shared)
    # -- an unhandled changes-requested handover, again every 30 minutes ------------
    for it in items:
        if it.source != "registry" or it.state != "ended" or it.continued:
            continue
        hv = book.handover_verdict(it.key)
        if not hv or hv[-1].get("verdict") != "changes-requested":
            continue
        k = "cr:%s:%s" % (it.repo, it.tip)
        t = told.get(k)
        if t is None:
            told[k] = {"first": now, "last": now, "count": 1}
            body.append(render_verdict(hv[-1], items_by_key))
        elif now - float(t.get("last") or now) >= REPEAT_MINUTES * 60:
            t["last"], t["count"] = now, int(t.get("count") or 1) + 1
            body.append(render_verdict(hv[-1], items_by_key, (t["count"], hhmm(float(t["first"])))))
    # -- a commit whose review was lost twice --------------------------------------
    for key, lost in book.losses.items():
        if len(lost) < MAX_LOSSES:
            continue
        k = "lost:%s:%s" % key
        if k in told:
            continue
        told[k] = {"first": now}
        a = lost[-1]
        body.append(["  [NO VERDICT TWICE] %s, %s@%s: %s" % (a.get("name"), os.path.basename(key[0] or ""),
                                                            str(key[1])[:12], " ".join(str(a.get("why")).split())[:300]),
                     "      Nothing more starts for this commit by itself. You can: fix the cause, then run "
                     "%s by hand." % "second-review.sh"])
    # -- what could not be read or started ------------------------------------------
    for p in problems:
        k = "problem:" + p[:120]
        if k in told:
            continue
        told[k] = {"first": now}
        body.append(["  [NOT STARTED] " + p[:400]])
    for k in list(told):
        if now - float(told[k].get("first") or now) > KEEP_SECONDS:
            del told[k]
    if not body:
        return []
    lines = ["REVIEW-WATCH %s: %d second-review notice%s (it only starts reviews and reports: nothing was paused, "
             "stopped or killed)" % (hhmm(now), len(body), "" if len(body) == 1 else "s")]
    used = len(lines[0])
    for b in body:
        cost = sum(len(x) + 1 for x in b)
        if used + cost > BLOCK_CHARS and len(lines) > 1:
            lines.append("  ... more in the next look's block, or read %s" % review_ledger())
            break
        lines += b
        used += cost
    return lines


# ---------------------------------------------------------------------------
# the session, the loop and the commands
# ---------------------------------------------------------------------------

def session_dir(sid):
    d = _p("sessions", sid or "no-session")
    os.makedirs(d, exist_ok=True)
    return d


def prune(keep):
    root = _p("sessions")
    now = time.time()
    try:
        names = os.listdir(root)
    except OSError:
        names = []
    for n in names:
        d = os.path.join(root, n)
        if d == keep or not os.path.isdir(d) or stall_watch.lock_held(os.path.join(d, "monitor.lock")):
            continue
        try:
            newest = max([os.path.getmtime(os.path.join(d, f)) for f in os.listdir(d)] + [os.path.getmtime(d)])
        except OSError:
            continue
        if now - newest > SESSION_KEEP_SECONDS:
            for f in os.listdir(d):
                try:
                    os.unlink(os.path.join(d, f))
                except OSError:
                    pass
            try:
                os.rmdir(d)
            except OSError:
                pass
    for sub in ("logs", "codex-words"):
        for f in glob.glob(_p(sub, "*")):
            try:
                if now - os.path.getmtime(f) > KEEP_SECONDS:
                    os.unlink(f)
            except OSError:
                pass


def tick(watcher, sd, now=None, out=None):
    """One look under the machine-wide look lock (two watchers take turns)."""
    out = out or sys.stdout
    now = clock() if now is None else now
    os.makedirs(state_root(), exist_ok=True)
    fd = os.open(_p("look.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        path = os.path.join(sd, "told.json")
        sstate = stall_watch._read_json(path)
        try:
            lines = watcher.look(now, sstate)
        except Exception as exc:  # noqa: BLE001: one failed look is said, never the end of watching
            k = "failed:%s" % exc.__class__.__name__
            told = sstate.setdefault("told", {})
            lines = [] if k in told else ["REVIEW-WATCH %s: a look failed (%s: %s); the next look tries again" % (
                hhmm(now), exc.__class__.__name__, str(exc)[:200])]
            told[k] = {"first": now}
        sstate["last_look"] = now
        stall_watch._write_json(path, sstate)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)
    if lines:
        out.write("\n".join(lines) + "\n")
        out.flush()
    return len(lines)


def current_session(engine_root):
    ws = stall_watch._load("review_watch_session_ws", os.path.join(engine_root, "mega-lander", "workspaces.py"))
    if ws is None:
        return "", None
    try:
        sid = ws.current_session() or ""
        pid = ws.session_pid(sid) if sid else ws.session_pid()
    except Exception:  # noqa: BLE001
        return "", None
    return sid, pid


def run_loop(watcher, engine_root):
    sid, spid = current_session(engine_root)
    sd = session_dir(sid)
    fd = stall_watch._try_lock(os.path.join(sd, "monitor.lock"))
    if fd is None:
        return 0                                    # this session is already watched
    prune(sd)
    alive = stall_watch.session_alive_check(spid) if spid else None
    poll = stall_watch._env_float("REVIEW_WATCH_POLL_SECONDS", POLL_SECONDS)
    try:
        while alive is None or alive():
            tick(watcher, sd)
            stall_watch._nap(poll, alive)
    finally:
        os.close(fd)
    return 0


def mode_status(engine_root):
    sid, _pid = current_session(engine_root)
    sd = _p("sessions", sid or "no-session")
    st = stall_watch._read_json(os.path.join(sd, "told.json"))
    held = stall_watch.lock_held(os.path.join(sd, "monitor.lock"))
    last = st.get("last_look")
    print("review-watch: %s; last look %s" % ("watching this session" if held else "NOT WATCHING this session",
                                             iso(last) if last else "never"))
    for path in sorted(glob.glob(_p("locks", "*.lock"))):
        info = stall_watch._read_json(path)
        print("  running: %s %s@%s (%s, attempt %s) since %s, pid %s" % (
            info.get("name"), os.path.basename(info.get("repo") or ""), str(info.get("tip"))[:12],
            info.get("trigger"), info.get("attempt"), iso(float(info.get("started_at") or 0)), info.get("pid")))
    return 0 if held else 1


def main(argv):
    ap = argparse.ArgumentParser(prog="review-watch.sh")
    g = ap.add_mutually_exclusive_group(required=True)
    for flag in ("--monitor", "--tick", "--status"):
        g.add_argument(flag, action="store_true")
    ap.add_argument("--config", default="")
    ap.add_argument("--engine-root", default="")
    a = ap.parse_args(argv)
    engine_root = a.engine_root or os.path.dirname(os.path.dirname(HERE))
    if a.status:
        return mode_status(engine_root)
    if not a.config:
        return 0                                    # a repository that never adopted the engine: nothing to watch
    watcher = Watcher(engine_root, a.config)
    if a.tick:
        sid, _pid = current_session(engine_root)
        tick(watcher, session_dir(sid))
        return 0
    return run_loop(watcher, engine_root)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
