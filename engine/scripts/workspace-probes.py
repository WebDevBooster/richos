#!/usr/bin/env python3
# ===========================================================================
# workspace-probes.py — EVERY COMMITTED PROBE OF workspaces.py, IN ONE COMMAND
# ===========================================================================
#
# WHY THIS EXISTS, AND IT IS NOT A CONVENIENCE
# ---------------------------------------------------------------------------
# Two rounds in a row of the workspace-spec work went BACKWARDS, and both times
# the evidence that they had was already committed in this repository.
#
#   * Round g1 -> g2 swapped the source of branch attribution. A reviewer's
#     probe that had stood at 6/6 dropped to 1/6. It was in the tree. Nothing
#     ran it, so nothing stopped the commit.
#   * Round g2 -> g3 swapped it again, and the same thing happened to a second
#     reviewer's probe.
#
# A probe is not a record of one afternoon. It is the sentence of the CEO's page
# that the build was once held to, written in a form a machine can re-ask. The
# only thing that makes it worth writing is that it gets asked AGAIN.
#
# So: one command, every probe, a non-zero exit if any of them is red.
#
# ===========================================================================
# THREE THINGS CHANGED ON 2026-09-12 (round 6, brief §7), AND WHY EACH ONE
# ===========================================================================
# Both reviewers refused the round-5 gate on the same finding: the runner is
# the one command that asks all fourteen questions, so every route that
# silences it is literally "a question not asked". Three routes decided the
# exit code and all three ran from inside the work under test:
#
#   1. THE WITNESS WAS A BRANCH NAME. A3 accepted a retirement when its commit
#      was contained in some local branch other than the one under test. Rich
#      cuts every reviewer's workspace at the engineer's tip, so every engineer
#      commit was "witnessed by" a reviewer branch with no forgery at all
#      (certification-frank-gate-integrity-2026-09-12.md §3(c)); `git branch
#      wip` did the same (certification-sage-gate-integrity route 2); and the
#      honest land — point 4 deletes branches — destroyed the witness and made
#      three probes UNRUNNABLE an hour after their retirements were accepted
#      (lifecycle-failure-record-2026-09-12.md §2c). A witness that is a branch
#      NAME cannot be the witness in a system whose first rule is that branches
#      get deleted.
#
#      THE WITNESS IS NOW THE RECORDED INTEGRATION BRANCH (point 14). A
#      retirement — or a `not-a-probe:` marker added to an existing file — is
#      attributable when its introducing commit HAS LANDED on the branch the
#      registry records as the one this repository's work integrates on. Only
#      Rich writes that branch, so the party failing a probe cannot produce the
#      witness from inside its own work; and the branch is the one thing point 4
#      never deletes, so the witness survives every land. The runner asks the
#      library — `integration_for(<repo>)` — and where nothing is recorded it
#      REFUSES every retirement and names the recording command. It never falls
#      back to `main`: that would be a second answer to point 14's one question.
#
#   2. MISSING READ THE WORKING TREE. A deleted probe stopped being MISSING when
#      a file existed at its path in the tree, committed or not, and when any
#      line in the retirements file named it, committed or not, signed by anyone
#      (certification-frank-gate-integrity B1: "the deletion has to be committed
#      and the concealment does not"). MISSING is now asked of git: a path is
#      present only if it is present at HEAD, and a deletion is excused only by
#      a whole-file retirement that passes the same name check and the same
#      A1-A3 as a live one.
#
#   3. DISCOVERY WAS A TEXT RULE. A file was a probe if its text named the
#      library and spelled an entry point; `getattr(m, "register" + "_spawn")`
#      spelled nothing and the probe did not exist (route 3). A probe is now
#      discovered because its author LISTED it in a committed manifest —
#      docs/verification/workspace-probes.manifest, read from HEAD via git, never
#      from the working tree. The text rule is kept as the backstop in the OTHER
#      direction: a committed file that looks like a probe and is not listed is
#      reported UNLISTED and blocks, so a probe cannot be quietly left off the
#      list either. A branch's own manifest lists a reviewer's probe on the
#      reviewer's branch; a branch with no manifest is scanned the old way.
#
# WHAT MAY RETIRE A PROBE — AND A TYPED NAME IS NOT AUTHORITY
# ---------------------------------------------------------------------------
# A red prior probe BLOCKS. The only thing that can retire one is the reviewer
# who WROTE it agreeing that it is obsolete — never the engineer who is failing
# it. That is not politeness. An engineer failing a probe is, by construction,
# the person with a reason to believe the probe is wrong, and is the person
# least able to tell "this assertion is obsolete" from "I broke this".
#
# The retirement lives beside the probe, in a file the reviewer writes and
# commits, and this runner reads it and says so by name:
#
#     docs/verification/workspace-probe-retirements.tsv
#     <probe filename>\t<case|*>\t<who retired it>\t<why>      per CASE
#     <probe filename>\t<who retired it>\t<why>                whole FILE
#
# RETIREMENT IS PER CASE, AND THAT IS NOT A CONVENIENCE EITHER. A reviewer ruled
# three of the cases in his own probe obsolete and one still valid, and then wrote
# NO RETIREMENT AT ALL — because retirement was keyed on the FILE, and retiring
# his file would have dropped five GREEN assertions to buy one green exit code.
# He was right to refuse that trade, and the mechanism was what made it a trade.
# An honest ruling must never cost coverage, so a retirement now names the case it
# is about, the probe still RUNS, and the cases nobody retired still decide the
# verdict.
#
# Both shapes are read, and the three-field one is not deprecated: a line a
# reviewer already committed must never need rewriting by an engineer, because
# rewriting it would make the ENGINEER the author of the introducing commit and
# A3 below would then refuse it. `*` in the case field is the explicit whole-file
# form for anything written from here on.
#
# HOW A CASE IS EXCLUDED, AND HOW IT FAILS WHEN IT CANNOT BE: an argv-shaped
# probe takes `probe.py <lib> [case ...]`, so the runner passes the SURVIVING
# cases and the retired ones are never asked. A scenario-shaped probe is one
# process per case, so retired scenarios are simply not started. A probe that
# IGNORES its case arguments will therefore still run the retired case and still
# go red — which is the safe direction, and the report says exactly that rather
# than leaving it to be guessed.
#
# THE THREE QUESTIONS, all answered from git, none of them from the text of the
# line:
#
#   A1  IS IT COMMITTED AT ALL? A line that exists only in the working tree
#       retires nothing. An unstaged edit is not a reviewer's act.
#   A2  DOES THE COMMIT THAT INTRODUCED IT TOUCH ANYTHING OUTSIDE
#       docs/verification/? A reviewer ruling on its own probe never edits the
#       engine. A commit that changes the library AND retires the probe that the
#       change is failing is refused by construction — which is the exact shape
#       of the shortcut this is here to stop.
#   A3  HAS THAT COMMIT LANDED ON THE RECORDED INTEGRATION BRANCH? A reviewer
#       commits on the reviewer's branch and Rich lands it, so an honest
#       retirement is reachable from the branch the registry records for this
#       repository's work (point 14). A commit that has not reached it — on the
#       branch under test, on a branch cut at the engineer's tip, on a branch
#       named anything — cannot retire anything. The witness is NAMED in the
#       report: the commit, the branch, and the branch's tip at the time.
#
# WHAT THIS STILL DOES NOT DO, SAID HERE RATHER THAN DISCOVERED LATER: every
# agent on this machine commits under one git identity, and there is no secret
# only a reviewer holds. A1-A3 make it impossible to retire a probe from inside
# the work that is failing it; a retirement Rich LANDS is accepted whoever wrote
# it, because landing is Rich's act and the land is on the record. Closing that
# properly needs a signature a reviewer alone can make, which needs a key
# nothing in this engine has yet.
#
# The same three questions govern the `not-a-probe:` declaration, for the same
# reason: it is a statement about somebody's probe. A marker present since the
# file's FIRST commit is the author declaring its own file, and it stands. A
# marker ADDED to a file that already existed must answer A1-A3, or the file goes
# on being a probe and the runner says the declaration was refused. Silencing a
# probe by annotating it was route 1 of four, and it needed no name at all.
#
# WHAT COUNTS AS A PROBE HERE
# ---------------------------------------------------------------------------
# A probe of workspaces.py is a committed .py file under docs/verification/ that
# is LISTED in docs/verification/workspace-probes.manifest at HEAD. The text rule
# — it names workspaces.py / workspaces.test.py and drives the library, or it
# loads a module from a path and calls one of the library's entry points — is
# the backstop that finds an UNLISTED one.
#
# A PROBE THAT DISAPPEARS IS A PROBE THAT WAS DELETED
# ---------------------------------------------------------------------------
# Route 4 of four: removing the file only lowers a count nothing was checking.
# So the runner also asks git which paths under docs/verification/ USED to hold
# a probe and hold nothing at HEAD, and which manifest entries hold nothing at
# HEAD, and reports each as MISSING — as blocking as a red one. A probe leaves
# by retirement, which is attributable, and never by deletion, which is not.
#
# Two shapes are both supported, because both are in the tree:
#
#   ARGV       `probe.py <path-to-workspaces.py> [case ...]`, self-sandboxing,
#              exit 0 when every case holds. Both reviewers' recent probes.
#   IN-TREE    a unittest file that imports engine/scripts/lib/workspaces.test.py
#              at a path relative to ITSELF. Frank's earlier probes. The runner
#              stages a throwaway tree — engine/scripts/lib/ populated from the
#              repository, workspaces.py replaced by the one under test — and
#              runs the probe from inside it, so "against a given workspaces.py"
#              means the same thing for both shapes.
#
# A PROBE THE RUNNER CANNOT EXECUTE IS NOT A PROBE THAT PASSED
# ---------------------------------------------------------------------------
# It is reported LOUDLY, by name, with the reason, and it makes this command
# exit non-zero — exactly like a red one. Silence about a probe that did not run
# is how the last two rounds happened.
#
# Files under docs/verification/ that are NOT probes of this library are counted
# and named under --show-all, never silently dropped.
#
# BRANCHES, NOT JUST HEAD
# ---------------------------------------------------------------------------
# A reviewer commits its probe on ITS OWN branch, which is exactly the branch
# the engineer has not merged. Discovering only HEAD would mean the probes
# written to judge THIS round are the ones this runner cannot see. So it also
# reads every local branch's manifest, materializes read-only what HEAD's does
# not list, and names the branch in the report. `codex/` is never read (point 2).
#
#     engine/scripts/workspace-probes.py                    # this tree's lib
#     engine/scripts/workspace-probes.py --lib <path>       # any workspaces.py
#     engine/scripts/workspace-probes.py --at <commit>      # that commit's lib
#     engine/scripts/workspace-probes.py --list             # discover only
#     engine/scripts/workspace-probes.py --tree-only        # skip other branches
#
# Exit 0 only when every discovered probe ran and every one of them was green.
# ===========================================================================
import argparse
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

