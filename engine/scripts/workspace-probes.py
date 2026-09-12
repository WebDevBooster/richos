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
# UNTIL 2026-09-12 THE ONLY CHECK ON THAT LINE WAS THAT <who> SPELLED THE
# PROBE'S AUTHOR — and a name is a string anybody can type. Both reviewers
# reproduced it in throwaway repositories: a retirement signed with the other
# reviewer's name, written by the party failing the probe, turned RED into
# RETIRED and the run exited 0. So the signature is now checked against
# something the failing party cannot produce INSIDE ITS OWN WORK. Three
# questions, all answered from git, none of them from the text of the line:
#
#   A1  IS IT COMMITTED AT ALL? A line that exists only in the working tree
#       retires nothing. An unstaged edit is not a reviewer's act.
#   A2  DOES THE COMMIT THAT INTRODUCED IT TOUCH ANYTHING OUTSIDE
#       docs/verification/? A reviewer ruling on its own probe never edits the
#       engine. A commit that changes the library AND retires the probe that the
#       change is failing is refused by construction — which is the exact shape
#       of the shortcut this is here to stop.
#   A3  IS THAT COMMIT CONTAINED IN A LOCAL BRANCH OTHER THAN THE ONE UNDER
#       TEST? A reviewer commits on the reviewer's branch and Rich lands it, so
#       an honest retirement is reachable from at least one other branch (its
#       author's, or the branch it landed on). A commit that exists ONLY in the
#       lineage being judged cannot retire anything. The witnessing branch is
#       NAMED in the report, so a retirement that is accepted always says what
#       stood behind it.
#
# WHAT THIS STILL DOES NOT DO, SAID HERE RATHER THAN DISCOVERED LATER: every
# agent on this machine commits under one git identity, and there is no secret
# only a reviewer holds. A1-A3 make it impossible to retire a probe from inside
# the work that is failing it; they do not make impersonation impossible. An
# engineer who creates a branch and commits a docs-only retirement on it will
# pass A1-A3. What stops that is not a check — it is that the witness is printed
# with every retirement, so the act is on the record rather than invisible.
# Closing it properly needs a signature a reviewer alone can make, which needs a
# key nothing in this engine has yet.
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
# either
#   (a) names workspaces.py / workspaces.test.py AND drives the library, or
#   (b) LOADS A MODULE FROM A PATH and calls one of the library's own entry
#       points — which is a probe that takes the library as an argument and
#       never spells the file name anywhere.
#
# (b) is not a generalization for its own sake. A probe of exactly that shape
# was invisible to this runner, and UNDISCOVERED IS WORSE THAN RED: a red probe
# stops a commit and an invisible one does not exist. Measured over the 253 .py
# files under docs/verification/ in this tree, (b) adds zero files that (a) did
# not already find, so the widening costs no false positives here.
#
# That is a structural test, so a new probe is discovered by being committed and
# by nothing else — no registration step, no list to keep in step.
#
# A PROBE THAT DISAPPEARS IS A PROBE THAT WAS DELETED
# ---------------------------------------------------------------------------
# Route 4 of four: removing the file only lowers a count nothing was checking.
# So the runner also asks git which paths under docs/verification/ USED to hold
# a probe and hold nothing now, and reports each as MISSING — as blocking as a
# red one. A probe leaves by retirement, which is attributable, and never by
# deletion, which is not.
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
# BRANCHES, NOT JUST THE WORKING TREE
# ---------------------------------------------------------------------------
# A reviewer commits its probe on ITS OWN branch, which is exactly the branch
# the engineer has not merged. Discovering only the working tree would mean the
# probes written to judge THIS round are the ones this runner cannot see. So it
# also reads every local branch that carries probes the tree does not have,
# materializes them read-only into a temporary directory, and names the branch
# in the report. `codex/` is never read (spec point 2).
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
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))

# WHAT COUNTS AS DRIVING THE LIBRARY. This was a list of entry points spelled
# with their opening parenthesis, and that was too narrow in the one direction
# that matters: a probe reaching the library through `getattr`, or naming an
# entry point without calling it, was SILENTLY NOT DISCOVERED. Undiscovered is
# strictly worse than red -- a red probe stops a commit and an invisible one
# does not exist. So loading the library at all counts, which is something every
# probe of it must do however it then drives it.
#
# THE TWO HALVES ARE NOW SEPARATE, because the library's file name is not a
# reliable part of a probe. LOADERS is "a module is loaded from a path" -- the
# only way to drive a workspaces.py handed over as an argument. ENTRY_POINTS is
# the set of names that belong to THIS library and to nothing else in the
# engine. A file that does both is a probe of this library whether or not it ever
# writes the string "workspaces.py".
LOADERS = ("spec_from_file_location", "exec_module", "import workspaces",
           "run_path", "SourceFileLoader", "load_source")
