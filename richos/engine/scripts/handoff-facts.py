#!/usr/bin/env python3
"""handoff-facts.py — a session's last artifact carries MEASUREMENTS, not a memory of them.

=============================================================================================
WHAT THIS IS FOR — type U, richos-hq docs/verification/lifecycle-failure-record-2026-09-13.md
=============================================================================================
The restart note written at the end of session `8b149a24` was typed from recollection at the
end of the longest session of the day. The next session could not trust it, re-derived every
fact from the machine, and the CEO waited 158 seconds for a lookup:

    "why the fuck did I have to wait 158 seconds for an answer to a simple question that
     contained the EXACT place to look at?"

A handoff that must be fully re-verified has NEGATIVE value: it cost a writing, it cost the
re-derivation, and in between it laundered wrong numbers into a summary the CEO was given as
established fact.

=============================================================================================
THE ONE IDEA, AND WHY IT IS GENERATION RATHER THAN CHECKING
=============================================================================================
`brief-provenance.py` (its record: docs/verification/brief-provenance-2026-09-14.md) solves
the sibling problem for an AGENT BRIEF by LABELING the statements that carry no source. That
shape is right there and wrong here, and the measurement that decides it is in this file's
record:

  * Pointed at the fifteen restart notes on this machine, that checker reports 2 to 47
    findings per note and the DEFECTIVE note ranks fifth of fifteen. A handoff is nothing but
    dense counts by genre, so a provenance heuristic cannot separate a bad one from a good
    one. At 8-12 rows per note the annotation is wallpaper, which is the dilution death its
    own record names.

  * Worse, and decisive: re-running the numbers would have CONFIRMED the sentence that was
    actually false. The note said "79 teammate escalations outstanding, oldest 8 days,
    explicitly waiting on him". Replayed against the append-only ledger at the instant the
    note was written, the measurement is 85 outstanding — 79 addressed to the LEAD and 6 to
    the CEO, oldest 8.4 days. The number 79 was exactly right. THE LABEL ON IT WAS WRONG.

A generated row cannot mislabel a number, because the label comes out of the same data as the
number. That is the whole argument for this shape.

=============================================================================================
THE CLOSED SET, AND WHY IT IS CLOSED
=============================================================================================
An agent brief can cite anything, which is why executing its commands at spawn time was
rejected there. A restart note cannot: measured over the fifteen-note corpus, 15 of 15 carry
repository-state claims and a commit SHA. The recurring facts are a small fixed set, each with
one fast command behind it, and that is what makes generation possible here and impossible
there.

  REPOSITORIES   tip, dirty count, ahead/behind upstream        15 of 15 notes
  ESCALATIONS    outstanding, split by audience, oldest          4 of 15 notes, and the one
                 that produced the wrong label
  DOCKER         reclaimable, summed across all four types       the other wrong figure
  AGENTS         what is still alive                             7 of 15 notes

NOTHING IS SILENTLY OMITTED. A fact that cannot be measured on this machine emits a row saying
UNMEASURED and naming the command, because a missing row reads as "nothing to report".

=============================================================================================
WHAT THE CHECK HALF CAN AND CANNOT SETTLE — the honest part
=============================================================================================
`--check` re-settles the claims a written note already carries. It issues a verdict ONLY where
a verdict is sound after the fact:

  SOUND, time-independent  A claimed commit either exists in that repository or it does not.
  SOUND, replayable        The escalation ledger is append-only with timestamps, so the state
                           at any past instant is reconstructible exactly. This is the check
                           that catches the audience mislabel.
  NOT RE-CHECKABLE         Docker usage, working-tree cleanliness, which agents were alive.
                           These have no ledger. After the fact there is no honest verdict,
                           and this says so rather than comparing two different instants and
                           calling the difference an error.

That asymmetry is the reason the primary mode is `--emit`: for the classes nothing can settle
later, being measured AT THE WRITE is the only thing that ever will.

NEVER BLOCKS. NEVER REWRITES A WORD THE AUTHOR WROTE. The annotation is a delimited section
appended to the note, refreshed in place on re-run, and removable by deleting the block.
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))

BEGIN = "<!-- handoff-facts: generated by handoff-facts.py — measurements, not recollections -->"
END = "<!-- /handoff-facts -->"
TIMEOUT = 20


# ---------------------------------------------------------------------------
# RUNNING A COMMAND — the output is kept, always, including on failure
# ---------------------------------------------------------------------------
def run(cmd, cwd=None, timeout=TIMEOUT):
    """(rc, stdout+stderr). A command that fails is a MEASUREMENT that failed, and its
    output is the finding; it is never turned into silence."""
    try:
        p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           timeout=timeout, text=True)
        return p.returncode, (p.stdout or "").strip()
    except FileNotFoundError:
        return 127, "%s: not on PATH" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "timed out after %ss" % timeout
    except OSError as e:
        return 1, str(e)


def shown(cmd):
    return " ".join(cmd)


# ---------------------------------------------------------------------------
# CLASS: REPOSITORIES
# ---------------------------------------------------------------------------
def repo_root_of(path):
    rc, out = run(["git", "-C", path, "rev-parse", "--show-toplevel"])
    return out if rc == 0 else ""


def default_root():
    """The directory the repositories live in, DERIVED from where this file is, never typed.

    engine/scripts/handoff-facts.py -> <checkout>/engine/scripts -> <checkout> -> its parent.
    A WORKTREE IS RESOLVED TO ITS MAIN CHECKOUT FIRST: this file runs from a teammate's
    worktree far more often than from the main checkout, and the worktree's parent is a
    worktree pen (`richos-wt/`) with no sibling repositories in it at all."""
    repo = os.path.dirname(os.path.dirname(HERE))
    rc, common = run(["git", "-C", repo, "rev-parse", "--path-format=absolute",
                      "--git-common-dir"])
    if rc == 0 and common.startswith("/"):
        main = os.path.dirname(common.rstrip("/"))
        if main:
            repo = main
    return os.path.dirname(repo)


def resolve_repo(name, root):
    """A repository NAME as a note writes it, resolved to a checkout under `root`.

    A BARE NAME IS NEVER RESOLVED RELATIVE TO THE CURRENT DIRECTORY. Doing so made the
    checker's answer depend on where it was invoked from, and on the corpus it bound a
    teammate's name to the worktree the checker happened to be standing in."""
    if os.sep in name or name.startswith("."):
        cand = repo_root_of(name)
        if cand:
            return cand
    cand = os.path.join(root, name)
    if os.path.isdir(os.path.join(cand, ".git")):
        return cand
    return ""