# THE RUNNER WRITES NOTHING BESIDE THE LIBRARY IT LOADS. Loading workspaces.py
# to ask it the witness (integration_witness) is an import, and an import writes
# __pycache__/workspaces.cpython-*.pyc next to the source unless told not to. In
# the runner's own suite that file was then swept up by `git add -A` into a
# reviewer's retirement commit, and A2 refused the retirement for "also
# changing the engine" — the runner's own side effect defeating the runner's own
# check. A tool that judges commits must not put files into them.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))

# WHAT COUNTS AS DRIVING THE LIBRARY — the BACKSTOP rule, which finds a probe
# that was not listed. LOADERS is "a module is loaded from a path"; ENTRY_POINTS
# is the set of names that belong to THIS library and to nothing else in the
# engine. A file that does both, or names the library and does either, looks
# like a probe from outside; if it is not in the manifest it is UNLISTED.
LOADERS = ("spec_from_file_location", "exec_module", "import workspaces",
           "run_path", "SourceFileLoader", "load_source")
ENTRY_POINTS = ("barrier", "observe_created_refs", "register_spawn", "register_cc",
                "record_start", "record_end", "bind_agent", "integration_target",
                "integration_for", "record_integration", "load_agent", "snapshot_refs",
                "named_key", "all_integration_records", "finished_state")
DRIVES = LOADERS + ENTRY_POINTS

RETIREMENTS = "docs/verification/workspace-probe-retirements.tsv"
MANIFEST = "docs/verification/workspace-probes.manifest"
VERIFICATION_DIR = "docs/verification/"

# A probe's author, from its path. Both reviewers name themselves in the file
# name they commit, which is the convention this repository already follows.
AUTHOR_PAT = re.compile(r"certification-([a-z]+)-", re.I)