ENTRY_POINTS = ("barrier", "observe_created_refs", "register_spawn", "register_cc",
                "record_start", "record_end", "bind_agent", "integration_target",
                "integration_for", "record_integration", "load_agent", "snapshot_refs",
                "named_key", "all_integration_records", "finished_state")
DRIVES = LOADERS + ENTRY_POINTS

RETIREMENTS = "docs/verification/workspace-probe-retirements.tsv"
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
# discovery
# ---------------------------------------------------------------------------
class Probe(object):
    def __init__(self, name, path, origin, text):
        self.name = name          # docs/verification/... — the committed path
        self.path = path          # where it can be executed from, now
        self.origin = origin      # "working tree" or a branch name
        self.text = text
        self.shape = shape_of(text)
        self.author = author_of(name, text)
        self.cases = cases_of(text)
        self.verdict = ""         # GREEN / RED / UNRUNNABLE / RETIRED / MISSING
        self.detail = ""
        self.seconds = 0.0
        self.output = ""
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
    """Structural, so a new probe is discovered by being committed: it names the
    library and it drives it. Both halves are needed -- the name alone matches
    any file that mentions a path, and `exec_module` alone matches half the
    engine.

    THE ONE WAY OUT IS A DECLARATION, not a path rule. A tool that builds or
    adapts probes looks exactly like a probe from outside, and a path rule
    cannot tell them apart: a reviewer's real probe lives under a `-logs/`
    directory today. So a file that is NOT a probe says so, in itself, where a
    reviewer reading it will see the claim:

        not-a-probe: <why this drives the library but asserts nothing>

    A bare marker exempts nothing -- the same discipline the contrast floor and
    the dialect guard use. The runner counts declared files and names them under
    --show-all, so an exemption is visible rather than silent.

    THE DECLARATION IS NOT APPLIED HERE ANY MORE. Dropping a declared file at
    discovery meant a marker ADDED to somebody else's probe removed it from the
    run with no check on who added it, and the run then said "every discovered
    probe ran, and every one of them is green" and exited 0. So a declared file
    is still discovered, and whether the declaration stands is decided against
    git by marker_authority() -- the same three questions a retirement answers.

    THE NAME OF THE LIBRARY IS NOT REQUIRED. A probe handed the library as an
    argument need never write the string, and that probe was invisible."""
    named = ("workspaces.py" in text) or ("workspaces.test.py" in text)
    loads = any(e in text for e in LOADERS)
    drives_entry = any(re.search(r"\b%s\s*\(" % e, text) for e in ENTRY_POINTS)
    if named and (loads or drives_entry):
        return True
    return loads and drives_entry


def shape_of(text):
    """How this probe is driven, read off the file itself — so a probe is
    discovered by being committed, never by being registered somewhere."""
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


