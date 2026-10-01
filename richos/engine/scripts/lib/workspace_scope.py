#!/usr/bin/env python3
"""workspace_scope.py — is this test run an engineer iterating in a workspace, or a full run?

THE DEFAULT, FLIPPED (CEO, 2026-10-01). An engineer iterating on one iPhone layout test ran
`native-ios-ui.test.sh` with no arguments seven times: each run was the whole UI suite on two
simulators, 828 s, about 100 minutes in all against about 2 for the one case on one device. The
scoping flags existed; narrowing depended on each agent remembering them, and briefs saying
"your test, run once" were not enough. So the runners narrow by themselves, and this module is
the one place that decides WHEN.

    workspace_scope.py decide <dir> [--full]
        Prints `key=value` lines, each value shell-quoted (bash reads them with `eval`):
          scope   full | narrow
          why     one sentence: what decided it
          branch  the checked-out branch ("" when detached)
          base    the merge base with main (narrow only)
          root    the checkout's top level
    workspace_scope.py fields <dir> [--full]
        The same decision as one line, `<scope>:<base>:<branch>`, for a shell that must not
        `eval` (ci-shard.sh: the engine's input qualifier refuses dynamic evaluation). Git
        forbids `:` in a branch name, and the branch is last, so `IFS=: read -r` is exact.
    workspace_scope.py changed <root> <base>
        Every path the working tree differs in from <base>, committed or not, plus untracked
        files; repository-relative, one per line.
    workspace_scope.py lines <root> <base> <path>
        The working tree's line numbers (1-based) that differ from <base> in <path>, one per
        line; every line of a file <base> does not have.
    workspace_scope.py inputs <suite-file>
        The suite's own `# run-tests: inputs` paths, one per line.

THE RULE, IN ORDER — the first that applies decides:
  1. `--full` (the runner's flag)                          -> full
  2. RICHOS_TEST_SCOPE=full|narrow in the environment       -> that. proof-run.py (the merge
     gate, Rich's land runs, the nightly's engine pass) and nightly-local.py's gates set
     `full`, so nothing they run is ever narrowed, whatever checkout they run in. Any other
     non-empty value is refused (exit 64): a typo must not quietly pick a scope.
  3. a linked git worktree on a `cc/` branch               -> narrow. That is a teammate
     workspace (`spawn.sh` and `create-teammate-worktree.sh` create exactly that); the main
     checkout, the nightly's checkout, a detached HEAD and any other branch are not.
  4. anything else                                          -> full.
A narrow decision needs the merge base with `main` (then `origin/main`); without one the run is
full and says why. Nothing here ever decides to run nothing: a runner that narrows and finds
no case refuses, naming the full command (its own business, not this module's).
"""
import os
import re
import shlex
import subprocess
import sys

ENV = "RICHOS_TEST_SCOPE"
WORKSPACE_BRANCH = "cc/"


def git(root, *args):
    out = subprocess.run(["git", "-C", root, *args], capture_output=True, text=True,
                         stdin=subprocess.DEVNULL)
    return out.stdout.strip() if out.returncode == 0 else None


def merge_base(root):
    for ref in ("main", "origin/main"):
        base = git(root, "merge-base", "HEAD", ref)
        if base:
            return base, ref
    return None, None


def decide(directory, full=False, environ=None):
    environ = os.environ if environ is None else environ
    root = git(directory, "rev-parse", "--show-toplevel") or ""
    branch = (git(directory, "symbolic-ref", "--short", "-q", "HEAD") or "") if root else ""
    result = {"scope": "full", "why": "", "branch": branch, "base": "", "root": root}
    if full:
        result["why"] = "--full was given"
        return result
    asked = environ.get(ENV, "")
    if asked and asked not in ("full", "narrow"):
        raise ValueError("%s=%r: it is full or narrow" % (ENV, asked))
    if asked == "full":
        result["why"] = "%s=full (a gate, a land, a nightly or the caller asked for everything)" % ENV
        return result
    if not root:
        result["why"] = "not a git checkout"
        return result
    if asked != "narrow":
        git_dir = git(directory, "rev-parse", "--absolute-git-dir")
        common = git(directory, "rev-parse", "--path-format=absolute", "--git-common-dir")
        linked = bool(git_dir and common) and os.path.realpath(git_dir) != os.path.realpath(common)
        if not branch.startswith(WORKSPACE_BRANCH):
            result["why"] = ("detached HEAD" if not branch else "branch %s is not a teammate workspace (cc/)" % branch)
            return result
        if not linked:
            result["why"] = "the main checkout, not a teammate workspace"
            return result
    base, ref = merge_base(root)
    if not base:
        result["why"] = "no merge base with main or origin/main, so nothing to narrow against"
        return result
    result.update(scope="narrow", base=base,
                  why=("%s=narrow" % ENV) if asked == "narrow"
                  else "teammate workspace %s, compared with %s at %s" % (branch, ref, base[:12]))
    return result


def changed(root, base):
    tracked = git(root, "diff", "--name-only", "--no-renames", base) or ""
    untracked = git(root, "ls-files", "--others", "--exclude-standard") or ""
    paths = {p.strip() for p in (tracked + "\n" + untracked).splitlines() if p.strip()}
    return sorted(paths)


HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def lines(root, base, path):
    """The working-tree lines of <path> that differ from <base>. A deletion touches the lines on
    either side of it, so a removed line inside a case still names that case."""
    if not os.path.exists(os.path.join(root, path)):
        return []
    if git(root, "cat-file", "-e", "%s:%s" % (base, path)) is None:
        with open(os.path.join(root, path), encoding="utf-8", errors="replace") as fh:
            return list(range(1, sum(1 for _ in fh) + 1))
    diff = subprocess.run(["git", "-C", root, "diff", "-U0", "--no-renames", "--no-color", base, "--", path],
                          capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
    touched = set()
    for row in diff.splitlines():
        m = HUNK.match(row)
        if not m:
            continue
        start, count = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
        if count == 0:
            touched.update(n for n in (start, start + 1) if n >= 1)
        else:
            touched.update(range(start, start + count))
    return sorted(touched)


def inputs(suite):
    with open(suite, encoding="utf-8") as fh:
        for row in fh:
            if row.startswith("# run-tests: inputs"):
                return row.split("inputs", 1)[1].split()
    return []


def claimed(path, declared):
    """Whether a repository-relative path is one of a suite's declared inputs (a file or a
    directory, as `run-tests.sh` digests them)."""
    return any(path == d or path.startswith(d.rstrip("/") + "/") for d in declared)


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 64
    cmd, rest = argv[0], argv[1:]
    try:
        if cmd == "decide" and rest:
            got = decide(rest[0], full="--full" in rest[1:])
            for key in ("scope", "why", "branch", "base", "root"):
                print("%s=%s" % (key, shlex.quote(got[key])))
            return 0
        if cmd == "fields" and rest:
            got = decide(rest[0], full="--full" in rest[1:])
            print("%s:%s:%s" % (got["scope"], got["base"], got["branch"]))
            return 0
        if cmd == "changed" and len(rest) == 2:
            print("\n".join(changed(*rest)))
            return 0
        if cmd == "lines" and len(rest) == 3:
            print("\n".join(str(n) for n in lines(*rest)))
            return 0
        if cmd == "inputs" and len(rest) == 1:
            print("\n".join(inputs(rest[0])))
            return 0
    except ValueError as exc:
        print("workspace_scope: %s" % exc, file=sys.stderr)
        return 64
    print("workspace_scope: usage: decide|fields <dir> [--full] | changed <root> <base> | "
          "lines <root> <base> <path> | inputs <suite>", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