# A declared non-probe, with a reason of its own. A bare marker exempts nothing.
NOT_A_PROBE = re.compile(r"not-a-probe:[ \t]*\S+[ \t]+\S+", re.I)


def sh(*args, **kw):
    """(returncode, stdout, stderr) — never raises on a non-zero exit."""
    try:
        p = subprocess.run(list(args), capture_output=True, text=True,
                           timeout=kw.get("timeout", 60), env=kw.get("env"))
    except subprocess.TimeoutExpired:
        return 124, "", "timed out after %ss" % kw.get("timeout", 60)
    except OSError as e:
        return 127, "", str(e)
    return p.returncode, p.stdout, p.stderr


def git(repo, *args, **kw):
    return sh("git", "-C", repo, *args, **kw)


def repo_root():
    rc, out, _ = git(HERE, "rev-parse", "--show-toplevel")
    if rc != 0:
        raise SystemExit("workspace-probes.py: not inside a git repository")
    return out.strip()


# ---------------------------------------------------------------------------
# THE WITNESS — the recorded integration branch, asked of the library (point 14)
# ---------------------------------------------------------------------------
_WITNESS = {}


def integration_witness(root):
    """(branch, tip, why_not) for the repository the runner stands in — THE ONE
    ANSWER, read from scripts/lib/workspaces.py beside this file. Cached per run.

    Loading the library by path is a duplicated LOADER, not a duplicated ANSWER:
    there is one implementation of "what does this work integrate on" and it is
    the registry's. Where nothing is recorded the answer is a `why_not` naming
    the recording command, and this runner ABSTAINS into refusal — it never
    substitutes `main`."""
    if root in _WITNESS:
        return _WITNESS[root]
    lib = os.path.join(HERE, "lib", "workspaces.py")
    try:
        spec = importlib.util.spec_from_file_location("workspaces_answer", lib)
        ws = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ws)
        branch, tip, why_not = ws.integration_for(root)
    except Exception as e:  # noqa: BLE001 — a witness that cannot be read is no witness
        branch, tip, why_not = "", "", "the registry could not be read from %s: %s" % (lib, e)
    _WITNESS[root] = (branch or "", tip or "", why_not or "")
    return _WITNESS[root]


def is_ancestor(root, commit, tip):
    rc, _, _ = git(root, "merge-base", "--is-ancestor", commit, tip)
    return rc == 0


# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------
class Probe(object):
    def __init__(self, name, path, origin, text):
        self.name = name          # docs/verification/... — the committed path
        self.path = path          # where it can be executed from, now
        self.origin = origin      # "HEAD" or a branch name
        self.text = text
        self.shape = shape_of(text)
        self.author = author_of(name, text)
        self.cases = cases_of(text)
        self.verdict = ""         # GREEN / RED / UNRUNNABLE / RETIRED / MISSING / UNLISTED
        self.detail = ""
        self.seconds = 0.0
        self.output = ""
        self.listed = True        # in the manifest of its origin
        # The `not-a-probe:` declaration, if any. Held rather than acted on at
        # discovery time: whether it STANDS is a question for git (A1-A3), and a
        # declaration the runner refuses must leave the file a probe.
        m = NOT_A_PROBE.search(text)
        self.declared = m.group(0).strip() if m else ""
        self.declared_refused = ""
        # Per-case retirement: {case: (who, why, witness)} and the cases that
        # survive it. `retired_cases` is never allowed to become every case
        # silently -- that is the whole-file verdict and it is said as one.
        self.retired_cases = {}
        self.live_cases = list(self.cases)
        self.case_notes = []


def is_workspaces_probe(text):
    """The BACKSTOP: structural, so a probe that was not listed is still seen.
    It names the library and drives it, or it loads a module from a path and
    calls one of the library's own entry points. Both halves are needed -- the
    name alone matches any file that mentions a path, and `exec_module` alone
    matches half the engine.

    THE ONE WAY OUT IS A DECLARATION, not a path rule. A tool that builds or
    adapts probes looks exactly like a probe from outside, and a path rule
    cannot tell them apart: a reviewer's real probe lives under a `-logs/`
    directory today. So a file that is NOT a probe says so, in itself, where a
    reviewer reading it will see the claim:

        not-a-probe: <why this drives the library but asserts nothing>

    A bare marker exempts nothing. The runner counts declared files and names
    them under --show-all, so an exemption is visible rather than silent. Whether
    the declaration stands is decided against git by marker_authority()."""
    named = ("workspaces.py" in text) or ("workspaces.test.py" in text)
    loads = any(e in text for e in LOADERS)
    drives_entry = any(re.search(r"\b%s\s*\(" % e, text) for e in ENTRY_POINTS)
    if named and (loads or drives_entry):
        return True
    return loads and drives_entry


def shape_of(text):
    """How this probe is driven, read off the file itself."""
    if re.search(r"sys\.argv\[2\]", text) and re.search(r"SCENARIO\s*==", text):
        return "argv-scenario"        # one process per scenario, lib as argv[1]
    if re.search(r"main\(sys\.argv\[1:\]\)", text):
        return "argv"                 # lib as argv[0], cases after it
    if "workspaces.test.py" in text and "unittest" in text:
        return "in-tree"              # imports the engine's own test file
    return "unknown"


def cases_of(text):
    m = re.search(r"^CASES\s*=\s*\[(.*?)\]", text, re.M | re.S)
    if m:
        return re.findall(r"[\"']([^\"']+)[\"']", m.group(1))
    return sorted(set(re.findall(r"SCENARIO\s*==\s*[\"']([^\"']+)[\"']", text)))


def author_of(name, text):
    m = AUTHOR_PAT.search(os.path.basename(name))
    if m:
        return m.group(1).lower()
    m = re.search(r"^\s*\"\"\"(\w+)'s\b", text, re.M)
    if m:
        return m.group(1).lower()
    return "the engineer"


def file_at(root, ref, path):
    rc, out, _ = git(root, "show", "%s:%s" % (ref, path))
    return out if rc == 0 else None


def exists_at(root, ref, path):
    rc, _, _ = git(root, "cat-file", "-e", "%s:%s" % (ref, path))
    return rc == 0


def manifest_at(root, ref):
    """(entries, present). The manifest AT A COMMIT, via git — never the working
    tree, so an entry that was only typed discovers nothing and an entry that
    was only deleted from the tree still counts."""
    text = file_at(root, ref, MANIFEST)
    if text is None:
        return [], False
    out = []
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if line and line not in out:
            out.append(line)
    return out, True


