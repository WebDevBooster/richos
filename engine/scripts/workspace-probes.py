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
# WHAT MAY RETIRE A PROBE
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
#     <probe filename>\t<who retired it>\t<why>
#
# The runner checks that <who> is the probe's own author — the name the probe's
# path or docstring carries — and REFUSES a retirement signed by anyone else,
# naming both. A retirement is a reviewer's act recorded in the tree, not a flag
# on a command line, because a flag is invisible to the next round.
#
# WHAT COUNTS AS A PROBE HERE
# ---------------------------------------------------------------------------
# A probe of workspaces.py is a committed .py file under docs/verification/ that
# (a) names workspaces.py or workspaces.test.py, and (b) drives at least one of
# the library's own entry points. That is a structural test, so a new probe is
# discovered by being committed and by nothing else — no registration step, no
# list to keep in step.
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
DRIVES = ("spec_from_file_location", "exec_module", "import workspaces",
          "barrier", "observe_created_refs", "register_spawn", "register_cc",
          "record_start", "record_end", "bind_agent", "integration_target",
          "integration_for", "record_integration", "load_agent", "snapshot_refs",
          "named_key", "all_integration_records")

RETIREMENTS = "docs/verification/workspace-probe-retirements.tsv"

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
        self.verdict = ""         # GREEN / RED / UNRUNNABLE / RETIRED
        self.detail = ""
        self.seconds = 0.0
        self.output = ""


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
    --show-all, so an exemption is visible rather than silent."""
    if NOT_A_PROBE.search(text):
        return False
    if "workspaces.py" not in text and "workspaces.test.py" not in text:
        return False
    return any(e in text for e in DRIVES)


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


def retirements(root):
    """{probe basename: (who, why)} — written and committed by the reviewer."""
    path = os.path.join(root, RETIREMENTS)
    out = {}
    if not os.path.exists(path):
        return out
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        out[os.path.basename(parts[0].strip())] = (parts[1].strip(), parts[2].strip())
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
            for sc in probe.cases:
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
                                % len(probe.cases))
            else:
                probe.verdict = "RED"
                probe.detail = "a scenario failed to run: exit %d" % rc
            return
        if probe.shape == "argv":
            rc, out, err = sh(sys.executable, "-B", probe.path, lib,
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
        discovered = len(probes)
        in_tree = sum(1 for p in probes if p.origin == "working tree")
        if args.only:
            probes = [p for p in probes if any(o in p.name for o in args.only)]

        retired = retirements(root)
        print("workspaces.py under test: %s" % lib)
        print("probes discovered:        %d (%d in the working tree, %d on other branches)%s"
              % (discovered, in_tree, discovered - in_tree,
                 "" if not args.only else
                 "  — %d selected by --only, SO THIS RUN PROVES NOTHING ABOUT THE REST"
                 % len(probes)))
        print("other files under docs/verification/ that are not probes of this library: %d%s"
              % (others, "" if args.show_all else "  (--show-all names them)"))
        print("")

        for p in probes:
            base = os.path.basename(p.name)
            if base in retired:
                who, why = retired[base]
                if who.lower() != p.author:
                    p.verdict = "UNRUNNABLE"
                    p.detail = ("its retirement is signed '%s' but the probe's author is '%s'. "
                                "Only a probe's own author may retire it." % (who, p.author))
                else:
                    p.verdict = "RETIRED"
                    p.detail = "%s: %s" % (who, why)
                continue
            if args.list:
                p.verdict = "(not run)"
                p.detail = "shape=%s author=%s cases=%d" % (p.shape, p.author, len(p.cases))
                continue
            run_probe(root, lib, p, args.timeout)

        width = max([len(p.name) for p in probes] + [10])
        for p in probes:
            where = "" if p.origin == "working tree" else "   [%s]" % p.origin
            print("%-10s %-*s %6.1fs%s" % (p.verdict, width, p.name, p.seconds, where))
            if p.detail:
                print("           %s" % p.detail)

        if args.show_all:
            print("\n--- files under docs/verification/ that are not probes of this library ---")
            base = os.path.join(root, "docs", "verification")
            for dirpath, _dn, fns in os.walk(base):
                for fn in sorted(fns):
                    if not fn.endswith(".py"):
                        continue
                    rel = os.path.relpath(os.path.join(dirpath, fn), root)
                    if rel not in have:
                        continue
                    if any(pr.name == rel for pr in probes):
                        continue
                    print("    %s" % rel)

        red = [p for p in probes if p.verdict == "RED"]
        stuck = [p for p in probes if p.verdict == "UNRUNNABLE"]
        if args.list:
            return 0                          # --list runs nothing and claims nothing

        print("")
        for p in red + stuck:
            print("=== %s — %s%s" % (p.verdict, p.name,
                                     "" if p.origin == "working tree" else "  [%s]" % p.origin))
            if p.detail:
                print("    %s" % p.detail)
            for line in (p.output or "").splitlines()[-25:]:
                print("    | %s" % line)
            print("")

        if red or stuck:
            print(REFUSAL)
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
