#!/usr/bin/env python3
"""brief-scope.py — A DISPATCH AGAINST A SPEC-GOVERNED BODY OF WORK MUST NAME A
POINT THE MEASUREMENT SAYS IS STILL RED.

===========================================================================
THE FAILURE THIS EXISTS TO PREVENT
===========================================================================
The CEO, 2026-09-14: "the big problem ... is that too often the engineer's brief
contains not just unnecessary and useless fluff, but often contains
catastrophically harmful instructions such as false facts in the brief, wrong
tasks, wrong scope, prescribed design (in cases where finding new design options
is the objective)."

FALSE FACTS are handled by brief-provenance.py. This file is about WRONG TASK
and WRONG SCOPE, and it is built against the one instance where the cost is
measured: round 9 of the workspace spec.

The history, which is the whole argument for this shape:

  * The CEO supervised every engineer brief himself, then put TWO ADVERSARIAL
    REVIEWERS on every brief BEFORE every round. His verdict is that this is the
    only reason the job was ever completed.
  * IT STILL FAILED. By round 7 the work had drifted off his fourteen points.
  * Type K of the lifecycle failure record, measured: his fourteen points contain
    ZERO adversarial words, and "every reviewer brief Rich wrote instructed them
    to attack the machinery." THE REVIEWERS WERE AUDITING AGAINST A PREMISE THE
    LEAD HAD ALREADY CORRUPTED.
  * What finally caught it was not a reviewer. It was the CEO noticing he was
    being told a round 10 was needed after being told round 7 or 8 would be the
    last. That signal reached a person by luck.

SO THE MECHANISM MUST NOT BE A READER. Any reader — human or otherwise — is
briefed by the lead, and a lead who is confidently off-scope briefs the reader
off-scope too. The anchor has to be something the lead does not author.

===========================================================================
WHAT IS NOT AUTHORED BY THE LEAD
===========================================================================
Two things:

  1. THE CEO'S SPEC. He wrote it; nobody edits it; it is recorded with its
     sha256 when the body of work starts.
  2. THE MEASUREMENT. The body of work's own harness prints a green/red verdict
     PER SPEC POINT. The lead does not type those verdicts; a run produces them.

From those two: A ROUND EXISTS TO TURN A RED POINT GREEN. If every point a
brief names is already recorded GREEN, the brief has no spec-derived reason to
exist — and that is a FACT, computed from a run, not a judgment about prose.

Round 9's own brief states its starting state as `14 green, 0 red`, with the
only reds in the probe RUNNER, which is the lead's scaffolding and is in none of
the CEO's fourteen sentences. THE BRIEF ANNOUNCES, IN ITS OWN THIRD LINE, THAT
THE SPEC HAS NOTHING LEFT TO ASK FOR.

===========================================================================
THE FAILURE IS NON-CONVERGENCE, NOT ONE BAD ROUND
===========================================================================
The CEO's own word for what nearly happened is not "a bad round". It is:
"even then it nearly turned into an INFINITE LOOP were it not for my manual
intervention after round 9."

A per-brief check that is right every single time and never ends the series has
not solved his problem. So two of the clauses below are about the SERIES and not
about the brief, and they are the reason a history ledger exists:

  * REGRESSED — a point that was green in the previous recorded verdict is red
    in the current one. This is type L's own rule, which the record states and
    nothing enforced:

> a round is measured against the PREVIOUS BUILD as well as against the spec.
> Any behaviour that worked before and does not work now ends the round,
> whatever else it achieved.

  * NOT-CONVERGING — across the last CONVERGENCE_WINDOW recorded verdicts the
    red count has not strictly fallen. That is what an infinite loop IS, and it
    is the ROUND-COUNT SIGNAL with semantic content: being told a round 10 is
    needed after round 7 was to be the last is only alarming because the red
    count stopped falling, and the count alone cannot say that.

Both refuse every dispatch against the body of work — including the one that
would fix it — until the CEO rules. That is deliberate and it is what he did by
hand: he ordered a hard reset deleting round 9 and installed round 8.

===========================================================================
WHAT THIS DOES NOT DO, STATED HERE SO IT IS NEVER READ AS COVERAGE
===========================================================================
IT DOES NOT CHECK THAT AN ITEM IS A GOOD WAY TO CLOSE ITS POINT. Round 9's item
2 prescribed a design ("record the lead's own windows") that made the build
worse in three measured respects. That design was NOT the lead's invention — it
is lifted verbatim from certification-frank-round8-2026-09-13.md:185, an
adversarial reviewer's own prescription, which even ends "That is a round-9
build, not a CEO decision." A faithful relay of a reviewer's wrong design is
invisible to every provenance and authorship check there is, and it is invisible
to this one. What this refuses is the DISPATCH, on the ground that the
measurement records point 2 green; it has no opinion about the design inside.

IT DOES NOT SURVIVE A SPEC THAT MOVES WITHOUT SAYING SO — it refuses instead.
The CEO's page went from 5 numbered points to 14 WHILE THE ROUNDS WERE RUNNING
(re-derived: 5 at 6f98eeca, 13 at bf25aade, both 2026-09-11; 14 at c7bc75ab,
2026-09-12). Two facts about that growth decide the design:

  * IT WAS APPEND-ONLY, so a point NUMBER is a stable anchor: point 2 at the
    five-point revision is point 2 at the fourteen-point revision.
  * ITS TEXT WAS NOT. Point 2 read "`codex/` is never touched." and now reads
    "A `codex/` workspace or branch is never deleted without the CEO's express
    word." A round built against the first sentence builds the wrong thing.

So the spec is recorded WITH ITS sha256 and any change to it refuses every
dispatch until the harness has been re-run and the spec re-recorded. That is
friction on exactly the days the CEO is editing his own page, and it is the
correct friction: every per-point verdict in existence was derived from the old
text.

IT DOES NOT MAKE A GREEN VERDICT TRUE. At round 8 the harness read point 2 green
while a reviewer had demonstrated point 2 was violable. Under this mechanism
that disagreement REFUSES THE SPAWN and produces the question "the measurement
says this is done and the brief says it is not — which is wrong?". That is the
right question and it is not a false positive; it is also friction on legitimate
work, and it is paid every time the harness is weaker than the reviewer.

===========================================================================
THE SHAPE
===========================================================================
  brief-scope.py record-spec <repo> --spec <path> --points <N> --verdict <path>
      Records, ON THE EXISTING BODY-OF-WORK RECORD (integration.json, one
      registration, no second inventory), that this work is governed by a spec:
      its path, its sha256 AT THE MOMENT OF RECORDING, how many numbered points
      it has, and where its per-point verdict is kept.

  brief-scope.py verdict --from-log <harness output> --base <sha> --out <path>
      Derives the per-point verdict from a RUN's output. Nothing is typed: the
      point verdicts are parsed from the harness's own `PASS C<n>` / `FAIL C<n>`
      lines and the file records the sha256 of the log they came from. Every
      verdict is also APPENDED to `<path>.history.jsonl`, which is what makes
      the series — not just the round — measurable.

  brief-scope.py check <payload.json> [--repo <repo>]
      The decision. Exit 0 allow (and exit 0 SILENTLY when the target body of
      work has no recorded spec, which is every body of work today). Exit 2
      refuse, with the reason and the CEO-facing question on stdout.

THE BRIEF'S DECLARATION, which is the only thing asked of the lead:

    scope: richos-001
    serves: point 2 - a codex/ ref deleted by an agent is restored
    serves: point 9 - a finished agent's Write is refused

`serves:` lines are the anchor. `scope:` is optional and only cross-checked when
present. Everything else in the brief is untouched and unread.
"""