def py_files_at(root, ref):
    rc, out, _ = git(root, "ls-tree", "-r", "--name-only", ref, VERIFICATION_DIR)
    if rc != 0:
        return []
    return [l.strip() for l in out.splitlines() if l.strip().endswith(".py")]


def materialize(root, ref, rel, stage, origin_tag):
    text = file_at(root, ref, rel)
    if text is None:
        return None
    dest = os.path.join(stage, origin_tag.replace("/", "_"), rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w", encoding="utf-8") as f:
        f.write(text)
    return Probe(rel, dest, "HEAD" if ref == "HEAD" else ref, text)


def head_probes(root, stage):
    """(probes, unlisted, others, manifest_present). Everything is read AT HEAD.

    Listed and present -> a probe. Listed and absent -> reported by
    deleted_probes() as MISSING. Present, not listed, and it looks like a probe
    -> UNLISTED (blocking) unless it carries a declaration, which is judged
    later against git like everything else."""
    entries, present = manifest_at(root, "HEAD")
    found, unlisted, others = [], [], 0
    seen = set()
    for rel in entries:
        if not rel.endswith(".py") or not exists_at(root, "HEAD", rel):
            continue
        p = materialize(root, "HEAD", rel, stage, "HEAD")
        if p is not None:
            found.append(p)
            seen.add(rel)
    for rel in py_files_at(root, "HEAD"):
        if rel in seen:
            continue
        text = file_at(root, "HEAD", rel)
        if text is None:
            continue
        if is_workspaces_probe(text):
            p = materialize(root, "HEAD", rel, stage, "HEAD")
            p.listed = False
            unlisted.append(p)
        else:
            others += 1
    return found, unlisted, others, present


def branch_probes(root, have, stage):
    """Probes committed on OTHER local branches — a reviewer's probe lives on the
    reviewer's branch, which is precisely the branch this round has not merged.
    A branch's own manifest says what it adds; a branch with no manifest is
    scanned by the text rule, which is the only thing it could have been judged
    by when it was written."""
    rc, out, _ = git(root, "rev-parse", "--abbrev-ref", "HEAD")
    mine = out.strip() if rc == 0 else ""
    rc, out, _ = git(root, "for-each-ref", "--format=%(refname:short)", "refs/heads")
    if rc != 0:
        return []
    found = []
    for br in sorted(out.split()):
        if br == mine or br.startswith("codex/"):      # point 2: never read codex/
            continue
        entries, present = manifest_at(root, br)
        candidates = entries if present else py_files_at(root, br)
        for rel in candidates:
            rel = rel.strip()
            if not rel.endswith(".py") or rel in have:
                continue
            text = file_at(root, br, rel)
            if text is None:
                continue
            if not present and not is_workspaces_probe(text):
                continue
            p = materialize(root, br, rel, stage, br)
            if p is not None:
                found.append(p)
                have.add(rel)
    return found


# ---------------------------------------------------------------------------
# ATTRIBUTION — the three questions git answers, and the text does not
# ---------------------------------------------------------------------------
HISTORY_LIMIT = 400


def head_branch(root):
    rc, out, _ = git(root, "rev-parse", "--abbrev-ref", "HEAD")
    return out.strip() if rc == 0 else ""


def introducing_commit(root, ref, path, needle):
    """The OLDEST commit reachable from <ref> whose <path> contains <needle> and
    whose first parent's does not.

    OLDEST, deliberately. A merge that carried the line onto this branch also
    "adds" it relative to its mainline parent, so taking the newest match would
    credit the land rather than the reviewer -- and the land is Rich's commit,
    which touches whatever the branch touched. The oldest match is the commit
    that actually wrote the line."""
    rc, out, _ = git(root, "log", "--format=%H", "-n", str(HISTORY_LIMIT),
                     ref or "HEAD", "--", path)
    if rc != 0:
        return ""
    found = ""
    for c in out.split():                       # newest first
        cur = file_at(root, c, path)
        if cur is None or needle not in cur:
            continue
        prev = file_at(root, c + "^", path)
        if prev is None or needle not in prev:
            found = c                           # ends on the oldest match
    return found


def commit_paths(root, commit):
    rc, out, _ = git(root, "show", "--name-only", "--format=", commit)
    if rc != 0:
        return []
    return [l.strip() for l in out.splitlines() if l.strip()]


def attributable(root, ref, path, needle, mine, docs_only=True):
    """(ok, witness_or_reason) — A1, A2, A3 in that order.

    Returns the WITNESS on success, because a retirement that is accepted has to
    say what stood behind it: a verdict of RETIRED with no witness named is the
    typed name all over again. The witness is the commit, the RECORDED
    integration branch it landed on, and that branch's tip at the time.

    `docs_only` IS A2, AND IT IS ASKED OF A RETIREMENT AND NOT OF A MARKER. The
    two declarations are not the same act. A retirement is about a probe that is
    RED, so the shortcut worth refusing is exactly "the commit that broke it also
    retired it". A `not-a-probe:` marker is about a file that asserts nothing, and
    the honest case for adding one is a helper committed alongside the engine
    change that needed it -- which is how the one such file in this tree got its
    marker, at 4c70bfc2, together with the runner. A1 and A3 still apply to the
    marker, and A3 now asks whether Rich LANDED it — a marker added on the branch
    under test, however many branches are cut at its tip, is refused."""
    commit = introducing_commit(root, ref, path, needle)
    if not commit:
        return False, ("A1: it is not in any commit reachable from %s. A line that "
                       "exists only in the working tree retires nothing -- an "
                       "unstaged edit is not a reviewer's act." % (ref or "HEAD"))
    paths = commit_paths(root, commit)
    outside = [q for q in paths if not q.startswith(VERIFICATION_DIR)]
    if docs_only and outside:
        return False, ("A2: the commit that wrote it (%s) also changes %s. A reviewer "
                       "ruling on its own probe never edits the engine, and a commit "
                       "that changes the library AND retires the probe the change is "
                       "failing is the shortcut this refuses."
                       % (commit[:12], ", ".join(sorted(outside)[:4])))
    branch, tip, why_not = integration_witness(root)
    if why_not:
        return False, ("A3: no branch is recorded as the one this repository's work "
                       "integrates on, so nothing can witness it (point 14). %s" % why_not)
    if not is_ancestor(root, commit, tip):
        return False, ("A3: the commit that wrote it (%s) has not landed on %s, the branch "
                       "recorded for this work (point 14). A reviewer commits on its own "
                       "branch and Rich lands it; a commit that has not reached the recorded "
                       "integration branch -- on %s, or on any branch cut at its tip -- cannot "
                       "retire anything. A branch NAME is no witness: point 4 deletes branches."
                       % (commit[:12], branch, mine or "the current lineage"))
    return True, "%s, landed on %s @ %s" % (commit[:12], branch, tip[:12])


def marker_authority(root, probe, mine):
    """Does this file's `not-a-probe:` declaration stand?

    A marker present in the commit that ADDED the file is its author declaring
    its own file, and needs nothing further -- that is the ordinary, honest case
    (a tool that builds probes, committed as a tool). A marker ADDED LATER is a
    statement about a file that already existed, so it answers A1-A3 like a
    retirement does."""
    ref = "HEAD" if probe.origin == "HEAD" else probe.origin
    rc, out, _ = git(root, "log", "--format=%H", "--diff-filter=A", "-n", "5",
                     ref, "--", probe.name)
    if rc == 0 and out.split():
        first = out.split()[-1]
        text = file_at(root, first, probe.name)
        if text is not None and NOT_A_PROBE.search(text):
            return True, "declared in the commit that added the file (%s)" % first[:12]
    return attributable(root, ref, probe.name, probe.declared, mine, docs_only=False)


def deleted_probes(root, mine):
    """Paths under docs/verification/ that USED to hold a probe of this library
    and hold nothing AT HEAD, plus manifest entries that hold nothing at HEAD.

    ASKED OF GIT, NEVER OF THE WORKING TREE (route 4, re-opened on 2026-09-12 by
    an uncommitted file at the deleted path). Renames are not deletions -- git's
    own rename detection reports those as R -- so this names files that were
    removed, which is the only way a probe can leave without a retirement."""
    gone = []
    rc, out, _ = git(root, "log", "--diff-filter=D", "--name-only",
                     "--format=C%H", "-n", str(HISTORY_LIMIT),
                     mine or "HEAD", "--", VERIFICATION_DIR + "*.py")
    if rc == 0:
        commit = ""
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            if line.startswith("C") and len(line) == 41:
                commit = line[1:]
                continue
            if exists_at(root, "HEAD", line):
                continue                     # deleted once, present again at HEAD
            text = file_at(root, commit + "^", line)
            if text is None or not is_workspaces_probe(text):
                continue
            if all(q != line for q, _c in gone):
                gone.append((line, commit))
    entries, _present = manifest_at(root, "HEAD")
    for rel in entries:
        if rel.endswith(".py") and not exists_at(root, "HEAD", rel) and all(q != rel for q, _c in gone):
            gone.append((rel, "the manifest lists it and HEAD does not have it"))
    return gone


def retirements(root):
    """{probe basename: {"whole": (who, why, raw) | None,
                         "cases": {case: (who, why, raw)}}}

    TWO SHAPES, BOTH READ. Four fields is per-CASE; three is the whole FILE, which
    is what every line committed before 2026-09-12 has. The three-field form is
    NOT deprecated and must not be rewritten: the introducing commit is the
    author's, and an engineer who reformatted the line would become the author of
    that commit and A3 would then refuse his own edit. `*` is the explicit
    whole-file case.

    The RAW LINE travels with every record, because attribution is asked about the
    exact text that was committed rather than about the file -- without that, a
    line could be edited in place and inherit somebody else's commit. The file is
    read from the working tree so that an UNCOMMITTED line can be named in the
    refusal (A1) rather than silently ignored; nothing below trusts it without
    asking git."""
    path = os.path.join(root, RETIREMENTS)
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = [q.strip() for q in line.split("\t")]
        if len(parts) < 3:
            continue
        base = os.path.basename(parts[0])
        rec = out.setdefault(base, {"whole": None, "cases": {}})
        if len(parts) >= 4 and parts[1] and parts[1] != "*":
            rec["cases"][parts[1]] = (parts[2], parts[3], line)
        elif len(parts) >= 4:
            rec["whole"] = (parts[2], parts[3], line)
        else:
            rec["whole"] = (parts[1], parts[2], line)
    return out


def deletion_excused(root, rel, retired, mine):
    """A deleted probe is not MISSING only when a WHOLE-FILE retirement for it
    passes the same two checks a live retirement passes: the signature matches
    the author the file name carries, and the line is attributable (A1-A3).
    An uncommitted line, a line signed by anyone else, or a per-case line
    excuses nothing -- deletion is not a per-case act."""
    rec = retired.get(os.path.basename(rel))
    if not rec or not rec.get("whole"):
        return False, "no whole-file retirement names it"
    who, _why, raw = rec["whole"]
    author = author_of(rel, "")
    if who.lower() != author:
        return False, ("its retirement is signed '%s' but the probe's author is '%s'"
                       % (who, author))
    ok, detail = attributable(root, "HEAD", RETIREMENTS, raw, mine)
    return ok, detail


# ---------------------------------------------------------------------------
# running
# ---------------------------------------------------------------------------
def stage_in_tree(root, lib, workdir, probe):
    """An in-tree probe reaches for engine/scripts/lib/ relative to ITSELF. Give
    it a throwaway tree whose lib is the workspaces.py under test, so that
    "against a given workspaces.py" means the same for every shape of probe."""
    libdir = os.path.join(workdir, "engine", "scripts", "lib")
    os.makedirs(libdir, exist_ok=True)
    src = os.path.join(root, "engine", "scripts", "lib")
    for fn in os.listdir(src):
        s = os.path.join(src, fn)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(libdir, fn))
    shutil.copy2(lib, os.path.join(libdir, "workspaces.py"))
    dest = os.path.join(workdir, os.path.dirname(probe.name))
    os.makedirs(dest, exist_ok=True)
    run_at = os.path.join(dest, os.path.basename(probe.name))
    shutil.copy2(probe.path, run_at)
    return run_at