def tree_probes(root):
    found = []
    base = os.path.join(root, "docs", "verification")
    others = 0
    for dirpath, _dirnames, filenames in os.walk(base):
        for fn in sorted(filenames):
            if not fn.endswith(".py"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root)
            try:
                text = open(full, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            if is_workspaces_probe(text):
                found.append(Probe(rel, full, "working tree", text))
            else:
                others += 1
    return found, others


def branch_probes(root, have, stage):
    """Probes committed on OTHER local branches — a reviewer's probe lives on the
    reviewer's branch, which is precisely the branch this round has not merged."""
    rc, out, _ = git(root, "rev-parse", "--abbrev-ref", "HEAD")
    mine = out.strip() if rc == 0 else ""
    rc, out, _ = git(root, "for-each-ref", "--format=%(refname:short)", "refs/heads")
    if rc != 0:
        return []
    found = []
    for br in sorted(out.split()):
        if br == mine or br.startswith("codex/"):      # point 2: never read codex/
            continue
        rc, listing, _ = git(root, "ls-tree", "-r", "--name-only", br, "docs/verification/")
        if rc != 0:
            continue
        for rel in sorted(listing.splitlines()):
            rel = rel.strip()
            if not rel.endswith(".py") or rel in have:
                continue
            rc, text, _ = git(root, "show", "%s:%s" % (br, rel))
            if rc != 0 or not is_workspaces_probe(text):
                continue
            dest = os.path.join(stage, br.replace("/", "_"), rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "w", encoding="utf-8") as f:
                f.write(text)
            found.append(Probe(rel, dest, br, text))
            have.add(rel)
    return found


# ---------------------------------------------------------------------------
# ATTRIBUTION — the three questions git answers, and the text does not
# ---------------------------------------------------------------------------
HISTORY_LIMIT = 400


def head_branch(root):
    rc, out, _ = git(root, "rev-parse", "--abbrev-ref", "HEAD")
    return out.strip() if rc == 0 else ""


def file_at(root, ref, path):
    rc, out, _ = git(root, "show", "%s:%s" % (ref, path))
    return out if rc == 0 else None


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


def witness_branches(root, commit, mine):
    """Local branches OTHER than the one under test that contain <commit>.

    `codex/` is never read (spec point 2), and a detached HEAD yields no `mine`,
    in which case every branch counts as a witness -- the honest answer, since
    there is then no branch under test to exclude."""
    rc, out, _ = git(root, "branch", "--format=%(refname:short)", "--contains", commit)
    if rc != 0:
        return []
    out_branches = []
    for b in out.splitlines():
        b = b.strip().lstrip("* ").strip()
        if not b or b.startswith("codex/") or b == mine or b.startswith("("):
            continue
        out_branches.append(b)
    return out_branches


def attributable(root, ref, path, needle, mine, docs_only=True):
    """(ok, witness_or_reason) — A1, A2, A3 in that order.

    Returns the WITNESS on success, because a retirement that is accepted has to
    say what stood behind it: a verdict of RETIRED with no witness named is the
    typed name all over again.

    `docs_only` IS A2, AND IT IS ASKED OF A RETIREMENT AND NOT OF A MARKER. The
    two declarations are not the same act. A retirement is about a probe that is
    RED, so the shortcut worth refusing is exactly "the commit that broke it also
    retired it". A `not-a-probe:` marker is about a file that asserts nothing, and
    the honest case for adding one is a helper committed alongside the engine
    change that needed it -- which is how the one such file in this tree got its
    marker, at 4c70bfc2, together with the runner. Refusing that would be an
    over-strict rule whose only effect is a waiver, and a habit of waiving is how
    a check dies. A1 and A3 still apply to the marker, and A3 is the one that
    refuses route 1: a marker added by the party failing the probe, on its own
    branch, witnessed by nothing."""
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
    witnesses = witness_branches(root, commit, mine)
    if not witnesses:
        return False, ("A3: the commit that wrote it (%s) exists only in %s, the branch "
                       "under test. A reviewer commits on its own branch and Rich lands "
                       "it, so an honest retirement is reachable from some other branch. "
                       "Work cannot retire the probe it is failing."
                       % (commit[:12], mine or "the current lineage"))
    return True, "%s, witnessed by %s" % (commit[:12], ", ".join(sorted(witnesses)[:3]))


def marker_authority(root, probe, mine):
    """Does this file's `not-a-probe:` declaration stand?

    A marker present in the commit that ADDED the file is its author declaring
    its own file, and needs nothing further -- that is the ordinary, honest case
    (a tool that builds probes, committed as a tool). A marker ADDED LATER is a
    statement about a file that already existed, so it answers A1-A3 like a
    retirement does."""
    ref = "HEAD" if probe.origin == "working tree" else probe.origin
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
    and hold nothing now.

    Route 4: a probe that simply disappears only lowers a count nothing checks.
    Renames are not deletions -- git's own rename detection reports those as R --
    so this names files that were removed, which is the only way a probe can
    leave without a retirement."""
    rc, out, _ = git(root, "log", "--diff-filter=D", "--name-only",
                     "--format=C%H", "-n", str(HISTORY_LIMIT),
                     mine or "HEAD", "--", VERIFICATION_DIR + "*.py")
    if rc != 0:
        return []
    gone, commit = [], ""
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("C") and len(line) == 41:
            commit = line[1:]
            continue
        if os.path.exists(os.path.join(root, line)):
            continue                     # deleted once, present again now
        text = file_at(root, commit + "^", line)
        if text is None or not is_workspaces_probe(text):
            continue
        gone.append((line, commit))
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
    line could be edited in place and inherit somebody else's commit."""
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
    A3  that commit is contained in a local branch OTHER than the one under
        test -- a reviewer commits on its own branch and Rich lands it

Every retirement that is accepted prints its commit and its witnessing branch,
so what stood behind it is on the record rather than taken on trust.

RETIREMENT IS PER CASE. A reviewer who finds three of his six cases obsolete and
three still live retires the three, and the probe goes on running the other three:

    <probe filename>\t<case>\t<author>\t<why this one case is obsolete>

Keyed on the FILE, that reviewer's only options were to drop five green
assertions to buy one green exit code, or to write nothing. He wrote nothing, and
he was right to.

A PROBE ALSO NEVER LEAVES BY BEING DELETED. A path that used to hold a probe and
holds nothing now is MISSING, and MISSING blocks exactly like RED: deletion is
not attributable to anybody, which is the whole reason retirement is.

Everything else is a regression to fix.
===========================================================================
""" % RETIREMENTS


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

        probes, others = tree_probes(root)
        have = set(p.name for p in probes)
        if not args.tree_only:
            probes += branch_probes(root, have, stage)
        probes.sort(key=lambda p: (p.origin != "working tree", p.name))
        mine = head_branch(root)

        # THE DECLARATION IS SETTLED BEFORE ANYTHING IS COUNTED, and it is
        # settled against git. A file whose `not-a-probe:` marker STANDS leaves
        # the run and is named; a file whose marker is REFUSED stays a probe and
        # carries the refusal into its report line. Route 1 of four was that this
        # decision used to be made by reading the text.
        declared_out = []
        kept = []
        for pr in probes:
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
        probes = kept
        discovered = len(probes)
        in_tree = sum(1 for p in probes if p.origin == "working tree")
        if args.only:
            probes = [p for p in probes if any(o in p.name for o in args.only)]

        retired = retirements(root)

        # ROUTE 4: a probe that is GONE. Asked of git, not of the tree, because
        # the tree is exactly where a deleted probe is invisible. A probe its
        # author retired is not missing -- it left the documented way -- so the
        # retirement filter is applied HERE, before the count is printed. Printing
        # the unfiltered number would report a retired probe as a deletion, which
        # is a number that contradicts the verdict three lines below it.
        missing = [(q, c) for q, c in deleted_probes(root, mine)
                   if os.path.basename(q) not in retired]
        print("workspaces.py under test: %s" % lib)
        print("probes discovered:        %d (%d in the working tree, %d on other branches)%s"
              % (discovered, in_tree, discovered - in_tree,
                 "" if not args.only else
                 "  — %d selected by --only, SO THIS RUN PROVES NOTHING ABOUT THE REST"
                 % len(probes)))
        print("branch under test:        %s" % (mine or "(detached HEAD)"))
        print("declared not-a-probe:     %d (each named below; a declaration is checked "
              "against git, never read)" % len(declared_out))
        print("probes DELETED from history and not retired: %d" % len(missing))
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

        width = max([len(p.name) for p in probes] + [10])
        for p in probes:
            where = "" if p.origin == "working tree" else "   [%s]" % p.origin
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
            print("\n--- files under docs/verification/ that are not probes of this library ---")
            base = os.path.join(root, "docs", "verification")
            probe_paths = set(pr.name for pr in probes) | set(pr.name for pr in declared_out)
            named = 0
            for dirpath, _dn, fns in os.walk(base):
                for fn in sorted(fns):
                    if not fn.endswith(".py"):
                        continue
                    rel = os.path.relpath(os.path.join(dirpath, fn), root)
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
        gone = [(q, c) for q, c in missing
                if not args.only or any(o in q for o in args.only)]
        for q, c in gone:
            print("%-10s %s" % ("MISSING", q))
            print("           it held a probe of this library and was DELETED in %s. A probe "
                  "leaves by retirement, which is attributable, and never by deletion, which "
                  "is not. Restore it, or have its author retire it in %s."
                  % (c[:12], RETIREMENTS))
        if args.list:
            return 1 if gone else 0           # --list runs nothing and claims nothing

        print("")
        for p in red + stuck:
            print("=== %s — %s%s" % (p.verdict, p.name,
                                     "" if p.origin == "working tree" else "  [%s]" % p.origin))
            if p.detail:
                print("    %s" % p.detail)
            for line in (p.output or "").splitlines()[-25:]:
                print("    | %s" % line)
            print("")

        if red or stuck or gone:
            print(REFUSAL)
            if gone:
                print("DELETED (a probe that used to exist and does not):")
                for q, c in gone:
                    print("    %s   removed in %s" % (q, c[:12]))
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