import hashlib
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))

# How many consecutive recorded verdicts must show a strictly falling red count.
# THREE, and the number is argued rather than picked: two is one hard round, which
# is normal and must not be refused; the CEO's own intervention came when a round
# 10 was proposed after round 7 was to be the last, which is three rounds of not
# finishing. A larger window buys precision with rounds nobody wanted.
CONVERGENCE_WINDOW = 3


def _load_workspaces():
    """workspaces.py owns where the state lives; this file never duplicates that
    knowledge, because a second inventory of one registration is failure type X."""
    import importlib.util
    path = os.path.join(HERE, "lib", "workspaces.py")
    spec = importlib.util.spec_from_file_location("richos_workspaces_bs", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


W = _load_workspaces()


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()


# ---------------------------------------------------------------------------
# 1. RECORDING THAT A BODY OF WORK IS GOVERNED BY A SPEC
# ---------------------------------------------------------------------------

def record_spec(repo, spec_path, points, verdict_path, by_session=""):
    rec = W.integration_record(repo)
    if not rec:
        raise SystemExit("brief-scope: %s has no recorded body of work; record its integration "
                         "branch first (spawn.sh does this)." % repo)
    spec_path = W.realpath(spec_path)
    if not os.path.isfile(spec_path):
        raise SystemExit("brief-scope: no spec at %s" % spec_path)
    path = W._integration_path()
    data = W.read_json(path) or {}
    work = (data.get("works") or {}).get(rec["id"])
    if work is None:
        raise SystemExit("brief-scope: body of work %s vanished between reads" % rec["id"])
    work["spec"] = {
        "path": spec_path,
        "sha256": sha256_file(spec_path),
        "points": int(points),
        "verdict": W.realpath(verdict_path),
        "recorded_by": by_session or os.environ.get("CLAUDE_SESSION_ID", ""),
    }
    W.write_json(path, data)
    return work["spec"]


# ---------------------------------------------------------------------------
# 2. THE VERDICT, DERIVED FROM A RUN AND NEVER TYPED
# ---------------------------------------------------------------------------

# The harness prints one of these per check, and C<n> is the CEO's point n.
# C0 is the harness's own self-check and is not one of his fourteen.
_VERDICT_LINE = re.compile(r"^\s*(PASS|FAIL)\s+C(\d+)\b")
_HEADLINE = re.compile(r"^\s*FOURTEEN:\s*(\d+)\s+green,\s*(\d+)\s+red")


def verdict_from_log(log_text):
    """{point number: 'green'|'red'} plus the harness headline, parsed from the
    harness's own output. A point the run never printed is ABSENT, and absent is
    not green."""
    points, headline = {}, None
    for line in log_text.splitlines():
        m = _VERDICT_LINE.match(line)
        if m:
            n = int(m.group(2))
            if n == 0:
                continue
            points[n] = "green" if m.group(1) == "PASS" else "red"
            continue
        h = _HEADLINE.match(line)
        if h:
            headline = line.strip()
    return points, headline


def history_path(verdict_path):
    return verdict_path + ".history.jsonl"


def read_history(verdict_path):
    """Every verdict ever recorded for this body of work, oldest first. The
    series is the unit the CEO's failure lives in, so the series is kept."""
    out = []
    try:
        with open(history_path(verdict_path), "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    except IOError:
        pass
    return out


def write_verdict(log_path, base_sha, out_path):
    with open(log_path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    points, headline = verdict_from_log(text)
    if not points:
        raise SystemExit("brief-scope: %s contains no `PASS C<n>` / `FAIL C<n>` lines; that is not "
                         "a run of the harness." % log_path)
    obj = {
        "base": base_sha,
        "headline": headline,
        "points": dict((str(k), v) for k, v in sorted(points.items())),
        "source_log": W.realpath(log_path),
        "source_log_sha256": sha256_text(text),
    }
    out_path = W.realpath(out_path)
    d = os.path.dirname(out_path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    W.write_json(out_path, obj)
    # Append-only: the series is the evidence, and a series that can be rewritten
    # is a series the lead authors, which is the thing this whole file refuses to
    # depend on.
    with open(history_path(out_path), "a", encoding="utf-8") as fh:
        fh.write(json.dumps(obj, sort_keys=True) + "\n")
    return obj


# ---------------------------------------------------------------------------
# 3. THE BRIEF'S DECLARATION
# ---------------------------------------------------------------------------

_SERVES = re.compile(r"^\s*(?:[-*>]\s*)?(?:\*\*)?serves:(?:\*\*)?\s*point\s*(\d+)\s*[-–—:]?\s*(.*)$",
                     re.IGNORECASE)
_SCOPE = re.compile(r"^\s*(?:[-*>]\s*)?(?:\*\*)?scope:(?:\*\*)?\s*([A-Za-z0-9_.-]+)", re.IGNORECASE)
_HATCH = re.compile(r"^\s*(?:[-*>]\s*)?(?:\*\*)?scope-ceo-word:(?:\*\*)?\s*(\S.*)$", re.IGNORECASE)


def parse_declaration(brief):
    """The anchor block, read from the brief exactly as written. Fenced code is
    skipped: a `serves:` line inside a quoted example is an example, not a
    declaration, and a brief that pastes another brief must not inherit its
    anchors."""
    serves, scope, hatch, fenced = [], None, None, False
    for raw in brief.splitlines():
        stripped = raw.lstrip()
        if stripped.startswith("```") or stripped.startswith("~~~"):
            fenced = not fenced
            continue
        if fenced:
            continue
        m = _SERVES.match(raw)
        if m:
            serves.append((int(m.group(1)), m.group(2).strip()))
            continue
        if scope is None:
            s = _SCOPE.match(raw)
            if s:
                scope = s.group(1)
                continue
        if hatch is None:
            h = _HATCH.match(raw)
            if h:
                hatch = h.group(1).strip()
    return {"serves": serves, "scope": scope, "hatch": hatch}


# ---------------------------------------------------------------------------
# 4. THE DECISION
# ---------------------------------------------------------------------------

class Refusal(Exception):
    def __init__(self, code, lines):
        Exception.__init__(self, code)
        self.code = code
        self.lines = lines


def _tip(repo, branch):
    try:
        out = subprocess.run(["git", "-C", repo, "rev-parse", branch],
                             capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def decide(repo, brief, now_tip=None):
    """Returns a list of allow-notes, or raises Refusal. SILENT (empty list) when
    the body of work has no recorded spec — which is the normal case and must
    stay free."""
    rec = W.integration_record(repo)
    if not rec:
        return []
    spec = rec.get("spec")
    if not spec:
        return []

    work_id = rec.get("id", "?")
    spec_path = spec.get("path", "")

    # The spec is the anchor, so a spec that is not the one that was recorded
    # invalidates every verdict and every anchor derived from it. This is the
    # clause that stops "which spec, or which part of it, applies" from being
    # something the lead can move.
    if not os.path.isfile(spec_path):
        raise Refusal("SPEC-MISSING", [
            "The spec recorded for body of work %s is not there: %s" % (work_id, spec_path)])
    live = sha256_file(spec_path)
    if live != spec.get("sha256"):
        raise Refusal("SPEC-CHANGED", [
            "The spec has changed since this body of work was recorded.",
            "  recorded sha256: %s" % spec.get("sha256"),
            "  on disk now:     %s" % live,
            "  %s" % spec_path,
            "Every per-point verdict and every anchor was derived from the OLD text.",
            "Re-run the harness and re-record the spec before dispatching against it."])

    verdict_path = spec.get("verdict", "")
    verdict = W.read_json(verdict_path) if verdict_path else None
    if not verdict or not verdict.get("points"):
        raise Refusal("NO-VERDICT", [
            "Body of work %s is governed by %s, and there is no per-point measurement to "
            "dispatch against." % (work_id, spec_path),
            "  expected at: %s" % (verdict_path or "(no verdict path recorded)"),
            "Run the harness and record its output:",
            "  brief-scope.py verdict --from-log <run output> --base <sha> --out %s"
            % (verdict_path or "<path>")])

    tip = now_tip if now_tip is not None else _tip(repo, rec.get("branch", "HEAD"))
    if tip and verdict.get("base") and verdict["base"] != tip:
        raise Refusal("VERDICT-STALE", [
            "The per-point measurement was taken at %s and %s is now at %s."
            % (verdict["base"][:12], rec.get("branch", "?"), tip[:12]),
            "A verdict older than the branch it judges says what USED to be red.",
            "Re-run the harness at %s and re-record it." % tip[:12]])

    decl = parse_declaration(brief)
    points = verdict["points"]
    red = sorted(int(k) for k, v in points.items() if v == "red")
    red_txt = (", ".join("point %d" % n for n in red)) if red else "NONE — every point is green"

    # --- THE SERIES CLAUSES ------------------------------------------------
    # These are properties of the body of work and not of this brief, so they are
    # decided before a word of the brief is parsed: a regressed or stalled series
    # refuses every dispatch, including the one that would fix it, which is
    # exactly what the CEO did by hand when he ordered the round-9 reset.
    # The CEO's hatch releases them, because ending a series is his call.
    if not decl["hatch"]:
        hist = read_history(verdict_path)
        if len(hist) >= 2:
            prev = hist[-2]["points"] if hist[-1].get("base") == verdict.get("base") else hist[-1]["points"]
            regressed = sorted(int(k) for k, v in points.items()
                               if v == "red" and prev.get(k) == "green")
            if regressed:
                raise Refusal("REGRESSED", [
                    "The last round made the build WORSE. %s %s green before it and %s red now."
                    % (", ".join("Point %d" % n for n in regressed),
                       "was" if len(regressed) == 1 else "were",
                       "is" if len(regressed) == 1 else "are"),
                    "",
                    "  previous measurement: %s" % (hist[-2].get("headline") or "?"),
                    "  current measurement:  %s" % (verdict.get("headline") or "?"),
                    "",
                    "A round that carries a strict regression does not land, so none of its good",
                    "half reaches the CEO either. Nothing more is dispatched against this work",
                    "until that is resolved.",
                    "",
                    "    A round of this work took %s backwards. Reset to the last build that"
                    % ", ".join("point %d" % n for n in regressed),
                    "    had them green, or carry on from here?"])

        if len(hist) >= CONVERGENCE_WINDOW:
            counts = [sum(1 for v in h.get("points", {}).values() if v == "red")
                      for h in hist[-CONVERGENCE_WINDOW:]]
            if counts[-1] > 0 and not all(a > b for a, b in zip(counts, counts[1:])):
                raise Refusal("NOT-CONVERGING", [
                    "The last %d rounds of this work did not reduce the red count: %s."
                    % (CONVERGENCE_WINDOW, " -> ".join(str(c) for c in counts)),
                    "",
                    "  still red: %s" % red_txt,
                    "",
                    "A series whose red count stops falling is not a series that is nearly done;",
                    "it is a loop. This is the round-count signal with the semantics attached —",
                    "the count alone cannot tell a hard round from a loop, and the count is what",
                    "the CEO had to notice himself, after round 9.",
                    "",
                    "    %d rounds of this work have not reduced what is failing. Keep going,"
                    % CONVERGENCE_WINDOW,
                    "    change approach, or stop?"])

    if decl["scope"] and decl["scope"] != work_id:
        raise Refusal("WRONG-WORK", [
            "The brief declares `scope: %s`; this repository's current body of work is %s."
            % (decl["scope"], work_id),
            "Renaming the body of work is how a dispatch leaves the spec's reach. If this "
            "genuinely is different work, that is the CEO's to start, not a line in a brief."])

    if not decl["serves"]:
        raise Refusal("NO-ANCHOR", [
            "Body of work %s is governed by the CEO's spec at %s, and this brief names no "
            "point of it." % (work_id, spec_path),
            "Add one line per work item:",
            "    serves: point <N> - <what this item makes true>",
            "Still red, and therefore dispatchable: %s" % red_txt])

    n_points = int(spec.get("points") or 0)
    bad = [n for n, _ in decl["serves"] if n_points and (n < 1 or n > n_points)]
    if bad:
        raise Refusal("NO-SUCH-POINT", [
            "The brief names point(s) %s; the spec has %d."
            % (", ".join(str(b) for b in bad), n_points),
            "  %s" % spec_path])

    absent = [(n, t) for n, t in decl["serves"] if str(n) not in points]
    if absent:
        raise Refusal("POINT-UNMEASURED", [
            "The brief names point(s) %s, and the run recorded no verdict for them."
            % ", ".join(str(n) for n, _ in absent),
            "An unmeasured point is not a red one. Measure it, then dispatch against it."])

    green_hits = [(n, t) for n, t in decl["serves"] if points.get(str(n)) == "green"]

    if green_hits:
        if decl["hatch"]:
            return ["scope: %s; the measurement records %s green and the dispatch proceeds on "
                    "the CEO's word: %s"
                    % (work_id, ", ".join("point %d" % n for n, _ in green_hits), decl["hatch"])]
        # EVERY item is judged, not the brief as a whole. A brief whose first item
        # is genuinely red and whose second is a rider is exactly the shape round 9
        # had, and a mechanism that passes the brief because one item earns its
        # place is a mechanism that carries the rider in with it.
        all_green = len(green_hits) == len(decl["serves"])
        code = "SPEC-SATISFIED" if all_green else "GREEN-ITEM"
        if all_green:
            lines = ["Every point this brief names is recorded GREEN by the measurement at %s."
                     % (verdict.get("base") or "?")[:12]]
        else:
            lines = ["This brief carries %d item(s) whose point is already recorded GREEN by the "
                     "measurement at %s." % (len(green_hits), (verdict.get("base") or "?")[:12]),
                     "The rest of it is dispatchable; these are riding along."]
        lines += [
            "",
            "  the measurement:  %s" % (verdict.get("headline") or "(no headline line)"),
            "  still red:        %s" % red_txt,
            "",
            "  the brief asks for:"]
        for n, t in green_hits:
            lines.append("    serves: point %d%s   <- recorded GREEN" % (n, (" - " + t) if t else ""))
        if all_green:
            lines += [
                "",
                "A round exists to turn a red point green. This one names nothing red, so the",
                "spec is not what is asking for it. That is not a defect in the brief's prose and",
                "it cannot be fixed by rewriting the brief.",
                "",
                "THE QUESTION THIS RAISES IS THE CEO'S, AND IT IS THE ONLY ONE HE ASKED HIMSELF",
                "THAT EVER CAUGHT THIS DRIFT:",
                "",
                "    The spec you wrote measures complete. This proposes another round on it.",
                "    Either the work is not wanted, or the measurement is wrong. Which?"]
        else:
            lines += [
                "",
                "Drop them and dispatch the rest — that costs one edit and no one's time. They",
                "are what the CEO calls the unnecessary half, and a round carries them only",
                "because nothing ever asked what they were for."]
        lines += [
            "",
            "If the work is wanted anyway, put HIS WORDS on the brief and dispatch:",
            "    scope-ceo-word: <what he said, and when>"]
        raise Refusal(code, lines)

    return ["scope: %s; %s named, %s red in the measurement at %s"
            % (work_id,
               ", ".join("point %d" % n for n, _ in decl["serves"]),
               red_txt, (verdict.get("base") or "?")[:12])]


# ---------------------------------------------------------------------------
# 5. THE HOOK ENTRY POINT
# ---------------------------------------------------------------------------

_XREPO = re.compile(r"^\s*cross-repo-worktree:\s*(\S+)", re.MULTILINE)


def repo_of(path):
    try:
        out = subprocess.run(["git", "-C", path, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    return W.main_checkout(out.stdout.strip()) or W.realpath(out.stdout.strip())


def targets(payload):
    """Every repository this spawn will write to: the one it is launched from and
    the one its cross-repo workspace lives in. Both are asked, because the
    workspace spec's own rounds are dispatched from one repository into another."""
    seen, out = set(), []
    ti = payload.get("tool_input") or {}
    prompt = str(ti.get("prompt") or "")
    for p in [payload.get("cwd") or ""] + _XREPO.findall(prompt):
        if not p:
            continue
        r = repo_of(p)
        if r and r not in seen:
            seen.add(r)
            out.append(r)
    return out, prompt


def check_payload(payload, repo_override=None):
    if (payload.get("tool_name") or "") != "Agent":
        return 0, []
    repos, prompt = targets(payload)
    if repo_override:
        repos = [W.realpath(repo_override)]
    notes = []
    for repo in repos:
        try:
            notes += decide(repo, prompt)
        except Refusal as r:
            return 2, ["guard-brief-scope REFUSES this spawn  (%s, %s)" % (r.code, repo),
                       ""] + r.lines
    return 0, notes


def main(argv):
    def get(flag, default=None):
        return argv[argv.index(flag) + 1] if flag in argv else default

    if len(argv) >= 3 and argv[1] == "record-spec":
        out = record_spec(argv[2], get("--spec"), get("--points"), get("--verdict"))
        print(json.dumps(out, indent=1))
        return 0
    if len(argv) >= 2 and argv[1] == "verdict":
        obj = write_verdict(get("--from-log"), get("--base") or "", get("--out"))
        print("%s  ->  %d point(s): %s"
              % (get("--out"), len(obj["points"]),
                 ", ".join("%s=%s" % kv for kv in sorted(obj["points"].items(),
                                                         key=lambda kv: int(kv[0])))))
        return 0
    if len(argv) >= 3 and argv[1] == "check":
        with open(argv[2], "r", encoding="utf-8", errors="replace") as fh:
            payload = json.load(fh)
        rc, lines = check_payload(payload, get("--repo"))
        for ln in lines:
            print(ln)
        return rc
    sys.stderr.write(
        "usage: brief-scope.py record-spec <repo> --spec <path> --points <N> --verdict <path>\n"
        "       brief-scope.py verdict --from-log <log> --base <sha> --out <path>\n"
        "       brief-scope.py check <payload.json> [--repo <repo>]\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