def run_probe(root, lib, probe, timeout):
    env = dict(os.environ)
    env.pop("RICHOS_SESSION_ID", None)
    started = time.time()
    workdir = tempfile.mkdtemp(prefix="wsprobe-")
    try:
        if probe.shape == "argv-scenario":
            # It asserts nothing: it PRINTS what the library did and its author
            # read the verdict off the page. So it cannot go red on an
            # expectation — only on blowing up — and it can never certify
            # anything either. Both halves of that are said out loud below.
            rc, out, err = 0, "", ""
            # RETIRED SCENARIOS ARE NEVER STARTED. One process per case is what
            # makes per-case retirement exact for this shape.
            for sc in probe.live_cases:
                c, o, e = sh(sys.executable, "-B", probe.path, lib, sc,
                             timeout=timeout, env=env)
                out += "\n--- %s (exit %d)\n%s" % (sc, c, o)
                err += e
                if c != 0:
                    rc = c
            probe.seconds = time.time() - started
            probe.output = (out + err).strip()
            if rc == 0:
                probe.verdict = "OBSERVED"
                probe.detail = ("%d scenarios ran and none blew up — but this probe ASSERTS "
                                "NOTHING, so it can neither regress nor certify. Its verdict "
                                "lives in its author's certification, not in the file."
                                % len(probe.live_cases))
            else:
                probe.verdict = "RED"
                probe.detail = "a scenario failed to run: exit %d" % rc
            return
        if probe.shape == "argv":
            # THE SURVIVING CASES ARE PASSED, and only when some case was retired
            # -- an argv probe's documented interface is `probe.py <lib> [case
            # ...]`, and passing the full list where nothing was retired would
            # change how every existing probe is invoked for no reason.
            argv_cases = list(probe.live_cases) if probe.retired_cases else []
            rc, out, err = sh(sys.executable, "-B", probe.path, lib, *argv_cases,
                              timeout=timeout, env=env)
        elif probe.shape == "in-tree":
            run_at = stage_in_tree(root, lib, workdir, probe)
            rc, out, err = sh(sys.executable, "-B", run_at, timeout=timeout, env=env)
        else:
            probe.verdict = "UNRUNNABLE"
            probe.detail = ("no runnable shape: it neither takes a workspaces.py path "
                            "nor imports the engine's own test file")
            return
        probe.seconds = time.time() - started
        probe.output = (out + err).strip()
        if rc == 0:
            probe.verdict = "GREEN"
            if probe.retired_cases:
                probe.detail = ("ran %d of %d case(s); the rest are retired per case. %s"
                                % (len(probe.live_cases), len(probe.cases),
                                   " | ".join(probe.case_notes)))
        elif rc != 0 and probe.retired_cases and probe.shape == "argv":
            # FAIL CLOSED, AND SAY WHICH IT IS. The runner cannot make a probe
            # honor its case arguments. If one ignores them it runs the retired
            # case anyway and stays red, which is the safe direction -- and the
            # two explanations are not the same thing, so neither is guessed.
            probe.verdict = "RED"
            probe.detail = ("exit %d with %d of %d case(s) requested (%s). Either this probe "
                            "ignores the case arguments the runner passes, or a case nobody "
                            "retired is genuinely red. %s"
                            % (rc, len(probe.live_cases), len(probe.cases),
                               ", ".join(probe.live_cases), " | ".join(probe.case_notes)))
            return
        elif rc == 124:
            probe.verdict = "UNRUNNABLE"
            probe.detail = "timed out after %ss" % timeout
        elif rc == 2 and probe.shape == "argv" and not out.strip():
            # argv-shaped probes use exit 2 for "you called me wrong" — which
            # means this runner could not drive it, not that the build is red.
            probe.verdict = "UNRUNNABLE"
            probe.detail = ("it refused the arguments this runner passes: %s"
                            % (err.strip().splitlines() or ["(nothing on stderr)"])[0])
        else:
            probe.verdict = "RED"
            probe.detail = "exit %d" % rc
    finally:
        shutil.rmtree(workdir, ignore_errors=True)