def measure_repo(path):
    name = os.path.basename(path.rstrip("/"))
    rc, tip = run(["git", "-C", path, "rev-parse", "--short=8", "HEAD"])
    if rc != 0:
        return {"fact": "`%s` tip" % name, "value": "UNMEASURED — %s" % tip,
                "cmd": "git -C %s rev-parse --short=8 HEAD" % path, "ok": False}
    _, porcelain = run(["git", "-C", path, "status", "--porcelain"])
    dirty = len([l for l in porcelain.split("\n") if l.strip()])
    _, branch = run(["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
    rc_u, counts = run(["git", "-C", path, "rev-list", "--left-right", "--count",
                        "@{upstream}...HEAD"])
    if rc_u == 0 and "\t" in counts:
        behind, ahead = counts.split("\t")[:2]
        sync = ("in sync with origin" if behind == "0" and ahead == "0"
                else "%s ahead / %s behind origin" % (ahead, behind))
    else:
        sync = "no upstream"
    state = "clean" if dirty == 0 else "%d file(s) uncommitted" % dirty
    return {
        "fact": "`%s` tip" % name,
        "value": "`%s` on `%s`, %s, %s" % (tip, branch, state, sync),
        "cmd": "git -C %s rev-parse --short=8 HEAD && git -C %s status --porcelain"
               % (path, path),
        "ok": True, "tip": tip, "path": path, "name": name,
    }


# ---------------------------------------------------------------------------
# CLASS: ESCALATIONS — through escalations.py, never a second implementation
# ---------------------------------------------------------------------------
def _escalations_module():
    try:
        import escalations  # noqa: F401  (engine/scripts/lib is on sys.path)
        return escalations
    except ImportError:
        return None


def _row_time(E, r):
    for k in ("raised", "acked", "ts"):
        v = r.get(k)
        if v:
            try:
                t = E.parse_iso(v)
                if t is not None:
                    return t
            except Exception:
                continue
    return None


def measure_escalations(as_of=None):
    """Outstanding escalations, split by audience.

    `as_of` replays the append-only ledger to a past instant — the property that makes an
    escalation claim in an already-written note re-checkable at all."""
    cmd = "escalate.sh list"
    E = _escalations_module()
    if E is None:
        return {"fact": "escalations outstanding", "ok": False,
                "value": "UNMEASURED — scripts/lib/escalations.py not importable", "cmd": cmd}
    rows, bad = E.read_rows()
    if rows is None:
        return {"fact": "escalations outstanding", "ok": False,
                "value": "UNMEASURED — the ledger exists and could not be read", "cmd": cmd}
    when = None
    if as_of:
        when = E.parse_iso(as_of) if isinstance(as_of, str) else as_of
    if when is not None:
        rows = [r for r in rows if (_row_time(E, r) is None) or (_row_time(E, r) <= when)]
    out = E.outstanding(rows, now=when)
    by = {}
    for e in out:
        by[e.get("for") or "unaddressed"] = by.get(e.get("for") or "unaddressed", 0) + 1
    oldest = ""
    if out:
        days = round((out[0].get("age_min") or 0) / 1440.0, 1)
        oldest = "; oldest %s days" % days
    split = ", ".join("%d `for=%s`" % (n, k) for k, n in sorted(by.items(), key=lambda x: -x[1]))
    return {
        "fact": "escalations outstanding",
        "value": "%d — %s%s" % (len(out), split or "none", oldest),
        "cmd": cmd + ("   (replayed to %s)" % as_of if as_of else ""),
        "ok": True, "total": len(out), "by": by,
        "malformed": bad,
    }


# ---------------------------------------------------------------------------
# CLASS: DOCKER
# ---------------------------------------------------------------------------
SIZE = re.compile(r"^([0-9.]+)\s*([kKMGTP]?B)$")
UNIT = {"B": 1.0, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15}


def to_bytes(tok):
    m = SIZE.match(tok.strip())
    if not m:
        return None
    try:
        return float(m.group(1)) * UNIT[m.group(2).upper()]
    except (KeyError, ValueError):
        return None


def measure_docker():
    cmd = "docker system df"
    rc, out = run(["docker", "system", "df"])
    if rc != 0:
        return {"fact": "docker reclaimable", "ok": False,
                "value": "UNMEASURED — %s" % out.split("\n")[0][:90], "cmd": cmd}
    total = 0.0
    seen = False
    for line in out.split("\n")[1:]:
        cols = line.split()
        if len(cols) < 2:
            continue
        # The RECLAIMABLE column is the last size on the row; a trailing "(61%)" is not one.
        for tok in reversed(cols):
            if tok.startswith("("):
                continue
            b = to_bytes(tok)
            if b is not None:
                total += b
                seen = True
            break
    if not seen:
        return {"fact": "docker reclaimable", "ok": False,
                "value": "UNMEASURED — no size column parsed from `docker system df`",
                "cmd": cmd}
    return {"fact": "docker reclaimable", "value": "%.1f GB" % (total / 1e9), "cmd": cmd,
            "ok": True, "gb": total / 1e9}


# ---------------------------------------------------------------------------
# CLASS: AGENTS
# ---------------------------------------------------------------------------
def measure_agents():
    script = os.path.join(HERE, "agent-liveness.sh")
    cmd = "agent-liveness.sh"
    if not os.path.isfile(script):
        return {"fact": "agents alive", "ok": False,
                "value": "UNMEASURED — agent-liveness.sh not present", "cmd": cmd}
    rc, out = run(["bash", script], timeout=TIMEOUT)
    # WHERE IT WAS ASKED IS PART OF THE ANSWER. The registry is per-checkout, so the same
    # command run from a worktree and from the main checkout answer about different sets.
    ent = re.search(r"entity:\s*(\S+)", out)
    where = " (entity: %s)" % ent.group(1) if ent else ""
    verdicts = re.findall(r"\b(ALIVE|NOT-ALIVE|INDETERMINATE)\b", out)
    if not verdicts:
        # THE TOOL'S OWN WORDS, NEVER REINTERPRETED. "no agent worktrees registered" is a
        # measured zero, not a failure to measure, and it is reported as the tool phrased it.
        line = next((l.strip() for l in out.split("\n")
                     if l.strip() and not l.strip().startswith("===")
                     and not l.strip().startswith("entity:")), "")
        if line:
            return {"fact": "agents alive", "value": "%s%s" % (line[:110], where),
                    "cmd": cmd, "ok": True, "alive": 0, "indeterminate": 0}
        return {"fact": "agents alive", "ok": False,
                "value": "UNMEASURED — no verdict line (rc %d)" % rc, "cmd": cmd}
    counts = {v: verdicts.count(v) for v in set(verdicts)}
    alive = counts.get("ALIVE", 0)
    ind = counts.get("INDETERMINATE", 0)
    value = "%d ALIVE" % alive
    if ind:
        value += ", %d INDETERMINATE (never collapsed to either)" % ind
    value += where
    return {"fact": "agents alive", "value": value, "cmd": cmd, "ok": True,
            "alive": alive, "indeterminate": ind}


# ---------------------------------------------------------------------------
# EMIT
# ---------------------------------------------------------------------------
def now_iso():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def collect(repo_paths, want_agents=True, as_of=None):
    rows = [measure_repo(p) for p in repo_paths]
    rows.append(measure_escalations(as_of=as_of))
    rows.append(measure_docker())
    if want_agents:
        rows.append(measure_agents())
    return rows


LEAD_IN = ("Every row below was produced by the command beside it at the moment this note was "
           "written. Nothing here was remembered. **Re-run any row: what it says now is what "
           "is true now, and any difference is the news.**")


def emit(rows, stamp=None):
    stamp = stamp or now_iso()
    out = ["## Measured at handoff — %s" % stamp, "", LEAD_IN, "",
           "| fact | measured | command |", "|---|---|---|"]
    for r in rows:
        out.append("| %s | %s | `%s` |" % (r["fact"], r["value"], r["cmd"]))
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# CHECK — claims of a KNOWN CLASS, settled only where settling is sound
# ---------------------------------------------------------------------------
NUM = r"(?:~|about |roughly |approximately )?([0-9][0-9,]*(?:\.[0-9]+)?)"
ESC_CLAIM = re.compile(NUM + r"\s*(?:\w+\s+){0,3}escalations?\b", re.I)
CEO_WORDS = re.compile(r"\b(him|his|the CEO|he\b|yours|your call)\b", re.I)
LEAD_WORDS = re.compile(r"\b(lead|Rich|mine|me\b)\b", re.I)
DOCKER_CLAIM = re.compile(NUM + r"\s*(k|K|M|G|T)B\b[^.\n]{0,40}\b(reclaimable|docker)\b|"
                          r"\b(reclaimable|docker)\b[^.\n]{0,40}?" + NUM + r"\s*(k|K|M|G|T)B\b",
                          re.I)
# A commit claim is a backticked SHA with a repository name somewhere in front of it. One
# regex spanning both was tried and it binds the WRONG name every time — "a turn-end CI gate
# (richos `8be20bb5`)" gives up `turn-end`, because the nearest word is not the repository.
# So the SHA is found first and the name is resolved backwards from it, nearest first, and
# RESOLUTION IS THE FILTER: a candidate that is not a checkout on this machine is not a name.
SHA_TOKEN = re.compile(r"`([0-9a-f]{7,40})`")
NAME_TOKEN = re.compile(r"[A-Za-z][\w.-]{2,40}")
NAME_WINDOW = 70
SENTENCE = re.compile(r"(?<=[.!?])\s+|\n")


def sentences_of(text):
    body = re.sub(r"^---\n.*?\n---\n", "", text, flags=re.S)       # frontmatter is not prose
    body = body.split(BEGIN)[0]                                    # never check our own output
    return [s.strip() for s in SENTENCE.split(body) if s.strip()]


def check_escalation_claims(text, measured):
    """The check that catches the real defect: a right number under a wrong label."""
    findings = []
    if not measured.get("ok"):
        return findings
    by = measured["by"]
    total = measured["total"]
    ceo = by.get("ceo", 0)
    lead = by.get("lead", 0)
    for s in sentences_of(text):
        m = ESC_CLAIM.search(s)
        if not m:
            continue
        try:
            claimed = int(float(m.group(1).replace(",", "")))
        except ValueError:
            continue
        addressed_ceo = bool(CEO_WORDS.search(s)) and not LEAD_WORDS.search(s)
        if addressed_ceo and claimed != ceo:
            if claimed in (total, lead):
                findings.append({
                    "kind": "MISLABELED",
                    "text": s,
                    "detail": "%d is the count addressed to the %s; the count addressed to the "
                              "CEO is %d. The number is right and the audience is not."
                              % (claimed, "lead" if claimed == lead else "whole team", ceo),
                })
            else:
                findings.append({
                    "kind": "CONTRADICTED",
                    "text": s,
                    "detail": "measured %d outstanding for the CEO (%d in total: %s)"
                              % (ceo, total, ", ".join("%d %s" % (n, k) for k, n in by.items())),
                })
        elif not addressed_ceo and claimed not in (total, lead, ceo):
            findings.append({
                "kind": "CONTRADICTED",
                "text": s,
                "detail": "measured %d outstanding (%s)"
                          % (total, ", ".join("%d %s" % (n, k) for k, n in by.items())),
            })
    return findings


# ATTRIBUTION vs MENTION, and the difference is the whole false-positive control.
#
#   "landed on richos main `16c2af5`"                    -> ATTRIBUTED to richos
#   "landed by a prospects session; extension HEAD `a3..`"-> richos is MENTIONED nearby and the
#                                                            commit belongs to the extension
#
# A name is an ATTRIBUTION only when nothing but connective words separates it from the SHA.
# The second sentence is real: it is the one false positive the first version of this check
# produced on the corpus.
CONNECTIVE = re.compile(
    r"^(?:main|master|tip|head|at|on|in|is|was|of|to|the|a|an|its|now|commit|commits|branch|"
    r"repo|repository|pushed|landed|and|then|\W+)$", re.I)


def tip_claims(text, root):
    """(sha, attributed-checkout-or-empty, [candidate checkouts], sentence)."""
    out = []
    for s in sentences_of(text):
        for m in SHA_TOKEN.finditer(s):
            window = s[max(0, m.start() - NAME_WINDOW):m.start()]
            tokens = NAME_TOKEN.findall(window)
            paths, attributed, blocked = [], "", False
            for n in reversed(tokens):
                p = resolve_repo(n, root)
                if p:
                    if not attributed and not blocked:
                        attributed = p
                    if p not in paths:
                        paths.append(p)
                elif not CONNECTIVE.match(n):
                    blocked = True
            if paths:
                out.append((m.group(1), attributed, paths, s))
    return out


def all_checkouts(root):
    out = []
    try:
        for name in sorted(os.listdir(root)):
            p = os.path.join(root, name)
            if os.path.isdir(os.path.join(p, ".git")):
                out.append(p)
    except OSError:
        pass
    return out


def check_tip_claims(text, root):
    """A claimed commit either exists or it does not, and that verdict is as sound a year
    later as it is at the write — the one class here that time cannot make unanswerable.

    THE CLAIM IS DELIBERATELY THE WEAKEST ONE THAT IS STILL WORTH MAKING: not "this SHA is not
    in the repository you named" but "this SHA is in NO repository on this machine". Binding a
    SHA to the wrong adjacent name is the way this check would invent a defect, and it did:
    "landed by a prospects session; extension HEAD `a333e62`" bound to `prospects`, where the
    commit is genuinely absent — it lives in `li-profile-data-grabber`, which the sentence
    calls "extension". Widening the miss path to every checkout removes that whole class, at
    the cost of a few milliseconds per SHA that was going to be reported anyway.

    REPEATS ARE COLLAPSED. A rewritten history makes every commit a note cites disappear at
    once; thirteen rows for one event is the dilution that kills a report nobody can skim."""
    findings = []
    dead, moved = {}, {}
    everywhere = None
    for sha, attributed, paths, s in tip_claims(text, root):
        here = [attributed] if attributed else paths
        if any(run(["git", "-C", p, "cat-file", "-e", sha + "^{commit}"])[0] == 0 for p in here):
            continue
        if everywhere is None:
            everywhere = all_checkouts(root)
        elsewhere = [p for p in everywhere if p not in here]
        found_in = next((p for p in elsewhere
                         if run(["git", "-C", p, "cat-file", "-e", sha + "^{commit}"])[0] == 0),
                        "")
        if found_in:
            # An ATTRIBUTED commit that lives in another checkout is a real finding: the note
            # points a reader at a repository where it is not. A merely MENTIONED one is not,
            # because the attribution was this check's guess and the guess was wrong.
            if attributed:
                moved.setdefault((os.path.basename(attributed), os.path.basename(found_in)),
                                 []).append((sha, s))
            continue
        dead.setdefault(os.path.basename(here[0]), []).append((sha, s))
    for (repo, other), hits in moved.items():
        findings.append({
            "kind": "ELSEWHERE",
            "text": hits[0][1],
            "detail": ("%s this note attributes to `%s` %s not there; %s in `%s`."
                       % ("%d commits" % len(hits) if len(hits) > 1 else "A commit (`%s`)"
                          % hits[0][0], repo, "are" if len(hits) > 1 else "is",
                          "they are" if len(hits) > 1 else "it is", other))
            + (" (%s)" % ", ".join("`%s`" % h[0] for h in hits[:6]) if len(hits) > 1 else ""),
        })
    for repo, hits in dead.items():
        if len(hits) < 3:
            for sha, s in hits:
                findings.append({
                    "kind": "CONTRADICTED", "text": s,
                    "detail": "`%s` names no commit in any repository under %s" % (sha, root),
                })
        else:
            findings.append({
                "kind": "CONTRADICTED",
                "text": hits[0][1],
                "detail": "%d commits this note attributes to `%s` exist in no repository "
                          "under %s (%s) — one event, not %d mistakes: a history that moved "
                          "under the note."
                          % (len(hits), repo, root,
                             ", ".join("`%s`" % h[0] for h in hits[:6])
                             + (", ..." if len(hits) > 6 else ""), len(hits)),
            })
    return findings


def check_docker_claims(text, measured, recheckable):
    findings = []
    for s in sentences_of(text):
        m = DOCKER_CLAIM.search(s)
        if not m:
            continue
        groups = [g for g in m.groups() if g]
        nums = [g for g in groups if re.match(r"^[0-9]", g)]
        units = [g for g in groups if re.match(r"^[kKMGT]$", g)]
        if not nums or not units:
            continue
        claimed_gb = float(nums[0].replace(",", "")) * (
            {"k": 1e-6, "K": 1e-6, "M": 1e-3, "G": 1.0, "T": 1e3}[units[0]])
        if not recheckable:
            findings.append({
                "kind": "NOT RE-CHECKABLE", "text": s,
                "detail": "disk usage has no ledger, and this note was not written just now. "
                          "Only a measurement taken AT THE WRITE could have settled it.",
            })
        elif measured.get("ok") and abs(claimed_gb - measured["gb"]) > 0.5:
            findings.append({
                "kind": "CONTRADICTED", "text": s,
                "detail": "measured %.1f GB reclaimable (`docker system df`)" % measured["gb"],
            })
    return findings


def check(text, rows, root, recheckable):
    esc = next((r for r in rows if r["fact"] == "escalations outstanding"), {})
    dock = next((r for r in rows if r["fact"] == "docker reclaimable"), {})
    return (check_escalation_claims(text, esc)
            + check_tip_claims(text, root)
            + check_docker_claims(text, dock, recheckable))


def findings_block(findings):
    if not findings:
        return ""
    out = ["**Prose in this note that the measurements do not support:**", ""]
    for f in findings:
        t = f["text"]
        out.append("- **%s** — “%s”" % (f["kind"], t if len(t) < 200 else t[:197] + "..."))
        out.append("  %s" % f["detail"])
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------------------
# THE ARTIFACT THE NEXT SESSION READS
# ---------------------------------------------------------------------------
def section(rows, findings, stamp=None):
    body = emit(rows, stamp)
    fb = findings_block(findings)
    if fb:
        body += "\n" + fb
    return "%s\n\n%s\n%s\n" % (BEGIN, body.rstrip("\n"), END)


def splice(note_text, block):
    """Append the section, or replace the one already there. THE AUTHOR'S WORDS ARE NEVER
    TOUCHED: everything outside the delimiters is returned byte-identical."""
    if BEGIN in note_text and END in note_text:
        head = note_text.split(BEGIN)[0]
        tail = note_text.split(END, 1)[1]
        return head.rstrip("\n") + "\n\n" + block + tail.lstrip("\n")
    return note_text.rstrip("\n") + "\n\n" + block


# ---------------------------------------------------------------------------
def note_is_fresh(path, seconds):
    try:
        import time
        return (time.time() - os.path.getmtime(path)) <= seconds
    except OSError:
        return False


def main(argv):
    ap = argparse.ArgumentParser(
        description="A restart handoff carries measurements, not recollections. Never blocks.")
    ap.add_argument("note", nargs="?", help="the restart note to check and annotate")
    ap.add_argument("--emit", action="store_true", help="print the measured block and exit")
    ap.add_argument("--repo", action="append", default=[],
                    help="a repository to measure; repeatable. Default: those the note names.")
    ap.add_argument("--root", default="", help="directory the repositories live in")
    ap.add_argument("--as-of", default="", help="replay the escalation ledger to this instant")
    ap.add_argument("--no-agents", action="store_true", help="skip the agent-liveness row")
    ap.add_argument("--in-place", action="store_true",
                    help="write the section into the note (append-only, refreshed on re-run)")
    ap.add_argument("--fresh-seconds", type=int, default=900,
                    help="a note older than this is not re-checkable for volatile classes")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    root = a.root or default_root()
    text = ""
    if a.note:
        try:
            with open(a.note, encoding="utf-8") as fh:
                text = fh.read()
        except OSError as e:
            print("cannot read %s: %s" % (a.note, e), file=sys.stderr)
            return 2

    repos = [resolve_repo(r, root) for r in a.repo]
    if not repos and text:
        # The repositories a note NAMES are the ones to measure. Checking what the artifact
        # claims beats measuring a list somebody typed once.
        for _sha, attributed, paths, _s in tip_claims(text, root):
            first = attributed or (paths[0] if paths else "")
            if first and first not in repos:
                repos.append(first)
    repos = [r for r in repos if r]

    rows = collect(repos, want_agents=not a.no_agents, as_of=(a.as_of or None))

    if a.emit or not a.note:
        sys.stdout.write(emit(rows))
        return 0

    recheckable = note_is_fresh(a.note, a.fresh_seconds)
    findings = check(text, rows, root, recheckable)
    block = section(rows, findings)

    if a.json:
        print(json.dumps({"rows": rows, "findings": findings, "section": block}, indent=2))
        return 0
    if a.in_place:
        with open(a.note, "w", encoding="utf-8") as fh:
            fh.write(splice(text, block))
        print("handoff-facts: %d measured row(s), %d finding(s) written into %s"
              % (len(rows), len(findings), a.note))
        return 0
    sys.stdout.write(block)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
