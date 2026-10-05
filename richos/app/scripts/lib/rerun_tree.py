#!/usr/bin/env python3
"""rerun_tree.py: A RERUN RUNS ON THE TREE THE CHECK RAN ON, NOT ON WHATEVER THE CHECKOUT HOLDS NOW.

THE FAILURE (2026-10-05). proof-run.py writes <run>/rerun/<nn>-<check>.sh for every check
(d789e80f3): its directory, its whole environment and its command. The directory was the
checkout the check ran in, by path. The merge gate runs in the main checkout WHILE the merge is
in progress, and a refused merge is then aborted, so that checkout is back on main and no longer
holds the merged tree. A front-door.js A1 failure (attempt-ioj6a1_a) "passed" its rerun on main
and proved nothing: the rerun tested main, not the code that failed.

WHAT THIS DOES.
  capture(path)   when a run starts: the tree the checkout at `path` holds, as git would commit
                  it (a scratch copy of its index, `git add -A`, `git write-tree`: the tracked
                  changes and every untracked file git does not ignore), with HEAD and MERGE_HEAD.
                  Nothing in the checkout or its real index is changed; the tree's objects are
                  written to the repository's object store, so they outlive an aborted merge.
  main()          what the rerun file runs. When the checkout still holds that tree, the check
                  runs there, as before. When it does not, the tree is checked out in a scratch
                  git worktree of the same repository (HEAD at the recorded HEAD, index and files
                  at the recorded tree, MERGE_HEAD as it was: the merge gate's own state), the
                  checkout's path is replaced by the scratch one in the command and its
                  environment, the check runs there, and the scratch worktree is removed however
                  the run ends. Dependency installs git ignores (node_modules) are linked in from
                  the checkout, never copied or installed. Which of the two it did is said on
                  stderr, with the tree.

Standard library only: the rerun file runs a copy of this file kept beside it in the run's
evidence, so a rerun never depends on what the checkout holds later.
"""
import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile

INSTALLED_DEPENDENCY_DIRECTORIES = ("node_modules",)   # proof_evidence.py's list of what an install is


def _env(extra=None):
    """The caller's environment without git's own variables (a hook's GIT_INDEX_FILE or GIT_DIR
    would point every command here at the gate's checkout), plus `extra`."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(extra or {})
    return env


def _git(cwd, *args, extra=None, check=True):
    r = subprocess.run(["git", "-C", cwd, *args], env=_env(extra), stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=600)
    if check and r.returncode != 0:
        raise ValueError("git %s failed in %s: %s" % (" ".join(args[:3]), cwd, (r.stderr or r.stdout).strip()[:300]))
    return r


def capture(path):
    """{"root", "tree", "head", "merge_head"} for the checkout holding `path`. Raises ValueError."""
    root = _git(path, "rev-parse", "--show-toplevel").stdout.strip()
    index = _git(root, "rev-parse", "--path-format=absolute", "--git-path", "index").stdout.strip()
    fd, scratch = tempfile.mkstemp(prefix="rerun-tree-index-")
    os.close(fd)
    try:
        if os.path.isfile(index):
            shutil.copyfile(index, scratch)    # its stat cache: only what changed is hashed
        else:
            os.unlink(scratch)
        _git(root, "add", "-A", extra={"GIT_INDEX_FILE": scratch})
        tree = _git(root, "write-tree", extra={"GIT_INDEX_FILE": scratch}).stdout.strip()
    finally:
        try:
            os.unlink(scratch)
        except OSError:
            pass
    head = _git(root, "rev-parse", "-q", "--verify", "HEAD", check=False).stdout.strip()
    merge = _git(root, "rev-parse", "-q", "--verify", "MERGE_HEAD", check=False).stdout.strip()
    return {"root": os.path.realpath(root), "tree": tree, "head": head, "merge_head": merge}


def rewrite(word, old, new):
    """`word` with the checkout's path replaced by the scratch one, where it is the path itself
    or a prefix of one (`/x/richos` in `/x/richos/a` and `K=/x/richos:y`, never `/x/richos-wt`)."""
    return re.sub(re.escape(old) + r"(?=/|:|$)", lambda _m: new, word)


def _link_installs(root, dest):
    r = _git(root, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z", check=False)
    for raw in (r.stdout or "").split("\0"):
        name = raw.rstrip("/")
        if not name or os.path.basename(name) not in INSTALLED_DEPENDENCY_DIRECTORIES:
            continue
        src, dst = os.path.join(root, name), os.path.join(dest, name)
        if os.path.isdir(src) and os.path.isdir(os.path.dirname(dst)) and not os.path.lexists(dst):
            os.symlink(src, dst)


def _say(text):
    sys.stderr.write("rerun: %s\n" % text)
    sys.stderr.flush()


def main(argv):
    ap = argparse.ArgumentParser(prog="rerun_tree.py")
    ap.add_argument("--root", required=True)
    ap.add_argument("--tree", required=True)
    ap.add_argument("--head", default="")
    ap.add_argument("--merge-head", default="")
    ap.add_argument("--cwd", required=True, help="the check's directory, relative to --root")
    ap.add_argument("command", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    command = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not command:
        ap.error("no command after --")
    try:
        now = capture(a.root)["tree"]
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        now = "unknown (%s)" % exc
    if now == a.tree:
        _say("%s holds the tree the check ran on (%s): running it there" % (a.root, a.tree))
        return subprocess.call(command, cwd=os.path.join(a.root, a.cwd))
    if not a.head:
        _say("REFUSED: %s no longer holds the tree the check ran on (%s; it holds %s), and no HEAD was "
             "recorded to check that tree out on" % (a.root, a.tree, now))
        return 2
    scratch = tempfile.mkdtemp(prefix="richos-rerun-tree-")
    dest = os.path.join(scratch, os.path.basename(a.root.rstrip("/")) or "checkout")
    added = False

    def _ended(signum, _frame):
        raise SystemExit(128 + signum)
    previous = {s: signal.signal(s, _ended) for s in (signal.SIGTERM, signal.SIGHUP)}
    try:
        _git(a.root, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach", "--no-checkout", dest, a.head)
        added = True
        _git(dest, "read-tree", "--reset", "-u", a.tree)
        if a.merge_head:
            path = _git(dest, "rev-parse", "--path-format=absolute", "--git-path", "MERGE_HEAD").stdout.strip()
            with open(path, "w") as fh:
                fh.write(a.merge_head + "\n")
        _link_installs(a.root, dest)
        _say("%s no longer holds the tree the check ran on (%s; it holds %s): running it in a scratch "
             "checkout of that tree, %s (HEAD %s%s), removed afterwards" % (
                 a.root, a.tree, now, dest, a.head[:12], ", merging %s" % a.merge_head[:12] if a.merge_head else ""))
        return subprocess.call([rewrite(w, a.root, dest) for w in command], cwd=os.path.join(dest, a.cwd))
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        _say("REFUSED: the tree the check ran on (%s) could not be checked out: %s" % (a.tree, exc))
        return 2
    finally:
        for s, h in previous.items():
            signal.signal(s, h)
        if added:
            # Only its own entry: never a repository-wide prune, which would erase other
            # worktrees' registrations that the workspace registry reads as evidence.
            _git(a.root, "worktree", "remove", "--force", "--force", dest, check=False)
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