# ---------------------------------------------------------------------------
# the refusal
# ---------------------------------------------------------------------------
REFUSAL = """
===========================================================================
A PRIOR PROBE IS RED. THIS BLOCKS.
===========================================================================
A probe under docs/verification/ is the sentence of the CEO's page that this
build was once held to. A red one is not a stale assertion until its AUTHOR
says it is.

THE ONLY THING THAT CAN RETIRE A PROBE IS THE REVIEWER WHO WROTE IT, AGREEING
THAT IT IS OBSOLETE. Never the engineer who is failing it — an engineer failing
a probe is the person with a reason to believe it is wrong and the person least
able to tell "this assertion is obsolete" from "I just broke this".

To retire one, its author adds a line to:

    %s
    <probe filename>\t<author>\t<why it is obsolete>

and commits it. This runner reads that file, checks the signature against the
probe's own author, and names any mismatch.

AND A TYPED NAME IS NOT AUTHORITY. The name is checked, and then git is asked
three questions the party failing the probe cannot answer from inside its own
work:

    A1  the line is in a COMMIT -- a working-tree edit retires nothing
    A2  that commit touches nothing outside docs/verification/ -- the commit
        that broke the probe may not be the commit that retires it
    A3  that commit has LANDED on the branch recorded as the one this work
        integrates on (point 14) -- a reviewer commits on its own branch and
        Rich lands it; a branch name is no witness, since point 4 deletes them

Every retirement that is accepted prints its commit and the landed-on branch,
so what stood behind it is on the record rather than taken on trust.

RETIREMENT IS PER CASE. A reviewer who finds three of his six cases obsolete and
three still live retires the three, and the probe goes on running the other three:

    <probe filename>\t<case>\t<author>\t<why this one case is obsolete>

Keyed on the FILE, that reviewer's only options were to drop five green
assertions to buy one green exit code, or to write nothing. He wrote nothing, and
he was right to.

A PROBE ALSO NEVER LEAVES BY BEING DELETED. A path that used to hold a probe and
holds nothing at HEAD is MISSING, and MISSING blocks exactly like RED: deletion
is not attributable to anybody, which is the whole reason retirement is.

A PROBE IS ASKED BECAUSE ITS AUTHOR LISTED IT. A committed file that looks like
a probe and is not in %s is UNLISTED, and UNLISTED blocks: add its line, or
declare `not-a-probe: <why>` inside it.

Everything else is a regression to fix.
===========================================================================
""" % (RETIREMENTS, MANIFEST)


def main(argv):
    ap = argparse.ArgumentParser(add_help=True, description=__doc__)
    ap.add_argument("--lib", default="", help="the workspaces.py under test")
    ap.add_argument("--at", default="", help="a commit whose workspaces.py to test")
    ap.add_argument("--only", action="append", default=[],
                    help="run only probes whose path contains this")
    ap.add_argument("--list", action="store_true", help="discover and classify only")
    ap.add_argument("--tree-only", action="store_true",
                    help="do not read probes committed on other local branches")
    ap.add_argument("--show-all", action="store_true",
                    help="also name the files that are not probes of this library")
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args(argv)

    root = repo_root()
    stage = tempfile.mkdtemp(prefix="wsprobes-stage-")
    try:
        lib = args.lib
        if args.at:
            if lib:
                raise SystemExit("workspace-probes.py: --lib and --at are exclusive")
            rc, text, err = git(root, "show", "%s:engine/scripts/lib/workspaces.py" % args.at)
            if rc != 0:
                raise SystemExit("workspace-probes.py: no workspaces.py at %s: %s"
                                 % (args.at, err.strip()))
            lib = os.path.join(stage, "workspaces-at-%s.py" % args.at.replace("/", "_"))
            with open(lib, "w", encoding="utf-8") as f:
                f.write(text)
        if not lib:
            lib = os.path.join(root, "engine", "scripts", "lib", "workspaces.py")
        lib = os.path.abspath(lib)
        if not os.path.exists(lib):
            raise SystemExit("workspace-probes.py: no such workspaces.py: %s" % lib)

        probes, unlisted, others, manifest_present = head_probes(root, stage)
        have = set(p.name for p in probes) | set(p.name for p in unlisted)
        if not args.tree_only:
            probes += branch_probes(root, have, stage)
        probes.sort(key=lambda p: (p.origin != "HEAD", p.name))
        mine = head_branch(root)
        w_branch, w_tip, w_why = integration_witness(root)

        # THE DECLARATION IS SETTLED BEFORE ANYTHING IS COUNTED, and it is
        # settled against git. A file whose `not-a-probe:` marker STANDS leaves
        # the run and is named; a file whose marker is REFUSED stays a probe and
        # carries the refusal into its report line. An UNLISTED file with a
        # standing declaration is a declared tool, not an unlisted probe.
        declared_out = []
        kept = []
        for pr in probes + unlisted:
            if not pr.declared:
                kept.append(pr)
                continue
            okd, whyd = marker_authority(root, pr, mine)
            if okd:
                pr.detail = whyd
                declared_out.append(pr)
            else:
                pr.declared_refused = whyd
                kept.append(pr)
        unlisted = [p for p in kept if not p.listed]
        probes = [p for p in kept if p.listed]
        discovered = len(probes)
        at_head = sum(1 for p in probes if p.origin == "HEAD")
        if args.only:
            probes = [p for p in probes if any(o in p.name for o in args.only)]
            unlisted = [p for p in unlisted if any(o in p.name for o in args.only)]

        retired = retirements(root)

        # ROUTE 4: a probe that is GONE. Asked of git, not of the tree, because
        # the tree is exactly where a deleted probe is invisible. A probe its
        # author retired is not missing -- it left the documented way -- so the
        # retirement filter is applied HERE, before the count is printed, and it
        # asks the same questions a live retirement answers: the name, and
        # A1-A3. An uncommitted line, or a line signed by anyone else, excuses
        # nothing (route 4 was re-opened by exactly that on 2026-09-12).
        missing = []
        for q, c in deleted_probes(root, mine):
            ok, why = deletion_excused(root, q, retired, mine)
            if not ok:
                missing.append((q, c, why))
        print("workspaces.py under test: %s" % lib)
        print("manifest:                 %s @ HEAD%s"
              % (MANIFEST, "" if manifest_present else "  — NOT COMMITTED: nothing is listed, so "
                 "every committed file that looks like a probe is UNLISTED below"))
        print("probes discovered:        %d (%d listed at HEAD, %d on other branches)%s"
              % (discovered, at_head, discovered - at_head,
                 "" if not args.only else
                 "  — %d selected by --only, SO THIS RUN PROVES NOTHING ABOUT THE REST"
                 % len(probes)))
        print("branch under test:        %s" % (mine or "(detached HEAD)"))
        if w_why:
            print("integration branch:       NOT RECORDED — every retirement and every later-added "
                  "declaration is refused until it is: %s" % w_why)
        else:
            print("integration branch:       %s @ %s (recorded; the witness every retirement must "
                  "have landed on)" % (w_branch, w_tip[:12]))
        print("declared not-a-probe:     %d (each named below; a declaration is checked "
              "against git, never read)" % len(declared_out))
        print("probes DELETED from history and not retired: %d" % len(missing))
        print("committed probes NOT LISTED in the manifest: %d" % len(unlisted))
        print("other files under docs/verification/ that are not probes of this library: %d%s"
              % (others, "" if args.show_all else "  (--show-all names them)"))
        print("")
        for pr in declared_out:
            print("%-10s %s" % ("DECLARED", pr.name))
            print("           %s" % pr.detail)
            print("           %s" % pr.declared)

        def check_retirement(pr, who, why, raw, what):
            """(ok, detail) — the name, then git. `what` is 'this probe' or
            'case <x>', so a refusal says WHICH line it is about."""
            if who.lower() != pr.author:
                return False, ("the retirement of %s is signed '%s' but the probe's author "
                               "is '%s'. Only a probe's own author may retire it."
                               % (what, who, pr.author))
            # A TYPED NAME IS NOT AUTHORITY. The name matches; now git is asked
            # whether the party failing this probe could have written the line
            # inside its own work.
            okr, witness = attributable(root, "HEAD", RETIREMENTS, raw, mine)
            if not okr:
                return False, ("the retirement of %s names the right author ('%s') and is "
                               "NOT attributable to that author. %s" % (what, who, witness))
            return True, witness

        for p in probes:
            base = os.path.basename(p.name)
            rec = retired.get(base)
            if rec and rec["whole"]:
                who, why, raw = rec["whole"]
                okw, detail = check_retirement(p, who, why, raw, "this probe")
                if not okw:
                    p.verdict = "UNRUNNABLE"
                    p.detail = detail
                    continue
                p.verdict = "RETIRED"
                p.detail = "%s [%s]: %s" % (who, detail, why)
                continue
            if rec and rec["cases"]:
                # PER CASE. Every line is checked on its own, a line naming a
                # case this probe does not have is REFUSED rather than ignored
                # (it is a typo or a line copied from another probe, and both are
                # worth seeing), and retiring every case is the whole file said
                # out loud rather than arrived at by subtraction.
                refusal = ""
                for case in sorted(rec["cases"]):
                    who, why, raw = rec["cases"][case]
                    if case not in p.cases:
                        refusal = ("its retirement names case '%s', which this probe does not "
                                   "have. Its cases are: %s. A retirement that matches nothing "
                                   "is a typo or a line copied from another probe, and either "
                                   "way it retires nothing."
                                   % (case, ", ".join(p.cases) or "(none the runner can read)"))
                        break
                    okc, detail = check_retirement(p, who, why, raw, "case '%s'" % case)
                    if not okc:
                        refusal = detail
                        break
                    p.retired_cases[case] = (who, why, detail)
                if refusal:
                    p.verdict = "UNRUNNABLE"
                    p.detail = refusal
                    p.retired_cases = {}
                    continue
                p.live_cases = [c for c in p.cases if c not in p.retired_cases]
                p.case_notes = ["case '%s' retired by %s [%s]: %s"
                                % (c, p.retired_cases[c][0], p.retired_cases[c][2],
                                   p.retired_cases[c][1])
                                for c in sorted(p.retired_cases)]
                if not p.live_cases:
                    p.verdict = "RETIRED"
                    p.detail = ("every one of its %d case(s) is retired, so the file is retired. "
                                "%s" % (len(p.cases), " | ".join(p.case_notes)))
                    continue
            if args.list:
                p.verdict = "(not run)"
                p.detail = ("shape=%s author=%s cases=%d%s"
                            % (p.shape, p.author, len(p.cases),
                               "" if not p.retired_cases
                               else " (%d retired per case: %s)"
                               % (len(p.retired_cases), ", ".join(sorted(p.retired_cases)))))
                continue
            run_probe(root, lib, p, args.timeout)

        for p in unlisted:
            p.verdict = "UNLISTED"
            p.detail = ("it is committed, it looks like a probe of this library, and %s does not "
                        "list it. A probe is asked because its author listed it; add its line, or "
                        "declare `not-a-probe: <why>` inside the file." % MANIFEST)

        width = max([len(p.name) for p in probes + unlisted] + [10])
        for p in probes + unlisted:
            where = "" if p.origin == "HEAD" else "   [%s]" % p.origin
            print("%-10s %-*s %6.1fs%s" % (p.verdict, width, p.name, p.seconds, where))
            if p.declared_refused:
                print("           DECLARATION REFUSED, so this file is still a probe: %s"
                      % p.declared_refused)
            if p.detail:
                print("           %s" % p.detail)
            elif p.case_notes:
                # PRINTED EVEN WHEN THE PROBE IS GREEN AND SAID NOTHING ELSE. A
                # per-case retirement reduces what was asked, and a reduction
                # nobody can see on the report is a coverage loss nobody can see.
                for note in p.case_notes:
                    print("           %s" % note)

        if args.show_all:
            # IT NAMED NOTHING, AND IT COUNTED 242. The filter was `if rel not in
            # have: continue` -- `have` is the set of PROBE paths, so the only
            # files that got past it were probes, and the next line then dropped
            # every one of them. An inventory that names none of what it counts is
            # the count on its own, which is the thing --show-all was offered as
            # the answer to.
            print("\n--- files under docs/verification/ at HEAD that are not probes of this library ---")
            probe_paths = set(pr.name for pr in probes + unlisted) | set(pr.name for pr in declared_out)
            named = 0
            for rel in py_files_at(root, "HEAD"):
                if rel in probe_paths:
                    continue
                print("    %s" % rel)
                named += 1
            print("    (%d named; the count above was %d — if these two disagree, believe "
                  "neither)" % (named, others))

        red = [p for p in probes if p.verdict == "RED"]
        stuck = [p for p in probes if p.verdict == "UNRUNNABLE"]
        # A DELETED PROBE IS BLOCKING, and it is blocking even under --list,
        # because --list is a discovery command and a probe that is gone is
        # exactly a discovery result. It is filtered by --only like any other.
        gone = [(q, c, w) for q, c, w in missing
                if not args.only or any(o in q for o in args.only)]
        for q, c, w in gone:
            print("%-10s %s" % ("MISSING", q))
            print("           it held a probe of this library and is DELETED at HEAD (%s). A probe "
                  "leaves by retirement, which is attributable, and never by deletion, which "
                  "is not (%s). Restore it, or have its author retire it in %s."
                  % (c[:12] if len(c) == 40 else c, w, RETIREMENTS))
        if args.list:
            return 1 if (gone or unlisted) else 0     # --list runs nothing and claims nothing

        print("")
        for p in red + stuck:
            print("=== %s — %s%s" % (p.verdict, p.name,
                                     "" if p.origin == "HEAD" else "  [%s]" % p.origin))
            if p.detail:
                print("    %s" % p.detail)
            for line in (p.output or "").splitlines()[-25:]:
                print("    | %s" % line)
            print("")

        if red or stuck or gone or unlisted:
            print(REFUSAL)
            if gone:
                print("DELETED (a probe that used to exist and does not):")
                for q, c, w in gone:
                    print("    %s   removed in %s" % (q, c[:12] if len(c) == 40 else c))
            if unlisted:
                print("UNLISTED (a committed probe the manifest does not name):")
                for p in unlisted:
                    print("    %s" % p.name)
            if red:
                print("RED (a prior probe now fails):")
                for p in red:
                    print("    %s   author: %s" % (p.name, p.author))
            if stuck:
                print("DID NOT RUN — and a probe the runner cannot execute is NOT a probe")
                print("that passed. Each of these is as blocking as a red one:")
                for p in stuck:
                    print("    %s   %s" % (p.name, p.detail))
            return 1

        if not probes:
            # A RUN THAT ASKED NOTHING IS NOT A RUN THAT PASSED. With no probe
            # selected this used to print the green line and exit 0, which is
            # byte-for-byte what a clean full run looks like -- a --only that
            # matches nothing, a discovery rule that quietly stopped matching,
            # or an empty docs/verification/ would all have read as "all clear".
            print("NOTHING WAS RUN. %d probe(s) were discovered and %s."
                  % (discovered,
                     "none was selected by --only %s" % ", ".join(args.only) if args.only
                     else "not one of them is a probe of this library"))
            print("A run that asked nothing is not a run that passed.")
            return 1
        print("every discovered probe ran, and every one of them is green.")
        return 0
    finally:
        shutil.rmtree(stage, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
